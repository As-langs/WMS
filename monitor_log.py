import json
import re
import time
from datetime import datetime, timedelta
from pathlib import Path

import requests


# ==================================================
# 1. 配置区域：请填写自己的账号及 Bark 地址
# ==================================================

BASE_URL = "http://127.0.0.1"

LOGIN_INDEX_URL = BASE_URL + "/Login/Index"
LOGIN_API_URL = BASE_URL + "/Login/CheckLoginAsync"
TASK_LIST_URL = BASE_URL + "/Task/List"
TASK_DETAIL_URL = BASE_URL + "/Task/ListDetail"

USERNAME = "admin"
PASSWORD = "admin"

# 填写自己的 Bark 推送地址，不要分享完整 Key
BARK_URL = "https://api.day.app/你的key"

CHECK_INTERVAL = 10
PAGE_SIZE = 100
MAX_PAGES = 10

# 根据你提供的实际响应，暂按 13 筛选生产领料出库
TARGET_TASK_TYPE = 13

# 查询最近 7 天到未来 2 天的数据，兼顾日期及时区差异
LOOKBACK_DAYS = 7
LOOKAHEAD_DAYS = 2

STATE_FILE = Path(__file__).resolve().parent / "wms_task_state.json"


class SessionExpired(Exception):
    """登录失效或接口返回的内容不是预期 JSON。"""
    pass


# ==================================================
# 2. 登录与通用接口
# ==================================================

def auto_login(session):
    print(f"[{time.strftime('%H:%M:%S')}] 正在登录 WMS...")

    try:
        session.get(LOGIN_INDEX_URL, timeout=10)

        response = session.post(
            LOGIN_API_URL,
            json={
                "UserName": USERNAME,
                "Password": PASSWORD
            },
            timeout=10
        )

        if response.status_code == 200:
            print("登录请求已提交，接下来验证接口会话。")
            return True

        print(f"登录请求失败，HTTP {response.status_code}")
        return False

    except requests.RequestException as exc:
        print(f"登录网络异常：{exc}")
        return False


def post_rows(session, url, payload):
    """请求接口，并检查响应是否包含预期的 rows 数组。"""

    response = session.post(
        url,
        data=payload,
        timeout=15
    )

    if response.status_code in (401, 403):
        raise SessionExpired(
            f"接口返回 HTTP {response.status_code}"
        )

    if "/Login/" in response.url:
        raise SessionExpired("请求被重定向到登录页面")

    try:
        data = response.json()
    except ValueError:
        raise SessionExpired("接口没有返回有效 JSON")

    if not isinstance(data, dict):
        raise SessionExpired("接口返回格式不正确")

    if not isinstance(data.get("rows"), list):
        raise SessionExpired("响应中没有预期的 rows 字段")

    return data


# ==================================================
# 3. 查询 Task/List
# ==================================================

def make_list_payload(offset):
    now = datetime.now()

    return {
        "limit": PAGE_SIZE,
        "offset": offset,
        "sort": "CreateDate",
        "order": "desc",
        "search": "",
        "datemin": (
            now - timedelta(days=LOOKBACK_DAYS)
        ).strftime("%Y-%m-%d"),
        "datemax": (
            now + timedelta(days=LOOKAHEAD_DAYS)
        ).strftime("%Y-%m-%d"),
        "Status": "",
        "TaskType": ""
    }


def get_task_id(task):
    value = task.get("TaskMainId")

    if value is None or str(value).strip() == "":
        return ""

    return str(value)


def get_task_type(task):
    try:
        return int(task.get("TaskType"))
    except (TypeError, ValueError):
        return None


def fetch_recent_tasks(session, seen_ids, initial=False):
    """
    按创建时间倒序查询任务。

    正常监控时，遇到已经处理过的任务就停止翻页，
    以减少不必要的接口请求。

    首次运行时建立历史基线，不发送历史任务通知。
    """

    found = []
    offset = 0

    for _ in range(MAX_PAGES):
        payload = make_list_payload(offset)

        data = post_rows(
            session,
            TASK_LIST_URL,
            payload
        )

        rows = data.get("rows", [])

        if not rows:
            break

        if initial:
            found.extend(rows)
        else:
            reached_old_task = False

            for row in rows:
                task_id = get_task_id(row)

                if task_id and task_id in seen_ids:
                    reached_old_task = True
                    break

                found.append(row)

            if reached_old_task:
                break

        if len(rows) < PAGE_SIZE:
            break

        offset += PAGE_SIZE

    return found


