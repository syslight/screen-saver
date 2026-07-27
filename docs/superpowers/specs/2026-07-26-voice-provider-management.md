# Home Agent 语音 Provider 管理规格

## 目标

在不改变展示端“薄客户端”边界的前提下，为 Home Agent 增加火山 ASR/TTS，并让火山流式接口
成为默认 provider；HomeAdmin 可查看 ASR/TTS/LLM 状态，按能力和 Provider 独立管理凭据与
有效参数、主动检测并在运行时切换。

## Provider 矩阵

| 类型 | Provider | 接口 | 默认 |
|---|---|---|---|
| ASR | `volcano` | ASR 2.0 `bigmodel_async` 双向流式 WebSocket | 是 |
| ASR | `local` | faster-whisper | 否 |
| ASR | `openai` | OpenAI-compatible `/audio/transcriptions` | 否 |
| TTS | `volcano` | V3 单向 HTTP 流式 `/api/v3/tts/unidirectional` | 是 |
| TTS | `piper` | 本地 Piper | 否 |
| TTS | `openai` | OpenAI-compatible `/audio/speech` | 否 |
| LLM | `glm` / `kimi` | OpenAI-compatible chat completions | 环境配置 |

火山 ASR 在 `voice.turn.start` 后建立连接，展示节点每个 PCM 块同时进入本地 VAD 与火山连接；
本地判停时结束火山流并取得最终文本。GLM/Kimi 使用 SSE token stream，按句进入火山/OpenAI
TTS；火山 TTS 使用独立 APP Key，把按行 JSON 中的 Base64 PCM 分片直接送入媒体协议 v2 的
AudioTrack/aplay，v1 才聚合为 WAV。

## 管理与状态

- HomeAdmin WebUI/BFF 复用家长 bearer 认证，不增加独立弱口令，也不访问 Home Agent 数据库。
- 状态分为 `unconfigured`、`ready`、`healthy`、`error`；展示是否启用、是否流式、模型/音色、
  最近检测时间与耗时。
- 主动检测真实调用目标 provider；响应与日志不得包含供应商原始响应或凭据。
- 每个 `kind + provider` 是独立配置单元。即使供应商相同，ASR 与 TTS 的密钥、Base URL、
  模型和参数也不能隐式共享或互相覆盖。
- 状态响应为每个 Provider 返回字段元数据：分区、类型、当前非密钥值、可选项、是否允许自定义、
  范围和来源。密钥只返回是否配置、来源和脱敏尾号。
- ASR 至少可配模型与语言；TTS 至少可配模型/资源、音色/角色、语速及该接口真正支持的参数；
  LLM 至少可配 Base URL、模型和 temperature。字段必须进入真实请求或模型加载，禁止假设置。
- 每张 Provider 卡片分别保存、清除和交互测试。ASR 测试显示真实录音转写，TTS 测试播放指定
  文字的合成音频，LLM 测试显示指定提示词的回复；选择当前链路与配置 Provider 是两个独立操作。
- 切换对下一轮语音生效，并写家庭审计记录。
- 选择写入数据目录 `voice-providers.json`，权限 `0600`，只含 ASR/TTS/LLM provider 名称。
- API Key、App ID/Access Token 由 Home Agent 的 Provider 级 write-only 管理 API 设置或清除；
  服务端将密钥保存至 `voice-provider-secrets.json`，将非密钥参数保存至
  `voice-provider-config.json`，权限均为 `0600`，审计只记录 Provider 与字段名。
- 旧扁平密钥文件启动时兼容映射，第一次保存任一 Provider 时升级为 ASR/TTS/LLM 分组结构。
- 火山 ASR 明确保存鉴权方式：新版控制台选择 `app_key`，仅发送 `X-Api-Key`；旧版应用选择
  `app_id_token`，仅发送 App ID + Access Token，禁止根据“哪个密钥不为空”隐式切换。
- 火山 TTS 仅使用 Provider 独立 APP Key。历史上误存为 TTS `accessToken` 的值启动时迁移为
  `apiKey`；管理端只回显已配置状态、来源和脱敏尾号，不返回密钥明文。

## 失败模式

- 默认火山 provider 未配置时明确显示 `unconfigured`，不得假装健康。
- 流式 ASR 建连失败时保留本轮 PCM，在判停后再按当前 provider 发起一次完整转写；仍失败则走
  现有 `voice.turn.state=error`。
- 运行中切换不打断已开始的轮次；下一轮读取新选择。
- 非法持久化选择在启动时忽略并回退环境默认值。
- 单个 Provider 参数非法时返回 `invalid_provider_configuration`，不得污染其他 Provider 或已有值。
