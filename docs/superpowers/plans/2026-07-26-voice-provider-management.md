# Home Agent 语音 Provider 管理实施计划

1. 扩展 Home Agent 配置，增加火山流式 ASR、OpenAI ASR/TTS 与默认 provider。
2. 实现火山 ASR 2.0 gzip 二进制 WebSocket 协议和录音期间 PCM 流式上传。
3. 建立 ASR/TTS/LLM provider registry、归一化健康状态和仅含名称的持久化选择。
4. 让 VoiceAgent 每轮快照 provider，记录 ASR/LLM/TTS 成功、错误和耗时。
5. 增加家长认证的 provider 状态、检测、切换和 write-only 密钥 API，切换及密钥字段写审计。
6. 由独立 `services/home_admin` 提供统一 WebUI/BFF，并由 `apps/home_admin` 提供 App 形态。
7. 增加协议、provider、API、持久化与密钥不泄露测试。
8. 同步 `.env.example`、Home Agent README、语音链路和家庭 Agent 协议文档。
9. 执行 Python 与 Flutter 全套门禁。
10. 将扁平密钥管理升级为按 `ASR/TTS/LLM + Provider` 隔离的字段描述和持久化结构。
11. 让模型、语言、音色、语速、采样率、temperature 和连接参数进入真实运行时 Provider。
12. 同步改造 HomeAdmin Web/App：每张 Provider 卡片独立保存、清除、检测，模型字段支持建议值
    与自定义值。
13. 增加旧密钥迁移、跨 Provider 不串值、密钥不回读、参数热更新与客户端解析测试。
