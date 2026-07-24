# 语音链路（Voice Pipeline）

本文档是 smart_frame 语音链路（KWS 唤醒 → 云端 ASR → 本地意图解析 → TTS 播报）的权威文档，事实以 `lib/voice/voice_pipeline.dart`、`lib/voice/wake_word.dart`、`lib/voice/asr_client.dart`、`lib/voice/intent_parser.dart`、`lib/voice/tts_service.dart`、`lib/voice/audio_utils.dart` 为准。按 AGENTS.md 约定：**修改 `lib/voice/` 时必须同步本文档**。语音链路的高层数据流与装配顺序见 `docs/architecture.md` 第 3、5 章，语音状态文本同步到手机端的协议字段见 `docs/protocol.md` 第 3 章。

## 1. 状态机

`VoicePipeline`（`voice_pipeline.dart:17`，`ChangeNotifier`）是一个四态状态机，状态枚举为 `VoiceState`（`voice_pipeline.dart:13`）：

```dart
enum VoiceState { idle, listening, processing, speaking }
```

界面与手机端看到的不是枚举名，而是 `stateText` 映射（`voice_pipeline.dart:46-51`），其中 idle 态按唤醒词是否就绪区分两种文案，因此五种显示文案对应四个状态：

| 状态 | `stateText` | 含义 |
|---|---|---|
| `idle` | `待唤醒`（`wakeWordReady == true`）/ `手动模式`（`wakeWordReady == false`） | 空闲，常驻监听麦克风；唤醒词就绪时喂 KWS |
| `listening` | `聆听中…` | 已触发，正在录音（时长 `listenSeconds`） |
| `processing` | `识别中…` | 录音送 ASR、意图解析与执行中 |
| `speaking` | `播报中…` | TTS 播报回复中 |

状态机对外公开的字段（`voice_pipeline.dart:32-37`）：`state`、`lastHeard`（最近一次识别文字）、`lastReply`（最近一次回复文字）、`wakeWordReady`、`micReady`、`statusMessage`（降级提示，见第 5 章）。`stateText` 经 `commands.voiceStateText` 注入（`main.dart:48`）进入状态快照的 `voice` 字段，实时广播到全部手机端。

### 状态转移图

```
                   triggerListen()（仅 idle 时生效，其余状态直接 return）
┌────────┐  ① 唤醒词命中  ② 空格键  ③ 手机 listen 指令  ┌───────────┐
│  idle  │ ───────────────────────────────────────────▶ │ listening │
└────────┘                                              └───────────┘
     ▲                                                        │
     │                                              录满 listenSeconds 秒
     │                                                        ▼
     │                                                 ┌────────────┐
     │                                                 │ processing │
     │                                                 └────────────┘
     │                                                        │ _reply()
     │                       正常回复 / ASR 未配置 / 没听清 / ASR 失败，均走此分支
     │                                                        ▼
     │                                                 ┌───────────┐
     └───────────────────────────────────────────────── │ speaking  │
          TTS 播报完成后再延时 800ms（避免录到自己的播报声），  └───────────┘
          KWS reset 后回 idle
```

要点：

- 只有 `idle` 能进入 `listening`：`triggerListen()` 第一行就是 `if (state != VoiceState.idle) return;`（`voice_pipeline.dart:101`），聆听/识别/播报中的重复触发被忽略。
- `processing` 到 `speaking` 是无条件的：无论识别成功与否，都会用一条语音回复收场（降级文案见第 5 章）。
- `speaking` 回 `idle` 前固定延时 800ms 并 `WakeWordService.reset()`（`voice_pipeline.dart:137-141`），防止把自己的播报声录进去造成自激循环。

## 2. 常驻音频流

`init()` 拿到麦克风权限后，用 `record` 包开一条**常驻不关闭**的音频流（`voice_pipeline.dart:77-81`），参数照抄：

```dart
final stream = await _recorder!.startStream(const RecordConfig(
  encoder: AudioEncoder.pcm16bits,
  sampleRate: 16000,
  numChannels: 1,
));
```

