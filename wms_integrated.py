# -*- coding: utf-8 -*-
"""
WMS 对话式生产领料出库 + 后台仓储任务监控
============================================================
功能：
1. CMD 输入物料名称和数量
2. 模糊匹配 Material/Search，人工确认物料
3. 自动换算包装规格对应的计划出库重量
4. StockOut/AddOrUpdate 创建出库单
5. StockOut/List 查询并识别新建 StockOutId
6. StockOut/AddOrUpdateD 添加出库明细
7. StockOut/Auditin 尝试自动审核
8. 自动审核失败时，允许人工审核后继续
9. StockOut/AllotAll 自动分配至四层拆垛口4
10. Task/List 查询近期仓储任务

已观察到的接口：
    GET  /Material/Search?text=胆碱
    POST /StockOut/AddOrUpdate
    POST /StockOut/AddOrUpdateD
    POST /StockOut/List
    GET  /StockOut/Auditin?id=<StockOutId>
    GET  /StockOut/AllotAll?id=<StockOutId>&outStation=4
    POST /Task/List（查询参数仍需按实际抓包核对）

重要说明：
- 创建、明细、审核、分配均会影响生产业务数据。
- 写操作失败后不自动重试。
- 自动审核失败时不会自动分配。
- 单据状态值 1、2、5 是根据目前提供的记录推断的，
  需要结合实际 WMS 页面核实。
- Task/List 的查询参数可能需要按当前系统调整。
============================================================
安装：
    python -m pip install requests

运行：
    python wms_integrated.py

首次使用前编辑同目录 wms_config.json 配置账号密码（无需每次启动输入）。
"""

import json
import re
import sys
import time
import os
import threading
from pathlib import Path

from datetime import datetime, timedelta
from decimal import Decimal, InvalidOperation
from difflib import SequenceMatcher

import requests


# ============================================================
# 本地配置：默认读取同目录 wms_config.json，也可用环境变量覆盖
# ============================================================
CONFIG_FILE = Path(__file__).resolve().parent / "wms_config.json"

