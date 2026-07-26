# 架构基线（Architecture）

本文档是 smart_frame 的架构基线：模块划分、启动装配顺序、`CommandService` 指令总线，以及语音交互与手机控制两条主链路的高层数据流。文中事实以代码为准（装配顺序以 `lib/main.dart` 行号为据）。

两条链路在本文只画高层数据流，字段级细节分别由专项文档展开：WebSocket/HTTP 协议见 `docs/protocol.md`，语音状态机与降级策略见 `docs/voice-pipeline.md`。

## 1. 模块划分

| 目录 / 文件 | 关键类 / 函数 | 职责 |
|---|---|---|
| `lib/config/app_config.dart` | `AppConfig` / `ConfigService` | 19 个配置字段的模型、加载与持久化（`config.json`），零配置可启动 |
| `lib/services/photo_service.dart` | `PhotoService` / `PhotoItem` | 本地 + NAS 相册聚合、自动轮播、按照片 ID 持久化/恢复播放位置、定时重扫、`nas-cache` 磁盘缓存与下一张预取、NAS 故障静默降级 |
| `lib/services/photo_index_service.dart` | `PhotoIndexService` / `PhotoDescription` | hidden/标签/人物索引，以及当前照片的已确认家庭身份、时间、地点、第三人称解说的计算端 SQLite / 展示端 HTTP 双后端 |
| `lib/services/screen_awake_service.dart` | `ScreenAwakeService` | wakelock 常亮；Linux 叠加 X11 屏保/DPMS 关闭与周期重申 |
| `lib/services/nas_photo_source.dart` | `NasSource` / `NasPhotoSource` / `NasPhotoRef` | NAS WebDAV 图源（`webdav_client`）：连接测试、递归列出远程图片（扩展名 + 截图规则过滤）、按引用下载；错误原样抛给调用方 |
| `lib/services/nas_filter.dart` | `nasPhotoAllowed`（纯函数） | NAS 截图规则过滤：关键词（替换语义、大小写不敏感、空串跳过）+ 内置截图文件名正则 |
| `lib/services/weather_service.dart` | `WeatherService` / `weatherFromJson` / `weatherCodeText` | Open-Meteo 地理编码 + 天气定时刷新，失败保留旧数据 |
| `lib/services/calendar_service.dart` | `calendarInfoFor`（纯函数） | 农历、干支生肖、节气、公历/农历节日（基于 `lunar` 包） |
| `lib/services/command_service.dart` | `CommandService` | **统一指令总线**：手机 / 语音 / 文字指令的唯一入口，见第 4 章 |
| `lib/server/control_server.dart` | `ControlServer` | shelf 内嵌 HTTP/WebSocket 服务器：控制台页、指令通道、照片上传、状态广播 |
| `lib/server/protocol.dart` | `ConsoleCommand` / `decodeCommand` / `encodeState` / `encodeEvent` | 手机端 WS 消息协议编解码 |
| `lib/voice/voice_pipeline.dart` | `VoicePipeline` / `VoiceState` | 语音状态机：常驻监听 → 唤醒 → 录音 → ASR → 意图 → TTS |
| `lib/voice/wake_word.dart` | `WakeWordService` / `ensureKwsModel` | sherpa-onnx KWS 唤醒词检测；模型缺失时后台下载 |
| `lib/voice/asr_client.dart` | `AsrClient` | OpenAI 兼容 Whisper API 客户端（`/audio/transcriptions`） |
| `lib/voice/tts_service.dart` | `TtsService` | edge-tts 播报（WSS 协议手写），失败回退系统 TTS |
| `lib/voice/intent_parser.dart` | `parseIntent` / `Intent` / `IntentType` | 本地意图解析（13 种意图，纯 Dart 无外部依赖） |
| `lib/voice/audio_utils.dart` | `pcmToWav` / `pcmBytesToFloat32` / `generateBeepWav` | PCM/WAV 转换与提示音生成 |
| `lib/ui/` | `DashboardPage` + 各 widget | 全屏仪表盘：相册背景（按屏幕物理尺寸等比解码，避免 ARM 软件渲染展开超大原图）+ 左上环境信息岛 + 右下动画故事卡 + 语音指示/二维码/设置浮层 |
| `web_console/index.html` | — | 手机控制台单页（原生 JS，打包进 Flutter assets） |

## 2. 模块图