即 16kHz、单声道、PCM16（小端 int16）——同时满足 sherpa-onnx KWS 与 Whisper API 的输入要求。

每个音频块的分发逻辑（`_onAudioChunk`，`voice_pipeline.dart:89-97`）：

| 条件 | 去向 |
|---|---|
| `_capturing == true`（触发后的录音窗口内） | 追加到 `_capture`，攒成一次识别用的 PCM |
| `state == idle && wakeWordReady` | 喂给 KWS：`WakeWordService.feed(chunk)`（内部 `pcmBytesToFloat32` 转 float32、`acceptWaveform(sampleRate: 16000)`、循环 `decode`，命中关键词即 `reset` 并回调 `onWake`，`wake_word.dart:83-98`） |
| 其余（listening/processing/speaking 且非录音窗口） | 丢弃——不喂 KWS、不录音 |

触发后 `_capture.clear()`、置 `_capturing = true`，录 `listenSeconds` 秒（默认 5）后置回 false（`voice_pipeline.dart:106-110`）。

## 3. 触发途径（三种）

三种途径最终都汇聚到同一个 `VoicePipeline.triggerListen()`：

| 途径 | 代码路径 |
|---|---|
| 唤醒词命中 | `VoicePipeline` 构造 `WakeWordService(onWake: triggerListen)`（`voice_pipeline.dart:63`），KWS 命中后回调 |
| 空格键 | `lib/ui/dashboard_page.dart:46` 直接调 `VoicePipeline.triggerListen()`（键盘快捷键不走指令总线，见 `docs/architecture.md` 第 2 章） |
| 手机 listen 指令 | 手机发 WS `{"type":"command","action":"listen"}` → `CommandService.executeCommand` 的 `case 'listen'` 调 `onListenRequested`（`command_service.dart:79-81`）→ 该回调在 `main.dart:49` 注入为 `voice.triggerListen`（即发即弃，不等待聆听完成） |

## 4. 处理管线

`triggerListen()` 的完整管线（`voice_pipeline.dart:100-130`）：

```
触发（三途径之一）
  │ idle → listening
  ▼
① 提示音：audioplayers 播放 generateBeepWav()（880Hz 正弦、150ms、
  16kHz，带 10ms 淡入淡出防爆音，audio_utils.dart:53-66）；播放失败被吞掉
  ▼
② 录音：KWS reset、清空 _capture，录 listenSeconds 秒
  │ listening → processing
  ▼
③ ASR 配置检查：asr.isConfigured（apiKey 非空）为 false 时短路，
  回复「还没有配置语音识别接口，请在设置里填写 API 地址和密钥。」→ 跳到 ⑦
  ▼
④ 拼 WAV：pcmToWav(List.of(_capture))——44 字节 RIFF 头 + PCM16 小端、
  16kHz、单声道（audio_utils.dart:16-50）
  ▼
⑤ 云端识别：AsrClient.transcribe(wavBytes)
  │ 识别文字 text（空 → 回复「没听清，请再说一次。」→ 跳到 ⑦）
  │ 异常 → 回复「语音识别出错了，请检查网络。」→ 跳到 ⑦
  ▼
⑥ onText(text) = CommandService.executeText(text)（main.dart:46 注入）
  = parseIntent(text) → executeIntent(intent) → 中文回复文字
  ▼
⑦ _reply(回复文字)：processing → speaking，TtsService.speak(回复)
  ▼
⑧ 播报完成后再延时 800ms，KWS reset，speaking → idle
```

### ASR 请求细节（`asr_client.dart`）

`AsrClient` 是 OpenAI 兼容 Whisper API 的客户端，三个配置项 `baseUrl` / `apiKey` / `model` 均为公开字段、设置页改了即时生效（`asr_client.dart:17-20`）：