def load_local_config():
    if not CONFIG_FILE.exists():
        return {}
    try:
        with CONFIG_FILE.open("r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception as exc:
        print(f"配置文件读取失败：{exc}")
        return {}

LOCAL_CONFIG = load_local_config()
WMS_USERNAME = os.environ.get("WMS_USERNAME", str(LOCAL_CONFIG.get("username", "admin"))).strip() or "admin"
WMS_PASSWORD = os.environ.get("WMS_PASSWORD", str(LOCAL_CONFIG.get("password", "")))
BARK_URL = os.environ.get("WMS_BARK_URL", str(LOCAL_CONFIG.get("bark_url", ""))).strip()


# ============================================================
# 一、基础配置
# ============================================================

BASE_URL = "http://127.0.0.1"

LOGIN_PAGE_URL = BASE_URL + "/Login/Index"
LOGIN_API_URL = BASE_URL + "/Login/CheckLoginAsync"

MATERIAL_SEARCH_URL = BASE_URL + "/Material/Search"

STOCKOUT_LIST_URL = BASE_URL + "/StockOut/List"
STOCKOUT_ADD_URL = BASE_URL + "/StockOut/AddOrUpdate"
STOCKOUT_DETAIL_ADD_URL = BASE_URL + "/StockOut/AddOrUpdateD"
STOCKOUT_AUDIT_URL = BASE_URL + "/StockOut/Auditin"
STOCKOUT_ALLOT_URL = BASE_URL + "/StockOut/AllotAll"

TASK_LIST_URL = BASE_URL + "/Task/List"

# 已由你提供的抓包确认：成品出库单
STOCKOUT_TYPE_ID = "503753018307510272"
STOCKOUT_TYPE_NAME = "成品出库单"

# 已验证的出口参数
OUT_STATION = 4
OUT_STATION_NAME = "四层拆垛口4"

# 已观察到的生产领料任务类型
TARGET_TASK_TYPE = 13

REQUEST_TIMEOUT = 20

# StockOut/List 查询范围
LIST_LIMIT = 100
LIST_LOOKBACK_DAYS = 120

# 根据你当前 WMS 的记录推断：
# 1 = 待审核
# 2 = 已审核、尚未分配
# 5 = 已分配后的状态
#
# 请以你当前 WMS 页面实际状态为准。
STATUS_PENDING_AUDIT = 1
STATUS_AUDITED = 2
STATUS_ALLOTTED = 5

# 业务接口响应的成功标志
SUCCESS_KEY = "Item1"
SUCCESS_MESSAGE_KEY = "Item2"


# ============================================================
# 二、通用工具
# ============================================================

def title(text):
    print("\n" + "=" * 68)
    print(text)
    print("=" * 68)


def fmt_decimal(value):
    """Decimal 格式化，避免出现不必要的尾随零。"""
    value = Decimal(value)
    text = format(value, "f")

    if "." in text:
        text = text.rstrip("0").rstrip(".")

    return text or "0"


def parse_json_response(response):
    """
    解析 JSON 响应。

    禁止把重定向后的 HTML 错误页当成成功。
    """

    if 300 <= response.status_code < 400:
        raise RuntimeError(
            "服务器返回重定向："
            + str(response.headers.get("Location", ""))
        )

    response.raise_for_status()

    try:
        return response.json()
    except ValueError as exc:
        raise RuntimeError(
            "接口没有返回有效 JSON。响应正文前 500 字符：\n"
            + response.text[:500]
        ) from exc


def is_business_success(data):
    """
    已观察到的成功响应：
    {"Item1": true, "Item2": "操作成功"}
    """

    if not isinstance(data, dict):
        return False

    value = data.get(SUCCESS_KEY)

    return (
        value is True
        or str(value).strip().lower() in ("true", "1")
    )


def extract_rows(data):
    """兼容列表、{rows: [...]} 和单条记录响应。"""

    if isinstance(data, list):
        return [x for x in data if isinstance(x, dict)]

    if not isinstance(data, dict):
        return []

    rows = data.get("rows")

    if isinstance(rows, list):
        return [x for x in rows if isinstance(x, dict)]

    if any(
        key in data
        for key in ("MaterialId", "StockOutId", "TaskMainId")
    ):
        return [data]

    return []


def safe_post_json(session, url, payload, referer=None):
    """
    POST JSON/form 接口的统一请求入口。

    注意：payload 使用表单提交，而不是 JSON，
    因为你抓取到的 WMS 写操作使用
    application/x-www-form-urlencoded。
    """

    headers = {
        "Accept": "application/json, text/plain, */*",
    }

    if referer:
        headers["Referer"] = referer

    response = session.post(
        url,
        data=payload,
        headers=headers,
        timeout=REQUEST_TIMEOUT,
        allow_redirects=False,
    )

    return parse_json_response(response)


# ============================================================
# 三、登录与会话验证
# ============================================================

def login(session, username, password):
    """
    使用此前脚本采用的登录接口。

    如果你现有的稳定版本使用了不同的登录字段或接口，
    请保留原版本已经验证成功的 login() 实现。
    """

    print("正在连接 WMS：", BASE_URL)

    try:
        page = session.get(
            LOGIN_PAGE_URL,
            timeout=REQUEST_TIMEOUT,
        )

        print("登录页面 HTTP 状态码：", page.status_code)

        response = session.post(
            LOGIN_API_URL,
            json={
                "UserName": username,
                "Password": password,
            },
            headers={
                "Accept": "application/json, text/plain, */*",
                "Referer": LOGIN_PAGE_URL,
            },
            timeout=REQUEST_TIMEOUT,
        )

        print("登录请求 HTTP 状态码：", response.status_code)
        print("登录请求已提交，接下来验证会话。")

        return response.status_code == 200

    except requests.RequestException as exc:
        print("登录网络异常：", exc)
        return False


def verify_session(session):
    """通过已验证的物料查询检查登录会话。"""

    print("正在验证 WMS 会话……")

    try:
        response = session.get(
            MATERIAL_SEARCH_URL,
            params={"text": "胆碱"},
            headers={
                "Accept": "application/json, text/plain, */*",
                "Referer": BASE_URL + "/StockOut",
            },
            timeout=REQUEST_TIMEOUT,
            allow_redirects=False,
        )

        data = parse_json_response(response)
        rows = extract_rows(data)

        print(
            f"会话验证成功，物料查询返回 {len(rows)} 条。"
        )

        return True

    except Exception as exc:
        print("会话验证失败：", exc)
        return False


# ============================================================
# 四、物料搜索与模糊匹配
# ============================================================

def normalize_text(text):
    return re.sub(r"\s+", "", str(text or "")).lower()


def similarity_score(query, material_name):
    """
    仅用于排序，不会自动选中物料。

    如果输入名称包含在标准名称中，给出较高参考分，
    但仍要求用户人工选择。
    """

    q = normalize_text(query)
    n = normalize_text(material_name)

    if not q or not n:
        return 0.0

    if q == n:
        return 1.0

    if q in n:
        return 0.96

    if n in q:
        return 0.90

    return SequenceMatcher(None, q, n).ratio()


def search_materials(session, keyword):
    response = session.get(
        MATERIAL_SEARCH_URL,
        params={"text": keyword},
        headers={
            "Accept": "application/json, text/plain, */*",
            "Referer": BASE_URL + "/StockOut",
        },
        timeout=REQUEST_TIMEOUT,
        allow_redirects=False,
    )

    data = parse_json_response(response)
    rows = extract_rows(data)

    ranked = []

    for material in rows:
        name = material.get("MaterialName", "")

        if not name:
            continue

        score = similarity_score(keyword, name)
        ranked.append((score, material))

    ranked.sort(key=lambda x: x[0], reverse=True)

    return ranked


def material_description(material):
    return (
        f"名称={material.get('MaterialName', '-')}"
        f" | 编码={material.get('MaterialNo', '-')}"
        f" | 规格={material.get('Specification', '-')}"
        f" | 单位={material.get('Unit', '-')}"
        f" | MaterialId={material.get('MaterialId', '-')}"
        f" | IsDel={material.get('IsDel', '-')}"
    )


def select_material(session, keyword):
    print(f'\n正在搜索物料："{keyword}"')

    try:
        candidates = search_materials(session, keyword)
    except Exception as exc:
        print("物料查询失败：", exc)
        return None

    if not candidates:
        print("没有查到候选物料。请换一个关键词重新输入。")
        return None

    candidates = candidates[:10]

    print(f'\n物料“{keyword}”的候选项：')

    for index, (score, material) in enumerate(candidates, start=1):
        print(
            f"[{index}] 匹配分={score:.3f} | "
            + material_description(material)
        )

    print("[0] 取消")

    while True:
        choice = input("请选择物料序号：").strip()

        if choice == "0":
            return None

        if not choice.isdigit():
            print("请输入有效序号。")
            continue

        index = int(choice)

        if index < 1 or index > len(candidates):
            print("序号超出范围。")
            continue

        material = candidates[index - 1][1]

        print("\n已选择物料：")
        print(material_description(material))
        if str(material.get("IsDel", "")) == "1":
            print("警告：该物料 IsDel=1，请在最终确认前核对其是否允许出库。")
        return material


# ============================================================
# 五、对话文本解析
# ============================================================

UNIT_PATTERN = (
    r"公斤|千克|kg|克|g|包|袋|桶|件|个|瓶|吨|t"
)

PATTERN_NAME_THEN_QUANTITY = re.compile(
    rf"^(?P<name>.+?)\s*"
    rf"(?P<qty>\d+(?:\.\d+)?)\s*"
    rf"(?P<unit>{UNIT_PATTERN})$",
    re.IGNORECASE,
)

PATTERN_QUANTITY_THEN_NAME = re.compile(
    rf"^(?P<qty>\d+(?:\.\d+)?)\s*"
    rf"(?P<unit>{UNIT_PATTERN})\s*"
    rf"(?P<name>.+)$",
    re.IGNORECASE,
)


def parse_requirement_text(text):
    """
    支持示例：

        盐酸盐 500kg
        胆碱 150kg，再领20包硫酸盐
        150公斤胆碱
        1 吨 乳清粉
        20包甜饲粉

    数量单位：
        kg、公斤、千克、克、g、吨、t、
        包、袋、桶、件、个、瓶

    不支持任意复杂的自然语言语义推断。
    """

    text = text.strip()

    # 将“再领”“另领”等词当作分隔符。
    segments = re.split(
        r"[，,；;\n]+|再领|另领|再来|并领|同时领",
        text,
    )

    requirements = []

    for segment in segments:
        segment = segment.strip()

        if not segment:
            continue

        match = PATTERN_NAME_THEN_QUANTITY.match(segment)

        if not match:
            match = PATTERN_QUANTITY_THEN_NAME.match(segment)

        if not match:
            raise ValueError(
                f"无法识别这一段：{segment}\n"
                "请使用“物料名 数量单位”的格式，例如："
                "胆碱 150kg，再领20包硫酸盐"
            )

        name = match.group("name").strip()
        qty_text = match.group("qty")
        unit = match.group("unit").strip().lower()

        try:
            quantity = Decimal(qty_text)
        except InvalidOperation as exc:
            raise ValueError(
                f"数量格式错误：{qty_text}"
            ) from exc

        if quantity <= 0:
            raise ValueError("数量必须大于 0。")

        if not name:
            raise ValueError("物料名称不能为空。")

        requirements.append({
            "query_name": name,
            "quantity": quantity,
            "input_unit": unit,
        })

    if not requirements:
        raise ValueError("没有识别到有效的领料需求。")

    return requirements


# ============================================================
# 六、将输入数量换算为 PlanOutWeight
# ============================================================

WEIGHT_UNITS = {
    "kg": "kg",
    "公斤": "kg",
    "千克": "kg",
    "g": "g",
    "克": "g",
    "吨": "t",
    "t": "t",
}

PACKAGE_UNITS = {
    "包",
    "袋",
    "桶",
    "件",
    "个",
    "瓶",
}


def specification_weight_kg(specification):
    """
    从规格字段提取重量，例如：
        25Kg
        25 kg
        25Kg/包

    若规格不是可识别的重量格式，则返回 None。
    """

    text = str(specification or "")

    match = re.search(
        r"(\d+(?:\.\d+)?)\s*(kg|公斤|千克|克|g)",
        text,
        re.IGNORECASE,
    )

    if not match:
        return None

    try:
        value = Decimal(match.group(1))
    except InvalidOperation:
        return None

    unit = match.group(2).lower()

    if unit in ("g", "克"):
        return value / Decimal("1000")

    return value


def calculate_plan_weight(requirement, material):
    """
    WMS 明细接口使用 PlanOutWeight。

    规则：
    1. 用户输入 kg、公斤、千克：直接作为计划重量。
    2. 用户输入 g、克：换算成 kg。
    3. 用户输入吨、t：换算成 kg。
    4. 用户输入包、袋、桶、件等：
       只有在物料单位匹配、规格可提取重量时才进行换算。
    5. 无法可靠换算时拒绝写入，不猜测数量规则。
    """

    quantity = requirement["quantity"]
    input_unit = requirement["input_unit"]

    if input_unit in ("kg", "公斤", "千克"):
        weight_kg = quantity

    elif input_unit in ("g", "克"):
        weight_kg = quantity / Decimal("1000")

    elif input_unit in ("吨", "t"):
        weight_kg = quantity * Decimal("1000")

    elif input_unit in PACKAGE_UNITS:
        material_unit = str(material.get("Unit", "")).strip()

        if material_unit != input_unit:
            raise ValueError(
                f"输入单位“{input_unit}”与 WMS 物料单位"
                f"“{material_unit}”不一致，无法可靠换算。"
            )

        per_package_kg = specification_weight_kg(
            material.get("Specification")
        )

        if per_package_kg is None or per_package_kg <= 0:
            raise ValueError(
                f"物料规格“{material.get('Specification', '')}”"
                "未能提取出每包装重量，不能自动换算。"
            )

        weight_kg = quantity * per_package_kg

    else:
        raise ValueError(
            f"不支持的数量单位：{input_unit}"
        )

    if weight_kg <= 0:
        raise ValueError("计划出库重量必须大于 0。")

    return weight_kg


# ============================================================
# 七、StockOut/List 查询
# ============================================================

def get_stockout_list(session):
    now = datetime.now()

    payload = {
        "limit": LIST_LIMIT,
        "offset": 0,
        "sort": "CreateDate",
        "order": "desc",
        "search": "",
        "datemin": (
            now - timedelta(days=LIST_LOOKBACK_DAYS)
        ).strftime("%Y-%m-%d"),
        "datemax": (
            now + timedelta(days=2)
        ).strftime("%Y-%m-%d"),
        "StockOutStatus": "",
        "StockOutType": "",
    }

    data = safe_post_json(
        session,
        STOCKOUT_LIST_URL,
        payload,
        referer=BASE_URL + "/StockOut",
    )

    if not isinstance(data, dict):
        raise RuntimeError("StockOut/List 返回格式异常。")

    rows = data.get("rows")

    if not isinstance(rows, list):
        raise RuntimeError(
            "StockOut/List 没有返回 rows 数组。"
        )

    return [row for row in rows if isinstance(row, dict)]


def find_stockout_by_id(session, stockout_id):
    rows = get_stockout_list(session)

    for row in rows:
        if str(row.get("StockOutId")) == str(stockout_id):
            return row

    return None


def get_status(row):
    try:
        return int(row.get("StockOutStatus"))
    except (TypeError, ValueError, AttributeError):
        return None


def find_new_stockout(session, old_ids, attempts=5):
    """
    AddOrUpdate 成功响应不包含主表 ID 时，
    通过创建前后 StockOut/List 的 ID 差异查找新单据。

    如果发现多张新单据，则停止，不擅自选取。
    """

    for attempt in range(attempts):
        rows = get_stockout_list(session)

        new_rows = [
            row for row in rows
            if str(row.get("StockOutId", "")) not in old_ids
            and str(row.get("StockOutTypeId", ""))
                == STOCKOUT_TYPE_ID
        ]

        if len(new_rows) == 1:
            return new_rows[0]

        if len(new_rows) > 1:
            raise RuntimeError(
                "检测到多张新增出库单，无法唯一确定主表 ID。"
                "请人工检查 WMS 页面，程序不会继续写入。"
            )

        if attempt < attempts - 1:
            time.sleep(1)

    return None


# ============================================================
# 八、创建出库单主表
# ============================================================

def create_stockout(session):
    title("创建成品出库单")

    # 在创建前读取已有单据 ID，用于识别新建记录。
    before_rows = get_stockout_list(session)

    old_ids = {
        str(row.get("StockOutId", ""))
        for row in before_rows
    }

    payload = {
        "id": "0",
        "CustomerId": "",
        "StockOutType": STOCKOUT_TYPE_ID,
        "OrderNo": "",
        "Remark": "",
    }

    print("正在提交 StockOut/AddOrUpdate……")

    try:
        data = safe_post_json(
            session,
            STOCKOUT_ADD_URL,
            payload,
            referer=BASE_URL + "/StockOut",
        )

    except Exception as exc:
        print("主表创建响应异常：", exc)
        print(
            "正在只读查询是否已经创建成功，"
            "不会重复提交创建请求。"
        )

        try:
            row = find_new_stockout(session, old_ids)
        except Exception:
            row = None

        if row:
            print(
                "通过列表差异找到了新增单据：",
                row.get("StockOutNo"),
                row.get("StockOutId"),
            )
            return row

        raise RuntimeError(
            "主表创建结果无法确认。"
            "请检查 WMS 页面，不要直接重新提交。"
        ) from exc

    print(
        "主表接口响应：",
        json.dumps(data, ensure_ascii=False)
    )

    if not is_business_success(data):
        raise RuntimeError(
            f"WMS 未确认主表创建成功：{data!r}"
        )

    row = find_new_stockout(session, old_ids)

    if row is None:
        raise RuntimeError(
            "主表接口返回成功，但列表中未能唯一找到新单据。"
            "请人工查询 WMS，不要重新创建。"
        )

    print("\n主表创建成功。")
    print("出库单号：", row.get("StockOutNo"))
    print("StockOutId：", row.get("StockOutId"))
    print("当前状态值：", row.get("StockOutStatus"))

    return row


# ============================================================
# 九、添加出库明细
# ============================================================

def add_stockout_detail(session, stockout_id, item):
    material = item["material"]

    payload = {
        "id": "0",
        "StockOutId": str(stockout_id),
        "MaterialId": str(material.get("MaterialId")),
        "PlanOutWeight": fmt_decimal(item["plan_weight_kg"]),
        "Batch": "",
        "Remark": "",
    }

    print(
        f"\n正在添加明细：{material.get('MaterialName')}，"
        f"{fmt_decimal(item['plan_weight_kg'])} kg"
    )

    data = safe_post_json(
        session,
        STOCKOUT_DETAIL_ADD_URL,
        payload,
        referer=BASE_URL + "/StockOut",
    )

    print(
        "明细接口响应：",
        json.dumps(data, ensure_ascii=False)
    )

    if not is_business_success(data):
        raise RuntimeError(
            f"明细添加未获业务成功确认：{data!r}"
        )

    print("明细添加成功。")


# ============================================================
# 十、审核接口
# ============================================================

def audit_stockout_once(session, stockout_id):
    """
    单次审核尝试。

    已观察到的请求形式：
        GET /StockOut/Audit?id=<StockOutId>

    不自动跟随重定向，不自动重试。
    """

    headers = {
        "Accept": "application/json, text/plain, */*",
        "Referer": BASE_URL + "/StockOut",
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0"
        ),
    }

    print("\n正在尝试自动审核：", stockout_id)

    response = session.get(
        STOCKOUT_AUDIT_URL,
        params={"id": str(stockout_id)},
        headers=headers,
        timeout=REQUEST_TIMEOUT,
        allow_redirects=False,
    )

    print("审核请求 URL：", response.request.url)
    print("HTTP 状态码：", response.status_code)
    print(
        "Content-Type：",
        response.headers.get("Content-Type", "")
    )
    print(
        "Location：",
        response.headers.get("Location", "(无)")
    )

    if 300 <= response.status_code < 400:
        raise RuntimeError(
            "审核请求被重定向："
            + str(response.headers.get("Location", ""))
        )

    result = parse_json_response(response)

    print(
        "审核响应：",
        json.dumps(result, ensure_ascii=False)
    )

    if not is_business_success(result):
        raise RuntimeError(
            f"WMS 未确认审核成功：{result!r}"
        )

    return result