# ==================================================
# 4. 查询 Task/ListDetail
# ==================================================

def fetch_task_details(session, task_id):
    data = post_rows(
        session,
        TASK_DETAIL_URL,
        {"pid": str(task_id)}
    )

    return data.get("rows", [])


# ==================================================
# 5. 解析 WMS 日期与数值
# ==================================================

def format_wms_date(value):
    """
    处理 WMS 返回的 .NET 日期格式：
    /Date(1792548542320)/
    """

    if value is None or value == "":
        return "未知"

    match = re.search(
        r"/Date\((-?\d+)(?:[+-]\d{4})?\)/",
        str(value)
    )

    if match:
        milliseconds = int(match.group(1))

        return datetime.fromtimestamp(
            milliseconds / 1000
        ).strftime("%Y-%m-%d %H:%M:%S")

    return str(value)


def format_number(value):
    if value is None:
        return "未知"

    try:
        number = float(value)

        if number.is_integer():
            return str(int(number))

        return f"{number:g}"

    except (ValueError, TypeError):
        return str(value)


# ==================================================
# 6. 组织推送消息
# ==================================================

def build_message(task, details):
    task_code = task.get("TaskCode", "未知")
    tray_code = task.get("TrayCode") or "-"

    create_time = format_wms_date(
        task.get("CreateDate")
    )

    lines = [
        f"任务编号：{task_code}",
        f"创建时间：{create_time}",
        f"托盘条码：{tray_code}",
        "",
        "物料明细："
    ]

    for index, item in enumerate(details, start=1):
        material_name = item.get(
            "MaterialName",
            "未知物料"
        )

        material_no = item.get(
            "MaterialNo",
            "-"
        )

        qty = format_number(item.get("Qty"))
        weight = format_number(item.get("Weight"))

        specification = item.get("Specification")

        lines.append(
            f"{index}. {material_name}（编码：{material_no}）"
        )
        lines.append(f"   件数：{qty}")
        lines.append(f"   重量：{weight} kg")

        if specification:
            lines.append(f"   规格：{specification}")

        lines.append("")

    return "\n".join(lines)


# ==================================================
# 7. Bark 推送
# ==================================================

def send_bark_msg(title, content):
    payload = {
        "title": title,
        "body": content,
        "group": "WMS生产领料出库",
        "sound": "minuet.caf"
    }

    try:
        response = requests.post(
            BARK_URL,
            json=payload,
            timeout=10
        )

        if response.status_code != 200:
            print(
                f"Bark HTTP 错误：{response.status_code}"
            )
            return False

        try:
            result = response.json()
        except ValueError:
            result = {}

        code = str(result.get("code", 200))

        if code != "200":
            print(f"Bark 返回失败：{result}")
            return False

        print("Bark 推送请求成功。")
        return True

    except requests.RequestException as exc:
        print(f"Bark 网络异常：{exc}")
        return False


# ==================================================
# 8. 保存监控状态
# ==================================================

def load_state():
    if not STATE_FILE.exists():
        return set(), {}, False

    try:
        data = json.loads(
            STATE_FILE.read_text(encoding="utf-8")
        )

        seen_ids = set(
            str(value)
            for value in data.get("seen_ids", [])
        )

        pending_tasks = {
            str(key): value
            for key, value in
            data.get("pending_tasks", {}).items()
        }

        initialized = bool(
            data.get("initialized", True)
        )

        return seen_ids, pending_tasks, initialized

    except Exception as exc:
        # 不自动覆盖损坏的状态文件，以免误发历史任务
        raise RuntimeError(
            f"读取状态文件失败：{exc}。"
            "请先备份并检查状态文件。"
        )


def save_state(seen_ids, pending_tasks):
    data = {
        "initialized": True,
        "seen_ids": sorted(seen_ids),
        "pending_tasks": pending_tasks
    }

    temp_file = STATE_FILE.with_suffix(".tmp")

    temp_file.write_text(
        json.dumps(
            data,
            ensure_ascii=False,
            indent=2
        ),
        encoding="utf-8"
    )

    temp_file.replace(STATE_FILE)