- 请求：`POST <asrBaseUrl>/audio/transcriptions`，`multipart/form-data`。
- 头部：`Authorization: Bearer <asrApiKey>`。
- 表单字段：`model`（取 `asrModel`，默认 `whisper-1`）、`language=zh`、文件字段 `file`（WAV 字节，文件名 `audio.wav`）。
- 超时 30 秒；HTTP 非 200 抛异常；成功时取响应 JSON 的 `text` 字段并 `trim()`。
- `isConfigured` 仅判断 `apiKey.isNotEmpty`（`asr_client.dart:23`）——只配 `baseUrl` 不配 key 视为未配置。

## 5. 降级矩阵

语音链路逐层降级，任何一层失败都不影响其余功能（NFR-6，见 `docs/requirements.md`）：

| 故障点 | 检测位置 | 行为 | 用户可见 |
|---|---|---|---|
| 无麦克风权限 | `init()` 中 `hasPermission()` 返回 false（`voice_pipeline.dart:56-61`） | `micReady = false`，不启动音频流、不初始化 KWS，语音整体不可用；天气/日历/相册/手机控制不受影响 | `statusMessage`：`没有麦克风权限，语音不可用` |
| KWS 模型缺失或加载失败 | `_wake.init(modelDir)` 返回 false（`voice_pipeline.dart:64-75`） | `wakeWordReady = false`，后台 `ensureKwsModel()` 下载模型；下载成功后重新 `init` 恢复待唤醒 | idle 显示`手动模式`；`statusMessage`：`未找到唤醒词模型，正在后台下载…` |
| KWS 模型下载失败 | `ensureKwsModel` 返回 false（`voice_pipeline.dart:68-74`） | 保持手动模式：空格键 / 手机 listen 指令仍可触发完整链路 | `statusMessage`：`唤醒词模型不可用，可用空格键或手机按钮触发` |
| ASR 未配置 | `asr.isConfigured == false`（`voice_pipeline.dart:113`） | 链路在送 ASR 前短路，不发起网络请求；手机文字指令链路（`executeText` 不经 ASR）不受影响 | 语音回复`还没有配置语音识别接口，请在设置里填写 API 地址和密钥。` |
| ASR 网络失败 | `transcribe` 抛异常（超时 / HTTP 非 200），`voice_pipeline.dart:126-129` | catch 后走正常回复流程，回 idle 继续监听 | 语音回复`语音识别出错了，请检查网络。` |
| ASR 识别结果为空 | `text.isEmpty`（`voice_pipeline.dart:121`） | 正常回 idle | 语音回复`没听清，请再说一次。` |
| edge-tts 失败 | `speak()` 内超时（20 秒）或异常（`tts_service.dart:38-45`） | 自动回退系统 TTS（三平台兜底命令见 5.2） | 播报音色变化，无错误提示 |
| 系统 TTS 也失败 | `_systemTts` 的 try/catch（`tts_service.dart:141-143`） | 仅 `debugPrint`，不抛异常，状态机照常回 idle | 无播报 |
| 语音初始化其他异常 | `init()` 外层 try/catch（`voice_pipeline.dart:83-84`） | 捕获后记 `statusMessage`，不影响应用启动（`voice.init()` 本来就是 `unawaited` 后台执行） | `statusMessage`：`语音初始化失败: <错误>` |

### 5.1 KWS 模型与后台下载（`wake_word.dart`）

