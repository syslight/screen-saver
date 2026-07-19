# 项目文档初始化 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 smart_frame 建立 AGENTS.md + docs/ 文档体系（9 个文件），内容以代码事实为准。

**Architecture:** 纯文档任务，不改任何代码。每个任务产出一篇文档，事实从指定源码文件提取；最后任务做全量验收。

**Tech Stack:** Markdown，Flutter 3.44+ / Dart ^3.12.2 项目。

## Global Constraints

- 全部文档用**中文**（代码标识符、命令、路径保持原文）。
- 规格：`docs/superpowers/specs/2026-07-18-project-docs-design.md`。
- **不得修改 `lib/`、`test/`、`web_console/`、`pubspec.yaml` 等任何代码文件**；只允许创建 `AGENTS.md` 和 `docs/**`。
- 文档中的事实必须与代码一致：命令必须真实可执行，协议字段以 `lib/server/protocol.dart` 为准，配置字段以 `lib/config/app_config.dart` 为准。
- 本项目**不是 git 仓库**：所有"commit"步骤跳过。
- Markdown 风格与 README.md 一致（中文叙述 + 表格 + 代码块）。

---

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

### Task 2: docs/requirements.md

**Files:**
- Create: `docs/requirements.md`

**Interfaces:**
- Consumes: `README.md`、`lib/config/app_config.dart`、`lib/main.dart`（失败隔离注释）、`lib/voice/voice_pipeline.dart`（降级逻辑）
- Produces: 需求基线；roadmap 中的限制项须与本文档非功能需求呼应

- [ ] **Step 1: 写 docs/requirements.md**：
  - 功能需求（按模块列可勾选项）：天气（Open-Meteo、免 key、城市名地理编码、定时刷新）、日历（公历/农历/干支生肖/节气/节日）、相册（本地目录轮播、交叉渐变、jpg/png/webp/bmp/gif——实际扩展名以 `lib/services/photo_service.dart` 的 `imageExts` 为准，写文档前先读它）、语音交互（唤醒词/空格/手机按钮三触发、文字指令、意图种类）、TTS（edge-tts 主用、系统 TTS 兜底）、手机控制（扫码进控制台、多设备同时在线、状态实时同步、上传照片）
  - 非功能需求：三平台桌面、全屏常驻（wakelock）、零配置可启动、单服务初始化失败不影响整体（`main.dart` 注释为据）、局域网内工作、语音链路逐层降级（KWS 模型缺失→手动模式；ASR 未配置→文字指令仍可用；TTS 网络失败→系统 TTS）
- [ ] **Step 2: 验证**：`grep imageExts lib/services/photo_service.dart` 核对扩展名清单；需求条目与 README 功能列表无矛盾

### Task 3: docs/architecture.md

**Files:**
- Create: `docs/architecture.md`

**Interfaces:**
- Consumes: `lib/main.dart`、`lib/services/command_service.dart`、`lib/server/control_server.dart`、`lib/voice/voice_pipeline.dart`、`pubspec.yaml`
- Produces: 架构基线；protocol.md 与 voice-pipeline.md 是其两条链路的展开

- [ ] **Step 1: 写 docs/architecture.md**：
  - 模块图（ASCII 或 mermaid，手机/键盘/语音 → CommandService → 各服务 → ControlServer 广播回手机）
  - 启动装配顺序（`main.dart`：config → photos → weather/tts/asr → CommandService → VoicePipeline（注入 executeText 与回调）→ 各服务独立 init（失败隔离）→ ControlServer → wakelock/全屏 → MultiProvider 8 个 provider）
  - 指令总线两个入口：`executeCommand(ConsoleCommand)`（手机 WS）与 `executeText(String)`（语音/文字，经 `parseIntent` → `executeIntent`），执行后 `onEvent`/`onStateChanged` 回调触发广播
  - 两条链路数据流各画一遍（语音：KWS→录 listenSeconds 秒→ASR→parseIntent→executeIntent→TTS；手机：WS command→executeCommand→broadcast state/event）
  - 依赖选型表：shelf*（内嵌 HTTP/WS）、sherpa_onnx（本地 KWS）、record（16kHz PCM 录音）、audioplayers（提示音）、lunar（农历）、qr_flutter、provider、window_manager/wakelock_plus、http、path_provider
