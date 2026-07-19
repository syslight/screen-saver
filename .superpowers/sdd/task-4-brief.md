### Task 4: docs/protocol.md

**Files:**
- Create: `docs/protocol.md`

**Interfaces:**
- Consumes: `lib/server/protocol.dart`、`lib/server/control_server.dart`、`lib/services/command_service.dart`（action 分支）、`web_console/index.html`（客户端实际发送的消息，写前必须读）
- Produces: 手机控制协议文档；修改 `lib/server/` 时必须同步本文档

- [ ] **Step 1: 写 docs/protocol.md**：
  - 连接：HTTP `GET /` 控制台页、`GET /ws` WebSocket、`POST /api/photos` multipart 上传；端口默认 8780，URL 为局域网 IP（`ControlServer.url`）
  - 客户端→服务器消息：`{"type":"command","action":<string>,"text"?:<string>,"value"?:<number>}`；action 全表（next_photo/prev_photo/refresh_weather/set_volume/announce/text_command/show_qr/hide_qr/listen，各参数与效果，以 `command_service.dart` switch 为准——注意 protocol.dart 注释里没有 hide_qr 但代码有，文档以代码为准）
  - 服务器→客户端：连接即推 `{"type":"state", photo, photoCount, weather, voice, volume}`（字段以 `currentState()` 为准），状态变化广播同构；事件 `{"type":"event","message":...}`；非法消息回复 event `无法理解的指令` 且不断连
  - 上传：multipart 字段按扩展名过滤（imageExts），文件名清洗（非法字符→`_`，去路径、空名/点开头→`photo`），重名加毫秒时间戳，全部完成后 `photos.rescan()`，响应 `{"saved": N}`
  - 附 1-2 个示例（curl 上传、WS 消息对）
- [ ] **Step 2: 验证**：`grep -n "case '" lib/services/command_service.dart` 列出的 action 与文档表格逐一对应；`grep -n "get(\|post(" lib/server/control_server.dart` 路由一致