- **模型目录**：配置项 `wakeWordModelDir`，默认应用支持目录下的 `kws-model`（`app_config.dart:117-119`；Linux 即 `~/.local/share/com.example.smart_frame/kws-model`）。
- **必备文件**（`WakeWordService.init`，`wake_word.dart:26-67`）：`encoder*.onnx` / `decoder*.onnx` / `joiner*.onnx`（同名有多个时优先选非 int8，int8 兜底，`wake_word.dart:70-80`）+ `tokens.txt` + `keywords.txt`，缺任何一个即视为模型不可用。
- **检测参数**：`numThreads: 2`、`maxActivePaths: 4`、`keywordsThreshold: 0.25`（`wake_word.dart:52-58`）。
- **自定义唤醒词**：编辑模型目录下的 `keywords.txt` 后重启应用即可（模型为 sherpa-onnx wenetspeech 中文关键词模型）。
- **下载流程**（`ensureKwsModel`，`wake_word.dart:112-133`）：`tokens.txt` 已存在直接返回 true；否则创建目录 → HTTP GET 下载（5 分钟超时，状态码须 200）→ 存为 `kws-model.tar.bz2` → `tar -xf <压缩包> -C <模型目录> --strip-components=1` 解压 → 删除压缩包 → 再次校验 `tokens.txt` 存在。任何一步失败返回 false（进入上表"下载失败"行）。
- **模型下载地址**（`wake_word.dart:23-24`，照抄）：

```
https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2
```

### 5.2 TTS 主备切换（`tts_service.dart`）

`TtsService.speak()` 主线是 **edge-tts**（微软神经网络语音，免费；语音名取配置 `ttsVoice`，默认 `zh-CN-XiaoxiaoNeural`；音量取 `volume`，clamp 到 0..1）：

- WSS 连接 `wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1`，查询参数含 `TrustedClientToken`、`Sec-MS-GEC`（Windows ticks 向下取整到 5 分钟 + token 的 SHA256 大写，`secMsGec`，`tts_service.dart:50-59`）、`Sec-MS-GEC-Version`、`ConnectionId`。
- 先发送 `speech.config`（输出格式 `audio-24khz-48kbitrate-mono-mp3`），再发 SSML；收取二进制帧中 `Path:audio` 的负载（前 2 字节为大端头部长度），收到 `Path:turn.end` 结束；没收到音频或没等到结束帧则抛 `StateError`。
- 整条主线包 20 秒超时，成功则用 audioplayers 播放返回的 MP3 字节。

主线失败（超时、网络不可达、协议异常）后回退**系统 TTS**，按平台执行兜底命令（`_systemTts`，`tts_service.dart:127-144`）：

| 平台 | 兜底命令 |
|---|---|
| macOS | `say <text>` |
| Windows | `powershell -Command 'Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak("<text>")'`（SAPI，文本经 `jsonEncode` 转义） |
| Linux 及其他 | `espeak-ng -v zh <text>` |

系统 TTS 再失败仅记日志，不抛出。

## 6. 意图种类表（15 种）

`parseIntent`（`lib/voice/intent_parser.dart`，纯 Dart 无外部依赖）把识别文字映射为 `IntentType` 枚举，共 15 个值。语音 ASR 结果与手机端 `text_command` 文字指令**共用同一入口** `CommandService.executeText`，因此下表对两种输入一致。

解析顺序即匹配优先级（顺序影响结果，与代码一致）：

1. 去掉尾部标点与空白（正则 `[，。！？!?,.\s]+$`）；去完为空 → `unknown`。
2. `播报` / `说` 前缀（须带内容）→ `announce`。
3. `天气` → `weather`；`农历`/`阴历` → `lunar`；`几点`/`时间` → `time`；`几号`/`日期`/`星期`/`什么日子` → `date`。
4. `上一张`/`前一张` → `prevPhoto`；`下一张`/`换一张`/`换一个` → `nextPhoto`。
5. 音量带数字（正则 `音量[^\d]{0,4}(\d{1,3})`，大于 1 视为百分比，clamp 到 0..1）→ `setVolume`；否则含 `音量` 且含 `大`/`高`/`加` → `volumeUp`，含 `小`/`低`/`减` → `volumeDown`。
6. `二维码` → `showQr`；`取消筛选`/`全部照片`/`播放全部` → `clearFilter`。
7. `播放`/`放`/`看`/`只看`/`显示` + 主题 → `filter`；`帮助`/`会什么`/`能做什么`/`会做什么` → `help`。
8. 都不匹配 → `unknown`。