- [ ] **Step 2: 验证**：装配顺序与 `lib/main.dart` 行号级一致；`grep 'Provider.value\|ChangeNotifierProvider.value' lib/main.dart | wc -l` = 8

### Task 4: docs/protocol.md

**Files:**
- Create: `docs/protocol.md`

**Interfaces:**
- Consumes: `lib/server/protocol.dart`、`lib/server/control_server.dart`、`lib/services/command_service.dart`（action 分支）、`web_console/index.html`（客户端实际发送的消息，写前必须读）
- Produces: 手机控制协议文档；修改 `lib/server/` 时必须同步本文档

- [ ] **Step 1: 写 docs/protocol.md**：
  - 连接：HTTP `GET /` 控制台页、`GET /ws` WebSocket、`POST /api/photos` multipart 上传；端口默认 8780，URL 为局域网 IP（`ControlServer.url`）
  - 客户端→服务器消息：`{"type":"command","action":<string>,"text"?:<string>,"value"?:<number>}`；action 全表（next_photo/prev_photo/refresh_weather/set_volume/announce/text_command/show_qr/hide_qr/listen，各参数与效果，以 `command_service.dart` switch 为准——注意 protocol.dart 注释里没有 hide_qr 但代码有，文档以代码为准）
  - 服务器→客户端：连接即推 `{"type":"state", photo, photoCount, weather, voice, volume}`（字段以 `currentState()` 为准），状态变化广播同构；事件 `{"type":"event","message":...}`；非法消息回复 event `无法理解的指令` 且不断连
  - 上传：multipart 字段按扩展名过滤（imageExts），文件名清洗（非法字符→`_`，去路径、空名/点开头→`photo`），重名加毫秒时间戳，全部完成后 `photos.rescan()`，响应 `{"saved": N}`
  - 附 1-2 个示例（curl 上传、WS 消息对）
- [ ] **Step 2: 验证**：`grep -n "case '" lib/services/command_service.dart` 列出的 action 与文档表格逐一对应；`grep -n "get(\|post(" lib/server/control_server.dart` 路由一致

### Task 5: docs/voice-pipeline.md

**Files:**
- Create: `docs/voice-pipeline.md`

**Interfaces:**
- Consumes: `lib/voice/voice_pipeline.dart`、`lib/voice/tts_service.dart`、`lib/voice/wake_word.dart`、`lib/voice/asr_client.dart`、`lib/voice/intent_parser.dart`（全部读一遍）
- Produces: 语音链路文档；改 `lib/voice/` 时必须同步

- [ ] **Step 1: 写 docs/voice-pipeline.md**：
  - 状态机：`idle/listening/processing/speaking` 四态 + `stateText` 映射（待唤醒/手动模式/聆听中…/识别中…/播报中…）+ 状态转移图
  - 常驻音频流：16kHz 单声道 PCM16（`RecordConfig` 参数照抄）；idle 且 wakeWordReady 时喂 KWS；触发后录 `listenSeconds` 秒
  - 触发三途径：唤醒词命中（`WakeWordService.onWake`）、空格键、手机 listen 指令（`onListenRequested`）
  - 处理管线：beep 提示音（`generateBeepWav`）→ `pcmToWav` → `AsrClient.transcribe`（OpenAI 兼容 Whisper，base_url/key/model 三配置）→ `onText`（即 `CommandService.executeText`）→ TTS 播报 → 800ms 后回 idle（避免录到自己）
  - 降级矩阵：无麦克风权限 / KWS 模型缺失（后台 `ensureKwsModel` 下载，模型 URL 与目录从 `wake_word.dart` 抄）/ 下载失败（手动模式）/ ASR 未配置 / ASR 网络失败 / TTS 主备切换（edge-tts→系统 TTS，以 `tts_service.dart` 实际实现为准，三平台兜底命令写清）
  - 意图种类表（读 `intent_parser.dart`：IntentType 全枚举 + 示例话术，与 README 话术示例对齐）
