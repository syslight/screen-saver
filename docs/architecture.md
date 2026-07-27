# 架构基线（Architecture）

> CCL 与 RK3588 的当前生产架构是薄展示端；语音计算统一位于 Home Agent。生产链路以
> [薄展示端与家庭媒体 Agent 架构](thin-display-media-agent.md)和
> [家庭 Agent 协议](home-agent-protocol.md)为准。

本文档是 smart_frame 的架构基线：模块划分、启动装配顺序、`CommandService` 指令总线，以及语音交互与手机控制两条主链路的高层数据流。文中事实以代码为准（装配顺序以 `apps/smart_frame/lib/main.dart` 行号为据）。

两条链路在本文只画高层数据流，字段级细节分别由专项文档展开：WebSocket/HTTP 协议见 `docs/protocol.md`，语音状态机与降级策略见 `docs/voice-pipeline.md`。

## 0. Monorepo 边界

| 顶层目录 | 类型 | 发布与依赖边界 |
|---|---|---|
| `apps/smart_frame/` | Flutter 应用 | 智能屏 Linux/macOS/Windows/Android 独立构建单元 |
| `apps/student/` | Flutter 应用 | 学生 Android 客户端，仅通过 Home Agent HTTP API 通信 |
| `apps/home_admin/` | Flutter 应用 | HomeAdmin App；家长 bearer 登录后管理家庭并连接智能屏 WS |
| `services/home_admin/` | Python 服务 | HomeAdmin WebUI/BFF；同源代理 Home Agent API，不访问其数据库 |
| `services/home_agent/` | Python 服务 | 家庭数据、作业、Agent 和 Room Node 协议的服务端权威实现 |
| `services/photo_indexer/` | Python 守护进程 | 读取 NAS、写共享照片索引，不承载家庭 Agent API |
| `packages/node_protocol/` | Dart package | 节点协议信封和 canonical fixtures，不依赖任一应用 |
| `deploy/` / `tool/` | 运维 | 跨应用部署单元和仓库级脚本 |

智能屏内部采用垂直功能模块。`core/` 只放多 feature 共用的配置、网络和平台能力；
`features/<name>/` 内按实际需要分成 `domain`、`application`、`data`、`presentation`。跨功能引用使用
`package:smart_frame/...` 的明确路径，避免通过旧的全局 `services/` 或 `ui/widgets/` 目录形成隐式耦合。

## 1. 模块划分

| 目录 / 文件 | 关键类 / 函数 | 职责 |
|---|---|---|
| `apps/smart_frame/lib/core/config/app_config.dart` | `AppConfig` / `ConfigService` | 39 个配置字段的模型、加载与持久化（`config.json`）；display 使用 `agentUrl` 和独立节点凭据 |
| `apps/smart_frame/lib/features/music/` | `MusicService` / `RemoteMusicSource` | 拉取服务端选中的授权音乐、本地缓存、播放控制与 TTS ducking；展示端不生成音乐 |
| `apps/smart_frame/lib/features/photos/application/photo_service.dart` | `PhotoService` / `PhotoItem` | 本地 + NAS 相册聚合、自动轮播、按照片 ID 持久化/恢复播放位置、定时重扫、`nas-cache` 磁盘缓存与下一张预取、NAS 故障静默降级 |
| `apps/smart_frame/lib/features/photos/application/photo_index_service.dart` | `PhotoIndexService` / `PhotoDescription` / `PersonProfile` | hidden/标签/人物索引、家长确认家庭关系，以及当前照片的已确认家庭身份、时间、地点、第三人称解说的计算端 SQLite / 展示端 HTTP 双后端 |
| `apps/smart_frame/lib/core/platform/screen_awake_service.dart` | `ScreenAwakeService` | wakelock 常亮；Linux 叠加 X11 屏保/DPMS 关闭与周期重申 |
| `apps/smart_frame/lib/features/photos/data/nas_photo_source.dart` | `NasSource` / `NasPhotoSource` / `NasPhotoRef` | NAS WebDAV 图源（`webdav_client`）：连接测试、递归列出远程图片（扩展名 + 截图规则过滤）、按引用下载；错误原样抛给调用方 |
| `apps/smart_frame/lib/features/photos/domain/nas_filter.dart` | `nasPhotoAllowed`（纯函数） | NAS 截图规则过滤：关键词（替换语义、大小写不敏感、空串跳过）+ 内置截图文件名正则 |