| IntentType | 匹配关键词（`contains`，除标注外） | 示例话术 | 执行与回复（`executeIntent`，`command_service.dart:93-149`） |
|---|---|---|---|
| `weather` | 天气 | 今天天气怎么样 | 播报当前天气：`<城市>现在<状况>，<温度>度，体感<体感>度，湿度<湿度>%。今天最高<高>度，最低<低>度。`；无数据回复`天气数据还没准备好，请稍后再试` |
| `time` | 几点 / 时间 | 现在几点 | `现在时间是 15 点 30 分。` |
| `date` | 几号 / 日期 / 星期 / 什么日子 | 今天几号 | `今天是7月18日，星期五。`（逢公历/农历节日追加`今天是<节日>。`） |
| `lunar` | 农历 / 阴历 | 农历多少 | `今天是农历<月日>，<干支>年，生肖属<生肖>。`（逢节气追加`今天是<节气>。`） |
| `nextPhoto` | 下一张 / 换一张 / 换一个 | 下一张 | `photos.next()`，回复`好的，下一张。` |
| `prevPhoto` | 上一张 / 前一张 | 上一张 | `photos.prev()`，回复`好的，上一张。` |
| `volumeUp` | 音量 + 大/高/加 | 音量大一点 | 音量 +0.1（clamp），回复`音量调到 90%。` |
| `volumeDown` | 音量 + 小/低/减 | 音量小一点 | 音量 −0.1（clamp），回复`音量调到 70%。` |
| `setVolume` | 音量 + 数字（正则） | 音量调到 50 | 设为指定值（`50`→0.5），回复`音量调到 50%。` |
| `announce` | 前缀 `播报` / `说` + 内容 | 播报：开饭了 | 用 TTS 播报剥掉 `播报`/`说` 前缀及前导分隔符（`：:，,` 与空白）后的内容（`intent_parser.dart:39-41` 的 `rest`），回复`好的。` |
| `showQr` | 二维码 | 显示二维码 | 屏幕弹出控制台二维码浮层，回复`二维码已显示在屏幕上。` |
| `filter` | 播放/放/看/只看/显示 + 主题 | 放猫的照片 | CLIP 文本搜索后仅轮播匹配 id；无结果时回复未找到 |
| `clearFilter` | 取消筛选 / 取消过滤 / 全部照片 / 播放全部 | 播放全部 | 清除筛选白名单，恢复全部可播放照片 |
| `help` | 帮助 / 会什么 / 能做什么 / 会做什么 | 你会做什么 | `我可以播报天气、时间和农历，可以切换照片、调节音量。你也可以用手机给我传照片、让我传话。` |
| `unknown` | （兜底） | 任意其他话 | `没听懂。你可以问天气、问日期，或者说下一张、音量大一点。` |

示例话术与 README「语音交互」一节保持一致。音量类回复中的百分比随当前值变化，表中仅为示例。

## 7. 相关配置项

以 `lib/config/app_config.dart` 为准，语音链路涉及其中 7 个字段（全部可在应用内按 **S** 修改；ASR 三字段改了即时生效，`listenSeconds`/`wakeWordModelDir` 等读取时机见各自代码）：

| 字段 | 默认值 | 作用 |
|---|---|---|
| `listenSeconds` | `5` | 触发后的录音时长（秒） |
| `asrBaseUrl` | `https://api.openai.com/v1` | Whisper API 地址，可指向 OpenAI、Groq 或本地 faster-whisper |
| `asrApiKey` | 空 | ASR API Key；为空即"ASR 未配置"降级 |
| `asrModel` | `whisper-1` | ASR 模型名（multipart 的 `model` 字段） |
| `ttsVoice` | `zh-CN-XiaoxiaoNeural` | edge-tts 语音名 |
| `volume` | `0.8` | 播报音量 0..1（语音/手机指令调节后会写回配置） |
| `wakeWordModelDir` | 空 → 应用支持目录/`kws-model` | KWS 模型目录（见 5.1） |
