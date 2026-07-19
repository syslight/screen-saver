# Task 1 报告：AGENTS.md

## 产出了什么

创建 `/home/peidong/source/screen-saver/AGENTS.md`（约 5.7KB），章节如下：

1. **项目简介** — 一句话定位 + 包名/平台/Flutter 版本，并指向 README.md 避免重复门面内容
2. **构建与命令** — `flutter pub get` / `analyze` / `test` / `run -d linux` / `build linux|windows|macos --release` 代码块；含三个坑：代理坑（127.0.0.1:10808 劫持 flutter_tester，含 `unset` 与 `env -u` 两种解法）、Linux GStreamer 用户态方案（`PKG_CONFIG_PATH`/`LIBRARY_PATH` 指向 `$HOME/.local/opt/gst/...`）、CMake 缓存坑（`CMAKE_INSTALL_PREFIX` 残留 `/usr/local` 的修法）
3. **目录结构** — 照 README 架构速览，补 `main.dart` 与 `test/` 两行
4. **硬性约定** — analyze+test 全绿（29 用例）、指令统一经 `CommandService`、改目录/命令/协议/配置须同步的文档清单（指到具体文件）、规格落 `docs/superpowers/specs/` 计划落 `docs/superpowers/plans/`、非 git 仓库禁 git 操作
5. **配置** — 路径 `~/.local/share/com.example.smart_frame/config.json`（Linux）+ 12 字段表格（字段/默认值/含义）
6. **测试地图** — 5 个测试文件 × 用例数 × 覆盖点表格

简报要求的章节与必含事实全部落入，无占位符。

## 验证结果

- `env -u ... /home/peidong/flutter/bin/flutter analyze` → **No issues found!**（写完文档后复跑一次，同样通过，证明未碰代码）
- `flutter test`（同 env -u 前缀）→ **+29: All tests passed!**，与简报"29 个用例"一致
- 事实抽查记录：
  - 配置字段：通读 `lib/config/app_config.dart`，12 个字段名/默认值/含义与表格逐一核对一致（含 photoDir 空→`~/Pictures`、wakeWordModelDir 空→支持目录/`kws-model` 两个 `_applyDefaults` 回填逻辑）
  - 用例数：`grep -c '^\s*(test|testWidgets)\(' test/` 合计 29（calendar 5 / control_server 8 / intent_parser 9 / protocol 5 / weather 2），且全仓库无 `testWidgets`，"纯 Dart 单测"表述属实
  - 测试覆盖点：抽查各测试文件的 group/test 名称，与测试地图描述一致（"其他"一处经精读源码后补全为"显示二维码、帮助、未知"）
  - 目录结构：`ls lib/ lib/* test/` 实查，与文档一致
  - flutter 位置：`/home/peidong/flutter/bin/flutter --version` → 3.44.6 stable，确不在 PATH，文档已注明绝对路径
  - GStreamer 用户态目录 `$HOME/.local/opt/gst/usr/lib/x86_64-linux-gnu/pkgconfig` 实查存在（含 gstreamer-1.0/app/audio 等 .pc）
  - CMake 缓存：`build/linux/x64/release/CMakeCache.txt` 中 `CMAKE_INSTALL_PREFIX` 当前为正确的 bundle 路径；`build/linux/x64/release/bundle/` 存在且含 `smart_frame` 二进制，证明 `flutter build linux --release` 真实可用
  - 非 git 仓库：`ls -d .git` 不存在，属实

## 文件清单

- 新建：`AGENTS.md`（项目根）
- 新建：`.superpowers/sdd/task-1-report.md`（本报告）
- 未修改任何其他文件（`lib/`、`test/`、`web_console/`、`pubspec.yaml` 等均零改动，analyze 通过可证）

## 疑虑或问题

- `flutter run -d linux`（交互式全屏应用）与 `flutter build windows|macos --release`（需对应系统）未在本机实际执行；前者是 Flutter 标准命令，后者由简报点名要求列入。`flutter build linux --release` 已由现存 bundle 产物间接证实可用。
- 简报建议的抽查命令 `grep -c '"' lib/config/app_config.dart` 返回 0（Dart 源码字符串用单引号），该命令本身无校验价值，已改用通读源码方式完成核对。