```
      手机浏览器 ×N                 键盘快捷键                     麦克风
  (web_console/index.html)      ←→ 空格 Q S Esc                     │
            │                          │                     16kHz PCM 流
   HTTP / WebSocket                    │ 直接调用                    │
            ▼                          ▼（不经总线）                ▼
  ┌───────────────────┐     ┌─────────────────────┐    ┌─────────────────────┐
  │ ControlServer      │     │ ←→ → PhotoService.  │    │ VoicePipeline        │
  │ （lib/server/）     │     │     next()/prev()   │    │ （lib/voice/）       │
  │ shelf HTTP + WS    │     │ 空格 → VoicePipeline│    │ KWS 唤醒 → 录音      │
  │  GET /             │     │     .triggerListen()│    │ → ASR → executeText │
  │  GET /ws           │     └─────────────────────┘    │ → TTS 播报          │
  │  POST /api/photos  │                                └──────────┬──────────┘
  └─────────┬──────────┘                                           │ 识别文字
            │ ConsoleCommand                                       ▼
            │                    ┌───────────────────────────────────────────┐
            │                    │ CommandService（lib/services/，指令总线）   │
            └───────────────────▶│ ① executeCommand(ConsoleCommand)          │
                                 │ ② executeText(String) = parseIntent       │
                                 │     → executeIntent(Intent)               │
                                 └──┬────────┬──────────┬──────────┬────────┘
                                    ▼        ▼          ▼          ▼
                             PhotoService WeatherService TtsService
                             （另：calendarInfoFor 纯函数，执行意图时直接调用）

  广播回路：executeCommand 执行后回调 onEvent + onStateChanged；executeIntent
  只回调 onStateChanged（均由 ControlServer.start 接线）→ ControlServer.broadcast
  → encodeEvent / encodeState → WebSocket 广播给全部已连接手机。
```

关于键盘：`lib/ui/dashboard_page.dart` 的快捷键是轻量本地操作——←/→ 直接调 `PhotoService.next()/prev()`，空格直接调 `VoicePipeline.triggerListen()`，S/Esc 为纯界面行为（设置 / 退出全屏）；Q 切换二维码浮层，隐藏时会调 `CommandService.dismissQr()` 同步本地状态（仅置 `showQrRequested = false` + `notifyListeners()`，不触发广播）。键盘快捷键整体不经指令总线；手机和语音两个入口才走总线；**新增指令（尤其是远程可达的）必须接入总线，不得绕过**。

## 3. 启动装配顺序（`lib/main.dart`）

`main()` 自上而下一次性完成服务装配，顺序如下（行号为 `lib/main.dart` 实际行号）：

1. **绑定初始化**（L24-25）：`WidgetsFlutterBinding.ensureInitialized()` + `windowManager.ensureInitialized()`。
2. **加载配置**（L27-30）：`getApplicationSupportDirectory()` 取应用支持目录 → 构造 `ConfigService` → `load()` 读 `config.json`（缺失/损坏回落默认值）。
3. **创建相册目录**（L33）：`Directory(config.photoDir).create(recursive: true)`。
4. **装配 NAS 图源与相册**（L35-43）：`NasPhotoSource` 按配置 `configure(url/user/password/remoteDir)`（仅建客户端，不连接）→ 构造 `PhotoService(photoDir, cacheDir: 支持目录/nas-cache)`。
5. **构造基础服务**（L44-49）：`WeatherService`（城市）、`TtsService`（语音名、音量）、`AsrClient`（baseUrl/apiKey/model）——均为纯构造，无副作用。
6. **构造指令总线**（L50-51）：`CommandService(config, photos, weather, tts)`。
7. **构造语音状态机**（L52-57）：`VoicePipeline(config, tts, asr, onText: commands.executeText)`——语音链路的识别文字直接注入总线的文字入口。
8. **回调互注**（L58-59）：`commands.voiceStateText = () => voice.stateText`（状态快照含语音状态）；`commands.onListenRequested = voice.triggerListen`（手机端"按住说话"按钮触发聆听）。
9. **各服务独立初始化，失败隔离**（L62-67）：`photos.init()` → `photos.applyNasConfig(config, nasSource)`（内部按 `nasEnabled`/`nasRemoteDir` 决定是否真连，失败静默降级）→ `startSlideshow(slideshowSeconds)`；`weather.start(refreshMinutes: ...)`；`voice.init()` 用 `unawaited` 放后台。单个服务失败（无麦克风权限、无网络、NAS 不可达等）不影响其余服务与界面启动。
10. **加载控制台页并构造服务器**（L69-75）：`rootBundle.loadString('web_console/index.html')` → 构造 `ControlServer(port, commands, photos, indexHtml)`。
11. **启动服务器**（L76-80）：`server.start()` 包在 try/catch 中，失败仅 `debugPrint`，应用照常运行（手机控制不可用）。
12. **常亮与全屏**：`ScreenAwakeService.start()` 启用 wakelock；Linux 叠加 `xset s off` / `xset -dpms` / `xset s noblank` 并周期重申；随后进入沉浸式全屏。
13. **runApp**（L85-100）：`MultiProvider` 注入 9 个 provider 后启动 `SmartFrameApp`（深色 Material 3 主题，首页 `DashboardPage`）。

