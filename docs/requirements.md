# 需求基线（Requirements）

本文档是 smart_frame 的需求基线：第 2 章按模块列出功能需求，每条独立可勾选（当前版本均已实现，故全部打勾）；第 3 章列出非功能需求，作为架构与迭代的长期约束，`docs/roadmap.md` 中的限制项须与这些编号（NFR-x）呼应。

文中事实以代码为准：配置字段以 `lib/config/app_config.dart` 为准，相册扩展名以 `lib/services/photo_service.dart` 的 `imageExts` 为准。

## 1. 项目概述

smart_frame 是跑在 Windows / macOS / Linux 上的 Flutter 桌面全屏智能屏（电子相框）：全屏仪表盘同时展示天气、日历与相册轮播，支持本地唤醒词 + 云端识别的语音交互，并内置 HTTP/WebSocket 服务器让多台手机同时接入控制台。目标场景是家庭常驻屏幕，要求零配置可启动、局部失败不拖垮整体。

## 2. 功能需求

### 2.1 天气

- [x] FR-W-1 使用 Open-Meteo 免费 API 获取天气，无需 API Key。
- [x] FR-W-2 以城市名配置地点（`city`，默认"北京"），经 Open-Meteo 地理编码（`geocoding-api.open-meteo.com`，`language=zh`，取首个结果）解析为经纬度。
- [x] FR-W-3 按 `weatherRefreshMinutes`（默认 30 分钟）定时自动刷新。
- [x] FR-W-4 界面展示当前温度、城市、天气状况（WMO 天气码映射为中文描述）、今日最低/最高温度与湿度；体感温度纳入天气语音播报；风速仅采集解析，未在界面或播报中使用。
- [x] FR-W-5 刷新失败时保留上一次成功的数据，仅记录错误，不打断界面。

### 2.2 日历

- [x] FR-C-1 显示公历日期与星期（如"星期五"）。
- [x] FR-C-2 显示农历月日（如"冬月廿三"）。
- [x] FR-C-3 显示干支年与生肖（如"甲辰"·"龙"）。
- [x] FR-C-4 当天为节气日时显示节气。
- [x] FR-C-5 显示公历与农历节日（含 `lunar` 库的 festivals 与 otherFestivals）。

### 2.3 相册

- [x] FR-P-1 轮播本地目录中的照片，目录由 `photoDir` 配置（默认 `~/Pictures`），目录不存在时自动创建。
- [x] FR-P-2 支持的图片扩展名：`.jpg` / `.jpeg` / `.png` / `.webp` / `.bmp` / `.gif`（小写匹配，以 `imageExts` 为准）。
- [x] FR-P-3 按 `slideshowSeconds`（默认 10 秒）自动切换；设为 0 时停止自动轮播。
- [x] FR-P-4 支持手动切换上一张 / 下一张（键盘 ← / →、手机控制台、语音指令），手动切换后重新开始轮播计时。
- [x] FR-P-5 照片切换使用交叉渐变过渡（`AnimatedSwitcher`）。
- [x] FR-P-6 每 30 秒自动重扫目录，新增照片（如手机上传）自动加入轮播；目录不可读等异常不打断界面。
- [x] FR-P-7 NAS 相册来源：可配置 WebDAV NAS（`nasEnabled` / `nasWebdavUrl` / `nasWebdavUser` / `nasWebdavPassword` / `nasRemoteDir`），远程图片与本地目录混合轮播（本地在前按路径排序，NAS 在后按文件名排序）；NAS 列表独立于本地重扫，每 300 秒刷新一次；`nasRemoteDir` 为空视为未配置，即使启用也不访问 NAS。
- [x] FR-P-8 NAS 图片不预下载，按需拉取并落磁盘缓存（应用支持目录 `nas-cache/`，文件名 = sha256(远程路径) 前 16 位 + 原扩展名）；缓存上限 500MB，超出按最久未访问（LRU）淘汰；展示当前张时后台预取下一张 NAS 图。
- [x] FR-P-9 NAS 截图规则过滤（`nasFilterEnabled` 默认开，仅作用于 NAS 来源）：路径或文件名含 `nasFilterKeywords` 任一关键词（默认 `截图` / `screenshot` / `屏幕快照` / `收集`，大小写不敏感，替换语义，空串跳过）即排除；文件名命中内置截图命名正则（`^Screenshot[_ -]`、`^Screen Shot`、`^screencap`，大小写不敏感）即排除。两个来源都只认 `imageExts`，视频不进相册。
- [x] FR-P-10 NAS 状态（`未启用` / `未配置` / `已连接 N 张` / `已连接 N 张（已过滤 M）` / `连接失败`）进入状态快照 `nas` 字段，手机控制台可见。

### 2.4 语音交互

