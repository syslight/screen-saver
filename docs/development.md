# 开发指南（Development）

本文是 smart_frame 的开发者上手指南，也是 [AGENTS.md](../AGENTS.md)「构建与命令 / 环境坑」章节的展开版：环境搭建、日常命令、调试手段、测试说明与常见坑。功能用法见 [README.md](../README.md)，模块与数据流见 [architecture.md](architecture.md)，语音链路见 [voice-pipeline.md](voice-pipeline.md)。

## 1. 环境搭建

### 1.1 Flutter SDK

要求 Flutter 3.44+（stable）。本机 SDK 不在 PATH，位于 `/home/peidong/flutter/bin/flutter`（实测 3.44.6 stable，Dart 3.12.2），本文命令中的 `flutter` 均指该二进制。首次拉取依赖：

```bash
flutter pub get
```

### 1.2 Linux 构建链

与 README「开发环境」一致：

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
```

### 1.3 GStreamer 开发文件（Linux）

audioplayers 的 Linux 实现依赖 gstreamer-1.0 / app / audio 的开发文件（TTS 播报走它），有 sudo 时直接装：

```bash
sudo apt install libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
```

**无 sudo 的用户态替代方案**（本机实际在用）：dev 文件用 `apt download` 下载后 `dpkg -x` 解到 `~/.local/opt/gst`，`.pc` 文件的 `prefix` 改为 `~/.local/opt/gst/usr`，`lib*.so` 软链指向系统运行时库（前提是系统已装 GStreamer 运行时，桌面发行版默认有）。复现步骤：

```bash
cd /tmp
apt download libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
for f in libgstreamer*.deb; do dpkg -x "$f" "$HOME/.local/opt/gst"; done

# .pc 的 prefix 从 /usr 改为用户态根（否则头文件路径仍指向 /usr/include）
sed -i "s|^prefix=/usr$|prefix=$HOME/.local/opt/gst/usr|" \
  "$HOME/.local/opt/gst/usr/lib/x86_64-linux-gnu/pkgconfig/"*.pc

# dev 包内的 lib*.so 是相对软链，解到自定义目录后会断链，
# 改为指向系统运行时库的绝对路径
cd "$HOME/.local/opt/gst/usr/lib/x86_64-linux-gnu"
for so in libgst*.so; do
  ln -sf "/usr/lib/x86_64-linux-gnu/$(basename "$(readlink "$so")")" "$so"
done
```

之后每次编译 / 运行前导出两个变量（可写进 shell rc）：

```bash
export PKG_CONFIG_PATH=$HOME/.local/opt/gst/usr/lib/x86_64-linux-gnu/pkgconfig
export LIBRARY_PATH=$HOME/.local/opt/gst/usr/lib/x86_64-linux-gnu
```

### 1.4 Windows / macOS

无额外系统依赖说明，按 Flutter 官方桌面平台要求准备好 Xcode / Visual Studio 即可；构建必须在对应系统上进行（`flutter run -d windows` / `-d macos`）。

### 1.5 Home Agent

家庭 Agent 使用 Python 3.12 和 uv，与照片 `daemon/` 的虚拟环境、依赖和数据库完全隔离：

```bash
cd home_agent
uv sync --frozen
uv run alembic upgrade head
uv run home-agent
```

默认数据目录为 `~/.local/share/family-home-agent`，默认只监听 `127.0.0.1:8790`。
环境变量见 `home_agent/.env.example`。学生平板阶段 B 的可信家庭 Wi-Fi 原型可显式设置
`HOME_AGENT_HOST=0.0.0.0`；不得做公网端口映射，远程访问前必须增加 TLS/反向代理。

假节点获得家长端创建的一次性配对码后运行：

```bash
cd home_agent
uv run fake-room-node --pairing-code '<一次性配对码>'
```

终端只显示凭据文件路径，不打印设备密钥；下次启动省略 `--pairing-code` 即可复用设备凭据。

家长作业中心随 Home Agent 一起启动，访问 `http://127.0.0.1:8790/parent/`。开发环境中的
作业图片写入 `<data_dir>/homework/assets/`，测试使用临时目录，不会写入真实家庭数据。

可选的作业视觉检查默认关闭。启用 Kimi K3 时设置
`HOME_AGENT_HOMEWORK_MODEL_ENABLED=true`、`HOME_AGENT_HOMEWORK_MODEL_API_KEY`，默认
base URL 和模型名分别为 `https://api.moonshot.ai/v1`、`kimi-k3`。切换 GLM 时改为
`https://open.bigmodel.cn/api/paas/v4` 和支持图片输入的具体模型名。真实发送只由家长页面逐次
确认触发；不要把 `.env` 或密钥提交到仓库。