9 个 provider（main.dart:87-97）：前 5 个是 `ChangeNotifierProvider.value`（对象本身是可监听的状态源），后 4 个是 `Provider.value`（纯服务对象）：

| provider 类型 | 对象 | 类 |
|---|---|---|
| `ChangeNotifierProvider.value` | configService | `ConfigService` |
| `ChangeNotifierProvider.value` | photos | `PhotoService` |
| `ChangeNotifierProvider.value` | weather | `WeatherService` |
| `ChangeNotifierProvider.value` | voice | `VoicePipeline` |
| `ChangeNotifierProvider.value` | commands | `CommandService` |
| `Provider.value` | tts | `TtsService` |
| `Provider.value` | asr | `AsrClient` |
| `Provider.value` | nasSource | `NasPhotoSource`（设置页"NAS 相册"区重建连接用） |
| `Provider.value` | server | `ControlServer` |

## 4. 指令总线 `CommandService`

所有远程/文字指令统一经 `CommandService`（`lib/services/command_service.dart`）处理，它持有 `AppConfig`、`PhotoService`、`WeatherService`、`TtsService` 的引用。总线有两个入口：

- **入口① `executeCommand(ConsoleCommand)`**（command_service.dart:45）：手机 WS 指令入口。按 `cmd.action` 分发：`next_photo` / `prev_photo` / `refresh_weather` / `set_volume` / `announce` / `text_command` / `show_qr` / `hide_qr` / `listen`（其中 `text_command` 桥接到入口②，`listen` 经 `onListenRequested` 回调触发 `VoicePipeline.triggerListen`）。执行完成后依次回调 `onEvent(message)` 与 `onStateChanged()`（command_service.dart:85-86）。
- **入口② `executeText(String)`**（command_service.dart:91）：语音 ASR 结果与手机文字输入共用，即 `executeIntent(parseIntent(text))`——先本地意图解析，再按意图类型执行（查天气/时间/日期/农历、切照片、调音量、播报、显示二维码、帮助、未知），生成中文回复文字。执行完成后回调 `onStateChanged()`（command_service.dart:147）。

两个回调由 `ControlServer.start()` 接线（control_server.dart:57-58）：`onEvent` → `broadcast(encodeEvent(msg))`；`onStateChanged` → `broadcast(encodeState(commands.currentState()))`。`currentState()`（command_service.dart:151）汇总当前照片、照片数、天气摘要、语音状态、音量，构成发给手机端的状态快照。

## 5. 链路一：语音交互数据流

```
麦克风 ──record──▶ 16kHz 单声道 PCM 流 ──▶ VoicePipeline
   （idle 且唤醒词就绪）WakeWordService.feed(chunk)   [sherpa-onnx KWS]
        │ 命中唤醒词（或空格键 / 手机 listen 指令手动触发）
        ▼
   triggerListen()
        │ listening：播放提示音（audioplayers），录音 listenSeconds 秒（默认 5）
        ▼
   processing：PCM 拼 WAV ──▶ AsrClient.transcribe()   [OpenAI 兼容 Whisper API]
        │ 识别文字
        ▼
   CommandService.executeText(text)
        = parseIntent(text) → executeIntent(intent) → 回复文字
        ▼
   speaking：TtsService.speak(回复)   [edge-tts，失败回退系统 TTS]
        ▼
   延时 800ms 后回 idle（避免录到自己的播报声），重新监听唤醒词
```

要点（细节见 `docs/voice-pipeline.md`）：

