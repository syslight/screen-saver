# HomeAdmin 直接重构计划

1. [x] 从 Home Agent 移除内嵌 `/parent/` 与 `/admin/` 页面。
2. [x] 新增 `services/home_admin`，托管统一 WebUI 并通过 BFF 调用 Home Agent API。
3. [x] 将 `apps/parent` 直接改为 `apps/home_admin`，同步 Flutter/Android 产品名。
4. [x] Home Agent 增加 write-only Provider 密钥管理、脱敏状态和审计。
5. [x] HomeAdmin WebUI 与 App 接入 Provider 状态、选择、检测和密钥管理。
6. [x] 同步当前架构、协议、开发、部署文档并执行 Python/Flutter 全套门禁。
7. [x] 启动 HomeAdmin 服务并打开 `http://127.0.0.1:8800/`。