### 1.6 Android 学生端

```bash
cd student_app
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

debug APK 位于 `student_app/build/app/outputs/flutter-apk/app-debug.apk`。可用
`adb install -r build/app/outputs/flutter-apk/app-debug.apk` 安装。平板和服务器连接同一可信
Wi-Fi 后，在家长作业中心生成 8 位一次性码，平板输入 `<服务器局域网 IP>:8790` 完成绑定。
当前最低 Android 版本为 6.0（API 23），设备 key 由 `flutter_secure_storage` 存入 Android
Keystore 支持的安全存储；manifest 禁用应用数据备份，避免 key 随备份迁移。

## 2. 日常命令

```bash
flutter pub get                              # 拉依赖
flutter analyze                              # 静态检查，提交前必须无问题
flutter test                                 # 57 个用例，详见第 4 章
flutter run -d linux                         # 开发运行（全屏）
flutter build linux|windows|macos --release  # 出包在 build/<平台>/.../release/ 下
```

Home Agent 与共享协议包质量门禁：

```bash
cd home_agent
uv run ruff check .
uv run ruff format --check .
uv run mypy src
uv run pytest --cov=home_agent --cov=linux_room_node

cd ../packages/node_protocol
/home/peidong/flutter/bin/dart analyze
/home/peidong/flutter/bin/dart test

