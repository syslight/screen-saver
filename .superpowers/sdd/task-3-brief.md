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

