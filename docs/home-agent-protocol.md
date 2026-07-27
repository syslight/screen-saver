# 家庭 Agent API 与节点协议

本文是 `services/home_agent/` 与 Linux/Android 房间节点的阶段 1 协议基线。Python 权威实现位于
`services/home_agent/src/home_agent/protocol/`，跨语言样例位于
`packages/node_protocol/fixtures/messages.json`。

## 1. 安全边界

- 默认服务地址 `http://127.0.0.1:8790`，仅供本机开发。
- `deploymentMode=edge` 是家庭服务；`cloud` 只保留认证、家庭、节点、审计和健康接口。
- 阶段 B 允许学生平板在同一可信家庭 Wi-Fi 内临时使用 HTTP；不得端口映射或暴露到公网，
  远程访问前必须增加 TLS。
- 家长会话使用 `Authorization: Bearer <token>`；房间节点和学生平板分别使用独立 device key。
- password、session token、pairing code、device key 均不以明文存库；一次性值只在创建时返回。
- 错误统一返回 `code`、`message`、`details`、`requestId`，不包含异常堆栈或凭据。

## 2. HTTP API

| 方法 | 路径 | 认证 | 用途 |
|---|---|---|---|
| GET | `/health/live` | 无 | 进程存活 |
| GET | `/health/ready` | 无 | 迁移完成、数据库可用 |
| POST | `/api/v1/bootstrap` | 仅首次 | 创建唯一家庭、客厅和第一位家长 |
| POST | `/api/v1/auth/login` | 无 | 返回不透明家长 token |
| POST | `/api/v1/auth/enrollment-codes` | 家长 | 创建 10 分钟、单次使用的家长 App 绑定码 |
| POST | `/api/v1/auth/enroll` | 一次性码 | 为新家长设备换取独立会话 |
| POST | `/api/v1/auth/logout` | 家长 | 立即撤销当前 token |
| POST | `/api/v1/users` | 家长 | 创建另一位同权限家长 |
| POST | `/api/v1/node-pairing-codes` | 家长 | 为指定 room 创建短时一次性 code |
| POST | `/api/v1/nodes/pair` | pairing code | 返回 `nodeId`、`roomId`、一次性 device key |
| GET | `/api/v1/nodes` | 家长 | 当前家庭节点及能力列表 |
| GET | `/api/v1/nodes/{id}` | 家长 | 节点详情 |
| POST | `/api/v1/nodes/{id}/commands` | 家长 | 向在线节点发送结构化命令并等待结果 |
| GET | `/api/v1/audit-events` | 家长 | `limit`/`offset` 分页审计记录 |
| GET | `/api/v1/admin/providers` | 家长 | ASR/TTS/LLM 选择与归一化健康状态 |
| PUT | `/api/v1/admin/providers/selection` | 家长 | 切换三类 provider 并持久化 |
| PUT | `/api/v1/admin/providers/{kind}/{name}/configuration` | 家长 | 独立更新一个 Provider 的凭据和参数 |
| POST | `/api/v1/admin/providers/check` | 家长 | 主动检测一个 provider |
| POST | `/api/v1/admin/providers/test` | 家长 | 使用指定文字或录音执行可观察的交互测试 |

请求/响应 JSON 使用 camelCase；未知字段被拒绝。`bootstrap` 成功后永久关闭，不能通过 API 重置家庭。
家长绑定码与会话 token 均只以 hash 保存；App 提交 `deviceName/platform` 便于独立撤销和审计。

## 3. WebSocket 信封

节点连接 `/api/v1/nodes/ws`，每条文本 JSON 使用：

```json
{
  "protocolVersion": 1,
  "messageId": "10000000-0000-4000-8000-000000000001",
  "sequence": 1,
  "type": "node.hello",
  "sentAt": "2026-07-24T12:00:00Z",
  "nodeId": "20000000-0000-4000-8000-000000000001",
  "roomId": "30000000-0000-4000-8000-000000000001",
  "sessionId": null,
  "payload": {}
}
```

