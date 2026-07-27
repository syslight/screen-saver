# 薄展示端与家庭媒体 Agent 架构

状态：已确认的迁移基线（2026-07-26）。

## 1. 核心决定

`smart_frame` 不再承担照片索引/去重、音乐生成、ASR、Agent 推理或 TTS 合成。Android 与
Linux/3588 使用同一个薄展示端：读取服务端已经整理好的照片和音乐，采集麦克风 PCM，展示画面，
播放音乐与 TTS。

家庭服务器运行独立的 `home_agent` 边缘网关；它可以部署在 x86 或 RK3588。现有
`photo_indexer` 作为其服务端计算 worker，负责扫描、元数据、向量、质量判断和去重，不直接暴露给
展示设备。

```text
CCL Android ─┐                         ┌─ photo_indexer / SQLite
             ├─ authenticated node ── home_agent ── photo/NAS storage
3588 display ┘       HTTP + WS         ├─ licensed music library
                                         └─ ASR → Agent → TTS
```

## 2. 职责边界

| 组件 | 负责 | 不负责 |
|---|---|---|
| `smart_frame` 展示端 | 设备配对、心跳、照片/音乐缓存、轮播、麦克风采集、音乐/TTS 播放、按键和触摸 | 扫描 NAS、照片去重、向量/VLM、音乐合成、ASR、Agent、TTS 合成 |
| `home_agent` | 设备身份与在线会话、媒体 API、音乐选择、本地 ASR/TTS、Coding Agent 调用、输出路由和审计 | 直接访问设备麦克风/扬声器、重型照片模型推理 |
| `photo_indexer` | 扫描、哈希、质量分析、embedding、人脸聚类、服务端去重、写索引 | 对设备提供 API、控制播放 |
| 媒体存储 | 原图、缩略图、授权音乐、TTS 临时资源和缓存 | 业务选择与设备路由 |

照片列表 API 只返回服务端判定为可见的代表照片。客户端不再下载完整列表后自行执行去重；同一份
服务端结果供 CCL、3588 和未来设备使用。

音乐不在展示端生成。服务端维护真实授权曲库和用户曲库，根据当前照片说明、时间和家庭设置选择
已有曲目；没有可用曲目时返回“无曲目”，客户端保持静音，不做 CPU 合成兜底。

## 3. 设备身份与默认回送

继续复用 `home_agent` 的 `nodeId`、`roomId`和 `deviceKey`，媒体 HTTP 和
`/api/v1/media/voice/ws` 使用同一节点身份。设备密钥只用于建立已认证会话；服务端从连接本身取得来源设备身份，不信任
客户端在业务 payload 中自报的 `sourceDeviceId`。

每次语音交互创建唯一 `turnId`，服务端保存：

- `sourceNodeId`：从哪个已认证设备收到麦克风输入；
- `targetNodeId`：输出设备，默认等于 `sourceNodeId`；
- `roomId` / `householdId`：路由和权限边界；
- ASR 文本、Agent 动作、TTS 状态和最终结果的审计元数据。

Agent 未显式指定目标时，TTS、提示音和与本轮有关的 UI 状态必须只发送回来源设备。显式跨设备
输出必须检查目标属于同一家庭、在线且声明 `speaker`/`display` 能力；失败时回到来源设备或返回
结构化错误，不能广播给全部屏幕。

## 4. 媒体与语音协议

目标 API 前缀统一为 `/api/v1/media`：

| 接口 | 用途 |
|---|---|
| `GET /photos` | 分页读取已去重、未隐藏的照片目录和稳定 ID |
| `GET /photos/{id}/content` | 读取适合目标显示尺寸的照片，支持 ETag/缓存 |
| `GET /photos/{id}/description` | 读取服务端说明、时间、地点和已确认人物信息 |
| `GET /music/select?photoId=...` | 服务端选择已有授权曲目；无曲目返回 204 |
| `GET /music/tracks/{id}/content` | 拉取或分段读取音乐文件，支持 ETag/Range |

控制与语音复用已认证节点会话。媒体协议版本升级后增加以下消息：

- `voice.turn.start`：设备请求开始一轮采集，声明 PCM16/16 kHz/mono；
- WebSocket binary frame：与该连接当前 `turnId` 关联的音频帧；
- `voice.turn.stop`：采集结束；
- `voice.turn.state`：服务端返回 listening/processing/speaking/idle；
- `audio.stream.start/end`：媒体协议 v2 向确定的目标设备下发 PCM 格式和总长度，中间紧随
  有序二进制 PCM 块；`audio.play + WAV` 只保留给 v1 节点降级。

首期可以为音频使用独立的已认证 WebSocket，来源身份仍由握手绑定；不要继续使用当前无身份的
全局 `/api/voice` 管线。服务端必须为每个 `turnId` 保存独立缓冲和状态，TTS 只写回该轮目标连接。

## 5. 部署规则

- x86 与 RK3588 都可运行完全相同的 `home_agent` 和 `photo_indexer` 服务；通过环境变量提供
  数据库、照片目录、NAS 和曲库位置，不写死主机路径。
- 家庭内只设置一个设备可访问的 `agentUrl`。计算 worker 可以与网关同机，也可以以后拆到另一台
  主机；设备不感知 worker 地址。
- CCL 与 3588 展示端使用同一 Flutter 代码和节点协议，分别生成 Android
  ARMv7 APK 和 Linux arm64 bundle；仅设备凭据、屏幕尺寸及能力声明不同。
- 原始麦克风音频默认只在家庭局域网传到家庭服务器；日志不保存 PCM，审计只保留必要元数据。
- 当前默认以火山 ASR 2.0 双向流式识别和火山 V3 单向 HTTP 流式 TTS 提供低延迟语音；CPU
  `faster-whisper small/int8` 与 Piper `zh_CN-huayan-medium` 分别作为本地 ASR/TTS provider；
  只有识别后的文本进入所选 GLM/Kimi Coding API。

## 6. 迁移顺序

1. 在 `home_agent` 增加媒体配置、只读照片目录 API、授权曲库 API 和设备鉴权测试。
2. 扩展节点协议，建立按 `nodeId + turnId` 隔离的语音会话与同设备默认回送测试。
3. 将 `smart_frame` 的 `HttpPhotoSource`、音乐源和 `VoiceClient` 接到新 API；删除展示端音乐生成
   与本地 ASR/TTS 路径。
4. 停用 Flutter 内嵌 compute `ControlServer` 的设备数据职责，保留迁移期兼容层后再删除。
5. 在 x86 或 3588 启动后台服务，重新部署 CCL，验收照片去重结果、远程音乐、语音输入和同设备
   TTS 回送闭环。