CCL 与 RK3588 均以 `serverRole=display` 运行：只负责缓存/展示、麦克风采集和音频播放；照片
扫描去重、音乐选择、ASR、Agent 与 TTS 合成都在独立 `home_agent`/`photo_indexer` 服务端。
服务可部署在 x86 或 RK3588，设备只感知一个 `agentUrl`。完整边界见
[薄展示端与家庭媒体 Agent 架构](thin-display-media-agent.md)。
| `apps/smart_frame/lib/features/weather/application/weather_service.dart` | `WeatherService` / `weatherFromJson` / `weatherCodeText` | Open-Meteo 地理编码 + 天气定时刷新，失败保留旧数据 |
| `apps/smart_frame/lib/features/calendar/domain/calendar_service.dart` | `calendarInfoFor`（纯函数） | 农历、干支生肖、节气、公历/农历节日（基于 `lunar` 包） |
| `apps/smart_frame/lib/features/remote_control/application/command_service.dart` | `CommandService` | **统一指令总线**：手机 / 语音 / 文字指令的唯一入口，见第 4 章 |
| `apps/smart_frame/lib/features/remote_control/data/control_server.dart` | `ControlServer` | shelf 内嵌 HTTP/WebSocket 服务器：控制台页、指令通道、照片上传、状态广播 |
| `apps/smart_frame/lib/features/remote_control/domain/protocol.dart` | `ConsoleCommand` / `decodeCommand` / `encodeState` / `encodeEvent` | 手机端 WS 消息协议编解码 |
| `apps/smart_frame/lib/features/voice/application/voice_client.dart` | `VoiceClient` | 按需录制 PCM、连接 Home Agent 语音 WS、播放服务端 TTS 与连续对话状态机 |
| `apps/smart_frame/lib/features/voice/application/native_wake_word.dart` | `NativeWakeWord` | 接收 Android 厂商原生唤醒元数据，不接触模型或识别文字 |
| `apps/smart_frame/android/.../NativeWakeBridge.kt` | `NativeWakeBridge` | 绑定 AILABS AliTVASR Binder，并在厂商登录不可用时只读订阅固件 `WakeupManager` wake event；不做识别 |
| `apps/smart_frame/lib/features/voice/application/tts_service.dart` | `TtsService` | edge-tts 播报（WSS 协议手写），失败回退系统 TTS |
| `apps/smart_frame/lib/features/voice/application/intent_parser.dart` | `parseIntent` / `Intent` / `IntentType` | 本地意图解析（13 种意图，纯 Dart 无外部依赖） |
| `apps/smart_frame/lib/features/*/presentation/` | `DashboardPage` + 各 widget | 全屏仪表盘：相册背景（按屏幕物理尺寸等比解码，避免 ARM 软件渲染展开超大原图）+ 左上环境信息岛 + 右下动画故事卡 + 语音指示/二维码/设置浮层 |
| `apps/smart_frame/assets/web_console/index.html` | — | 手机控制台单页（原生 JS，打包进 Flutter assets） |

## 2. 模块图

