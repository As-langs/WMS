# WMS 出库助手 + 后台任务监控基于iPhone bark （自动登录配置版）

## 文件
- `wms_integrated.py`：整合后的出库助手和后台任务监控。
- `wms_config.json`：本地账号密码与 Bark 推送地址配置。

## 启动
1. 将两个文件放在同一目录。
2. 打开 `wms_config.json`，确认 `username`、`password` 和 `bark_url` 是你自己的配置。
3. 安装依赖：`python -m pip install requests`
4. 启动：`python wms_integrated.py`

程序会自动读取配置并登录，不再每次启动时询问 WMS 用户名和密码。`WMS_USERNAME`、`WMS_PASSWORD`、`WMS_BARK_URL` 环境变量可覆盖配置文件中的值。

## 安全提示
- 当前配置中的账号密码请务必核对是否正确，建议改为本机实际账号密码。
- `wms_config.json` 包含密码，不要发给他人或上传到公共网盘/代码仓库。
- 本程序会创建真实出库单、审核并自动分配。首次测试前请确认物料、数量和出口；结果不明确时先在 WMS 核对，不要直接重试。
- monitor_log.py为单监控脚本
- wms_integrated.py为自动出库+监控脚本