def wait_for_stockout_status(
    session,
    stockout_id,
    expected_statuses,
    attempts=6,
    interval=2,
):
    """
    只读轮询 StockOut/List，不重复执行写操作。
    """

    for attempt in range(attempts):
        row = find_stockout_by_id(session, stockout_id)

        if row:
            status = get_status(row)

            if status in expected_statuses:
                return row

        if attempt < attempts - 1:
            time.sleep(interval)

    return None


def ensure_stockout_audited(session, stockout_id):
    """
    先尝试自动审核。

    若审核接口异常：
    1. 先查询实际状态。
    2. 如果已审核，继续。
    3. 如果仍待审核，暂停，等待用户在 WMS 页面人工审核。
    4. 只在列表状态确认已审核后继续。
    """

    title("审核出库单")

    current = find_stockout_by_id(session, stockout_id)

    if not current:
        raise RuntimeError(
            "无法查询刚创建的出库单，停止审核和分配。"
        )

    status = get_status(current)

    print("当前出库单号：", current.get("StockOutNo"))
    print("当前状态值：", status)

    if status == STATUS_ALLOTTED:
        print("该单据状态显示已分配，不再执行审核或分配。")
        return "already_allotted"

    if status == STATUS_AUDITED:
        print("列表显示该单据已审核，跳过审核请求。")
        return "audited"

    if status != STATUS_PENDING_AUDIT:
        raise RuntimeError(
            f"单据状态为 {status}，"
            "不符合已确认的待审核状态，停止后续写操作。"
        )

    try:
        audit_stockout_once(session, stockout_id)

    except Exception as exc:
        print("\n自动审核未能确认成功：", exc)

    # 不管接口响应如何，都先查询真实状态。
    verified = wait_for_stockout_status(
        session,
        stockout_id,
        {
            STATUS_AUDITED,
            STATUS_ALLOTTED,
        },
    )

    if verified:
        status = get_status(verified)

        if status == STATUS_ALLOTTED:
            print("列表显示单据已经分配，不重复执行。")
            return "already_allotted"

        if status == STATUS_AUDITED:
            print("列表已确认审核完成。")
            return "audited"

    # 自动审核未确认，并且列表仍未显示审核成功。
    latest = find_stockout_by_id(session, stockout_id)

    if not latest:
        raise RuntimeError(
            "无法再次查询单据状态，停止后续操作。"
        )

    status = get_status(latest)

    if status != STATUS_PENDING_AUDIT:
        raise RuntimeError(
            f"审核后状态无法确认：{status}。"
            "请在 WMS 页面核对，不执行自动分配。"
        )

    print("\n自动审核尚未成功确认。")
    print("请在浏览器 WMS 页面进行以下操作：")
    print("1. 打开刚创建的出库单。")
    print("2. 确认明细、数量、重量无误。")
    print("3. 点击审核。")
    print("4. 确认页面已显示审核成功。")

    choice = input(
        "\n人工审核完成后按 Enter 继续，输入 q 取消："
    ).strip().lower()

    if choice == "q":
        raise RuntimeError(
            "用户取消。单据可能已经创建并添加明细，"
            "请在 WMS 页面检查实际状态。"
        )

    verified = wait_for_stockout_status(
        session,
        stockout_id,
        {
            STATUS_AUDITED,
            STATUS_ALLOTTED,
        },
        attempts=10,
        interval=2,
    )

    if not verified:
        raise RuntimeError(
            "等待后仍无法确认审核成功。"
            "不会自动分配，请检查 WMS 页面状态。"
        )

    status = get_status(verified)

    if status == STATUS_ALLOTTED:
        print("单据已显示为分配后的状态，不重复分配。")
        return "already_allotted"

    if status != STATUS_AUDITED:
        raise RuntimeError(
            f"审核后状态为 {status}，"
            "不符合已确认的审核完成状态。"
        )

    print("人工审核已通过 StockOut/List 状态验证。")
    return "audited"


