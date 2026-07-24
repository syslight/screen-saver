# 智能屏（Smart Frame）

跑在 Windows / macOS / Linux 上的全屏智能屏应用（电子相框），Flutter 桌面端。

本仓库也已开始承载独立的家庭 Agent 基础设施：`home_agent/` 是本地优先的 Python
服务端和 Linux 房间节点，`packages/node_protocol/` 是未来 Linux/Android 节点共用的
Dart 协议包，`student_app/` 是独立的 Android 学生作业端。现有智能屏仍可独立运行。

![Flutter](https://img.shields.io/badge/Flutter-3.44%2B-02569B?logo=flutter&logoColor=white)
![Platform](https://img.shields.io/badge/平台-Windows%20%7C%20macOS%20%7C%20Linux-blue)

## 功能特性

- **天气**：Open-Meteo 免费 API，无需 API Key，城市名自动定位
- **日历**：公历 + 农历 + 干支生肖 + 节气 + 节日
- **相册**：本地文件夹 + NAS（WebDAV）混合轮播（交叉渐变），截图自动过滤，手机扫码即可上传照片
- **语音交互**：本地唤醒词（sherpa-onnx KWS）→ 云端 Whisper 识别 → 本地意图解析 → edge-tts 播报（系统 TTS 兜底）
- **手机控制**：内置 HTTP/WebSocket 服务器，手机浏览器扫码进入控制台，多设备同时在线、状态实时同步

## 快速开始

开发环境：

- Flutter 3.44+（stable）
- Linux 构建链：`sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`

运行与构建：

```bash
flutter pub get
flutter run -d linux          # 开发运行（全屏）
flutter build linux --release # 出包：build/linux/x64/release/bundle/
flutter build apk --release   # Android arm64 展示端
```

家庭 Agent 阶段 1：

```bash
cd home_agent
uv sync --frozen
uv run home-agent             # 默认 http://127.0.0.1:8790
```

首次启动后通过 `/api/v1/bootstrap` 创建家庭和第一位家长，再由家长创建一次性节点配对码。
完整 API 和节点消息见 [`docs/home-agent-protocol.md`](docs/home-agent-protocol.md)。当前仅提供
本机默认仍是 HTTP/WS 开发链路。阶段 B 允许学生平板在同一可信家庭 Wi-Fi 内临时使用 HTTP，
但不得做端口映射或暴露到公网；远程访问前必须配置 HTTPS。

家长作业中心位于 `http://127.0.0.1:8790/parent/`：可录入家庭成员、手动布置作业、管理
学生平板、上传纸质作业照片并人工确认完成质量。学生 Android App 已支持绑定孩子、查看与
开始任务、拍摄最多 6 页、提交和查看家长反馈；模型自动检查将在后续阶段接入。

学生平板联调时让 Home Agent 监听局域网，并构建/安装独立 App：

```bash
cd home_agent
HOME_AGENT_HOST=0.0.0.0 uv run home-agent

cd ../student_app
flutter pub get
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

在家长页面选择 10 岁孩子生成 8 位一次性配对码；平板填写服务器电脑的局域网地址，例如
`192.168.1.10:8790`。配对后设备固定绑定该孩子，换人必须由家长撤销并重新配对。

在 Windows / macOS 上同理（`flutter run -d windows` / `-d macos`，构建需对应系统）。
Android 首次启动需输入同一局域网内的计算节点地址，详见
[`docs/display-node-deploy.md`](docs/display-node-deploy.md)。

## 键盘快捷键

| 按键 | 功能 |
|---|---|
| ← / → | 上一张 / 下一张照片 |
| 空格 | 手动触发语音聆听（唤醒词模型不可用时用此方式） |
| Q | 显示/隐藏控制台二维码 |
| S | 设置 |
| Esc | 退出全屏 |

## 手机控制台

1. 按 **Q** 显示二维码，手机扫码（需与电脑同一局域网），或浏览器直接访问 `http://<电脑IP>:8780`
2. 功能：查看状态、切换照片、调节音量、发文字指令、让屏幕播报、按语义筛选播放、上传照片、配置 NAS 相册
3. 多台手机可同时连接，状态实时同步

## 语音交互

- 首次启动会在后台下载唤醒词模型（约 15MB），下载完成后说出默认唤醒词即可唤醒（模型来自 sherpa-onnx wenetspeech KWS，自定义唤醒词可编辑配置目录下 `kws-model/keywords.txt`）
- 唤醒词下载失败或不想用时：**空格键** 或手机控制台的文字指令同样可用
- 支持的话术示例：今天天气怎么样 / 现在几点 / 今天几号 / 农历多少 / 下一张 / 音量大一点 / 放猫的照片 / 播放全部 / 播报：开饭了 / 显示二维码 / 你会做什么
- 语音识别需要 OpenAI 兼容的 Whisper API（在设置 S 里配置 `base_url` 和 `key`，可指向 OpenAI、Groq 或本地 faster-whisper 服务）；未配置时语音链路自动降级，其余功能不受影响
- TTS 默认使用 edge-tts（免费，中文语音自然），网络不可达时回退系统 TTS（Linux `espeak-ng` / macOS `say` / Windows SAPI）

## 配置

配置文件位于应用数据目录（Linux：`~/.local/share/com.example.smart_frame/config.json`），全部字段有默认值，零配置可启动，也可在设置（S 键）里修改：

```json
{
  "city": "北京",
  "photoDir": "",
  "serverPort": 8780,
  "slideshowSeconds": 10,
  "weatherRefreshMinutes": 30,
  "listenSeconds": 5,
  "asrBaseUrl": "https://api.openai.com/v1",
  "asrApiKey": "",
  "asrModel": "whisper-1",
  "ttsVoice": "zh-CN-XiaoxiaoNeural",
  "volume": 0.8,
  "wakeWordModelDir": "",
  "nasEnabled": false,
  "nasWebdavUrl": "http://192.168.1.22:5005",
  "nasWebdavUser": "",
  "nasWebdavPassword": "",
  "nasRemoteDir": "",
  "nasFilterEnabled": true,
  "nasFilterKeywords": ["截图", "screenshot", "屏幕快照", "收集"]
}
```

说明：

- `photoDir` 为空时回落到 `~/Pictures`，把照片放进去即可（支持 jpg/png/webp/bmp/gif），手机上传的照片也存这里
- NAS 相册（WebDAV）在设置（S 键）或 web 控制台的「NAS 相册设置」卡片（`http://<电脑IP>:8780`）里配置：地址 / 账号 / 密码 / 远程目录，支持截图规则过滤；NAS 照片与本地照片混合轮播，未配置或连接失败时自动降级为本地相册，不影响其他功能
- **去重与跳过**：`dedupEnabled` 开启后，对播放过的照片算内容指纹（sha256 完全重复 + dHash 近似重复），重复的张播放时跳过（**不删原文件**，只读）；`nasFilterMinBytes` 过滤小图/缩略图、`@eaDir` 自动排除。索引随播放增量积累（SQLite，存应用数据目录 `photo_index.db`）
- **HEIC 支持**：iPhone 的 `.heic` 照片需系统 `heif-convert` 解码——Linux 装一次 `sudo apt install libheif-examples`（macOS 自带、Windows 需 libheif）；未安装时 HEIC 自动跳过、其余格式不受影响
- **智能打标签（VLM，可选）**：开启 `vlmEnabled` 后，调用本地 [ollama](https://ollama.com) 视觉模型（默认 `minicpm-v`，先 `ollama pull minicpm-v`）给照片打场景标签、判定非照片（截图/表情包/文档/图标），非照片播放跳过。标签随播放增量计算（每张几秒，GTX 1070 Ti 级显卡），存 `photo_index.db`
- `nasWebdavPassword` 为本地明文存储（家庭局域网场景），请勿把真实配置文件提交到公开仓库

## 测试

```bash
flutter analyze
flutter test    # 若本机配了代理，localhost 被代理劫持时需先 unset http_proxy 等变量
```

## 架构速览

```
lib/
  config/app_config.dart      配置模型与持久化
  services/                   weather / calendar / photo / command(统一指令总线)
  server/                     shelf HTTP+WS 服务器、消息协议
  voice/                      唤醒词(KWS)、ASR 客户端、意图解析、edge-tts、状态机
  ui/                         全屏仪表盘与各小组件
web_console/index.html        手机控制台单页（原生 JS，打包进 assets）
home_agent/                   家庭 Agent Server + Linux Room Node（独立 Python/uv 工程）
student_app/                  独立 Android 学生端（配对、作业、相机提交、审核结果）
packages/node_protocol/       Linux/Android 房间节点共享 Dart 协议模型
```

手机 WS 指令与语音/文字意图统一进 `CommandService` 处理，执行后经 WebSocket 广播状态给全部手机端；键盘快捷键为历史直连实现（不经总线、不触发广播），新增指令不得绕过总线。

## 文档

完整文档见 [docs/](docs/README.md)（需求、架构、协议、语音、开发、多 Agent/worktree 协作、commit 规范、部署、路线图）。