cd ../../student_app
/home/peidong/flutter/bin/flutter analyze
/home/peidong/flutter/bin/flutter test
/home/peidong/flutter/bin/flutter build apk --debug
```

Python 集成测试会在临时目录迁移数据库，并在 localhost 启动真实 Uvicorn + Fake Room Node，
自动验证初始化、登录、配对、能力上报、`fake.echo` 命令和断线状态，不依赖外网或真硬件。

**代理注意事项**：本机代理（127.0.0.1:10808）会劫持 flutter_tester 的 localhost WebSocket，导致 `test` / `run` 失败，跑之前必须先清掉代理变量（原理与解法见第 5.1 节）：

```bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
```

或单次执行用 `env -u`（推荐，不污染环境）：

```bash
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy /home/peidong/flutter/bin/flutter test
```

本机实测（2026-07-19）：上述 `env -u` 方式跑 `flutter test`，57 个用例全部通过。

## 3. 调试

### 3.1 日志：统一走 `debugPrint`

各服务不打日志框架，诊断信息全部走 `debugPrint`，`flutter run` 控制台直接可见（`flutter test` 输出里同样能看到）。现有日志点：

| 位置 | 日志内容 |
|---|---|
| `lib/server/control_server.dart:55` | `控制台已启动: <url>`——手机控制台地址，扫码/浏览器访问用它 |
| `lib/main.dart:79` | `控制台服务器启动失败: <e>`——端口被占等原因 |
| `lib/voice/wake_word.dart:63/96/130` | 唤醒词初始化失败 / 检测异常 / KWS 模型下载失败 |
| `lib/voice/voice_pipeline.dart:127` | `ASR 失败: <e>`——Whisper API 不可达、key 无效等 |
| `lib/voice/tts_service.dart:43/142` | edge-tts 失败回退系统 TTS / 系统 TTS 也失败 |

### 3.2 语音问题：先看右下角状态文本

语音链路的降级状态文本（`statusMessage`）不进日志，只在屏幕右下角可见：右下角的语音状态指示（`VoiceIndicator`，`lib/ui/widgets/voice_indicator.dart:7`）展示 `VoicePipeline.statusMessage`（`lib/voice/voice_pipeline.dart:37`，展示代码在 `voice_indicator.dart:31`），典型文案：

- `语音初始化失败: <e>`（`voice_pipeline.dart:84`，init 整体异常）
- `没有麦克风权限，语音不可用`（`voice_pipeline.dart:58`）
- `未找到唤醒词模型，正在后台下载…` / `唤醒词模型不可用，可用空格键或手机按钮触发`（`voice_pipeline.dart:66/72`）

所以排查语音问题的顺序：先看屏幕右下角状态文本定位降级原因，再回 `flutter run` 控制台找对应 `debugPrint` 细节。各状态与降级分支的完整说明见 [voice-pipeline.md](voice-pipeline.md)。

## 4. 测试说明

`flutter test` 共 57 个用例，全部是纯 Dart 单测（无 widget 测试），不需要真机窗口环境：

| 文件 | 用例数 | 覆盖 |
|---|---|---|
| `test/app_config_test.dart` | 3 | AppConfig NAS 字段：默认值、`fromJson({})` 回落默认、toJson/fromJson 往返逐字段相等 |
| `test/calendar_service_test.dart` | 5 | `calendarInfoFor`：春节（正月初一）、元旦与星期、干支生肖、节气（立春）、普通日星期 |
| `test/control_server_test.dart` | 8 | 控制台页 GET /、WS 连接即发状态快照（含 `nas` 字段）、指令执行与事件/状态广播、文字指令走意图解析、音量设置、multipart 上传照片（含非图片拒绝）、非法 WS 消息容错 |
| `test/intent_parser_test.dart` | 9 | `parseIntent`：天气 / 时间 / 日期 / 农历 / 照片切换 / 音量 / 播报 / 其他（显示二维码、帮助、未知）/ 带标点结尾 |
| `test/nas_filter_test.dart` | 6 | `nasPhotoAllowed`：关键词命中路径任意段排除（大小写不敏感）、内置截图文件名正则、普通照片放行、`enabled=false` 全放行、keywords 替换语义、空串关键词跳过 |
| `test/nas_photo_source_test.dart` | 4 | 假 WebDAV 服务器（`dart:io HttpServer`）端到端：ping + 递归列出（截图被过滤）、downloadTo 写盘长度正确、401 时 ping 抛异常、未 configure/remoteDir 空返回空 |
| `test/photo_service_test.dart` | 15 | `PhotoService`：本地+NAS 混合列表排序与 id、`currentName`、fileFor 本地直返、NAS 下载入缓存与命中不重复下载、LRU 淘汰、NAS 失败静默降级（连接失败/未启用/未配置）、无缓存目录返回 null、rescan 保持当前张、next/prev 环绕与 setDir、prefetchNext 预取、`applyNasConfig` 首次刷新 fire-and-forget 不阻塞、下载中断清理部分缓存文件、nasStatus 含已过滤计数 |
| `test/protocol_test.dart` | 5 | `decodeCommand`（合法、带参数、非法输入抛 `FormatException`）、`encodeState`、`encodeEvent` |
| `test/weather_service_test.dart` | 2 | `weatherCodeText` 天气码文案、`weatherFromJson` 解析 Open-Meteo 响应 |

其中 `test/control_server_test.dart` 是端到端测试，真实启动 HTTP/WS 服务器，有几个值得模仿的写法：

- **端口 0 由系统分配**（`control_server_test.dart:93`）：`ControlServer(port: 0, ...)`，`setUp` 后从 `server.boundPort` 取实际端口，避免与本机 8780 或其他服务冲突——新增服务器测试沿用此模式，不要写死端口。
- **Open-Meteo 走 `MockClient`**：geocoding 返回北京坐标、forecast 返回固定天气，不碰外网；中文响应必须 `http.Response.bytes` + utf-8（默认 latin1 会乱码）。
- **照片目录用临时目录**：`Directory.systemTemp.createTemp`，`tearDown` 递归删除。
- **TTS 静默失败**：测试环境无音频插件，`speak` 内部静默失败，不影响协议验证。

跑测试前同样注意第 5.1 节的代理问题。改动代码后的完成标准（AGENTS.md 硬性约定）：`flutter analyze` 无问题且 `flutter test` 全绿。

## 5. 常见坑

### 5.1 代理劫持 localhost WebSocket（test / run 失败）

**现象**：`flutter test` 卡住或报 WebSocket 连接错误，`flutter run` 起不来。

**原因**：本机代理（127.0.0.1:10808）把 flutter_tester 与 Dart VM Service 之间的 localhost WebSocket 也接管了，localhost 连接被劫持。

**解法**：跑 `test` / `run` 前清掉代理变量，二选一：

```bash
# 方式一：当前 shell 清掉（影响后续所有命令）
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy

# 方式二：单次执行用 env -u（推荐，不污染环境）
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy /home/peidong/flutter/bin/flutter test
```

### 5.2 CMake 缓存导致 install 阶段 Permission denied

**现象**：`flutter build linux --release` 在 install 阶段报 Permission denied，试图写 `/usr/local`。

**原因**：之前 configure 失败过的缓存把 `CMAKE_INSTALL_PREFIX` 留在了默认值 `/usr/local`。

**解法**：改 `build/linux/x64/release/CMakeCache.txt` 中 `CMAKE_INSTALL_PREFIX` 为 `<项目根>/build/linux/x64/release/bundle`；或直接 `flutter clean` 重来（更省事，代价是全量重编）。

### 5.3 Linux 链接 GStreamer 失败

audioplayers 编译期报 `gstreamer-1.0` / `gst/app` 找不到，即缺 GStreamer 开发文件，按第 1.3 节装系统包或配置用户态方案；用户态方案记得先导出 `PKG_CONFIG_PATH` 与 `LIBRARY_PATH` 再编译。