- 唤醒词模型缺失时启动后后台下载（`ensureKwsModel`），下载失败退化为手动模式，空格键 / 手机按钮仍可触发整条链路。
- `AsrClient` 未配置 API Key（`isConfigured == false`）时，链路在 ASR 前短路，语音回复提示去设置填写，其余功能不受影响。
- 语音状态（`VoiceState.idle/listening/processing/speaking`）经 `commands.voiceStateText` 进入状态快照，实时同步到手机端。

## 6. 链路二：手机控制数据流

```
手机浏览器 ──HTTP GET /──▶ 控制台单页 index.html（Flutter asset 内容）
手机浏览器 ──WS GET /ws──▶ ControlServer._onWebSocket
     │ 连接建立即发状态快照 encodeState(currentState())（control_server.dart:65）
     │ 之后每条 WS 文本消息：
     ▼
   decodeCommand() ──▶ ConsoleCommand ──▶ CommandService.executeCommand()
                                              │ 操作 PhotoService / WeatherService /
                                              │ TtsService / VoicePipeline
                                              ▼
                                  onEvent(message)  → encodeEvent ──┐
                                  onStateChanged()  → encodeState ──┴─▶
                                  ControlServer.broadcast ──▶ 全部已连接手机
```

要点（字段级协议见 `docs/protocol.md`）：

- 多台手机可同时连接（`_clients` 集合），任何一台发出指令，执行结果与最新状态广播给**所有**已连接手机，天然实现多设备状态同步。
- 非法 WS 消息（非 JSON、缺字段）捕获后仅回送一条"无法理解的指令"事件，不断连。
- 照片上传走 HTTP 而非 WS：`POST /api/photos`（multipart/form-data）→ 按扩展名过滤非图片 → 文件名清洗 + 重名加时间戳（防路径穿越与覆盖）→ 写入 `photoDir` → `photos.rescan()` 让新照片进入轮播 → 返回 `{"saved": n}`。
- `ControlServer.start()` 失败（如端口被占用）只记日志，不影响其余功能（失败隔离）。

## 7. 链路三：相册 NAS 数据流

```
main：NasPhotoSource.configure(url/user/password/remoteDir)（仅建客户端，main.dart:36-41）
      PhotoService(photoDir, cacheDir: 支持目录/nas-cache)（main.dart:42-43）
        │ photos.init() 后 applyNasConfig(config, nasSource)（main.dart:64）
        ▼
  nasEnabled=false → nasStatus=未启用，不访问 NAS
  nasRemoteDir 为空 → nasStatus=未配置，不访问 NAS
  启用时 ──▶ _refreshNas()（首次 fire-and-forget，不阻塞启动/设置保存）：NasPhotoSource.listPhotos()
               递归 PROPFIND nasRemoteDir（连接超时 8 秒）
               → 按 PhotoService.imageExts 过滤扩展名（视频不进相册）
               → nasPhotoAllowed 截图规则过滤（关键词 + 内置正则，被过滤数计入 lastFilteredCount）
               → 按文件名排序并入轮播列表（本地在前、NAS 在后）
               → 成功：nasStatus=已连接 N 张（M>0 时为「已连接 N 张（已过滤 M）」）；之后每 300 秒自动刷新
        │
  UI 展示经 PhotoService.fileFor(item)：
        本地项 → 直接返回 File
        NAS 项 → 查 nas-cache（命中即刷新访问时间 LRU）
                 未命中 → 下载入缓存（同一远程路径并发只下载一次）
                 下载失败 → 清理部分缓存文件并记日志，返回 null，跳过该张
        prefetchNext() 预取下一张 NAS 图，保证轮播间隔内不卡
        │
  缓存：文件名 = sha256(远程路径) 前 16 位 + 原扩展名；
        总量超 500MB 按 lastModified 最旧先淘汰（刚写入的文件不淘汰）
        │
  降级：listPhotos 抛错 → 保留已知引用（已缓存仍可展示），
        nasStatus=连接失败，下轮刷新自动重试；
        nasStatus 经 currentState() 的 nas 字段广播到全部手机端
```

要点：