# ==================================================
# 9. 处理新增任务与待重试任务
# ==================================================

def process_new_tasks(session, seen_ids, pending_tasks):
    new_tasks = fetch_recent_tasks(
        session,
        seen_ids,
        initial=False
    )

    # 接口按创建时间倒序返回。
    # 倒过来处理，使同一批新任务尽量按时间先后推送。
    for task in reversed(new_tasks):
        task_id = get_task_id(task)

        if not task_id or task_id in seen_ids:
            continue

        # 先记录发现的任务，避免失败后丢失待处理信息。
        seen_ids.add(task_id)

        if get_task_type(task) == TARGET_TASK_TYPE:
            pending_tasks[task_id] = task

            print(
                f"[{time.strftime('%H:%M:%S')}] "
                f"发现生产领料出库任务："
                f"{task.get('TaskCode', task_id)}"
            )

        save_state(seen_ids, pending_tasks)

    # 重试未完成的明细读取或 Bark 推送。
    for task_id, task in list(pending_tasks.items()):
        try:
            details = fetch_task_details(
                session,
                task_id
            )

            # 明细可能尚未生成，留到下一轮重试。
            if not details:
                print(
                    f"任务 {task.get('TaskCode', task_id)} "
                    "暂时没有明细，稍后重试。"
                )
                continue

            message = build_message(task, details)

            success = send_bark_msg(
                "WMS 新生产领料出库任务",
                message
            )

            if success:
                print(
                    f"任务 {task.get('TaskCode', task_id)} "
                    "已完成推送。"
                )

                pending_tasks.pop(task_id, None)
                save_state(seen_ids, pending_tasks)

        except SessionExpired:
            # 交给主循环重新登录。
            raise

        except Exception as exc:
            # 保留任务，下一轮继续尝试。
            print(
                f"任务 {task.get('TaskCode', task_id)} "
                f"处理异常，将重试：{exc}"
            )


# ==================================================
# 10. 主程序
# ==================================================

def main():
    if (
        not USERNAME
        or not PASSWORD
        or USERNAME.startswith("填写你的")
        or PASSWORD.startswith("填写你的")
        or not BARK_URL.startswith("https://api.day.app/")
        or "填写你的" in BARK_URL
    ):
        print(
            "请先填写 WMS 账号、密码和 Bark 推送地址。"
        )
        return

    session = requests.Session()

    session.headers.update({
        "Accept": "application/json, text/javascript, */*; q=0.01",
        "X-Requested-With": "XMLHttpRequest",
        "Referer": BASE_URL + "/Task"
    })

    if not auto_login(session):
        print("初始登录失败，程序退出。")
        return

    try:
        seen_ids, pending_tasks, initialized = load_state()
    except RuntimeError as exc:
        print(exc)
        return

    # 首次启动只建立历史基线，不推送旧任务。
    if not initialized:
        print("首次启动：正在读取历史任务并建立基线……")

        while True:
            try:
                baseline_rows = fetch_recent_tasks(
                    session,
                    set(),
                    initial=True
                )

                for task in baseline_rows:
                    task_id = get_task_id(task)

                    if task_id:
                        seen_ids.add(task_id)

                save_state(seen_ids, pending_tasks)

                print(
                    f"历史基线建立完成，共记录 "
                    f"{len(seen_ids)} 个任务 ID。"
                )
                print("现在开始监控后续新增任务。")
                break

            except SessionExpired as exc:
                print(f"会话需要重新登录：{exc}")
                auto_login(session)
                time.sleep(3)

            except Exception as exc:
                print(f"建立历史基线失败：{exc}")
                time.sleep(5)

    print("WMS 生产领料出库监控已启动。")

    while True:
        try:
            process_new_tasks(
                session,
                seen_ids,
                pending_tasks
            )

        except SessionExpired as exc:
            print(f"检测到登录失效：{exc}")
            print("正在重新登录……")

            if not auto_login(session):
                print("重新登录失败，将在下一轮重试。")

        except requests.RequestException as exc:
            print(f"网络请求异常：{exc}")

        except Exception as exc:
            print(f"监控异常：{exc}")

        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()
