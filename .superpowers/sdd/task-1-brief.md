### Task 1: AGENTS.md

**Files:**
- Create: `AGENTS.md`

**Interfaces:**
- Consumes: 本计划 Global Constraints；`pubspec.yaml`；`README.md`；`lib/main.dart`（服务装配）；`lib/config/app_config.dart`（12 个配置字段及默认值）
- Produces: 所有后续 agent 会话的项目入口；`docs/README.md` 会链接回它

- [ ] **Step 1: 写 AGENTS.md**，章节与必含事实如下：

章节：
1. 项目简介（一句话：Flutter 桌面全屏智能屏，Windows/macOS/Linux，天气/日历/相册/语音/手机控制）
2. 构建与命令（代码块）：
   - `flutter pub get`、`flutter analyze`、`flutter test`、`flutter run -d linux`、`flutter build linux|windows|macos --release`
   - **代理坑**：本机代理（127.0.0.1:10808）会劫持 flutter_tester 的 localhost WebSocket，跑 test/run 前必须 `unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy`（或 `env -u`）
   - **Linux GStreamer**：audioplayers 需要 gstreamer-1.0/app/audio 开发文件；无 sudo 时用用户态方案：`export PKG_CONFIG_PATH=$HOME/.local/opt/gst/usr/lib/x86_64-linux-gnu/pkgconfig` 和 `export LIBRARY_PATH=$HOME/.local/opt/gst/usr/lib/x86_64-linux-gnu`（dev 文件由 apt 下载 dpkg -x 解到该目录，.so 软链已指向系统运行时库）
   - **CMake 缓存坑**：configure 失败过的缓存会把 `CMAKE_INSTALL_PREFIX` 留在 `/usr/local`，导致 install 阶段 Permission denied；修法是改 `build/linux/x64/release/CMakeCache.txt` 中该值为 `<项目根>/build/linux/x64/release/bundle`，或 `flutter clean`
3. 目录结构（照 README 架构速览，`lib/` 下 config/services/server/voice/ui + `web_console/` + `test/`）
4. 硬性约定：
   - 改代码后必须 `flutter analyze` 无问题且 `flutter test` 全绿（当前 29 个用例）
   - 所有外部指令（语音/手机/键盘）统一经 `CommandService`（`lib/services/command_service.dart`），新指令不得绕过
   - 改目录结构/命令/协议/配置项必须同步更新对应文档（指到具体文件）
   - 规格文档落 `docs/superpowers/specs/`，计划落 `docs/superpowers/plans/`
5. 配置：文件路径 `~/.local/share/com.example.smart_frame/config.json`（Linux），12 个字段表格（字段名/默认/含义，从 `app_config.dart` 抄：city 北京、photoDir 空→~/Pictures、serverPort 8780、slideshowSeconds 10、weatherRefreshMinutes 30、listenSeconds 5、asrBaseUrl https://api.openai.com/v1、asrApiKey 空、asrModel whisper-1、ttsVoice zh-CN-XiaoxiaoNeural、volume 0.8、wakeWordModelDir 空→支持目录/kws-model）
6. 测试地图：5 个测试文件各自覆盖什么（calendar/control_server/intent_parser/protocol/weather）

- [ ] **Step 2: 验证**
  - `flutter analyze` 无问题（证明没碰代码）
  - 抽查：`grep -c '"' lib/config/app_config.dart` 确认字段表与源码一致；`ls test/` 确认测试地图准确