- `NasPhotoSource` 不在内部吞错误（`ping` / `listPhotos` / `downloadTo` 异常原样抛出），降级决策集中在 `PhotoService`（`photo_service.dart:165-179` 的 `_refreshNas`、`:222-235` 的 `_download`）。
- 设置页（S 键）"NAS 相册"区保存配置后，先 `nasSource.configure(...)` 重建客户端，再 `photos.applyNasConfig(...)` 立即生效（`lib/ui/widgets/settings_sheet.dart:145-151`）；"测试连接"按钮用当前填写的值建临时实例 `ping()`，不影响运行中的共享实例（`settings_sheet.dart:87-106`）。

## 8. 依赖选型

以 `pubspec.yaml` 为准，关键依赖及选型理由：

| 包 | 用途 | 选型理由 |
|---|---|---|
| `shelf` + `shelf_router` | 内嵌 HTTP 服务器与路由 | Dart 团队官方包，纯 Dart 实现，单测中可直接起服务器（`test/control_server_test.dart`），无需外部组件 |
| `shelf_web_socket` + `web_socket_channel` | WS 指令通道 | 与 shelf 无缝集成；`web_socket_channel` 同时复用于 edge-tts 的 WSS 客户端（`TtsService`） |
| `shelf_multipart` | 照片上传 multipart 解析 | shelf 生态的 multipart 支持 |
| `sherpa_onnx` | 本地 KWS 唤醒词 | 离线常驻唤醒、不耗云端额度；支持编辑 `keywords.txt` 自定义唤醒词 |
| `record` | 麦克风录音 | 跨三平台流式录音，输出 `pcm16bits` / 16kHz / 单声道，同时满足 KWS 与 Whisper 的输入要求 |
| `audioplayers` | 音频播放 | 播放 edge-tts 返回的 MP3 字节流与唤醒提示音 |
| `lunar` | 农历 / 干支 / 生肖 / 节气 / 节日 | 纯 Dart 无网络依赖，一次计算覆盖日历全部需求 |
| `qr_flutter` | 控制台二维码 | 无原生依赖，直接嵌入 widget 树 |
| `provider` | 依赖注入与状态订阅 | Flutter 官方推荐；5 个 `ChangeNotifier` 状态源 + 4 个纯服务对象（见第 3 章） |
| `window_manager` | 桌面窗口控制 | 启动全屏、Esc 退出全屏（三平台） |
| `wakelock_plus` | 阻止系统休眠 | 智能屏常驻常亮 |
| `http` | HTTP 客户端 | Open-Meteo 天气、Whisper ASR 请求、KWS 模型下载 |
| `path_provider` | 应用支持目录 | 各平台定位 `config.json` 与 KWS 模型默认目录 |
| `path` | 路径处理 | 路径拼接、扩展名判断、上传文件名清洗 |
| `crypto` | SHA256 | edge-tts `Sec-MS-GEC` 访问令牌计算（`TtsService.secMsGec`）；NAS 缓存文件名哈希（`PhotoService` `_cachePathFor`） |
| `webdav_client` | NAS WebDAV 客户端 | 群晖等 NAS 的 PROPFIND 递归列目录与 GET 下载，纯 Dart；用 `dart:io HttpServer` 起假 WebDAV 服务器即可端到端单测（`test/nas_photo_source_test.dart`） |

## 9. 家庭 Agent 基础设施

家庭 Agent 与当前智能屏内嵌 `ControlServer` 是两个独立服务。阶段 1 不改造现有 Flutter
指令总线，也不调用硬件或模型：

```text
家长 Web/App ── HTTP bearer ──▶ Home Agent Server
学生 Android App ─ Student key ─▶        │
                                      │
                           SQLite/WAL + Alembic
                                      │
       Linux/Android Room Node ── WebSocket ──┘
          配对码→设备密钥       hello/能力/心跳/命令
```

- `home_agent/src/home_agent/`：FastAPI API、认证、配对、repository、审计和在线节点 registry。
- `student_app/`：独立 Flutter Android 客户端；设备固定绑定一个孩子，只消费最小权限作业 API。
- `home_agent/src/linux_room_node/`：独立假节点进程；保存权限为 `0600` 的设备凭据，断线指数退避。
- `packages/node_protocol/`：Dart 信封和能力模型；与 Python 读取同一份 canonical fixtures。
- 数据库只保存密码的 Argon2id 哈希和 token/code/device key 的 SHA-256 哈希；明文凭据只返回一次。
- WebSocket 首帧必须是已认证 `node.hello`；断线清理使用受取消保护的短事务，避免残留在线状态。
- 协议和 API 详见 [home-agent-protocol.md](home-agent-protocol.md)。