# ============================================================
# 十一、自动分配
# ============================================================

def allot_stockout(session, stockout_id):
    """
    已验证的请求形式：

    GET /StockOut/AllotAll?id=<StockOutId>&outStation=4

    写操作只提交一次，不自动重试。
    """

    title("自动分配")

    current = find_stockout_by_id(session, stockout_id)

    if not current:
        raise RuntimeError(
            "分配前无法查询出库单，停止分配。"
        )

    status = get_status(current)

    if status == STATUS_ALLOTTED:
        print("该单据已经处于分配后的状态，跳过分配。")
        return True

    if status != STATUS_AUDITED:
        raise RuntimeError(
            f"分配前状态为 {status}，"
            "未确认单据已审核，禁止调用 AllotAll。"
        )

    params = {
        "id": str(stockout_id),
        "outStation": str(OUT_STATION),
    }

    headers = {
        "Accept": "application/json, text/plain, */*",
        "Referer": BASE_URL + "/StockOut",
    }

    print("出库单号：", current.get("StockOutNo"))
    print("StockOutId：", stockout_id)
    print("出口：", OUT_STATION_NAME)
    print("outStation：", OUT_STATION)
    print("正在调用 StockOut/AllotAll……")

    try:
        response = session.get(
            STOCKOUT_ALLOT_URL,
            params=params,
            headers=headers,
            timeout=REQUEST_TIMEOUT,
            allow_redirects=False,
        )

        print("HTTP 状态码：", response.status_code)
        print("请求 URL：", response.request.url)
        print(
            "Location：",
            response.headers.get("Location", "(无)")
        )

        result = parse_json_response(response)

        print(
            "分配响应：",
            json.dumps(result, ensure_ascii=False)
        )

        if not is_business_success(result):
            raise RuntimeError(
                f"WMS 未确认分配成功：{result!r}"
            )

        print("自动分配接口明确返回业务成功。")

    except Exception as exc:
        print("分配接口结果异常：", exc)
        print("正在只读核对单据状态，不重复提交分配。")

        try:
            row = wait_for_stockout_status(
                session,
                stockout_id,
                {STATUS_ALLOTTED},
                attempts=5,
                interval=2,
            )
        except Exception:
            row = None

        if row:
            print("列表状态已显示分配后的状态。")
            return True

        raise RuntimeError(
            "自动分配结果尚未确认。"
            "请刷新 WMS 页面核对实际状态，"
            "不要直接重复调用 AllotAll。"
        ) from exc

    # 接口响应成功后，再核对单据状态。
    row = wait_for_stockout_status(
        session,
        stockout_id,
        {STATUS_ALLOTTED},
        attempts=5,
        interval=2,
    )

    if row:
        print("StockOut/List 已确认单据进入分配后的状态。")
        return True

    print(
        "注意：接口返回业务成功，但列表状态尚未确认更新。"
    )
    print(
        "程序不会再次分配。请在 WMS 页面核对实际状态。"
    )

    return True


