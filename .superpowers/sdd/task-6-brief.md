### Task 6: docs/development.md

**Files:**
- Create: `docs/development.md`

**Interfaces:**
- Consumes: `README.md`（开发环境节）、本计划 Global Constraints 的三条环境坑、`test/` 目录
- Produces: 开发者上手指南；AGENTS.md 的展开版

- [ ] **Step 1: 写 docs/development.md**：
  - 环境：Flutter 3.44+ stable；Linux 构建链 `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`；GStreamer dev（`libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev`）+ 无 sudo 的用户态替代方案（同 Global Constraints）
  - 日常命令：run/test/analyze（带代理注意事项）；本机实测：`env -u http_proxy ... flutter test` → 29 用例全过
  - 调试：服务日志走 `debugPrint`（flutter run 控制台可见，如"控制台已启动: http://..."）；语音初始化失败仅体现在状态栏文本
  - 测试说明：5 个测试文件覆盖点；`control_server_test.dart` 用 `serverPort: 0` 由系统分配端口（写前先扫一眼确认）
- [ ] **Step 2: 验证**：`flutter analyze` 无问题；文档中 apt 包名与 README 一致（gstreamer 两个包是新增事实）

