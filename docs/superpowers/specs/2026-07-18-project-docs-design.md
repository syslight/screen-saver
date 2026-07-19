# 项目文档初始化 — 设计规格

日期：2026-07-18
状态：已获用户批准

## 背景

smart_frame（智能屏）功能已基本完整（天气/日历/相册/语音/TTS/多手机控制），但除 README 外没有结构化文档，也没有面向 AI coding agent 的基建文件。此前会话出现过"任务状态丢失"问题，需要用文档把项目知识固化下来。

## 目标

1. 为 AI coding agent 提供入口文件 `AGENTS.md`：命令、结构、约定、环境坑。
2. 初始化 `docs/` 文档体系，覆盖需求、架构、协议、语音链路、开发、部署、路线图。
3. 确立 superpowers 工作流在本项目的落地约定（规格文档目录）。

## 决策

- 方案：AGENTS.md 作入口 + docs/ 按主题分篇（对比过单一大文档、按受众分目录两种方案，均否）。
- 语言：中文，与 README 一致。
- 规格文档目录：`docs/superpowers/specs/YYYY-MM-DD-<主题>-design.md`（superpowers 默认约定）。
- 文档内容以代码为准生成（协议以 `lib/server/` 为准，语音链路以 `lib/voice/` 为准），不凭空设计。

## 文档清单与职责

| 文件 | 职责 |
|---|---|
| `AGENTS.md` | AI agent 入口：项目简介、构建/运行/测试命令、目录结构、硬性约定、环境坑、规格目录约定 |
| `docs/README.md` | 文档索引 |
| `docs/requirements.md` | 功能需求（五大功能）+ 非功能需求（三平台、离线降级、局域网控制） |
| `docs/architecture.md` | 模块划分、CommandService 指令总线、语音与手机控制两条主链路数据流、关键依赖选型理由 |
| `docs/protocol.md` | 手机控制协议：HTTP 端点、WebSocket 消息格式、照片上传接口 |
| `docs/voice-pipeline.md` | KWS→ASR→意图解析→TTS 状态机与降级策略、相关配置项 |
| `docs/development.md` | 环境搭建（含 Linux 依赖）、运行、测试、调试、常见坑 |
| `docs/deployment.md` | Windows/macOS/Linux 打包命令、产物位置、分发注意事项 |
| `docs/roadmap.md` | 已知限制与候选改进方向 |

## 硬性约定（写入 AGENTS.md）

- 提交前 `flutter analyze` 无问题、`flutter test` 全绿。
- 所有外部指令（语音/手机/键盘）统一经 `CommandService` 处理，新增指令不得绕过。
- 改目录结构、命令、协议、配置项时，必须同步更新对应文档。
- 本机代理会劫持 Flutter 工具链 localhost WebSocket：跑 `flutter test`/`flutter run` 前需清空 `http_proxy` 等变量。
- Linux 构建依赖 GStreamer 开发文件；无 sudo 环境用 `~/.local/opt/gst` 用户态方案（`PKG_CONFIG_PATH` + `LIBRARY_PATH`）。

## 非目标（YAGNI）

- 不重写 README（只做必要对齐，保持它作为门面）。
- 不写 API 级 dartdoc 参考（代码注释已有）。
- 不引入文档生成工具/站点。
- 不初始化 git 仓库（用户未要求；规格中"提交到 git"一步因此跳过）。

## 验收标准

- 上述 9 个文件全部落盘，内容与代码实际行为一致。
- `flutter analyze` 与 `flutter test` 保持全绿（文档任务不应动代码）。
- 一个新 agent 只读 AGENTS.md 即可完成构建、测试、了解架构。
