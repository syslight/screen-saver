## Global Constraints

- 规格：`docs/superpowers/specs/2026-07-19-nas-photo-source-design.md`，功能/字段名/默认值以它为准。
- 遵守 `AGENTS.md` 硬性约定：`flutter analyze` 无问题、`flutter test` 全绿是完成门槛。
- flutter 二进制：`/home/peidong/flutter/bin/flutter`；跑 test/analyze 前必须 `env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy`。
- 项目**不是 git 仓库**：所有 "commit" 步骤跳过。
- 代码注释用中文，风格与现有代码一致；新指令不得绕过 CommandService（本期无新指令）。
- 现有 29 个测试保持全绿；现有公共行为（`currentState()` 既有字段、上传接口、轮播语义）不得破坏。
- **YAGNI**：不写回 NAS、不做缩略图、不多 NAS、不做 EXIF 判定。

