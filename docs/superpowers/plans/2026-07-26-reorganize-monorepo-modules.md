# Monorepo 与功能模块目录重整计划

日期：2026-07-26

## 目标

本次只调整目录边界、导入和运行路径，不改变协议、配置格式、数据库结构或业务行为。

仓库顶层按交付单元划分：

```text
apps/
  smart_frame/       智能屏 Flutter 应用（Linux/macOS/Windows/Android）
  student/           学生 Android Flutter 应用
services/
  home_agent/        家庭 Agent Server 与 Linux Room Node
  photo_indexer/     NAS 照片离线索引守护进程
packages/
  node_protocol/     跨端共享节点协议包
deploy/              部署单元
docs/                全仓文档
tool/                全仓运维脚本
```

智能屏 `lib/` 再按功能垂直切分：

```text
lib/
  main.dart
  core/              配置、网络、平台能力
  features/
    calendar/
    dashboard/
    photos/
    remote_control/
    settings/
    setup/
    voice/
    weather/
```

每个 feature 按需要使用 `domain/`、`application/`、`data/`、`presentation/`，不为了形式创建空层。

## 边界

- 不更改 Dart/Python 类名、API 路由、WebSocket 消息、配置字段和 SQLite schema。
- 根目录不再是 Flutter package；智能屏命令统一在 `apps/smart_frame/` 执行。
- 部署脚本使用仓库相对路径推导工程位置，systemd 模板同步到新服务目录。
- 历史规格与历史计划中的路径作为当时记录保留；权威入口文档和当前架构文档更新到新路径。

## 验证

- `apps/smart_frame`: `flutter analyze`、`flutter test`
- `apps/student`: `flutter analyze`、`flutter test`
- `services/home_agent`: `ruff check/format`、`mypy src`、`pytest`
- `services/photo_indexer`: Python 编译检查
- `packages/node_protocol`: `dart analyze`、`dart test`
- 全仓旧活动路径扫描和 `git diff --check`
