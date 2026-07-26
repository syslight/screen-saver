# smart_frame（智能屏）· AI Agent 指南

本文件是所有 AI coding agent 的项目入口，每个会话先读这里。功能介绍、快捷键、使用方法见 [README.md](README.md)，本文只讲"干活需要知道的事"。深层文档索引见 [docs/README.md](docs/README.md)（需求 / 架构 / 协议 / 语音 / 开发 / 部署 / 路线图）。

无论使用 Codex、Claude Code、Kimi Code CLI 或其他 Agent，均以本文件为项目规则的唯一权威入口；客户端专用入口只能引用本文件，不得复制维护另一套规则。涉及并行任务时，还必须先读 [docs/agent-workflow.md](docs/agent-workflow.md)。

## 项目简介

Monorepo 当前包含 Flutter 全屏智能屏，以及独立的家庭 Agent 基础设施。智能屏目标平台
Windows / macOS / Linux / Android，包名 `smart_frame`，Flutter 3.44+（stable）；家庭 Agent
使用 Python 3.12 + uv，通过版本化 HTTP/WebSocket 协议连接 Linux/Android 房间节点；
`student_app/` 是独立的 Flutter Android 学生作业端。

## 构建与命令

本机 `flutter` 不在 PATH，位于 `/home/peidong/flutter/bin/flutter`（当前 3.44.6 stable），下文命令中的 `flutter` 均指它。

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d linux
flutter build linux|windows|macos --release   # 出包在 build/<平台>/.../release/ 下
flutter build apk --release                   # Android arm64 展示端

cd student_app
flutter pub get
flutter analyze
flutter test
flutter build apk --debug                     # 独立学生端 APK
```

### 代理坑

本机代理（127.0.0.1:10808）会劫持 flutter_tester 的 localhost WebSocket，跑 `test`/`run` 前必须先清掉代理变量：

```bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
```

或单次执行用 `env -u`（推荐，不污染环境）：

```bash
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy /home/peidong/flutter/bin/flutter test
```

### Linux GStreamer（无 sudo 用户态方案）

audioplayers 需要 gstreamer-1.0 / app / audio 开发文件。无 sudo 时用用户态方案（dev 文件由 apt 下载后 `dpkg -x` 解到该目录，`.so` 软链已指向系统运行时库）：

```bash
export PKG_CONFIG_PATH=$HOME/.local/opt/gst/usr/lib/x86_64-linux-gnu/pkgconfig
export LIBRARY_PATH=$HOME/.local/opt/gst/usr/lib/x86_64-linux-gnu
```

### CMake 缓存坑

configure 失败过的缓存会把 `CMAKE_INSTALL_PREFIX` 留在 `/usr/local`，导致 install 阶段 Permission denied。修法：改 `build/linux/x64/release/CMakeCache.txt` 中该值为 `<项目根>/build/linux/x64/release/bundle`，或直接 `flutter clean`。

## 目录结构

```
lib/
  main.dart                   入口：服务装配 + Provider 注入
  config/app_config.dart      配置模型与持久化（ConfigService）
  services/                   weather / calendar / photo（聚合 NAS 图源 nas_photo_source、过滤 nas_filter、去重索引 photo_index_service）/ command(统一指令总线)
  server/                     shelf HTTP+WS 服务器、消息协议
  voice/                      唤醒词(KWS)、ASR 客户端、意图解析、edge-tts、状态机
  ui/                         全屏仪表盘与各小组件
web_console/index.html        手机控制台单页（原生 JS，打包进 assets）
daemon/                       照片守护进程（Python 3.12 + uv，离线全量预处理 NAS 照片：dinov2/CLIP/insightface/VLM，写共享 SQLite；见 daemon/README.md）
home_agent/                   家庭 Agent Server + Linux Room Node；独立 uv 环境、SQLite 和 Alembic 迁移
  src/home_agent/web/parent/  家长作业中心静态单页；认证、成员、任务、上传和人工审核