# ============================================================
# 十二、查询仓储任务
# ============================================================

def parse_dotnet_date(value):
    """
    解析 .NET 日期格式：
        /Date(1793117389163)/
    """

    if not value:
        return None

    match = re.search(r"/Date\((-?\d+)", str(value))

    if not match:
        return None

    try:
        milliseconds = int(match.group(1))
        return datetime.fromtimestamp(milliseconds / 1000)
    except (ValueError, OSError, OverflowError):
        return None


def query_tasks(session, run_started):
    """
    Task/List 查询参数基于当前已知列表接口形式编写。

    注意：
    - 需要与你实际抓到的 Task/List 请求参数核对。
    - TaskType=13 不能单独证明任务属于某张出库单。
    """

    title("查询仓储任务")

    now = datetime.now()

    payload = {
        "limit": 100,
        "offset": 0,
        "sort": "CreateDate",
        "order": "desc",
        "search": "",
        "datemin": (
            now - timedelta(days=1)
        ).strftime("%Y-%m-%d"),
        "datemax": (
            now + timedelta(days=1)
        ).strftime("%Y-%m-%d"),
        "Status": "",
        "TaskType": "",
    }

    try:
        data = safe_post_json(
            session,
            TASK_LIST_URL,
            payload,
            referer=BASE_URL + "/StockOut",
        )

    except Exception as exc:
        print("Task/List 查询失败：", exc)
        print(
            "这不代表自动分配失败。"
            "请到 WMS 页面核对任务。"
        )
        return

    rows = extract_rows(data)

    if not rows:
        print("Task/List 没有返回可识别的任务记录。")
        return

    recent_tasks = []

    for task in rows:
        if str(task.get("TaskType")) != str(TARGET_TASK_TYPE):
            continue

        created = parse_dotnet_date(task.get("CreateDate"))

        if created and created >= run_started - timedelta(minutes=2):
            recent_tasks.append((created, task))

    recent_tasks.sort(key=lambda x: x[0], reverse=True)

    if not recent_tasks:
        print(
            f"当前返回的记录中，未发现本次启动后新增的 "
            f"TaskType={TARGET_TASK_TYPE} 任务。"
        )

        print("\n最近的生产领料任务（仅供核对）：")

        count = 0

        for task in rows:
            if str(task.get("TaskType")) != str(TARGET_TASK_TYPE):
                continue

            print(
                "TaskCode={TaskCode} | "
                "TaskMainId={TaskMainId} | "
                "Status={Status} | "
                "OutStation={OutStation} | "
                "TrayCode={TrayCode}".format(
                    TaskCode=task.get("TaskCode", "-"),
                    TaskMainId=task.get("TaskMainId", "-"),
                    Status=task.get("Status", "-"),
                    OutStation=task.get("OutStation", "-"),
                    TrayCode=task.get("TrayCode", "-"),
                )
            )

            count += 1

            if count >= 10:
                break

        return

    print(
        f"发现 {len(recent_tasks)} 条近期 "
        f"TaskType={TARGET_TASK_TYPE} 任务："
    )

    for created, task in recent_tasks:
        print("-" * 68)
        print("创建时间：", created.strftime("%Y-%m-%d %H:%M:%S"))
        print("TaskCode：", task.get("TaskCode", "-"))
        print("TaskMainId：", task.get("TaskMainId", "-"))
        print("TaskType：", task.get("TaskType", "-"))
        print("Status：", task.get("Status", "-"))
        print("OutStation：", task.get("OutStation", "-"))
        print("TrayCode：", task.get("TrayCode", "-"))
        print("StartLocation：", task.get("StartLocation", "-"))

    print(
        "\n注意：以上是按任务类型和创建时间筛出的候选任务，"
        "仍需结合 WMS 页面确认与本次出库单的关联。"
    )


