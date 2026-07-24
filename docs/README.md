# 文档索引

smart_frame 的完整文档体系。项目门面（功能介绍、快捷键、用法、配置）见根目录 [README.md](../README.md)，本文只索引按主题分篇的文档。

| 文件 | 一句话说明 | 何时读 |
|---|---|---|
| [AGENTS.md](../AGENTS.md) | AI coding agent 的项目入口：构建命令、目录结构、硬性约定、环境坑、配置表、测试地图 | 让 AI 改代码时（agent 每会话先读）；人改代码前也值得扫一遍「硬性约定」 |
| [requirements.md](requirements.md) | 需求基线：按模块分的功能需求（FR-x）与非功能需求（NFR-x），逐条编号 | 判断"该不该做"、按编号引用需求、对照验收功能时 |
| [architecture.md](architecture.md) | 架构基线：模块划分、启动装配顺序、`CommandService` 指令总线、语音与手机控制两条主链路数据流 | 新增模块或指令、动装配顺序、想搞清楚数据怎么流时 |
| [protocol.md](protocol.md) | 手机控制协议权威定义：HTTP 端点、WebSocket 消息字段、照片上传接口 | 改 `lib/server/`、写第三方客户端、调试手机端通信时（改协议必须同步本文档） |
| [home-agent-protocol.md](home-agent-protocol.md) | 家庭 Agent HTTP/WS 协议：认证、配对、节点信封、能力与命令 | 改 `home_agent/`、Linux/Android 房间节点或共享协议包时 |
| [voice-pipeline.md](voice-pipeline.md) | 语音链路权威文档：四态状态机、KWS/ASR/意图/TTS 行为与降级策略 | 改 `lib/voice/`、排查语音问题、配置 ASR/TTS 时（改语音链路必须同步本文档） |
| [development.md](development.md) | 开发者上手指南：环境搭建、日常命令、调试手段、测试说明、常见坑 | 新机器搭环境、跑测试、踩到代理/CMake/GStreamer 坑时 |
| [agent-workflow.md](agent-workflow.md) | 多 Agent + Git worktree 协作 SOP：隔离、任务契约、跨工具启动、验收与交接 | 使用 Codex、Claude、Kimi 等并行开发或审查时 |
| [commit-convention.md](commit-convention.md) | Git commit 规范：原子提交、标题格式、变更/负面影响/Review 重点与验证模板 | 获准提交代码、审查提交历史或准备合并时 |
| [deployment.md](deployment.md) | 三平台打包与分发：构建命令、产物路径、分发清单、首启注意事项、开机自启思路 | 出 release 包、把应用拷到别的机器、配置开机自启时 |
| [roadmap.md](roadmap.md) | 已知限制（逐条带代码依据、呼应 NFR 编号）与候选改进方向 | 评估新需求是否撞上已知限制、规划迭代时 |

另：`docs/superpowers/specs/` 存放设计规格，`docs/superpowers/plans/` 存放实施计划。