student_app/                  独立 Flutter Android 学生端；设备配对、作业列表、拍照提交和审核结果
packages/node_protocol/       节点协议 Dart 模型、共享 canonical fixtures 与合约测试
deploy/                       systemd user unit（守护进程常驻）
test/                         11 个 Dart 测试文件，见下方"测试地图"
```

NAS 图源引入新依赖 `webdav_client`（`pubspec.yaml`），桌面设置页（S 键）与 web 控制台（`/api/config`、`/api/config/test`，见 `docs/protocol.md` 第 5 章）均可配置 NAS 并测试连接；二者写同一份 `config.json`。

## 硬性约定

- **改代码后必须验证**：智能屏改动需 `flutter analyze` 无问题且 `flutter test` 全绿；
  `home_agent/` 改动还必须执行 `uv run ruff check .`、`uv run ruff format --check .`、
  `uv run mypy src`、`uv run pytest --cov=home_agent --cov=linux_room_node`；
  `student_app/` 改动执行其目录下的 `flutter analyze`、`flutter test`，涉及 Android 插件或
  manifest 时还要构建 APK；`packages/node_protocol/` 改动执行 `dart analyze` 与 `dart test`。
  各语言/包边界互不代替验收。
- **指令统一入口**：现状——手机 WS 指令与语音意图统一经 `CommandService`（`lib/services/command_service.dart`）总线处理，执行后经 WebSocket 广播状态给全部手机端；键盘快捷键为直连服务的历史实现（`lib/ui/dashboard_page.dart`：←/→ 直连 `PhotoService`、空格直连 `VoicePipeline.triggerListen`，不经总线、不触发广播）。规范——新增指令应接入 `CommandService` 总线，不得绕过它直接操作服务，以便状态广播到全部手机端。
- **改了就要同步文档**：
  - 目录结构 / 构建命令 → README.md（「运行与构建」「架构速览」）+ 本文件对应章节
  - 协议字段（以 `lib/server/protocol.dart` 为准）→ `docs/protocol.md` + 本文件相关描述 + `test/protocol_test.dart`
  - 语音链路（`lib/voice/`，含意图解析、状态机、KWS/ASR/TTS 行为）→ `docs/voice-pipeline.md`
  - 配置项（以 `lib/config/app_config.dart` 为准）→ README.md「配置」+ 本文件「配置」表格
- **规格与计划**：规格文档落 `docs/superpowers/specs/`，计划落 `docs/superpowers/plans/`。
- **家庭 Agent 协议**：以 `home_agent/src/home_agent/protocol/` 和共享 fixture 为准；改字段时同步
  `docs/home-agent-protocol.md`、Python 合约测试与 `packages/node_protocol/` Dart 合约测试。
- **学生权限边界**：学生端必须使用独立 `Student` device key，不能保存或复用家长 bearer；
  学生任务响应不得包含 `referenceAnswer`、`rubric` 或其他孩子信息。更换孩子必须撤销后重配。
- 本项目是 git 仓库，托管在 GitHub 私有仓库 `screen-saver`；`git commit` / `push` 等变更操作必须先经用户确认，不要自动执行。
- **提交规范**：获得用户确认后，commit 必须遵守 [docs/commit-convention.md](docs/commit-convention.md)：标题说明提交目的，正文必须写清“要做什么 / 做了什么 / 负面影响 / Review 重点 / 验证”。不得用 `update`、`fix bug` 等无法审计的模糊描述。

## 多 Agent / worktree 协作

- 一个可写任务对应一个独立分支和一个独立 worktree；禁止多个可写 Agent 共用同一工作目录。只读调研可共享目录，但不得落盘。
- 主协调者负责拆分任务、声明文件边界、避免依赖倒置，并且是唯一负责最终归并和全量验收的角色。
- 子任务开始前记录基线提交；结束时必须交付：状态、改动文件、验证命令与结果、未解决风险、建议归并顺序。禁止只回复“完成”。
- 未经用户确认，任何 Agent 都不得 `git commit`、`git push`、合并分支、删除分支或移除 worktree；不得用 `git reset --hard`、`git clean -fd` 等破坏性命令处理冲突。
- 并行任务尽量按互不重叠的文件/模块拆分；若必须修改共享文件，由主协调者指定唯一 owner，其他 Agent 只提交建议或补丁说明。
- 完整 SOP、命名规范、命令、任务简报与交接模板见 [docs/agent-workflow.md](docs/agent-workflow.md)；辅助命令见 `tool/agent_worktree.sh`。

## 配置

配置文件：`~/.local/share/com.example.smart_frame/config.json`（Linux；其他平台为对应的应用支持目录）。全部字段有默认值，零配置可启动，也可在应用内按 **S** 修改。共 19 个字段：

| 字段 | 默认值 | 含义 |
|---|---|---|
| `city` | `广州` | 天气城市名（Open-Meteo 地理编码） |
| `photoDir` | 空 → `~/Pictures` | 相册目录（手机上传的照片也存这里） |
| `serverPort` | `8780` | 手机控制台端口 |
| `slideshowSeconds` | `10` | 相册轮播间隔（秒） |
| `weatherRefreshMinutes` | `30` | 天气刷新间隔（分钟） |
| `listenSeconds` | `5` | 唤醒后聆听时长（秒） |
| `asrBaseUrl` | `https://api.openai.com/v1` | OpenAI 兼容 Whisper API（可指向 Groq 等） |
| `asrApiKey` | 空 | ASR API Key；未配置时语音链路自动降级 |
| `asrModel` | `whisper-1` | ASR 模型名 |
| `ttsVoice` | `zh-CN-XiaoxiaoNeural` | edge-tts 语音名 |
| `volume` | `0.8` | 播报音量 0..1 |
| `wakeWordModelDir` | 空 → 支持目录/`kws-model` | sherpa-onnx KWS 唤醒词模型目录 |
| `nasEnabled` | `false` | 是否启用 NAS 相册来源 |
| `nasWebdavUrl` | `http://192.168.1.22:5005` | NAS WebDAV 地址 |
| `nasWebdavUser` | 空 | NAS WebDAV 账号 |
| `nasWebdavPassword` | 空 | NAS WebDAV 密码（本地明文存储，局域网场景） |
| `nasRemoteDir` | 空 | NAS 远程照片目录；为空视为未配置（即使启用也不扫描，状态"未配置"） |
| `nasFilterEnabled` | `true` | NAS 截图规则过滤开关（仅作用于 NAS 来源） |
| `nasFilterKeywords` | `['截图', 'screenshot', '屏幕快照', '收集']` | NAS 过滤关键词（路径含关键词即排除，大小写不敏感，替换语义） |
| `nasFilterMinBytes` | `30720` | NAS 过滤：小于此字节数的文件视为缩略图/图标排除（0=不限） |
| `dedupEnabled` | `true` | 是否启用内容级去重（sha256 完全重复 + dHash 近似重复），播放跳过 |
| `dedupPHashThreshold` | `5` | dHash 海明距离 ≤ 此值视为近似重复（0-64，越小越严格） |
| `heicEnabled` | `true` | 是否支持 HEIC/HEIF（需系统 `heif-convert`，不可用时自动降级跳过） |
| `vlmEnabled` | `false` | 是否启用 VLM（ollama 视觉模型）打标签 + 非照片判定（重，默认关） |
| `vlmModel` | `minicpm-v` | ollama 视觉模型名（minicpm-v / llama3.2-vision / llava 等） |
| `ollamaUrl` | `http://localhost:11434` | ollama API 地址 |