# ============================================================
# 十三、整理输入并确认出库内容
# ============================================================

def prepare_items(session, requirements):
    items = []

    for requirement in requirements:
        material = select_material(
            session,
            requirement["query_name"],
        )

        if material is None:
            raise RuntimeError(
                f"物料“{requirement['query_name']}”未完成确认。"
            )

        weight_kg = calculate_plan_weight(
            requirement,
            material,
        )

        spec_weight = specification_weight_kg(
            material.get("Specification")
        )

        estimated_packages = None

        if (
            spec_weight
            and spec_weight > 0
            and str(material.get("Unit", "")).strip()
                in PACKAGE_UNITS
        ):
            estimated_packages = weight_kg / spec_weight

        items.append({
            "query_name": requirement["query_name"],
            "quantity": requirement["quantity"],
            "input_unit": requirement["input_unit"],
            "material": material,
            "plan_weight_kg": weight_kg,
            "estimated_packages": estimated_packages,
        })

    return items


def show_draft(items):
    title("出库单确认")

    print("单据类型：", STOCKOUT_TYPE_NAME)
    print("出口：", OUT_STATION_NAME)
    print("outStation：", OUT_STATION)
    print("-" * 68)

    for index, item in enumerate(items, start=1):
        material = item["material"]

        print(
            f"{index}. 输入名称：{item['query_name']}"
        )

        print(
            "   标准名称：",
            material.get("MaterialName", "-"),
        )

        print(
            "   物料编码：",
            material.get("MaterialNo", "-"),
        )

        print(
            "   规格/单位：",
            f"{material.get('Specification', '-')}"
            f" / {material.get('Unit', '-')}",
        )

        print(
            "   输入数量：",
            f"{fmt_decimal(item['quantity'])}"
            f" {item['input_unit']}",
        )

        print(
            "   计划出库重量：",
            f"{fmt_decimal(item['plan_weight_kg'])} kg",
        )

        if item["estimated_packages"] is not None:
            print(
                "   按规格估算包装数：",
                fmt_decimal(item["estimated_packages"]),
                material.get("Unit", ""),
            )

        print(
            "   MaterialId：",
            material.get("MaterialId", "-"),
        )

        print(
            "   IsDel：",
            material.get("IsDel", "-"),
        )

        print("-" * 68)


# ============================================================
# 十四、执行一张新的出库单
# ============================================================

def execute_new_stockout(session):
    title("WMS 对话式生产领料出库")

    print("输入示例：")
    print("  盐酸盐 500kg")
    print("  胆碱 150kg，再领20包硫酸盐")
    print("  150公斤胆碱")
    print("输入 q 取消。")

    text = input("\n领料需求> ").strip()

    if text.lower() in ("q", "quit", "exit"):
        print("已取消。")
        return

    requirements = parse_requirement_text(text)

    print("\n识别到以下需求：")

    for requirement in requirements:
        print(
            f"- {requirement['query_name']} "
            f"{fmt_decimal(requirement['quantity'])} "
            f"{requirement['input_unit']}"
        )

    items = prepare_items(session, requirements)

    show_draft(items)

    if input(
        "确认以上物料、重量和单据类型正确？(y/N)："
    ).strip().lower() != "y":
        print("已取消，没有执行写操作。")
        return

    print("\n已收到最终确认，开始执行出库流程。")
    print("写操作不会自动重试；如果结果不明确，请先核对 WMS。")

    run_started = datetime.now()

    # --------------------------------------------------------
    # 第一步：创建主表
    # --------------------------------------------------------

    stockout = create_stockout(session)

    stockout_id = str(stockout.get("StockOutId"))
    stockout_no = stockout.get("StockOutNo", "-")

    if not stockout_id or stockout_id == "None":
        raise RuntimeError(
            "新建单据缺少 StockOutId，停止后续操作。"
        )

    print("\n新建出库单：", stockout_no)
    print("StockOutId：", stockout_id)

    # --------------------------------------------------------
    # 第二步：添加全部明细
    # --------------------------------------------------------

    title("添加出库明细")

    for item in items:
        try:
            add_stockout_detail(
                session,
                stockout_id,
                item,
            )

        except Exception as exc:
            print("\n明细添加失败：", exc)
            print("出库单号：", stockout_no)
            print("StockOutId：", stockout_id)
            print(
                "程序不会继续审核或分配。"
                "请检查 WMS 页面中已写入的明细，"
                "不要直接重复提交。"
            )
            return

    # --------------------------------------------------------
    # 第三步：审核
    # --------------------------------------------------------

    try:
        audit_result = ensure_stockout_audited(
            session,
            stockout_id,
        )

    except Exception as exc:
        title("流程暂停：审核未确认")

        print("异常：", exc)
        print("出库单号：", stockout_no)
        print("StockOutId：", stockout_id)
        print(
            "\n单据和明细可能已经创建。"
            "请在 WMS 页面检查实际状态。"
            "本次不会自动分配，也不会重新创建单据。"
        )
        return

    if audit_result == "already_allotted":
        print("\n单据已经处于分配后的状态，不再重复分配。")
        query_tasks(session, run_started)
        return

    # --------------------------------------------------------
    # 第四步：自动分配
    # --------------------------------------------------------

    try:
        allot_stockout(
            session,
            stockout_id,
        )

    except Exception as exc:
        title("流程暂停：分配结果未确认")

        print("异常：", exc)
        print("出库单号：", stockout_no)
        print("StockOutId：", stockout_id)
        print(
            "请刷新 WMS 页面核对状态。"
            "不要直接重复调用自动分配接口。"
        )

        return

    # --------------------------------------------------------
    # 第五步：查询任务
    # --------------------------------------------------------

    query_tasks(
        session,
        run_started,
    )

    title("本次处理结束")

    print("出库单号：", stockout_no)
    print("StockOutId：", stockout_id)
    print("单据类型：", STOCKOUT_TYPE_NAME)
    print("出口：", OUT_STATION_NAME)
    print(
        "\n请在 WMS 页面最终核实出库单状态、"
        "已分配数量及仓储任务。"
    )
    return True


