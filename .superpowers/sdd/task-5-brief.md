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