## 测试地图

`flutter test` 共 85 个用例，全部是纯 Dart 单测（无 widget 测试）：

| 文件 | 用例数 | 覆盖 |
|---|---|---|
| `test/app_config_test.dart` | 3 | AppConfig NAS 字段：默认值、`fromJson({})` 回落默认、toJson/fromJson 往返逐字段相等 |
| `test/android_setup_page_test.dart` | 2 | Android 计算节点 URL 校验与规范化 |
| `test/calendar_service_test.dart` | 5 | `calendarInfoFor`：春节（正月初一）、元旦与星期、干支生肖、节气（立春）、普通日星期 |
| `test/control_server_test.dart` | 17 | 控制台页 GET /、照片说明端点参数/404/已确认家庭身份字段、WS 连接即发状态快照（含 `nas` 字段）、指令执行与事件/状态广播、文字指令走意图解析、音量设置、multipart 上传照片（含非图片拒绝）、非法 WS 消息容错、NAS 配置端点（GET 读取不含密码、POST 保存密码空=不改、POST test 不可达 ok:false）、保存后 nas 状态广播、筛选参数校验与清除 |
| `test/intent_parser_test.dart` | 10 | `parseIntent`：天气 / 时间 / 日期 / 农历 / 照片切换 / 音量 / 播报 / 语义筛选与清除 / 其他（显示二维码、帮助、未知）/ 带标点结尾 |
| `test/nas_filter_test.dart` | 8 | `nasPhotoAllowed`：关键词命中路径任意段排除（大小写不敏感）、内置截图文件名正则、普通照片放行、`enabled=false` 全放行、keywords 替换语义、空串关键词跳过、`@eaDir` 段排除、小文件（size<minBytes）排除 |
| `test/nas_photo_source_test.dart` | 4 | 假 WebDAV 服务器（`dart:io HttpServer`）端到端：ping + 递归列出（截图被过滤且计入 `lastFilteredCount`）、downloadTo 写盘长度正确、401 时 ping 抛异常、未 configure/remoteDir 空返回空 |
| `test/photo_service_test.dart` | 23 | `PhotoService`：本地+NAS 混合列表与缓存、故障降级、轮播/筛选/hidden 行为、按照片 ID 持久化恢复位置、等待 NAS 首次列表后恢复、display 强制拉取 HTTP 图源 |
| `test/photo_index_service_test.dart` | 6 | `PhotoIndexService`：读库 hidden/status、标签/人物筛选、照片路径时间与地点推断、索引时间/标签到文字解说、只返回家长确认的身份 |
| `test/protocol_test.dart` | 5 | `decodeCommand`（合法、带参数、非法输入抛 `FormatException`）、`encodeState`、`encodeEvent` |
| `test/weather_service_test.dart` | 2 | `weatherCodeText` 天气码文案、`weatherFromJson` 解析 Open-Meteo 响应 |