- 当前只支持 `protocolVersion=1`；时间统一 UTC ISO-8601。
- `messageId` 为 UUID；`sequence` 从 1 开始并在单连接内严格递增。
- 首帧必须是 `node.hello`，payload 含 `deviceKey`、`softwareVersion`、`platform`、
  `mediaProtocolVersion`；认证前不处理其他消息。
- 错版本、未知类型、非法 payload 返回结构化 `error`；身份或序列冲突结束该连接。
- 相同 node 的新合法连接替换旧连接；只有当前连接断开时才把节点标为 offline。

## 4. 消息类型

| 方向 | type | payload 核心字段 |
|---|---|---|
| Node→Server | `node.hello` | 设备密钥、软件/媒体协议版本 |
| Node→Server | `node.capabilities` | 全量 `capabilities` 数组；替换旧快照 |
| 双向 | `heartbeat.ping` / `heartbeat.pong` | `nonce` |
| Server→Node | `command.request` | `commandName`、`arguments` |
| Node→Server | `command.result` | `requestMessageId`、`success`、`result`、`errorCode` |
| Node→Server | `node.event` | `eventName`、`data` |
| 双向 | `error` | `code`、`message`、`details` |

能力项包含 `capabilityId`、`type`、`status`、`properties`、`commands`。状态为
`online/busy/disabled/error`；已知 camera/microphone_array/speaker/display 属性执行类型校验，
同时允许 `properties` 增加新字段用于后续版本扩展。

通用节点 `/api/v1/nodes/ws` 在阶段 1 不定义音视频二进制帧。展示端语音使用下述独立、已鉴权
的媒体 WebSocket；假节点仍不访问真实硬件。

### 4.1 展示端语音媒体 WebSocket

展示节点连接 `/api/v1/media/voice/ws`，首帧同样必须为合法 `node.hello`。后续 JSON 信封与
二进制 PCM 帧严格按连接顺序发送：

| 方向 | type | payload 核心字段 |
|---|---|---|
| Display→Server | `voice.turn.start` | `turnId`、`pcm_s16le`、16000 Hz、单声道 |
| Display→Server | 二进制 | 当前 turn 的 PCM 数据；空闲音频不上传 |
| Display→Server | `voice.turn.stop` | `turnId`、可选 `cancelled`；旧客户端/人工取消兼容入口 |
| Server→Display | `voice.turn.state` | 状态、识别文字、回复、`continueDialog` |
| Server→Display | `audio.stream.start` | v2：`audio/pcm`、`pcm_s16le`、sample rate、单声道 |
| Server→Display | 二进制 | v2：有序 PCM chunk，当前目标约 50 ms/块 |
| Server→Display | `audio.stream.end` | v2：`turnId` 和实际发送的总 `byteLength` |
| Server→Display | `audio.play` + 二进制 | v1 降级：`audio/wav` 长度元数据及完整 WAV |

当前服务端直接在二进制 PCM 流上做端点检测：约 120ms 有效人声后，尾部静音约 700ms 自动
进入 `processing`；8 秒无人说话返回 `idle/continueDialog=false`；单轮最长 12 秒。终端收到
`processing` 后释放麦克风，不需要主动发送正常 `voice.turn.stop`。旧客户端的 stop 仍受支持；
`cancelled=true` 时服务端清空本轮数据，不调用 ASR、Agent 或 TTS。正常轮次中 `continueDialog=true`
要求展示端在音频流实际播放完成后开始下一轮聆听；退出话术会返回 false。服务端只把 TTS
回送给本轮的已认证来源连接。新展示端在 `node.hello.mediaProtocolVersion=2` 声明流式播放；
版本 1 不发送 `audio.stream.*`。LLM token stream 在服务端按句切分后与 TTS 并行，协议只暴露
可播放的 PCM，不暴露供应商 SSE 或思考内容。

### 4.2 Provider 管理

