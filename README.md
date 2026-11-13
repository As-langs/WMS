# WMS 智能助手 (WMS Assistant)

面向 **iOS、Android、局域网 Web 与 Windows 自动化脚本** 的多端企业仓储物流一体化作业系统。

围绕企业 WMS 仓储高频作业场景，提供智能物料出库、托盘快捷查验、PDA 实际出库确认、近实时任务监控及高并发多模式报表导出。

---

## 目录结构与架构模块

仓库已按平台与运行场景进行模块化拆分优化，目录结构如下：

```text
WMS/
├── WMS-IOS/                 # [iOS 客户端] 原生 SwiftUI 移动端应用 (iOS 18.0+)
│   ├── WMS 1.0/             # SwiftUI 界面、网络层与长效沙盒存储
│   ├── WMSStockOutiOS.xcodeproj # Xcode 工程配置
│   ├── build_ipa.sh         # 一键离线编译与固化图标 IPA 打包脚本
│   ├── 仓储扫码蓝色立体图标.png # 1024x1024 专属应用图标
│   ├── README.md            # iOS 端特性与构建指南
│   └── HANDOFF.md           # iOS 端架构方案与深度设计交接文档
│
├── WMS-AD/                  # [Android 客户端] 原生 Android 应用工程
│   ├── app/                 # 业务源码、界面与清单配置
│   ├── gradle/              # Gradle 包装器配置
│   ├── build.gradle.kts     # 构建配置文件
│   └── README.md            # Android 端说明
│
├── WMS-WEB/                 # [局域网 Web] 局域网协同服务
│   ├── WMS-LAN-Web/         # Web 核心服务实现与静态模板
│   └── README.md            # Web 启动、端口与安全配置说明
│
├── WMS-SC/                  # [立体库后台脚本] 自动化出库与监控
│   ├── wms_integrated.py    # 综合出库与 PDA 处理脚本
│   ├── monitor_log.py       # 实时任务监控日志处理
│   ├── wms.bat              # Windows 一键启动批处理
│   ├── wms_config.json      # 脚本配置文件
│   └── README.md            # 脚本模式使用与参数说明
│
└── README.md                # 仓库总览索引与版本发布记录
```

---

## 各端平台与使用场景

| 平台 / 模块 | 核心技术栈 | 适用场景 | 快速入口 |
| :--- | :--- | :--- | :--- |
| **iOS 端 (`WMS-IOS`)** | Swift 5.0, SwiftUI, iOS 18.0+ | iPhone / iPad 移动手持作业，支持智能对话出库、托盘查验、PDA 出库确认及秒级导出 | [进入 WMS-IOS](./WMS-IOS) |
| **Android 端 (`WMS-AD`)** | Kotlin, Jetpack, Android 8.0+ | Android 手持 PDA、手机与工业平板 | [进入 WMS-AD](./WMS-AD) |
| **局域网 Web (`WMS-WEB`)** | Python Flask, HTML5 | 仓库内电脑、手机或平板免安装，通过局域网浏览器协同访问 | [进入 WMS-WEB](./WMS-WEB) |
| **自动化脚本 (`WMS-SC`)** | Python 3.10+, Batch | Windows 电脑后台持续驻留监听、自动领料出库及任务复盘 | [进入 WMS-SC](./WMS-SC) |

---

## 🔥 iOS 1.1 版本重大更新特性

最新发布的 **iOS 1.1** 版本带来了全方位的交互补齐、性能提升与桌面图标固化：

1. **补齐 PDA 托盘实际出库确认 (`OutTaskConfirm`)**：
   - 无论在主对话界面直接输入托盘号（如 `A00412`），还是在托盘快捷查验弹窗中，均可查阅物料明细、编码、规格、`TaskDetailId` 与计划数量。
   - 提供直观的机器人实际取出数量调整器（支持加减步进与直接录入），默认自动对齐计划量。
   - **两阶段二次安全核验**：确认进入“真实出库确认预览”面板，详细展示接口名、参数1（托盘号）、参数2（序列化明细）、计划/实际/剩余总量及操作警告，防止误触。
   - 提交后直观展示服务器原始响应报文，并自动同步触发本地任务监控记录增量刷新。
2. **应用图标全面固化**：
   - 内置专属 **1024x1024 蓝成立体仓储扫码桌面图标**。
   - 打包脚本自动按 iOS 规范生成多分辨率图标并注入 Payload，彻底摆脱外部模拟器代理依赖，安装后桌面图标永久固化。
3. **受控并发明细预加载与极速导出引擎**：
   - 基于 Swift 结构化并发 `TaskGroup` 维持 8 路并发池拉取缺失明细，耗时由 30~50 秒缩短至 2~3 秒（提速 8~10 倍）。
   - **双模式导出**：
     - ⚡️ **极速模式**：0.1 秒秒出，零网络请求。
     - 📋 **完整明细模式**：并发汇聚物料批次、件数、重量、质检状态等字段。
   - 支持 **带高亮样式的 Excel 2003 XML (.xls)** 与 **带 UTF-8 BOM 防乱码的通用 CSV (.csv)**。
4. **沙盒专属长效持久化**：
   - 数据存储从 `UserDefaults` 平滑无感迁移至 App 沙盒专属存储目录（`Documents/WMSTasks/`），杜绝大批量数据卡顿。
   - 具备前台 30 秒锚点增量轮询与应用启动 90 天全量历史回溯机制。

---

## 快速构建与安装指南

### 1. iOS 端打包 (IPA)
进入 `WMS-IOS` 目录，执行一键打包脚本：
```bash
cd WMS-IOS
./build_ipa.sh
```
* **输出路径**：`WMS-IOS/IPA_Build/WMSStockOutiOS.ipa`
* **产物大小**：~3.0 MB（包含 arm64 架构二进制及全套固化图标资源）

### 2. 脚本模式运行 (Windows)
```cmd
cd WMS-SC
wms.bat
```

### 3. 局域网 Web 启动
```bash
cd WMS-WEB/WMS-LAN-Web
python web_app.py
```

---

## 下载与版本发布 (Releases)

各平台正式编译安装包请访问 GitHub Releases 页面获取：

👉 **[前往 GitHub Releases 发布页面](https://github.com/As-langs/WMS/releases)**

* **iOS 客户端**：下载 `WMSStockOutiOS_v1.1.ipa`
* **Android 客户端**：下载 `WMSbeat.apk`
* **Windows / 脚本包**：下载脚本便携压缩包

---

## 安全与免责声明

1. 本项目为企业 WMS 仓储作业辅助工具，写操作（生产领料单创建、物料明细添加、审核分配以及 PDA 托盘实际出库确认）均会直接修改真实生产环境的库存与单据状态。
2. 在正式使用前，请务必在测试或受控授权网络环境中充分验证账号权限及接口连通性。
3. 请妥善保管 WMS 登录密码、PDA 用户凭据及内网服务地址，严禁将内部系统暴露至公网环境。
