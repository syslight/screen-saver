# 打包与分发（Deployment）

本文讲如何把 smart_frame 打成 release 包并分发到目标机器：三平台构建命令与产物路径、分发清单、首启注意事项、开机自启思路。环境搭建与构建链依赖见 [development.md](development.md)，功能与配置用法见 [README.md](../README.md)。

## 1. 三平台构建

Flutter 桌面端**不可交叉编译**：打哪个平台的包，就必须在对应系统上构建。以下命令均在 `apps/smart_frame/` 执行，其 `linux/`、`windows/`、`macos/` 平台工程均随应用放在该目录。

### 1.1 Linux（本机已实测）

```bash
cd apps/smart_frame
flutter pub get
flutter build linux --release
```

产物目录：`build/linux/x64/release/bundle/`，结构如下（本机 `ls` 实测）：

```
bundle/
  smart_frame     # 可执行文件
  lib/            # 引擎与插件动态库
  data/           # flutter_assets（含 web_console 等 assets）
```

### 1.2 Windows（需在 Windows 上构建）

需在装有 Visual Studio（Desktop development with C++）的 Windows 机器上执行，命令与 Linux 同构：

```bash
cd apps/smart_frame
flutter pub get
flutter build windows --release
```

产物目录（Flutter 官方通例，二进制名以 `windows/CMakeLists.txt` 的 `BINARY_NAME = smart_frame` 为准）：`build\windows\x64\runner\Release\`，含 `smart_frame.exe` 及同目录的 DLL 与 `data/`。

### 1.3 macOS（需在 macOS 上构建）

需在装有 Xcode 的 Mac 上执行：

```bash
cd apps/smart_frame
flutter pub get
flutter build macos --release
```

产物（Flutter 官方通例，产品名以 `macos/Runner/Configs/AppInfo.xcconfig` 的 `PRODUCT_NAME = smart_frame` 为准）：`build/macos/Build/Products/Release/smart_frame.app`。

> Windows / macOS 两条构建路径本机未实测，命令写法为 Flutter 官方通例，与 Linux 同构；实际产物路径以对应机器上构建输出为准。

## 2. 分发清单

- **整目录拷贝**：Flutter 桌面 release 产物是自包含的，分发时把产物目录**整体**拷走（Linux 为整个 `bundle/`，Windows 为整个 `Release/`，macOS 为整个 `.app`），不要只拷单个可执行文件——动态库和 `data/` 都在旁边。
- **运行时依赖**：
  - Linux：目标机需有 GTK3 与 GStreamer 运行时（桌面发行版通常自带）；TTS 播报依赖 GStreamer，详见 [development.md](development.md) 1.3。
  - Windows / macOS：无额外依赖说明，按 Flutter 桌面应用常规分发即可。
- **数据不进包**：照片、配置均在目标机的应用支持目录生成（Linux：`~/.local/share/com.example.smart_frame/`），不与安装包捆绑。

## 3. 首启注意事项

- **唤醒词模型联网下载一次**：首次启动会在后台下载 sherpa-onnx KWS 唤醒词模型（约 15MB，存到应用支持目录 `kws-model/`）；机器完全离线或下载失败时语音唤醒不可用，可用**空格键**或手机控制台文字指令替代，其余功能不受影响。
- **ASR 需配置**：云端语音识别默认未配置 API Key，需在设置（S 键）里填 `base_url` 和 `key`（OpenAI 兼容接口，可指向 Groq 或本地 faster-whisper）；未配置时语音链路自动降级。
- **相册默认目录**：默认轮播 `~/Pictures`（可在设置里改），把照片（jpg/png/webp/bmp/gif）放进去即可，手机上传的照片也存这里。
- **NAS 相册需在设置里配置**：默认关闭。在设置（S 键）"NAS 相册"区填 WebDAV 地址 / 账号 / 密码 / 远程照片目录并打开开关（有"测试连接"按钮可先验证）；`远程照片目录` 留空视为未配置，不会访问 NAS。未配置或连接失败时自动降级为本地相册（状态显示 `未配置` / `连接失败`），不影响其余功能。NAS 图片按需下载到应用支持目录 `nas-cache/`（上限 500MB，自动淘汰最久未访问）。
- **防火墙放行控制台端口**：手机控制台走 HTTP/WebSocket，默认端口 **8780**；目标机防火墙需放行该端口的入站 TCP，且手机与电脑须在同一局域网，否则扫码/浏览器访问 `http://<电脑IP>:8780` 不通。
- **天气联网**：天气走 Open-Meteo 免费 API，无需 Key，但需要出网；断网时天气卡片显示不可用，其余功能正常。

## 4. 开机自启与无人值守

只列思路，不展开实现：

- **Linux**：桌面环境的 autostart 机制（`~/.config/autostart/*.desktop`）或 systemd user service 指向 bundle 内的 `smart_frame`。
- **Windows**：「启动」文件夹快捷方式（`shell:startup`）或任务计划程序登录触发器。
- **macOS**：系统设置的「登录项」或 LaunchAgent。

三平台共同注意：自启场景下确保网络先于应用就绪（首启要下 KWS 模型、天气要联网），并把唤醒词模型预先下载好再交付，可减少首启等待。
