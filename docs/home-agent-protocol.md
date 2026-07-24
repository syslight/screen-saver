# 家庭 Agent API 与节点协议

本文是 `home_agent/` 与 Linux/Android 房间节点的阶段 1 协议基线。Python 权威实现位于
`home_agent/src/home_agent/protocol/`，跨语言样例位于
`packages/node_protocol/fixtures/messages.json`。

## 1. 安全边界

- 默认服务地址 `http://127.0.0.1:8790`，仅供本机开发。
- 局域网接入真设备前必须增加 TLS；不得将当前明文 HTTP/WS 暴露到公网。
- 家长会话使用 `Authorization: Bearer <token>`；节点首次配对后使用独立 device key。
- password、session token、pairing code、device key 均不以明文存库；一次性值只在创建时返回。
- 错误统一返回 `code`、`message`、`details`、`requestId`，不包含异常堆栈或凭据。

## 2. HTTP API

| 方法 | 路径 | 认证 | 用途 |
|---|---|---|---|
| GET | `/health/live` | 无 | 进程存活 |
| GET | `/health/ready` | 无 | 迁移完成、数据库可用 |
| POST | `/api/v1/bootstrap` | 仅首次 | 创建唯一家庭、客厅和第一位家长 |
| POST | `/api/v1/auth/login` | 无 | 返回不透明家长 token |
| POST | `/api/v1/auth/logout` | 家长 | 立即撤销当前 token |
| POST | `/api/v1/users` | 家长 | 创建另一位同权限家长 |
| POST | `/api/v1/node-pairing-codes` | 家长 | 为指定 room 创建短时一次性 code |
| POST | `/api/v1/nodes/pair` | pairing code | 返回 `nodeId`、`roomId`、一次性 device key |
| GET | `/api/v1/nodes` | 家长 | 当前家庭节点及能力列表 |
| GET | `/api/v1/nodes/{id}` | 家长 | 节点详情 |
| POST | `/api/v1/nodes/{id}/commands` | 家长 | 向在线节点发送结构化命令并等待结果 |
| GET | `/api/v1/audit-events` | 家长 | `limit`/`offset` 分页审计记录 |

请求/响应 JSON 使用 camelCase；未知字段被拒绝。`bootstrap` 成功后永久关闭，不能通过 API 重置家庭。

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

阶段 1 不定义音视频二进制帧和媒体上传。假节点声明 camera、microphone_array、speaker，
实现 `fake.echo` 与 `fake.set_status`，不访问真实硬件。

## 5. 家庭作业阶段 A

家长页面由 `GET /parent/` 提供，token 只保存在浏览器 `sessionStorage`。以下 API 均要求
家长 bearer session：

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
