# 路线图（Roadmap）

本文档列出当前版本的已知限制与候选改进方向。已知限制逐条给出代码依据，并与 `docs/requirements.md` 的非功能需求编号（NFR-x）呼应；候选改进仅为方向记录，不承诺排期。

## 1. 已知限制

### L-1 原生唤醒适配器当前只覆盖 AILABS 固件

- **依据**：`NativeWakeBridge.kt` 显式绑定 AILABS 的 AliTVASR service component。
- **当前真机结果**：公开 callback 受厂商登录状态阻断；Magisk 只读 `WakeupManager` 适配器已在
  AILABS_S1L 上把固件 KWS 事件转换成 App wake event，并成功启动按需录音。
- **影响**：该适配器只覆盖已 root 的 AILABS 固件；其他 Android/RK3588 终端若没有同类厂商事件
  接口，仍需保留手动触发语音。
- **缓解**：为新设备增加厂商事件适配器；设备没有可用原生接口时才由服务端提供 KWS，模型不得
  重新放入 App。

### L-2 语音交互依赖 Home Agent 可达

- **依据**：智能屏已删除 App 内 ASR/TTS/KWS，`VoiceClient` 只连接已认证的 Home Agent 语音 WebSocket。
- **影响**：服务器离线时相册仍工作，但自然语音对话不可用。
- **缓解**：Home Agent 支持部署到 x86 或 RK3588；ASR/TTS provider 可在服务端本地/云端切换，节点保留手动重连状态。

### L-3 控制台无鉴权

- **依据**：`apps/smart_frame/lib/features/remote_control/data/control_server.dart:45-52` 注册 `/`、`/ws`、`/api/photos` 三个路由并以 `InternetAddress.anyIPv4` 监听全部网卡，全程无认证中间件、无连接校验。
- **影响**：同一局域网内任何设备均可打开控制台、查看状态、发送指令、上传照片。
- **定位**：按家庭可信局域网场景设计（呼应 NFR-5）；在不可信网络中部署时属于风险而非缺陷，需自行以防火墙等手段隔离。

### L-4 照片上传无大小与配额限制

- **依据**：`apps/smart_frame/lib/features/remote_control/data/control_server.dart:83-103` 的 `_onUpload` 仅校验扩展名白名单（`PhotoService.imageExts`）与内容非空，未限制单文件大小、上传总量与频率。
- **影响**：局域网内任何设备可反复上传填满磁盘。
- **定位**：与 L-3 同属局域网信任模型的一部分（呼应 NFR-5）。

### L-5 无 iOS 原生 App

- **依据**：`apps/smart_frame/android/` 已提供展示端，但无 `ios/` 目录；iPhone 仍通过 `apps/smart_frame/assets/web_console/index.html` 控制。
- **影响**：iOS 端不能常驻后台、无系统级分享入口，需手动输入地址或扫码进入。
- **定位**：Android 用于全屏 display 节点，iOS 暂保留零安装的浏览器控制台。

## 2. 候选改进

以下方向仅作记录，均不承诺排期；实施前应先落规格文档（`docs/superpowers/specs/`）。

NAS 相册子项目 1（WebDAV 图源 + 截图过滤 + LRU 缓存 + 混合轮播）已于 2026-07-19 完成（规格：`docs/superpowers/specs/2026-07-19-nas-photo-source-design.md`），不再是候选方向；其后三个子项目见下表末三行。

| 方向 | 针对限制 | 说明 |
|---|---|---|
| 局域网 token 鉴权 | L-3、L-4 | 首次连接经 token 校验（如二维码 URL 携带一次性 token），未授权连接拒绝或只读 |
| 应用内自定义唤醒词 | L-1 | 当前需手工编辑 `kws-model/keywords.txt`（见 `docs/requirements.md` FR-V-2）；可在设置页提供编辑入口并热生效 |
| 照片管理 | L-4 | 控制台支持删除 / 收藏照片，配合上传配额一并考虑 |
| iOS 原生控制台 | L-5 | 复用现有 HTTP/WebSocket 协议（见 `docs/protocol.md`）开发原生 App，浏览器控制台继续保留 |
| 天气预警播报 | — | 接入天气预警数据源，启动或定时主动语音播报预警信息 |
| NAS 缓存写失败的在线读流兜底 | — | 子项目 1 规格原设计"缓存写盘失败直接在线读流展示"未实现（`webdav_client` 的 `read2File` 无读流 API，当前行为为清理部分文件并跳过该张，见规格"实现偏差"节）；如需兜底需自行实现流式下载 |
| NAS 子项目 2：智能索引库 | — | 在已完成的 NAS 接入之上建本地索引：EXIF 解析、模型级截图判定（子项目 1 明确留下的"PNG 且无 EXIF"判定归此）、按时间/地点归类 |
| NAS 子项目 3：主题相册生成 | — | 基于索引库生成主题相册（如人物/旅程合集），可配文案与音乐 |
| NAS 子项目 4：故事播放模式 | — | 照片按叙事线编排播放，区别于现有顺序轮播 |
