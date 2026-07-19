# Task 7 报告：docs/deployment.md

## 状态：DONE

## 做了什么

创建 `docs/deployment.md`（未改动任何代码文件），内容按简报四节组织：

1. **三平台构建**：强调桌面端不可交叉编译。Linux 为本机实测命令 `flutter build linux --release`，产物 `build/linux/x64/release/bundle/`（已 `ls` 验证：`smart_frame` + `lib/` + `data/`）。Windows/macOS 给出同构官方命令（`flutter build windows|macos --release`）与产物路径（`build\windows\x64\runner\Release\smart_frame.exe`、`build/macos/Build/Products/Release/smart_frame.app`），并明确标注"需在对应系统上构建、本机未实测"。二进制/产品名非杜撰：分别核对了 `windows/CMakeLists.txt`（`BINARY_NAME = smart_frame`）与 `macos/Runner/Configs/AppInfo.xcconfig`（`PRODUCT_NAME = smart_frame`）。
2. **分发清单**：产物整目录拷贝（不要只拷可执行文件）；Linux 目标机需 GTK3 + GStreamer 运行时（引用 development.md 1.3）；配置/照片在应用支持目录、不进包。
3. **首启注意**：KWS 模型首启联网下载一次（约 15MB，存 `kws-model/`，失败时空格键/文字指令兜底）；ASR 需在设置里配 `base_url`/`key`，未配置自动降级；相册默认 `~/Pictures`；防火墙放行控制台端口 8780 且同局域网；补充了天气需出网一条。均与 README/AGENTS.md 事实一致。
4. **开机自启**：三平台各一句话思路（autostart desktop / shell:startup / 登录项），并提示自启需保证网络先行、预下载 KWS 模型。

## 验证

- `ls build/linux/x64/release/bundle/` → `data  lib  smart_frame`，与文档一致。
- `env -u ... flutter analyze` → **No issues found!**（纯文档新增，未触碰代码）。

## 疑虑

- Windows/macOS 产物路径为 Flutter 官方通例、本机无法实测，文档中已显式标注"以对应机器上构建输出为准"。
