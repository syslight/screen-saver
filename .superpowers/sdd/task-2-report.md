# Task 2 报告：docs/requirements.md

## 产出

创建了 `docs/requirements.md`（中文，Markdown 风格与 README.md 一致），结构：

- **1. 项目概述**：定位与核心要求（零配置、失败隔离）。
- **2. 功能需求**：按 6 个模块列出 36 条可勾选项（当前均已实现，全部打勾），编号 FR-<模块>-<n>：
  - 2.1 天气（FR-W-1~5）：Open-Meteo 免 key、城市名地理编码（zh、取首个结果）、`weatherRefreshMinutes` 定时刷新、展示字段（温度/体感/湿度/风速/WMO 码中文描述/今日高低温）、失败保留旧数据。
  - 2.2 日历（FR-C-1~5）：公历+星期、农历月日、干支生肖、节气、公历农历节日（festivals + otherFestivals）。
  - 2.3 相册（FR-P-1~6）：本地目录轮播、扩展名 `.jpg/.jpeg/.png/.webp/.bmp/.gif`（以 `imageExts` 为准）、`slideshowSeconds` 自动切换（0 停止）、三渠道手动切换并重置计时、交叉渐变（AnimatedSwitcher）、30 秒重扫。
  - 2.4 语音交互（FR-V-1~7）：唤醒词/空格/手机按钮三触发、模型后台下载（约 15MB，keywords.txt 自定义）、提示音+`listenSeconds` 录音、OpenAI 兼容 Whisper ASR、`parseIntent` 13 种意图、文字指令同链路、状态机同步手机端。
  - 2.5 TTS（FR-T-1~3）：edge-tts 主用（zh-CN-XiaoxiaoNeural）、系统 TTS 兜底（espeak-ng / say / SAPI）、音量 0..1。
  - 2.6 手机控制（FR-M-1~7）：shelf HTTP+WS（默认 8780）、Q 键二维码（`http://<局域网IPv4>:<端口>`）、控制台六功能、多设备同时在线、连接即快照+指令后广播、`POST /api/photos` multipart 上传（非图片不存入）、指令统一经 CommandService。
- **3. 非功能需求**：NFR-1 三平台桌面、NFR-2 全屏常驻（window_manager + wakelock_plus）、NFR-3 零配置可启动（12 字段默认值）、NFR-4 失败隔离（引 `lib/main.dart` 注释为据）、NFR-5 局域网内工作（标明四项外网依赖）、NFR-6 语音链路逐层降级（麦克风权限/KWS 模型/ASR 未配置/TTS 失败四层）、NFR-7 质量基线（analyze 无问题 + 29 单测全绿）。编号供 roadmap.md 呼应。

## 事实核对（均与源码一致）

- `imageExts` 实际值 `['.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif']`（`lib/services/photo_service.dart:11`，`.toLowerCase()` 匹配），文档照此写，与 README 的"jpg/png/webp/bmp/gif"表述不矛盾（文档更精确，含 `.jpeg`）。
- 上传逻辑（`lib/server/control_server.dart:83-103`）：非 `imageExts` 扩展名的文件跳过不保存——文档写"非图片文件拒绝"。
- 快捷键（`lib/ui/dashboard_page.dart:28-53`）、二维码内容 `server.url`（`qrcode_overlay.dart:35`，基于 `NetworkInterface` 局域网 IPv4）、意图枚举 13 种（`intent_parser.dart:4-18`）、TTS 回退三平台命令（`tts_service.dart:127-144`）、配置 12 字段默认值（`app_config.dart`）、天气字段与刷新（`weather_service.dart`）均已逐条比对。
- 需求条目与 README 功能列表无矛盾。

## 验证结果

```
env -u http_proxy ... /home/peidong/flutter/bin/flutter analyze
→ No issues found! (ran in 6.6s)
```

纯文档任务，未改任何代码文件，未执行 git 操作（本项目非 git 仓库）。

## 文件清单

- 新建：`docs/requirements.md`
- 未修改任何其他文件。

## 疑虑

- "可勾选项"理解为 checkbox 列表：因基线条目对应当前已实现行为，全部打 `- [x]`，并在文档开头注明语义；若后续 Task 8（roadmap）希望用 `- [ ]` 表示未完成项，可在 roadmap 中自行使用，不影响本文档。
- 无其他疑虑。


---

## Fix 记录（审查后修正）

审查指出 FR-W-4 与代码不符，经复核确认属实，另采纳两条 Minor 建议。共修改 `docs/requirements.md` 三处，未动其他文件：

1. **FR-W-4（事实错误，已修正）**：原条声称界面展示体感温度与风速。实际 `lib/ui/widgets/weather_widget.dart:36-62` 仅显示当前温度、城市、天气描述、今日最低/最高温度、湿度；体感温度仅出现在天气语音播报（`lib/services/command_service.dart:102`）；风速在 `weather_service.dart` 解析后无任何消费方。现改为："界面展示当前温度、城市、天气状况（WMO 天气码映射为中文描述）、今日最低/最高温度与湿度；体感温度纳入天气语音播报；风速仅采集解析，未在界面或播报中使用。"
2. **FR-V-2（Minor）**：删去"约 15MB"（数字出自 README 而非代码），改为"sherpa-onnx wenetspeech KWS 模型"。
3. **FR-M-2（Minor）**：补充边角情况——局域网 IP 获取失败时地址回落为 `http://localhost:<端口>`（仅本机可访问），依据 `lib/server/control_server.dart:53-54`（`url = 'http://${ip ?? 'localhost'}:$boundPort'`）。

修正后验证：`flutter analyze` → No issues found（纯文档改动，不影响代码）。
