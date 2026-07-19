# Task 6 报告：docs/development.md

日期：2026-07-18
状态：DONE

## 交付物

- 新建 `docs/development.md`（158 行），未修改任何代码文件（`lib/`、`test/`、`pubspec.yaml` 等均未动）。
- 结构：1 环境搭建（Flutter SDK / Linux 构建链 / GStreamer 开发文件含用户态方案 / Windows-macOS）→ 2 日常命令（含代理注意事项与本机实测结论）→ 3 调试（debugPrint 日志点表格、语音状态文本排查路径）→ 4 测试说明（29 用例 5 文件表格 + control_server_test.dart 端到端写法要点）→ 5 常见坑（代理劫持 / CMake 缓存 / GStreamer 链接失败）。

## 事实核实记录

- **apt 包名**：Linux 构建链 `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev` 与 README.md:14 逐字一致；GStreamer 两包 `libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev` 为简报要求的新增事实。
- **Flutter 版本**：`flutter --version` 实测 3.44.6 stable / Dart 3.12.2，二进制路径 `/home/peidong/flutter/bin/flutter` 真实可用。
- **端口 0**：`test/control_server_test.dart:93` 确认 `ControlServer(port: 0, ...)`，`:98` `port = server.boundPort`，文件头注释（:27）即"端口 0 = 系统分配"。文档引为新增服务器测试的范式。
- **测试覆盖点**：通读 5 个测试文件，用例数 5/8/9/5/2 = 29，与 AGENTS.md 测试地图一致。
- **调试事实**：debugPrint 日志点逐行核对（control_server.dart:55 / main.dart:67 / wake_word.dart:63,96,130 / voice_pipeline.dart:127 / tts_service.dart:43,142）；`statusMessage` 由 `voice_indicator.dart:31` 展示，位置为右下角（voice_indicator.dart:6 注释证实，初稿"底部状态栏"已修正）。
- **用户态 GStreamer 方案**：对照 `~/.local/opt/gst` 实际状态写出可复现步骤——`.pc` 的 `prefix` 已改为 `$HOME/.local/opt/gst/usr`（读过 gstreamer-1.0.pc 证实）、`libgst*.so` 为指向 `/usr/lib/x86_64-linux-gnu/*.so.0` 的绝对软链（ls -la 证实），文档补充了 sed 改 prefix 和重建软链两步（AGENTS.md 未展开的细节）。

## 验证结果

- `env -u http_proxy ... flutter analyze` → **No issues found!**（1.2s）
- `env -u http_proxy ... flutter test` → **+29: All tests passed!**（实测，简报"29 用例全过"成立；测试输出中同时观察到 `控制台已启动: http://192.168.1.9:41103`，佐证 debugPrint 可见性与端口随机分配）

## 疑虑 / 说明

- 无阻塞疑虑。一点说明：用户态 GStreamer 复现步骤（apt download + dpkg -x + sed prefix + 重建软链）是依据当前 `~/.local/opt/gst` 的终态反推的合理步骤，终态各项均已验证，但原始的逐步操作历史无从考证；若日后换机执行发现差异，应按实际情况修订第 1.3 节。
- 文档内 `../AGENTS.md`、`../README.md` 相对链接在 docs/ 目录下有效；voice-pipeline.md 等既有文档未用相对链接，风格差异属可接受范围。