```
      手机浏览器 ×N                 键盘快捷键                     麦克风
  (apps/smart_frame/assets/web_console/index.html)      ←→ 空格 Q S Esc                     │
            │                          │                     16kHz PCM 流
   HTTP / WebSocket                    │ 直接调用                    │
            ▼                          ▼（不经总线）                ▼
  ┌───────────────────┐     ┌─────────────────────┐    ┌─────────────────────┐
  │ ControlServer      │     │ ←→ → PhotoService.  │    │ VoiceClient          │
  │ （remote_control）  │     │     next()/prev()   │    │ （voice/application） │
  │ shelf HTTP + WS    │     │ 空格 → VoiceProvider│    │ 原生唤醒 → 按需录音 │
  │  GET /             │     │     .triggerListen()│    │ → Home Agent WS     │
  │  GET /ws           │     └─────────────────────┘    │ ← TTS 音频播放      │
  │  POST /api/photos  │                                └─────────────────────┘
  └─────────┬──────────┘                                           │ 识别文字
            │ ConsoleCommand
            │                    ┌───────────────────────────────────────────┐
            │                    │ CommandService（remote_control，指令总线） │
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

关于键盘：←/→ 直接调 `PhotoService.next()/prev()`，空格调用当前 `VoiceProvider.triggerListen()`，S/Esc 为纯界面行为；Q 切换二维码浮层。键盘快捷键不经指令总线；新增远程指令必须接入 `CommandService`。

## 3. 启动装配顺序（`apps/smart_frame/lib/main.dart`）

`main()` 自上而下一次性完成服务装配，顺序如下（行号为 `apps/smart_frame/lib/main.dart` 实际行号）：

1. **绑定初始化**（L24-25）：`WidgetsFlutterBinding.ensureInitialized()` + `windowManager.ensureInitialized()`。
2. **加载配置**（L27-30）：`getApplicationSupportDirectory()` 取应用支持目录 → 构造 `ConfigService` → `load()` 读 `config.json`（缺失/损坏回落默认值）。
3. **创建相册目录**（L33）：`Directory(config.photoDir).create(recursive: true)`。
4. **装配 NAS 图源与相册**（L35-43）：`NasPhotoSource` 按配置 `configure(url/user/password/remoteDir)`（仅建客户端，不连接）→ 构造 `PhotoService(photoDir, cacheDir: 支持目录/nas-cache)`。
5. **构造基础服务**：`WeatherService`、`TtsService` 与 `CommandService`；`TtsService` 只服务旧的本地播报指令，不参与家庭 Agent 对话合成。
6. **构造指令总线**（L50-51）：`CommandService(config, photos, weather, tts)`。
7. **构造语音薄客户端**：有 Home Agent 节点凭据时创建 `VoiceClient`，否则创建 `UnavailableVoiceProvider`；Android 的原生桥只提供唤醒元数据。
8. **回调互注**：`commands.voiceStateText` 与 `commands.onListenRequested` 指向当前 `VoiceProvider`。
9. **各服务独立初始化，失败隔离**：照片、天气和语音 WS 分别初始化；无麦克风权限、原生唤醒不可用或 Home Agent 不可达不影响相册。
10. **加载控制台页并构造服务器**（L69-75）：`rootBundle.loadString('assets/web_console/index.html')` → 构造 `ControlServer(port, commands, photos, indexHtml)`。
11. **启动服务器**（L76-80）：`server.start()` 包在 try/catch 中，失败仅 `debugPrint`，应用照常运行（手机控制不可用）。
12. **常亮与全屏**：`ScreenAwakeService.start()` 启用 wakelock；Linux 叠加 `xset s off` / `xset -dpms` / `xset s noblank` 并周期重申；随后进入沉浸式全屏。
13. **runApp**（L85-100）：`MultiProvider` 注入 9 个 provider 后启动 `SmartFrameApp`（深色 Material 3 主题，首页 `DashboardPage`）。

9 个 provider（main.dart:87-97）：前 5 个是 `ChangeNotifierProvider.value`（对象本身是可监听的状态源），后 4 个是 `Provider.value`（纯服务对象）：

| provider 类型 | 对象 | 类 |
|---|---|---|
| `ChangeNotifierProvider.value` | configService | `ConfigService` |
| `ChangeNotifierProvider.value` | photos | `PhotoService` |
| `ChangeNotifierProvider.value` | weather | `WeatherService` |
| `ChangeNotifierProvider.value` | voice | `VoiceClient` / `UnavailableVoiceProvider` |
| `ChangeNotifierProvider.value` | commands | `CommandService` |
| `Provider.value` | tts | `TtsService` |
| `Provider.value` | nasSource | `NasPhotoSource`（设置页"NAS 相册"区重建连接用） |
| `Provider.value` | server | `ControlServer` |

## 4. 指令总线 `CommandService`

所有远程/文字指令统一经 `CommandService`（`apps/smart_frame/lib/features/remote_control/application/command_service.dart`）处理，它持有 `AppConfig`、`PhotoService`、`WeatherService`、`TtsService` 的引用。总线有两个入口：

- **入口① `executeCommand(ConsoleCommand)`**：手机 WS 指令入口。除照片、天气、TTS、二维码和聆听指令外，还处理 `set_music_enabled` / `set_music_muted` / `set_music_volume`，统一广播事件和最新状态。
- **入口② `executeText(String)`**（command_service.dart:91）：语音 ASR 结果与手机文字输入共用，即 `executeIntent(parseIntent(text))`——先本地意图解析，再按意图类型执行（查天气/时间/日期/农历、切照片、调音量、播报、显示二维码、帮助、未知），生成中文回复文字。执行完成后回调 `onStateChanged()`（command_service.dart:147）。

两个回调由 `ControlServer.start()` 接线（control_server.dart:57-58）：`onEvent` → `broadcast(encodeEvent(msg))`；`onStateChanged` → `broadcast(encodeState(commands.currentState()))`。`currentState()`（command_service.dart:151）汇总当前照片、照片数、天气摘要、语音状态、音量，构成发给手机端的状态快照。

## 5. 链路一：语音交互数据流

```
AILABS 固件“天猫精灵”KWS ──原生 wake event / EventChannel──▶ VoiceClient
                                               │ voice.turn.start
麦克风（仅本轮）── PCM16/16k/mono ──────────────┼────────▶ Home Agent
                                               │           服务端 VAD 自动断句
VoiceClient ◀──────── processing state ─────────┤           火山流式/本地/OpenAI ASR
  立即释放麦克风                                │           GLM/Kimi Agent
VoiceClient ◀── speaking + PCM start/chunks/end ─┘           火山/Piper/OpenAI TTS
  播放结束后按 continueDialog 决定是否继续录下一轮