# ============================================================
# 十五、后台仓储任务监控与 Bark 通知（整合自 monitor_log.py）
# ============================================================

TASK_DETAIL_URL = BASE_URL + "/Task/ListDetail"
CHECK_INTERVAL = 10
PAGE_SIZE = 100
MAX_PAGES = 10
MONITOR_LOOKBACK_DAYS = 7
MONITOR_LOOKAHEAD_DAYS = 2
STATE_FILE = Path(__file__).resolve().parent / "wms_task_state.json"
last_monitor_heartbeat = 0


class SessionExpired(Exception):
    """监控接口登录失效或返回格式不符合预期。"""


def monitor_login(session, username, password):
    try:
        session.get(LOGIN_PAGE_URL, timeout=10)
        response = session.post(
            LOGIN_API_URL,
            json={"UserName": username, "Password": password},
            headers={"Accept": "application/json, text/plain, */*"},
            timeout=10,
            allow_redirects=False,
        )
        if response.status_code != 200:
            print(f"[监控] 登录失败，HTTP {response.status_code}")
            return False
        # 用只读任务查询验证会话，而非只看登录 HTTP 200。
        verify = session.post(
            TASK_LIST_URL,
            data=monitor_list_payload(0),
            headers={"Accept": "application/json, text/plain, */*",
                     "Referer": BASE_URL + "/Task"},
            timeout=15,
            allow_redirects=False,
        )
        if verify.status_code in (401, 403) or "/Login/" in verify.url:
            return False
        data = verify.json()
        return isinstance(data, dict) and isinstance(data.get("rows"), list)
    except Exception as exc:
        print(f"[监控] 登录/验证异常：{exc}")
        return False


def monitor_list_payload(offset):
    now = datetime.now()
    return {
        "limit": PAGE_SIZE, "offset": offset, "sort": "CreateDate",
        "order": "desc", "search": "",
        "datemin": (now - timedelta(days=MONITOR_LOOKBACK_DAYS)).strftime("%Y-%m-%d"),
        "datemax": (now + timedelta(days=MONITOR_LOOKAHEAD_DAYS)).strftime("%Y-%m-%d"),
        "Status": "", "TaskType": "",
    }


def monitor_post_rows(session, url, payload):
    response = session.post(
        url, data=payload, timeout=15, allow_redirects=False,
        headers={"Accept": "application/json, text/plain, */*",
                 "Referer": BASE_URL + "/Task"},
    )
    if response.status_code in (401, 403) or "/Login/" in response.url:
        raise SessionExpired("登录失效或被重定向到登录页面")
    if 300 <= response.status_code < 400:
        raise SessionExpired("接口返回重定向：" + str(response.headers.get("Location", "")))
    try:
        data = response.json()
    except ValueError as exc:
        raise SessionExpired("接口没有返回有效 JSON") from exc
    if not isinstance(data, dict) or not isinstance(data.get("rows"), list):
        raise RuntimeError("监控接口返回格式不符合预期（缺少 rows）")
    return data


def monitor_task_id(task):
    value = task.get("TaskMainId")
    return str(value).strip() if value is not None else ""


def monitor_task_type(task):
    try:
        return int(task.get("TaskType"))
    except (TypeError, ValueError):
        return None


def monitor_fetch_recent_tasks(session, seen_ids, initial=False):
    found = []
    offset = 0
    for _ in range(MAX_PAGES):
        rows = monitor_post_rows(session, TASK_LIST_URL, monitor_list_payload(offset)).get("rows", [])
        if not rows:
            break
        if initial:
            found.extend(rows)
        else:
            reached_old = False
            for row in rows:
                task_id = monitor_task_id(row)
                if task_id and task_id in seen_ids:
                    reached_old = True
                    break
                found.append(row)
            if reached_old:
                break
        if len(rows) < PAGE_SIZE:
            break
        offset += PAGE_SIZE
    return found


def monitor_fetch_task_details(session, task_id):
    data = monitor_post_rows(session, TASK_DETAIL_URL, {"pid": str(task_id)})
    return data.get("rows", [])


def monitor_format_date(value):
    if not value:
        return "未知"
    match = re.search(r"/Date\((-?\d+)(?:[+-]\d{4})?\)/", str(value))
    if match:
        try:
            return datetime.fromtimestamp(int(match.group(1)) / 1000).strftime("%Y-%m-%d %H:%M:%S")
        except (ValueError, OSError, OverflowError):
            pass
    return str(value)


def monitor_format_number(value):
    if value is None:
        return "未知"
    try:
        number = float(value)
        return str(int(number)) if number.is_integer() else f"{number:g}"
    except (ValueError, TypeError):
        return str(value)


def monitor_build_message(task, details):
    lines = [
        f"任务编号：{task.get('TaskCode', '未知')}",
        f"创建时间：{monitor_format_date(task.get('CreateDate'))}",
        f"托盘条码：{task.get('TrayCode') or '-'}",
        "",
        "物料明细：",
    ]
    for index, item in enumerate(details, start=1):
        lines.append(f"{index}. {item.get('MaterialName', '未知物料')}（编码：{item.get('MaterialNo', '-')}）")
        lines.append(f"   件数：{monitor_format_number(item.get('Qty'))}")
        lines.append(f"   重量：{monitor_format_number(item.get('Weight'))} kg")
        if item.get("Specification"):
            lines.append(f"   规格：{item.get('Specification')}")
        lines.append("")
    return "\n".join(lines)


def monitor_send_bark(title_text, content):
    if not BARK_URL.startswith("https://api.day.app/") or "your_key_here" in BARK_URL:
        print("[监控] 未配置有效的 WMS_BARK_URL，已跳过 Bark 推送。")
        return False
    try:
        response = requests.post(
            BARK_URL,
            json={"title": title_text, "body": content,
                  "group": "WMS生产领料出库", "sound": "bell.caf"},
            timeout=10,
        )
        return response.status_code == 200
    except requests.RequestException as exc:
        print(f"[监控] Bark 推送异常：{exc}")
        return False