HomeAdmin WebUI/App 调用 Edge 模式 API；Home Agent 自身不托管管理页面。状态 API 返回当前
`selection` 和按 `asr/tts/llm` 分组的 provider 列表。每项包含名称、展示名、当前模型、
音色/角色、语言、是否流式、是否已配置、是否启用、`unconfigured/ready/healthy/error`
归一化状态，以及该 Provider 独有的 `fields` 元数据。普通字段返回当前值、来源、可选项和
取值范围；密钥字段只返回 `configured/source/hint`，不返回 API Key、token 或供应商原始错误。

切换请求：

```json
{"asr":"volcano","tts":"volcano","llm":"glm"}
```

允许值分别为 ASR `volcano/local/openai`、TTS `volcano/piper/openai`、LLM `glm/kimi`。
选择只影响下一轮语音，服务端以 `0600` 文件持久化并写 `voice.providers.select` 审计事件。
检测请求为 `{"kind":"asr","name":"volcano"}`；检测可能产生极少量供应商调用费用。

交互测试请求按 Provider 类型传入实际内容：TTS/LLM 使用 `text`，ASR 使用浏览器采集并降采样为
PCM16/16 kHz/mono 后的 `audioBase64`。响应分别返回可播放 WAV 的 `audioBase64/audioMimeType`，
或 ASR/LLM 的 `text`，并包含 `latencyMs`。示例：

```json
{"kind":"tts","name":"volcano","text":"小方语音服务测试。"}
```

交互测试内容不得写入审计日志；LLM 测试使用临时会话并在返回后清除上下文。

配置更新路径中的 `kind/name` 唯一确定目标，例如火山 ASR 使用
`/asr/volcano/configuration`，火山 TTS 使用 `/tts/volcano/configuration`，两者不会共享后台
覆盖值。请求格式：

```json
{
  "values": {"model":"bigmodel","language":"zh-CN","apiKey":"write-only"},
  "clear": []
}
```

每个 Provider 只接受状态 API `fields` 中声明的字段。模型、语言、音色和生成参数写入权限
`0600` 的 `voice-provider-config.json`；密钥写入同权限的 `voice-provider-secrets.json`。
更新后重建该 Provider，下一次调用立即生效；审计只记录 Provider 和字段名，不记录值。
旧 `/providers/credentials` 仅保留扁平密钥写入过渡入口，不再用于 HomeAdmin；新客户端不能依赖
旧版聚合凭据响应。

### 4.3 Home Hub 云代理能力

家庭主服务器通过 Home Hub Connector 主动连接云端，不要求家庭公网入站端口。首期声明：

| capability | commands | 说明 |
|---|---|---|
| `home.hub` | `home.status` | 家庭 Agent 和相册健康状态 |
| `display.photo` | `frame.get_state`、`frame.command` | 相册状态与结构化控制 |
| `audio.playback` | `frame.command` | 音乐、音量和 TTS 控制 |

`frame.command.arguments` 只允许白名单 action：`next_photo`、`prev_photo`、
`refresh_weather`、`set_volume`、`set_music_enabled`、`set_music_muted`、
`set_music_volume`、`announce`、`text_command`。Cloud Control 只路由并审计命令元数据，不读取、
解释或存储照片内容，也不提供摄像头/麦克风原始流命令。

## 5. 家庭作业阶段 A

HomeAdmin WebUI 通过独立 BFF 调用以下 API，token 只保存在浏览器 `sessionStorage`。以下 API
均要求家长 bearer session：

| 方法 | 路径 | 用途 |
|---|---|---|
| GET/POST | `/api/v1/homework/members` | 查询/创建家庭成员 |
| PATCH | `/api/v1/homework/members/{id}` | 修改成员 |
| GET/POST | `/api/v1/homework/tasks` | 查询/创建作业 |
| GET/PATCH | `/api/v1/homework/tasks/{id}` | 查看/修改作业 |
| POST | `/api/v1/homework/tasks/{id}/start` | 开始作业 |
| POST | `/api/v1/homework/tasks/{id}/cancel` | 取消作业 |
| GET/POST | `/api/v1/homework/tasks/{id}/submissions` | 查询提交或 multipart 上传图片 |
| GET | `/api/v1/homework/assets/{id}` | 鉴权下载原图 |
| POST | `/api/v1/homework/submissions/{id}/review` | 家长 `accept`/`retry` |
| GET | `/api/v1/homework/events?taskId=` | 查询不可变业务事件 |