- [ ] **Step 2: 验证**：IntentType 枚举数 `grep -c '^\s\+\w\+,' lib/voice/intent_parser.dart` 与文档表一致；状态名与 `voice_pipeline.dart` 一致

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

### Task 7: docs/deployment.md

**Files:**
- Create: `docs/deployment.md`

**Interfaces:**
- Consumes: `README.md`、`linux/`、`windows/`、`macos/` 工程目录存在性
- Produces: 打包分发指南

- [ ] **Step 1: 写 docs/deployment.md**：
  - 三平台构建命令与产物路径（Linux：`flutter build linux --release` → `build/linux/x64/release/bundle/`；Windows/macOS 同构，需对应系统上构建，不可交叉编译桌面端）
  - 分发清单：bundle 整目录拷贝；首启注意（KWS 模型需联网下载一次、ASR 需在设置里配 API、相册默认 ~/Pictures、防火墙需放行控制台端口 8780）
  - 开机自启/无人值守：仅列出思路（各平台自启机制一句话），不展开实现
- [ ] **Step 2: 验证**：产物路径与 `flutter build linux --release` 实际输出一致（本机已有 `build/linux/x64/release/bundle/smart_frame` 可 `ls` 验证）

### Task 8: docs/roadmap.md

**Files:**
- Create: `docs/roadmap.md`

**Interfaces:**
- Consumes: 已写好的 requirements.md（保持口径）；`lib/server/control_server.dart`（无鉴权事实）；`lib/voice/wake_word.dart`（模型来源）
- Produces: 已知限制 + 候选改进清单

- [ ] **Step 1: 写 docs/roadmap.md**：
  - 已知限制（每条给依据）：唤醒词模型首次需访问 GitHub（release-assets 可能超时）；ASR 依赖外部 OpenAI 兼容 API；控制台无鉴权（局域网内任何设备可连可发指令，依据：`control_server.dart` 无 auth 中间件）；上传无大小/配额限制；无原生手机 App（浏览器控制台）
  - 候选改进（不承诺排期）：局域网 token 鉴权、本地 ASR（faster-whisper）、自定义唤醒词、照片管理（删除/收藏）、Android/iOS 原生控制台、天气预警播报
- [ ] **Step 2: 验证**：限制项与 requirements.md 非功能需求不矛盾；无鉴权表述与代码一致

### Task 9: docs/README.md + 收尾验收

**Files:**
- Create: `docs/README.md`
- Modify: `README.md`（只加一行指向 docs/ 的链接，不重写）

**Interfaces:**
- Consumes: 前 8 个任务的产出
- Produces: 文档索引；完整文档体系

- [ ] **Step 1: 写 docs/README.md**：9 篇文档表格索引（文件/一句话说明/何时读）
- [ ] **Step 2: 在 README.md 的"架构速览"前加一行**：`完整文档见 [docs/](docs/README.md)（需求、架构、协议、语音、开发、部署、路线图）。`
- [ ] **Step 3: 全量验收**
  - `flutter analyze` 无问题、`env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy flutter test` 29 用例全过
  - `ls AGENTS.md docs/README.md docs/requirements.md docs/architecture.md docs/protocol.md docs/voice-pipeline.md docs/development.md docs/deployment.md docs/roadmap.md` 全部存在
  - 链接检查：docs/README.md 中所有相对链接指向存在的文件
  - 事实抽查：随机 3 条文档中的命令实际执行成功
