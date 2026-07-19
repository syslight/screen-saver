# Task 3 报告：docs/architecture.md

## 状态

DONE

## 产出

- 创建 `docs/architecture.md`（约 15 KB，唯一产出文件，未改动任何代码文件）。

## 文档结构

1. **模块划分**：15 行表格，覆盖 `lib/config`、`lib/services`（photo/weather/calendar/command）、`lib/server`（control_server/protocol）、`lib/voice`（pipeline/wake_word/asr/tts/intent_parser/audio_utils）、`lib/ui`、`web_console`。
2. **模块图**：ASCII 图（项目无 mermaid 渲染环境，按简报建议用 ASCII），手机/键盘/语音三路输入 → `CommandService` → 各服务，广播回路回手机。
3. **启动装配顺序**：12 步，全部标注 `lib/main.dart` 实际行号（L22-23 绑定初始化 → L25-28 配置 → L31 相册目录 → L33-39 基础服务 → L40-41 指令总线 → L42-47 语音状态机 → L48-49 回调互注 → L52-55 失败隔离 init → L57-63 控制台页与服务器构造 → L64-68 启动服务器 → L70-71 常亮全屏 → L73-87 runApp）。含 8 个 provider 的表格（5×`ChangeNotifierProvider.value` + 3×`Provider.value`）。
4. **指令总线**：两个入口 `executeCommand(ConsoleCommand)`（command_service.dart:45，9 个 action 分支）与 `executeText(String)`（command_service.dart:91，`parseIntent` → `executeIntent`）；回调 `onEvent`/`onStateChanged`（command_service.dart:85-86、147）由 `ControlServer.start()` 接线（control_server.dart:57-58）触发广播；`currentState()`（command_service.dart:151）状态快照。
5. **链路一：语音交互数据流**：ASCII 高层流程（record 16kHz PCM → KWS feed → triggerListen → 录 listenSeconds 秒 → ASR → executeText → TTS → 800ms 后回 idle），降级要点各一句，字段级细节指向 `docs/voice-pipeline.md`。
6. **链路二：手机控制数据流**：ASCII 高层流程（WS 连接即发快照 → decodeCommand → executeCommand → onEvent/onStateChanged → broadcast 全部手机），含照片上传 HTTP 路径与失败隔离说明，字段级协议指向 `docs/protocol.md`。
7. **依赖选型表**：14 行，覆盖简报要求的 shelf 系、sherpa_onnx、record、audioplayers、lunar、qr_flutter、provider、window_manager/wakelock_plus、http、path_provider，另补 `path` 与 `crypto`（均为 pubspec 直接依赖且有明确架构用途），每行附选型理由。

## 验证

- 装配顺序与 `lib/main.dart` 行号级一致（逐行比对 L22-87）。
- `grep -c 'Provider.value\|ChangeNotifierProvider.value' lib/main.dart` = **8** ✓
- 链路符号与代码一致：`VoiceState`、`triggerListen`、`feed`、`transcribe`、`executeText`、`parseIntent`、`executeIntent`、`decodeCommand`、`broadcast`、`ensureKwsModel`、`secMsGec` 等均按源码原样引用。
- `env -u http_proxy ... flutter analyze` → **No issues found!**（纯文档任务，未触碰代码）

## 与代码的一处偏差说明（已如实写入文档）

简报模块图写"手机/键盘/语音 → CommandService"，但代码中键盘快捷键（`lib/ui/dashboard_page.dart` 的 `_onKey`）是**直接调用** `PhotoService.next()/prev()` 与 `VoicePipeline.triggerListen()`，不经总线也不触发广播。文档按代码事实描述，并在模块图下加了一段说明，同时强调"新增指令（尤其远程可达的）必须接入总线"的约定。这与 `AGENTS.md` / `docs/requirements.md`（FR-M-7）中"键盘也统一经 CommandService"的表述不完全一致——那是约定层面的说法，代码现状是键盘走了捷径。本次按"事实以代码为准"的全局约束处理，未改动那两篇文档；如需统一口径，建议后续任务决定是改代码还是改文档。

## 遗留事项

- `docs/protocol.md`（Task 4）与 `docs/voice-pipeline.md`（Task 5）尚未创建，本文档中的前向引用待那两个任务落地后生效。
