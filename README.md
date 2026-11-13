# WMS 智能助手 (WMS Assistant)

[![iOS Release](https://img.shields.io/badge/iOS-1.1%20Release-blue?logo=apple&style=flat-square)](https://github.com/As-langs/WMS/releases/tag/IOS1.1)
[![Android](https://img.shields.io/badge/Android-1.0-brightgreen?logo=android&style=flat-square)](https://github.com/As-langs/WMS/releases/tag/Android1.0)
[![Web](https://img.shields.io/badge/Web-3.0-orange?logo=googlechrome&style=flat-square)](https://github.com/As-langs/WMS/releases/tag/3.0)
[![Script](https://img.shields.io/badge/Script-2.0-blueviolet?logo=python&style=flat-square)](https://github.com/As-langs/WMS/releases/tag/2.0)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20iOS%20%7C%20Android%20%7C%20Web-lightgrey?style=flat-square)](#各端平台与使用场景)

**面向 Windows 自动化脚本、局域网 Web、iOS 和 Android 的多平台企业级 WMS 仓储作业辅助系统**

WMS 智能助手围绕企业立体库与传统平库的高频作业场景，提供**智能物料出库**、**托盘快捷查验**、**PDA 实际出库二次确认**、**近实时任务监控**及**多模式极速报表导出**能力。项目覆盖电脑后台、局域网协同和手持移动端，可根据现场网络环境与作业终端自由选择使用入口。

---

## 目录索引与项目架构

仓库已完成全平台模块化重构优化，目录结构清晰独立：

```text
WMS/
├── WMS-IOS/                 # [iOS 客户端] 原生 SwiftUI 移动端应用 (iOS 18.0+)
│   ├── WMS 1.0/             # SwiftUI 界面、网络层与沙盒存储
│   ├── WMSStockOutiOS.xcodeproj # Xcode 工程配置 (Version 1.1)
│   ├── build_ipa.sh         # 一键离线编译与固化图标 IPA 打包脚本
│   ├── 仓储扫码蓝色立体图标.png # 1024x1024 专属高清应用图标
│   ├── README.md            # iOS 端特性与构建指南
│   └── HANDOFF.md           # 架构方案与深度设计交接文档
│
├── WMS-AD/                  # [Android 客户端] 原生 Android 工程 (Kotlin / Jetpack)
│   ├── app/                 # 业务源码、界面与清单配置
│   ├── gradle/              # Gradle 包装器
│   ├── build.gradle.kts     # 模块级构建脚本
│   └── README.md            # Android 端使用与编译说明
│
├── WMS-WEB/                 # [局域网 Web] 浏览器协同作业端 (Flask / HTML5)
│   ├── WMS-LAN-Web/         # Web 核心服务实现与静态模板
│   └── README.md            # 局域网 Web 启动与安全配置说明
│
├── WMS-SC/                  # [立体库后台脚本] Windows 自动化出库与监控 (Python)
│   ├── wms_integrated.py    # 综合出库与 PDA 处理脚本
│   ├── monitor_log.py       # 实时任务监控日志处理
│   ├── wms.bat              # Windows 快捷启动批处理
│   ├── wms_config.json      # 配置文件
│   └── README.md            # 脚本模式使用与参数说明
│
└── README.md                # 仓库总览索引与版本发布记录
```

---

## 各端平台与使用场景

| 平台 / 模块 | 核心技术栈 | 适用场景 | 源码目录 | 最新独立发布 (Release) |
| :--- | :--- | :--- | :--- | :--- |
| **iOS 端 (`WMS-IOS`)** | Swift 5.0, SwiftUI, iOS 18.0+ | iPhone / iPad 手持作业，支持智能交互出库、托盘查验、PDA 实际出库确认及秒级并发导出 | [浏览 WMS-IOS 源码](./WMS-IOS) | [🍏 iOS 1.1 发布页](https://github.com/As-langs/WMS/releases/tag/IOS1.1) |
| **Android 端 (`WMS-AD`)** | Kotlin, Jetpack Compose, Android 8.0+ | 工业手持 PDA、Android 手机与仓储平板 | [浏览 WMS-AD 源码](./WMS-AD) | [🤖 Android 1.0 发布页](https://github.com/As-langs/WMS/releases/tag/Android1.0) |
| **局域网 Web (`WMS-WEB`)** | Python 3.10+, Flask, HTML5 | 仓库内电脑、手机或平板免安装，通过局域网浏览器协同访问 | [浏览 WMS-WEB 源码](./WMS-WEB) | [🌐 Web 3.0 发布页](https://github.com/As-langs/WMS/releases/tag/3.0) |
| **自动化脚本 (`WMS-SC`)** | Python 3.10+, Batch | Windows 电脑后台持续驻留监听、自动领料出库及异常任务复盘 | [浏览 WMS-SC 源码](./WMS-SC) | [⚡️ 脚本 2.0 发布页](https://github.com/As-langs/WMS/releases/tag/2.0) |

---

## 🚀 核心业务能力

### 1. WMS 连接与会话验证
- 支持灵活配置 WMS 服务器地址及登录账号凭据。
- 内置针对 PDA 接口的 `UserName` 与 `WarehouseOid` 数字身份参数校验与自动回退。
- 基于 Session/Cookie 持久化通信，提供连通性健康检测与自动/手动断线重连。

### 2. 智能物料查询与多规格匹配
- 支持按物料名称、拼音或模糊关键字查询 WMS 物料主数据。
- 直观陈列物料编码、规格型号、计量单位及供应商信息，提供候选列表供人工比对复核。

### 3. 生产领料与自动化出库辅助
- 支持物料名称与需求重量（支持 kg、吨、包等）多格式自然识别。
- 支持按输入顺序流水线批次处理多物料出库需求。
- 自动按包装规格向上取整计算包数，出库前进行数据核对，自动流转生成出库单、添加明细、审核及分配。

### 4. PDA 托盘任务与实际出库二次确认 (`OutTaskConfirm`)
- **托盘快捷查验**：根据托盘号查询待出库 PDA 任务列表，展示物料名称、编码、规格、`TaskDetailId` 与计划数量。
- **实际数量调整**：支持机器人实际取出数量修改（支持步进加减与直接键盘录入），限制为大于 0 且不超过计划数量的整数。
- **二次防误触预览**：提交前展示托盘号、接口名、参数1、参数2（`TaskDetailId|实际数量;`）、计划/实际/剩余总量及高危写操作告警。
- **多端闭环**：在 **iOS 1.1**、**Android 1.0** 与 **Python 脚本** 中均已实现全流程无缝对齐。

### 5. 任务记录中枢与高并发报表导出
- **实时任务监听**：近实时监听入库与出库作业，提供前台增量轮询与本地长效历史归档。
- **结构化并发预加载**：基于 8 路并发池拉取物料明细，告别单线程阻塞。
- **双模式极速导出**：
  - ⚡️ **极速模式 (Summary Only)**：0.1 秒秒出基础信息，无需网络请求。
  - 📋 **完整明细模式 (Full Details)**：并发汇总批号、件数、重量、质检状态及坏包标识。
  - 格式支持：带样式的 **Excel 2003 XML (.xls)** 与内置 UTF-8 BOM 防乱码的 **通用 CSV (.csv)**。

---

## 🔥 iOS 1.1 版本重大更新日志

1. **补齐 PDA 托盘实际出库确认 (`OutTaskConfirm`)**：
   - 解决旧版仅能查询托盘列表、无法在手持端提交出库确认的痛点。
   - 主聊天屏直接输入托盘号（如 `A00412`）或快捷弹窗均可一键呼出确认面板，支持实际数量微调与参数二次核验，确认后直接写入 WMS。
2. **桌面应用图标全面固化**：
   - 内置全新 **1024x1024 蓝成立体仓储扫码专属桌面图标**。
   - 优化构建与打包管线，自动生成全套规范分辨率并注入 Payload，彻底脱离系统 CoreSimulator 代理依赖，安装后桌面图标永久固化。
3. **导出引擎与任务中枢性能重构**：
   - 基于 Swift `TaskGroup` 受控 8 路并发预加载，耗时压缩至 2~3 秒（提速 8~10 倍）。
   - 数据持久化无感平滑迁移至应用沙盒专属目录（`Documents/WMSTasks/`），杜绝大量数据导致的 UI 卡顿。
4. **多端目录结构规范化**：
   - 升级项目组织结构，将 iOS 工程集中归档至 `WMS-IOS/`。

---

## 快速构建与运行

### 1. iOS 端打包 (IPA)
```bash
cd WMS-IOS
./build_ipa.sh
```
* 输出产物：`WMS-IOS/IPA_Build/WMSStockOutiOS.ipa`（~3.0 MB，含固化图标与 arm64 二进制）

### 2. Android 端编译 (APK)
```bash
cd WMS-AD
./gradlew assembleRelease
```

### 3. Windows 脚本运行
```cmd
cd WMS-SC
wms.bat
```

### 4. 局域网 Web 服务启动
```bash
cd WMS-WEB/WMS-LAN-Web
pip install -r requirements.txt
python web_app.py
```

---

## 下载与发布渠道 (Releases)

各端均拥有独立的 Release 版本与安装包，请按需点击前往对应版本页面下载：

* 🍏 **iOS 客户端 (v1.1)**：[前往下载 WMSStockOutiOS_v1.1.ipa (Release IOS1.1)](https://github.com/As-langs/WMS/releases/tag/IOS1.1)
* 🤖 **Android 客户端 (v1.0)**：[前往下载 WMSbeat.apk (Release Android1.0)](https://github.com/As-langs/WMS/releases/tag/Android1.0)
* 🌐 **局域网 Web (v3.0)**：[前往下载 Web 3.0 部署包 (Release 3.0)](https://github.com/As-langs/WMS/releases/tag/3.0)
* ⚡️ **Windows 脚本模式 (v2.0)**：[前往下载 立体库自动化脚本包 (Release 2.0)](https://github.com/As-langs/WMS/releases/tag/2.0)
* 📦 **全部历史版本总览**：[浏览 GitHub Releases 完整列表](https://github.com/As-langs/WMS/releases)

---

## 安全注意事项

1. **写操作核实**：生产领料单创建、物料明细追加、分配审核以及 PDA 托盘实际出库确认均直接修改真实 WMS 数据库。在生产环境操作前请人工核对物料与数量无误。
2. **网络异常防重**：若遇到超时或未返回明确成功标志，请先通过 WMS 网页端核实单据状态，切勿盲目重复提交。
3. **凭据安全**：请妥善保管 WMS 账号密码与网络配置，严禁将内部局域网服务或敏感凭据泄露至公网。