- [x] FR-V-1 三种触发方式：本地唤醒词（sherpa-onnx KWS，常驻监听）、空格键、手机控制台按钮。
- [x] FR-V-2 唤醒词模型缺失时后台自动下载（sherpa-onnx wenetspeech KWS 模型）；自定义唤醒词可编辑配置目录下 `kws-model/keywords.txt`。
- [x] FR-V-3 触发后播放提示音并录音 `listenSeconds`（默认 5 秒）。
- [x] FR-V-4 录音送 OpenAI 兼容的 Whisper API 识别（`asrBaseUrl` / `asrApiKey` / `asrModel` 可配置，可指向 OpenAI、Groq 或本地 faster-whisper）。
- [x] FR-V-5 识别文字经本地意图解析（`parseIntent`）映射为指令，意图共 13 种：天气、时间、日期、农历、上一张、下一张、音量增、音量减、设定音量、播报、显示二维码、帮助、未知。
- [x] FR-V-6 手机控制台输入的文字指令与语音识别结果走同一意图解析和指令总线。
- [x] FR-V-7 语音状态机（待唤醒 / 手动模式 / 聆听中 / 识别中 / 播报中）实时显示在界面上，并同步到手机端。

### 2.5 TTS 播报

- [x] FR-T-1 默认使用 edge-tts（微软神经网络语音，免费）播报，`ttsVoice` 默认 `zh-CN-XiaoxiaoNeural`。
- [x] FR-T-2 edge-tts 失败（如网络不可达）时自动回退系统 TTS：Linux `espeak-ng`、macOS `say`、Windows SAPI（PowerShell `System.Speech`）。
- [x] FR-T-3 播报音量 `volume`（0..1，默认 0.8）可配置，手机控制台与语音指令均可调节。

### 2.6 手机控制

- [x] FR-M-1 内置 HTTP/WebSocket 服务器（shelf），端口由 `serverPort` 配置（默认 8780）。
- [x] FR-M-2 按 **Q** 显示控制台二维码，内容为 `http://<电脑局域网 IPv4>:<端口>`；手机与电脑在同一局域网扫码进入，也可浏览器直接访问该地址。局域网 IP 获取失败时地址回落为 `http://localhost:<端口>`（仅本机可访问）。
- [x] FR-M-3 控制台功能：查看实时状态、切换照片、调节音量、发送文字指令、让屏幕播报、上传照片。
- [x] FR-M-4 多台手机可同时连接，同时在线。
- [x] FR-M-5 状态实时同步：WebSocket 连接建立即推送状态快照；任何指令执行后向全部客户端广播状态与事件。
- [x] FR-M-6 上传照片走 `POST /api/photos`（multipart/form-data），存入 `photoDir`，非图片文件拒绝。
- [x] FR-M-7 指令统一入口——规范：所有外部指令（语音 / 手机 / 键盘）统一经 `CommandService` 处理，执行后经 WebSocket 广播状态，新增指令不得绕过指令总线直接操作服务；现状：手机 WS 指令与语音 / 文字意图经总线并广播，键盘快捷键为历史直连实现（不经总线、不触发广播，详见 [architecture.md](architecture.md)「关于键盘」一节）。

## 3. 非功能需求

- NFR-1 **三平台桌面**：Windows / macOS / Linux，Flutter 3.44+（stable），同一套代码出三个平台的包。
- NFR-2 **全屏常驻**：启动即全屏（window_manager），`wakelock_plus` 阻止系统休眠；按 Esc 退出全屏。
- NFR-3 **零配置可启动**：全部 19 个配置字段有默认值，配置文件缺失或损坏时回落默认值；相册目录不存在时自动创建。
- NFR-4 **失败隔离**：各服务独立初始化，单个失败不影响整体（`lib/main.dart` "各服务独立初始化，单个失败不影响整体"为据）——语音初始化放后台执行，控制台服务器启动失败仅记录日志，应用照常运行。
- NFR-5 **局域网内工作**：手机控制要求与电脑同一局域网；除天气、ASR、edge-tts 与唤醒词模型首次下载外，全部功能（日历、相册、意图解析、系统 TTS）不依赖互联网。
- NFR-6 **语音链路逐层降级**：
  - 无麦克风权限 → 语音整体不可用，其余功能不受影响；
  - KWS 模型缺失且后台下载失败 → 手动模式（空格键 / 手机按钮触发）；
  - ASR 未配置 → 语音回复提示去设置填写 API 地址和密钥，文字指令链路仍可用；
  - edge-tts 网络失败 → 自动回退系统 TTS。
- NFR-7 **质量基线**：`flutter analyze` 无问题、`flutter test` 全绿（当前 54 个纯 Dart 单测）才算改动完成。
- NFR-8 **NAS 相册逐层降级**：未启用 / 未配置（`nasRemoteDir` 为空）→ 完全不访问 NAS；连接失败 / 凭据错误 → 静默降级为"本地 + 已缓存 NAS 图"，不弹窗，状态落 `连接失败`，下轮刷新（300 秒）自动重试；单张下载失败 → 跳过该张（视同不存在），不影响轮播。
