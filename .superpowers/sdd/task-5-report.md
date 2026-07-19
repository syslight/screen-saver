# Task 5 报告：docs/voice-pipeline.md

日期：2026-07-18
状态：DONE

## 交付物

- 新建 `docs/voice-pipeline.md`（约 17.5 KB），为语音链路（KWS→ASR→意图→TTS）的权威文档，声明"修改 `lib/voice/` 时必须同步本文档"，并与 `docs/architecture.md`（第 2、3、5 章）、`docs/protocol.md`（第 3 章）、`docs/requirements.md`（NFR-6）交叉引用。

## 文档结构（与简报逐条对应）

1. **状态机**：`VoiceState` 四态（`idle/listening/processing/speaking`，voice_pipeline.dart:13）+ `stateText` 五文案映射（待唤醒/手动模式/聆听中…/识别中…/播报中…，voice_pipeline.dart:46-51）+ ASCII 状态转移图（含"仅 idle 可进 listening""processing→speaking 无条件""speaking 回 idle 前 800ms 延时 + KWS reset"三个要点）。
2. **常驻音频流**：`RecordConfig(encoder: pcm16bits, sampleRate: 16000, numChannels: 1)` 参数照抄（voice_pipeline.dart:77-81）；`_onAudioChunk` 三分支分发表（录音窗口 / idle 且 wakeWordReady 喂 KWS / 其余丢弃）；触发后录 `listenSeconds` 秒。
3. **触发三途径**：唤醒词命中（`WakeWordService(onWake: triggerListen)`，voice_pipeline.dart:63）、空格键（dashboard_page.dart:46 直连，不经总线）、手机 listen 指令（command_service.dart:79-81 → `onListenRequested`，main.dart:49 注入）。
4. **处理管线**：8 步流程图——`generateBeepWav` 提示音（880Hz/150ms/16kHz/10ms 淡入淡出）→ 录音 → ASR 配置短路检查 → `pcmToWav` 拼 44 字节 WAV 头 → `AsrClient.transcribe`（POST `<baseUrl>/audio/transcriptions`，multipart，Bearer 鉴权，`model`+`language=zh`，30s 超时）→ `onText` = `CommandService.executeText` → `_reply` TTS 播报 → 800ms 后回 idle；ASR 请求细节单列小节。
5. **降级矩阵**：9 行矩阵（无麦克风权限 / KWS 模型缺失 / 下载失败（手动模式）/ ASR 未配置 / ASR 网络失败 / 识别结果为空 / edge-tts 失败 / 系统 TTS 也失败 / 初始化其他异常），每行含检测位置（文件:行号）、行为、用户可见文案（均逐字抄自代码）。5.1 节 KWS 模型细节（默认目录、必备文件、`keywordsThreshold: 0.25` 等参数、`ensureKwsModel` 下载解压流程、模型 URL 照抄）；5.2 节 TTS 主备（edge-tts WSS 协议要点 + 20s 超时）与三平台兜底命令表（macOS `say` / Windows PowerShell System.Speech / Linux `espeak-ng -v zh`）。
6. **意图种类表**：解析顺序 7 步（含尾部标点剥离、播报前缀优先、音量正则优先于大小）+ 13 种 `IntentType` 全枚举表（匹配关键词、示例话术、执行与回复），示例话术与 README「语音交互」一节对齐。
7. **相关配置项**：7 个语音相关字段表（`listenSeconds`/`asrBaseUrl`/`asrApiKey`/`asrModel`/`ttsVoice`/`volume`/`wakeWordModelDir`），以 `app_config.dart` 为准。

## 验证

- **IntentType 枚举数**：`grep -c '^\s\+\w\+,' lib/voice/intent_parser.dart` = 13，文档意图表恰 13 行（weather/time/date/lunar/nextPhoto/prevPhoto/volumeUp/volumeDown/setVolume/announce/showQr/help/unknown，顺序与枚举一致）。✅
- **状态名**：与 voice_pipeline.dart 逐字一致（含 `…` 省略号与 idle 双文案条件）。✅
- **KWS 模型 URL**：与 wake_word.dart:23-24 拼接结果逐字符一致（grep 复核）。✅
- **TTS 兜底命令**：与 tts_service.dart:127-144 的 `Platform.isMacOS`/`isWindows`/else 三分支一致。✅
- **星期格式**：`calendar_service.dart:41` 为 `'星期${solar.getWeekInChinese()}'`，文档示例"星期五"成立。✅
- **`flutter analyze`**：`env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy /home/peidong/flutter/bin/flutter analyze` → **No issues found!**（未改动任何代码，仅新增 docs/voice-pipeline.md）。✅
- 未执行 `flutter test`：纯文档任务未触碰 `lib/`、`test/`，按简报只需 analyze；测试基线（29 用例）不受影响。

## 边界遵守

- 仅创建 `docs/voice-pipeline.md` 与本报告，未修改 `lib/`、`test/`、`web_console/`、`pubspec.yaml` 等任何代码文件。
- 本项目非 git 仓库，未执行任何 git 操作。

## 疑虑

- 规格文档清单中的 `docs/README.md`（文档索引）当前不存在，本任务范围外，未创建；索引中对 voice-pipeline.md 的登记应由负责 docs/README.md 的任务处理。
- 意图表中音量回复的百分比（90%/70%/50%）为按默认值 0.8 推算的示例，已在表下注明"随当前值变化"。