def monitor_load_state():
    if not STATE_FILE.exists():
        return set(), {}, False
    try:
        data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        seen = {str(v) for v in data.get("seen_ids", [])}
        pending = {str(k): v for k, v in data.get("pending_tasks", {}).items()}
        return seen, pending, bool(data.get("initialized", True))
    except Exception as exc:
        raise RuntimeError(f"读取监控状态文件失败：{exc}") from exc


def monitor_save_state(seen_ids, pending_tasks):
    data = {"initialized": True, "seen_ids": sorted(seen_ids), "pending_tasks": pending_tasks}
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(STATE_FILE)


def monitor_status_text():
    elapsed = time.time() - last_monitor_heartbeat if last_monitor_heartbeat else None
    if elapsed is None:
        return "初始化中"
    if elapsed < 35:
        return "正常运行中"
    return f"可能挂起（最后心跳 {int(elapsed)} 秒前）"


def background_monitor_worker(username, password):
    global last_monitor_heartbeat
    seen_ids, pending_tasks, initialized = set(), {}, False
    try:
        seen_ids, pending_tasks, initialized = monitor_load_state()
    except Exception as exc:
        print(f"[监控] {exc}；本次使用内存状态继续。")

    # 监控线程使用独立 Session，避免与前台出库请求共享 requests.Session。
    monitor_session = requests.Session()
    monitor_session.headers.update({"Accept": "application/json, text/plain, */*"})
    while True:
        try:
            if not monitor_login(monitor_session, username, password):
                print("[监控] 登录/会话验证失败，10 秒后重试。")
                time.sleep(10)
                continue

            if not initialized:
                print("[监控] 首次启动，正在建立历史任务基线……")
                baseline = monitor_fetch_recent_tasks(monitor_session, set(), initial=True)
                for task in baseline:
                    task_id = monitor_task_id(task)
                    if task_id:
                        seen_ids.add(task_id)
                monitor_save_state(seen_ids, pending_tasks)
                initialized = True
                last_monitor_heartbeat = time.time()
                print(f"[监控] 历史基线建立完成：{len(seen_ids)} 条任务。")

            while True:
                last_monitor_heartbeat = time.time()
                new_tasks = monitor_fetch_recent_tasks(monitor_session, seen_ids, initial=False)
                for task in reversed(new_tasks):
                    task_id = monitor_task_id(task)
                    if not task_id or task_id in seen_ids:
                        continue
                    seen_ids.add(task_id)
                    if monitor_task_type(task) == TARGET_TASK_TYPE:
                        print(f"\n[{time.strftime('%H:%M:%S')}] [监控] 发现新生产领料任务：{task.get('TaskCode', task_id)}")
                        if BARK_URL.startswith("https://api.day.app/") and "your_key_here" not in BARK_URL:
                            pending_tasks[task_id] = task
                        else:
                            print("[监控] 未配置有效 Bark 地址，本任务仅记录，不会反复尝试推送。")
                    monitor_save_state(seen_ids, pending_tasks)

                for task_id, task in list(pending_tasks.items()):
                    try:
                        details = monitor_fetch_task_details(monitor_session, task_id)
                        if not details:
                            continue
                        message = monitor_build_message(task, details)
                        if monitor_send_bark("WMS 新生产领料出库任务", message):
                            pending_tasks.pop(task_id, None)
                            monitor_save_state(seen_ids, pending_tasks)
                            print(f"[监控] 已推送任务 {task.get('TaskCode', task_id)}。")
                    except SessionExpired:
                        raise
                    except Exception as exc:
                        print(f"[监控] 查询/推送任务 {task_id} 失败：{exc}")

                time.sleep(CHECK_INTERVAL)
        except SessionExpired as exc:
            print(f"[监控] {exc}，准备重新登录。")
            monitor_session = requests.Session()
            monitor_session.headers.update({"Accept": "application/json, text/plain, */*"})
            time.sleep(2)
        except Exception as exc:
            print(f"[监控] 监控循环异常：{exc}；{CHECK_INTERVAL} 秒后重试。")
            time.sleep(CHECK_INTERVAL)


# ============================================================
# 十六、整合后的主程序
# ============================================================

def main():
    title("WMS 对话式生产领料出库 + 后台任务监控")
    print("WMS：", BASE_URL)
    print("单据类型：", STOCKOUT_TYPE_NAME)
    print("出口：", OUT_STATION_NAME)
    print("outStation：", OUT_STATION)
    print("目标任务类型：", TARGET_TASK_TYPE)
    print("审核接口：", STOCKOUT_AUDIT_URL)
    print("监控轮询间隔：", CHECK_INTERVAL, "秒")
    if BARK_URL:
        print("Bark 推送：已从本地配置或环境变量读取")
    else:
        print("Bark 推送：未配置（监控仍运行，但不会发送推送）")

    username = WMS_USERNAME
    password = WMS_PASSWORD
    if not password:
        print("未配置 WMS 密码。请编辑同目录 wms_config.json 的 password 字段，或设置 WMS_PASSWORD 环境变量。")
        return
    print(f"\n正在使用本地配置自动登录 WMS（用户名：{username}）；密码不会显示。")

    session = requests.Session()
    session.headers.update({"Accept": "application/json, text/plain, */*"})
    if not login(session, username, password):
        print("登录请求失败，请检查 WMS 登录接口。")
        return
    if not verify_session(session):
        print("会话验证失败，请检查登录状态和账号权限。")
        return

    monitor_thread = threading.Thread(
        target=background_monitor_worker,
        args=(username, password),
        name="wms-task-monitor",
        daemon=True,
    )
    monitor_thread.start()
    print("[监控] 后台任务监控线程已启动。")

    while True:
        try:
            execute_new_stockout(session)
            print(f"\n后台监控状态：{monitor_status_text()}")
            again = input("\n是否继续处理下一张出库单？(y/N)：").strip().lower()
            if again != "y":
                break
        except KeyboardInterrupt:
            print("\n用户中断。请核对 WMS 中已经提交的业务数据。")
            break
        except Exception as exc:
            title("程序异常")
            print("异常：", exc)
            print("如果异常发生在写操作之后，请先核对 WMS 状态，不要盲目重试。")
            again = input("\n是否返回输入下一张出库单？(y/N)：").strip().lower()
            if again != "y":
                break

    print("前台出库助手已退出；后台监控线程将在程序结束时停止。")


if __name__ == "__main__":
    main()