图片不信任文件名和 MIME 声明，服务端实际解码后只接受 JPEG/PNG/WebP。限制为单张
12 MiB、每次最多 6 张、家庭总配额 5 GiB。阶段 A 没有模型调用；成功提交后任务状态为
`needs_parent_review`，家长接受后为 `completed`，要求重做后回到 `in_progress`。

## 6. Android 学生端阶段 B

学生设备与房间节点是两套权限。家长为一个 active child 创建短时一次性码，平板消费后获得
只显示一次的学生 device key；后续请求使用 `Authorization: Student <device-key>`。配对码与
device key 只存 SHA-256 hash，家长撤销设备后旧 key 立即返回 401。

家长 API：

| 方法 | 路径 | 用途 |
|---|---|---|
| POST | `/api/v1/homework/student-pairing-codes` | `childId` 创建 8 位、短时一次性码 |
| GET | `/api/v1/homework/student-devices` | 查看设备、绑定孩子、active 与最近连接时间 |
| POST | `/api/v1/homework/student-devices/{id}/revoke` | 撤销设备；恢复必须重新配对 |

学生设备 API：

| 方法 | 路径 | 用途 |
|---|---|---|
| POST | `/api/v1/student/pair` | 消费 `code`，提交 `name/platform`，换取一次性明文 key |
| GET | `/api/v1/student/me` | 读取当前设备和绑定孩子 |
| GET | `/api/v1/student/homework/tasks` | 只列出绑定孩子的任务 |
| GET | `/api/v1/student/homework/tasks/{id}` | 读取自己的任务详情 |
| POST | `/api/v1/student/homework/tasks/{id}/start` | `pending → in_progress` |
| GET/POST | `/api/v1/student/homework/tasks/{id}/submissions` | 查询反馈或 multipart 提交图片 |

学生任务响应不含 `referenceAnswer`、`rubric`；提交响应只给出 `assetCount`，不返回原图路径或
下载 URL；审核只返回家长决定、摘要和质量等级，不返回内部结构化 items。任务查询和变更均以
设备的 `household_id + child_id` 双重限定，对其他孩子的资源统一返回 404。

## 7. 作业 Agent 检查阶段 C

视觉模型默认关闭，并且不会在学生提交后自动运行。以下 API 只接受家长 bearer session：

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/v1/homework/model-status` | 返回 `enabled/configured/baseUrlHost/modelName`，不返回 key |
| POST | `/api/v1/homework/submissions/{id}/inspect` | 家长明确授权并同步执行一次检查 |
| GET | `/api/v1/homework/submissions/{id}/inspections` | 按时间倒序返回不可覆盖的检查记录 |

`inspect` 将本地纠正方向、最长边缩至 2400 像素并转为 JPEG 的图片，以及任务要求、参考答案和
评分标准发送到配置的 OpenAI-compatible `/chat/completions`。默认模型名 `kimi-k3` 是 Kimi 的
具体模型，不是供应商名称；切换 GLM 时只替换 base URL、key 和支持视觉输入的具体模型名。

检查记录状态为 `running/completed/needs_parent_review/failed`，与作业任务/提交状态分离。返回
字段包含 `imageQuality`、`summary`、`confidence`、`suggestedDecision` 以及分项
`location/issue/hint/similarExample/steps/confidence`。图片不清或不全、总置信度低于 0.75、任一
分项低于 0.65，或模型建议 `review` 时，检查记录标为 `needs_parent_review`。模型建议不会自动
调用家长的 `accept/retry`；失败只保存归一化 `errorCode`，不保存或返回供应商原始响应。
