# 智能屏（Smart Frame）

跑在 Windows / macOS / Linux 上的全屏智能屏应用（电子相框），Flutter 桌面端。

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
```

在 Windows / macOS 上同理（`flutter run -d windows` / `-d macos`，构建需对应系统）。

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
2. 功能：查看状态、切换照片、调节音量、发文字指令、让屏幕播报、上传照片
3. 多台手机可同时连接，状态实时同步

## 语音交互

- 首次启动会在后台下载唤醒词模型（约 15MB），下载完成后说出默认唤醒词即可唤醒（模型来自 sherpa-onnx wenetspeech KWS，自定义唤醒词可编辑配置目录下 `kws-model/keywords.txt`）
- 唤醒词下载失败或不想用时：**空格键** 或手机控制台的文字指令同样可用
- 支持的话术示例：今天天气怎么样 / 现在几点 / 今天几号 / 农历多少 / 下一张 / 音量大一点 / 播报：开饭了 / 显示二维码 / 你会做什么
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
- NAS 相册（WebDAV）在设置（S）里开启：地址 / 账号 / 远程目录，支持截图规则过滤；NAS 照片与本地照片混合轮播，未配置或连接失败时自动降级为本地相册，不影响其他功能
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
```

手机 WS 指令与语音/文字意图统一进 `CommandService` 处理，执行后经 WebSocket 广播状态给全部手机端；键盘快捷键为历史直连实现（不经总线、不触发广播），新增指令不得绕过总线。

## 文档

完整文档见 [docs/](docs/README.md)（需求、架构、协议、语音、开发、部署、路线图）。
