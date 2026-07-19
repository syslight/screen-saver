## Global Constraints

- 全部文档用**中文**（代码标识符、命令、路径保持原文）。
- 规格：`docs/superpowers/specs/2026-07-18-project-docs-design.md`。
- **不得修改 `lib/`、`test/`、`web_console/`、`pubspec.yaml` 等任何代码文件**；只允许创建 `AGENTS.md` 和 `docs/**`。
- 文档中的事实必须与代码一致：命令必须真实可执行，协议字段以 `lib/server/protocol.dart` 为准，配置字段以 `lib/config/app_config.dart` 为准。
- 本项目**不是 git 仓库**：所有"commit"步骤跳过。
- Markdown 风格与 README.md 一致（中文叙述 + 表格 + 代码块）。

