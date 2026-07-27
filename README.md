# 智能屏（Smart Frame）

跑在 Windows / macOS / Linux 上的全屏智能屏应用（电子相框），Flutter 桌面端。

本仓库也已开始承载独立的家庭 Agent 基础设施：`services/home_agent/` 是本地优先的 Python
服务端和 Linux 房间节点，`packages/node_protocol/` 是未来 Linux/Android 节点共用的
Dart 协议包，`apps/student/` 是独立的 Android 学生作业端，`apps/home_admin/` 是 HomeAdmin
App，`services/home_admin/` 是同一管理产品的 WebUI/BFF。现有智能屏仍可独立运行。

![Flutter](https://img.shields.io/badge/Flutter-3.44%2B-02569B?logo=flutter&logoColor=white)
![Platform](https://img.shields.io/badge/平台-Windows%20%7C%20macOS%20%7C%20Linux-blue)

## 功能特性

- **天气**：Open-Meteo 免费 API，无需 API Key，城市名自动定位
- **日历**：公历 + 农历 + 干支生肖 + 节气 + 节日
- **相册**：本地文件夹 + NAS（WebDAV）混合轮播（交叉渐变），自动续播上次位置，显示照片时间/地点/人物故事；家长可在手机控制台把人脸聚类确认成家庭身份，截图自动过滤，扫码即可上传照片
- **智能配乐**：家庭服务端按人物、人生阶段、地点和事件选择真实授权音乐；展示端只缓存和播放
- **语音交互**：CCL/3588 采集麦克风 → `home_agent` 完成 ASR/Agent/TTS → 音频默认回到来源设备播放
- **手机控制**：内置 HTTP/WebSocket 服务器，手机浏览器扫码进入控制台，多设备同时在线、状态实时同步

## 快速开始

开发环境：

- Flutter 3.44+（stable）
- Linux 构建链：`sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`

运行与构建：

```bash
cd apps/smart_frame
flutter pub get
flutter run -d linux          # 开发运行（全屏）
flutter build linux --release # 出包：build/linux/x64/release/bundle/
flutter build apk --release   # Android arm64 展示端
```

家庭 Agent 阶段 1：

```bash
cd services/home_agent
uv sync --frozen
uv run home-agent             # 默认 http://127.0.0.1:8790

cd ../home_admin
uv sync --frozen
uv run home-admin             # 默认 http://127.0.0.1:8800
```

首次启动后通过 `/api/v1/bootstrap` 创建家庭和第一位家长，再由家长创建一次性节点配对码。
完整 API 和节点消息见 [`docs/home-agent-protocol.md`](docs/home-agent-protocol.md)。当前仅提供
本机默认仍是 HTTP/WS 开发链路。阶段 B 允许学生平板在同一可信家庭 Wi-Fi 内临时使用 HTTP，
但不得做端口映射或暴露到公网；远程访问前必须配置 HTTPS。

HomeAdmin WebUI 位于 `http://127.0.0.1:8800/`：先启动 `services/home_admin`，即可录入家庭
成员、管理 AI provider/密钥、手动布置作业、管理学生平板、上传纸质作业照片并人工确认完成
质量。学生 Android App 已支持绑定孩子、查看与
开始任务、拍摄最多 6 页、提交和查看家长反馈；家长 Web 还可逐次授权 Kimi K3 或兼容的
GLM 视觉模型检查图片。模型默认关闭，检查建议不会自动改变作业状态。

学生平板联调时让 Home Agent 监听局域网，并构建/安装独立 App：

```bash
cd services/home_agent
HOME_AGENT_HOST=0.0.0.0 uv run home-agent

cd ../../apps/student
flutter pub get
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

在家长页面选择 10 岁孩子生成 8 位一次性配对码；平板填写服务器电脑的局域网地址，例如
`192.168.1.10:8790`。配对后设备固定绑定该孩子，换人必须由家长撤销并重新配对。

在 Windows / macOS 上同理（`flutter run -d windows` / `-d macos`，构建需对应系统）。
Android 首次启动需输入同一局域网内的家庭 Agent 地址并完成设备配对，详见
[`docs/display-node-deploy.md`](docs/display-node-deploy.md)。
32 位 MT8167 天猫精灵 CCL 与 RK3588 使用同一套薄展示端架构。CCL 部署示例：

```bash
tool/deploy_ccl_android.sh --take-over \
  http://<home-agent-IP>:8790 \
  "$HOME/.local/share/family-home-agent/display-nodes/ccl.json"
```

`--take-over` 使用 Magisk 启动守护在原厂桌面之后拉起相册，不把第三方 Activity 设为 HOME，
也不 suspend 或卸载原厂持久系统包。恢复原厂 UI 使用 `tool/restore_ccl_vendor_ui.sh`。

HomeAdmin App 在家可直连家庭服务器，外网可连接 HTTPS Cloud Control：

```bash
cd apps/home_admin
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

在家填写局域网地址时，App 直连 8790/8780；外网填写 HTTPS 云平台地址时，App 按能力发现
Home Hub 并通过云端转发结构化命令。已登录家长可生成 10 分钟、单次使用的手机绑定码。
会话 token 存 Android 安全存储；家庭照片、人脸、声纹和作业原图不会上传到控制平面。
云端与家庭部署见[家庭云控制平台规格](docs/superpowers/specs/2026-07-26-cloud-control-platform.md)。

## 键盘快捷键

| 按键 | 功能 |
|---|---|
| ← / → | 上一张 / 下一张照片 |
| 空格 | 手动触发语音聆听（设备原生唤醒不可用时用此方式） |
| Q | 显示/隐藏控制台二维码 |
| S | 设置 |
| Esc | 退出全屏 |

## 手机控制台

1. 按 **Q** 显示二维码，手机扫码（需与电脑同一局域网），或浏览器直接访问 `http://<电脑IP>:8780`
2. 功能：查看状态、切换照片、调节音量、发文字指令、让屏幕播报、按语义筛选播放、上传照片、配置 NAS 相册
3. 多台手机可同时连接，状态实时同步

## 语音交互

- AILABS 设备优先复用固件已有的“天猫精灵”KWS；App 不实现唤醒模型，其他设备可用触屏、
  空格或控制端手动触发
- 智能屏只负责按需 PCM 录音和音频播放；`home_agent` 完成服务端自动断句，并在火山流式、
  本地和 OpenAI ASR/TTS 以及 GLM/Kimi Agent provider 间运行时切换（默认火山流式）
- 默认链路以约 50 ms PCM 块上传，LLM token 按句触发 TTS，Android/Linux 边接收边播放；
  旧媒体协议节点继续使用完整 WAV 降级
- HomeAdmin 管理端可查看 provider 配置/健康状态、主动检测并切换 ASR/TTS/LLM
- App 不依赖 sherpa/ONNX，不下载任何 KWS/ASR/TTS 模型；空闲时也不上传麦克风音频
- AILABS_S1L 在厂商账号未登录时不会发出 `start_recording` callback；专用 App 适配器通过
  Magisk 只读订阅固件 `WakeupManager` 的已识别事件，不读取 PCM 或厂商 ASR 文本
- 支持的话术示例：今天天气怎么样 / 现在几点 / 今天几号 / 农历多少 / 下一张 / 音量大一点 / 放猫的照片 / 播放全部 / 播报：开饭了 / 显示二维码 / 你会做什么
- TTS 播放完成后可连续对话；“退出对话 / 不聊了 / 先这样”退出本次短期会话

## 配置

配置文件位于应用数据目录（Linux：`~/.local/share/com.example.smart_frame/config.json`），全部字段有默认值，零配置可启动，也可在设置（S 键）里修改：

`listenSeconds`、`asr*`、`ttsVoice` 与 `wakeWordModelDir` 是旧配置文件兼容字段，当前语音链路
忽略它们；模型和供应商配置统一放在 Home Agent。智能屏只使用 `agentUrl` 和服务端签发的节点凭据。

```json
{
  "city": "广州",
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
  "musicEnabled": true,
  "musicMuted": false,
  "musicVolume": 0.55,
  "musicDir": "",
  "musicOutputEnabled": true,
  "musicQuietStartHour": 22,
  "musicQuietEndHour": 8,
  "wakeWordModelDir": "",
  "nasEnabled": false,
  "nasWebdavUrl": "http://192.168.1.22:5005",
  "nasWebdavUser": "",
  "nasWebdavPassword": "",
  "nasRemoteDir": "",
  "nasFilterEnabled": true,
  "nasFilterKeywords": ["截图", "screenshot", "屏幕快照", "收集"],
  "serverRole": "display",
  "agentUrl": "http://192.168.1.9:8790",
  "nodeId": "<server-issued>",
  "roomId": "<server-issued>",
  "deviceKey": "<server-issued>"
}
```

说明：

- `photoDir` 为空时回落到 `~/Pictures`，把照片放进去即可（支持 jpg/png/webp/bmp/gif），手机上传的照片也存这里
- **续播与照片说明**：当前照片 ID 写入应用支持目录的 `slideshow_state.json`，重启后恢复到同一张；拍摄时间优先取索引元数据，其次从相机文件名/日期目录推断，地点只显示明确的自定义相册目录，VLM 解说不可用时用已有场景标签生成简短说明，缺失字段不显示。
- **屏幕常亮**：Android 使用 wakelock；Linux 同时使用 wakelock 和 `xset` 关闭屏保/DPMS，并定期重申，避免桌面电源管理器重新启用黑屏。
- **智能配乐**：授权/用户曲库安装在 `home_agent` 所在服务器，来源与安装方式见 [授权音乐库](docs/music-library.md)。`display` 节点只拉取服务端选中的曲目并缓存播放；没有曲目时静音，不生成音乐。
- NAS 相册（WebDAV）在设置（S 键）或 web 控制台的「NAS 相册设置」卡片（`http://<电脑IP>:8780`）里配置：地址 / 账号 / 密码 / 远程目录，支持截图规则过滤；NAS 照片与本地照片混合轮播，未配置或连接失败时自动降级为本地相册，不影响其他功能
- **去重与跳过**：CCL/3588 `display` 模式只消费服务端已去重、未隐藏的照片列表；扫描、哈希、近似去重和 VLM 均由 `photo_indexer` 在服务器完成。`dedupEnabled` 仅保留给历史 `compute` 兼容模式。
- **HEIC 支持**：iPhone 的 `.heic` 照片需系统 `heif-convert` 解码——Linux 装一次 `sudo apt install libheif-examples`（macOS 自带、Windows 需 libheif）；未安装时 HEIC 自动跳过、其余格式不受影响
- **智能打标签（VLM，可选）**：开启 `vlmEnabled` 后，调用本地 [ollama](https://ollama.com) 视觉模型（默认 `minicpm-v`，先 `ollama pull minicpm-v`）给照片打场景标签和一句简短文字解说，并判定非照片（截图/表情包/文档/图标），非照片播放跳过。结果随后台索引增量计算，存 `photo_index.db`
- `nasWebdavPassword` 为本地明文存储（家庭局域网场景），请勿把真实配置文件提交到公开仓库

## 测试

```bash
cd apps/smart_frame
flutter analyze
flutter test    # 若本机配了代理，localhost 被代理劫持时需先 unset http_proxy 等变量
```

## 架构速览

```
apps/
  smart_frame/                智能屏 Flutter 应用
    lib/core/                 配置、网络和平台能力
    lib/features/             相册、语音、天气、日历、远程控制等垂直功能模块
    assets/web_console/       手机控制台单页
  student/                    独立 Android 学生端
  home_admin/                 HomeAdmin App（局域网直连 + HTTPS 云控制）
services/
  home_admin/                 HomeAdmin WebUI/BFF（不直接访问 Home Agent 数据库）
  home_agent/                 edge/cloud Agent + Linux Room Node + Home Hub Connector
  photo_indexer/              NAS 照片索引与识别守护进程
packages/node_protocol/       Linux/Android 房间节点共享 Dart 协议模型
deploy/                       部署单元
tool/                         全仓运维脚本
```

手机 WS 指令与语音/文字意图统一进 `CommandService` 处理，执行后经 WebSocket 广播状态给全部手机端；键盘快捷键为历史直连实现（不经总线、不触发广播），新增指令不得绕过总线。

## 文档

完整文档见 [docs/](docs/README.md)（需求、架构、协议、语音、开发、多 Agent/worktree 协作、commit 规范、部署、路线图）。
