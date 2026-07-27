# 家庭云控制平台规格

## 目标

在阿里云部署轻量控制平面，使家长控制端可在任意网络查询和控制家庭智能系统。所有家庭设备使用统一节点协议注册；当前 x86 Linux 服务器作为主 Home Hub，未来可经管理员确认迁移到 RK3588。

## 已确认原则

- 当前只服务一个家庭，但账号、节点、审计和路由从第一版按 `householdId` 隔离。
- 家庭照片、人脸、声纹、对话、作业原图和长期记忆默认只保存在家庭 Home Hub。
- 同一家庭 Wi-Fi 内优先局域网直连；不可达时自动使用阿里云控制平面。
- 阿里云只保存账号、设备身份、能力、在线状态、命令元数据和审计，不保存原始家庭音视频。
- 公网只开放 HTTPS/WSS 443；家庭端和设备都主动向云端建立连接，不映射家庭 8780/8790。

## 角色

### Cloud Control

- 家庭与家长认证。
- 一次性家长端绑定码和一次性节点注册码。
- 节点注册、能力目录、在线状态、心跳、命令路由和审计。
- 短时离线队列只允许显式标记为可重放、幂等且低风险的命令；首版不自动重放。

### Home Hub

- 当前运行在 x86 Linux；未来可运行在 RK3588。
- 保存家庭隐私数据并运行家庭 Agent、作业、记忆、传感器融合和局域网自动化。
- 作为高权限节点主动连接 Cloud Control，代理相册及其他本地节点的控制能力。
- 同一家庭首版只允许一个 active 主 Home Hub；迁移必须由家长确认，不做自动抢主。

### 普通节点

节点不按 App 名称写死，注册一个或多个 capability。首批命名空间：

- `home.hub`
- `display.photo`
- `audio.playback`
- `voice.capture`
- `voice.dialog`
- `camera.observe`
- `homework.student`

一个设备可同时声明多个能力。命令必须属于节点已上报的 capability，并返回结构化结果。

## 连接与认证

1. 管理员在 Cloud Control 创建十分钟有效的一次性注册码。
2. 节点本地生成并保存独立 device key，使用注册码换取 `nodeId/roomId/deviceKey`。
3. 节点使用 WSS 长连接发送 `node.hello`、能力和心跳，接收命令并返回结果。
4. 家长 App 首次使用一次性绑定码换取独立会话；绑定码和 token 在数据库中只保存 SHA-256 hash。
5. 每个设备可独立撤销；家长会话、节点凭据和学生凭据互不复用。

## 首期命令

Home Hub 先提供：

- `home.status`：返回家庭 Agent、智能相册和 Home Hub 版本/健康状态。
- `frame.get_state`：读取当前照片、音乐、天气和连接状态。
- `frame.command`：转发当前相册控制协议的结构化 action/text/value。

Cloud Control 不直接访问智能屏 8780，也不解释或保存照片内容。

## 部署

- 阿里云：Caddy（TLS/WSS）+ cloud-mode Home Agent + SQLite WAL（单家庭首期）+ 加密备份。
- 家庭：edge-mode Home Agent + Home Hub Connector + smart_frame。
- ECS 安全组：443 对公网；22 只允许可信管理 IP；8790/8780 不开放。

## 非目标

- 首期不转发摄像头实时视频或麦克风原始流。
- 首期不做 Home Hub 自动故障切换。
- 首期不把家庭 Agent 的作业、记忆或人物数据库同步到云端。
- 首期不允许未经许可证和家长授权的第三方服务直接操作节点。