```

要点（细节见 `docs/voice-pipeline.md`）：

- App 不包含 sherpa/ONNX、VAD、ASR 或 TTS 合成；固件服务不可用时退化为手动触发。
- Home Agent 检测尾部静音后发 `processing`，客户端以该服务端状态作为停止录音的依据。
- LLM token 按句进入 TTS 队列；媒体协议 v2 用 PCM 二进制块边下发边播放，v1 节点使用完整
  WAV 降级。
- 节点凭据认证和来源路由保证 TTS 只返回发起本轮的终端。

## 6. 链路二：手机控制数据流

```
手机浏览器 ──HTTP GET /──▶ 控制台单页 index.html（Flutter asset 内容）
手机浏览器 ──WS GET /ws──▶ ControlServer._onWebSocket
     │ 连接建立即发状态快照 encodeState(currentState())（control_server.dart:65）
     │ 之后每条 WS 文本消息：
     ▼
   decodeCommand() ──▶ ConsoleCommand ──▶ CommandService.executeCommand()
                                              │ 操作 PhotoService / WeatherService /
                                              │ TtsService / VoiceProvider
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
- 设置页（S 键）"NAS 相册"区保存配置后，先 `nasSource.configure(...)` 重建客户端，再 `photos.applyNasConfig(...)` 立即生效（`apps/smart_frame/lib/features/settings/presentation/settings_sheet.dart:145-151`）；"测试连接"按钮用当前填写的值建临时实例 `ping()`，不影响运行中的共享实例（`settings_sheet.dart:87-106`）。

## 8. 依赖选型

以 `apps/smart_frame/pubspec.yaml` 为准，关键依赖及选型理由：

| 包 | 用途 | 选型理由 |
|---|---|---|
| `shelf` + `shelf_router` | 内嵌 HTTP 服务器与路由 | Dart 团队官方包，纯 Dart 实现，单测中可直接起服务器（`apps/smart_frame/test/features/remote_control/control_server_test.dart`），无需外部组件 |
| `shelf_web_socket` + `web_socket_channel` | WS 指令通道 | 与 shelf 无缝集成；`web_socket_channel` 同时复用于 edge-tts 的 WSS 客户端（`TtsService`） |
| `shelf_multipart` | 照片上传 multipart 解析 | shelf 生态的 multipart 支持 |
| `record` | 麦克风录音 | 跨平台按需流式录音，向 Home Agent 输出 `pcm16bits` / 16kHz / 单声道 |
| `audioplayers` | 音频播放 | 播放 Home Agent 返回的 TTS 与背景音乐 |
| `lunar` | 农历 / 干支 / 生肖 / 节气 / 节日 | 纯 Dart 无网络依赖，一次计算覆盖日历全部需求 |
| `qr_flutter` | 控制台二维码 | 无原生依赖，直接嵌入 widget 树 |
| `provider` | 依赖注入与状态订阅 | Flutter 官方推荐；5 个 `ChangeNotifier` 状态源 + 4 个纯服务对象（见第 3 章） |
| `window_manager` | 桌面窗口控制 | 启动全屏、Esc 退出全屏（三平台） |
| `wakelock_plus` | 阻止系统休眠 | 智能屏常驻常亮 |
| `http` | HTTP 客户端 | Open-Meteo 天气与 Home Agent 媒体 API |
| `path_provider` | 应用支持目录 | 各平台定位 `config.json`、照片和媒体缓存 |
| `path` | 路径处理 | 路径拼接、扩展名判断、上传文件名清洗 |
| `crypto` | SHA256 | edge-tts `Sec-MS-GEC` 访问令牌计算（`TtsService.secMsGec`）；NAS 缓存文件名哈希（`PhotoService` `_cachePathFor`） |
| `webdav_client` | NAS WebDAV 客户端 | 群晖等 NAS 的 PROPFIND 递归列目录与 GET 下载，纯 Dart；用 `dart:io HttpServer` 起假 WebDAV 服务器即可端到端单测（`apps/smart_frame/test/features/photos/nas_photo_source_test.dart`） |

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

- `services/home_agent/src/home_agent/`：FastAPI API、认证、配对、repository、审计和在线节点 registry。
- `apps/student/`：独立 Flutter Android 客户端；设备固定绑定一个孩子，只消费最小权限作业 API。
- `services/home_agent/src/linux_room_node/`：独立假节点进程；保存权限为 `0600` 的设备凭据，断线指数退避。
- `packages/node_protocol/`：Dart 信封和能力模型；与 Python 读取同一份 canonical fixtures。
- 数据库只保存密码的 Argon2id 哈希和 token/code/device key 的 SHA-256 哈希；明文凭据只返回一次。
- WebSocket 首帧必须是已认证 `node.hello`；断线清理使用受取消保护的短事务，避免残留在线状态。
- 协议和 API 详见 [home-agent-protocol.md](home-agent-protocol.md)。
