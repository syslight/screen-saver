# 手机控制协议（Protocol）

本文档是 smart_frame 手机控制协议的权威定义，事实以 `lib/server/protocol.dart`、`lib/server/control_server.dart`、`lib/services/command_service.dart` 为准。按 AGENTS.md 约定：**修改 `lib/server/` 时必须同步本文档**。手机控制链路的高层数据流见 `docs/architecture.md` 第 6 章（装配顺序见其第 3 章），本文只写字段级协议。

## 1. 连接与路由

服务器为应用内嵌的 shelf HTTP/WebSocket 服务器（`ControlServer`），监听 `0.0.0.0`（`InternetAddress.anyIPv4`），端口取配置项 `serverPort`（默认 `8780`）。启动后 `ControlServer.url` 为局域网访问地址，形如 `http://192.168.1.5:8780`（取不到局域网 IP 时为 `localhost`）。手机与电脑需在同一局域网。

| 方法与路径 | 处理 | 说明 |
|---|---|---|
| `GET /` | 返回控制台单页 | `content-type: text/html; charset=utf-8`，内容为 Flutter asset `web_console/index.html` |
| `GET /ws` | WebSocket 升级 | 指令与状态通道，消息格式见第 2、3 章 |
| `POST /api/photos` | 照片上传 | `multipart/form-data`，见第 4 章 |

要点：

- **多客户端**：所有已连接手机保存在 `_clients` 集合中，数量不限；任何一台发出指令，执行结果（event）与最新状态（state）都广播给**全部**已连接手机，天然实现多设备同步。
- **连接即推状态**：WS 连接建立后，服务器立即向该连接发送一条 state 快照（`control_server.dart:65`）。
- **不断连容错**：收到非法 WS 消息只回一条 event，不关闭连接（见第 2 章）。
- 官方控制台页断线后每 2 秒自动重连（`web_console/index.html` 的 `connect()`）。

## 2. 客户端 → 服务器：command 消息

WS 文本帧，JSON 对象：

```json
{"type": "command", "action": "set_volume", "value": 0.5}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `type` | string | 是 | 固定为 `"command"`，否则视为非法消息 |
| `action` | string | 是 | 指令名，非空字符串，取值见下表 |
| `text` | string | 否 | 文本参数（`announce` / `text_command` 使用） |
| `value` | number | 否 | 数值参数（`set_volume` 使用，0..1） |

解析规则（`decodeCommand` / `ConsoleCommand.fromJson`）：消息不是 JSON 对象、`type` 不是 `"command"`、`action` 缺失或非非空字符串，均抛 `FormatException`；`text` 不是字符串、`value` 不是数字时按缺省（`null`）处理。

### action 全表

以 `CommandService.executeCommand` 的 switch 分支（`command_service.dart:47-84`）为准，共 9 个。注意 `protocol.dart` 的注释里漏了 `hide_qr`，**以代码为准**：

| action | 参数 | 效果 | 广播的 event 消息 |
|---|---|---|---|
| `next_photo` | 无 | 相册切到下一张（`photos.next()`） | `已切到下一张` |
| `prev_photo` | 无 | 相册切到上一张（`photos.prev()`） | `已切到上一张` |
| `refresh_weather` | 无 | 立即刷新天气（`weather.refresh()`） | `天气已刷新` / `天气刷新失败` |
| `set_volume` | `value`：0..1，缺省保持当前 | 设置播报音量（clamp 到 0..1）并写入配置 | `音量 50%`（百分比取整） |
| `announce` | `text`：播报内容 | 经 TTS 播报该文本；`text` 为空不播报 | `播报：<text>` / `播报内容为空` |
| `text_command` | `text`：自然语言指令 | 走本地意图解析（`executeText` = `parseIntent` → `executeIntent`），与语音 ASR 结果同一入口 | 意图的中文回复文字，如 `现在时间是 15 点 30 分。` |
| `show_qr` | 无 | 屏幕显示控制台二维码浮层 | `二维码已显示` |
| `hide_qr` | 无 | 隐藏二维码浮层 | `二维码已隐藏` |
| `listen` | 无 | 触发一次语音聆听（经 `onListenRequested` 回调到 `VoicePipeline.triggerListen`） | `开始聆听` |
| 其他任意值 | — | 不执行任何操作，不报错 | `未知指令: <action>` |

除 `text_command` 外的指令（含未知 action）执行后，服务器先广播一条 event（上表消息），再广播一条 state 快照（`command_service.dart:85-86` 的 `onEvent` → `onStateChanged` 顺序），共两条。`text_command` 是例外：意图执行在 `executeIntent` 内已先触发一次 `onStateChanged`（`command_service.dart:147`），回到 `executeCommand` 后再走 `onEvent` → `onStateChanged`，实际广播为 **state → event → state** 三条（示例见第 5 章）。

**非法消息处理**：无法解析的消息（非 JSON、非对象、`type`/`action` 不符）不会执行任何指令，服务器仅向**该连接**回一条 event `无法理解的指令`，连接保持不断开。

## 3. 服务器 → 客户端：state 与 event

### state 状态快照

两种时机发送：WS 连接建立时（仅发给新连接）；任何指令执行后（广播给全部连接）。消息体：

```json
{
  "type": "state",
  "photo": "IMG_20240701_123000.jpg",
  "photoCount": 42,
  "weather": "北京 晴 32°",
  "voice": "待唤醒",
  "volume": 0.8,
  "nas": "已连接 128 张"
}
```

字段以 `CommandService.currentState()`（`command_service.dart:151-159`）为准：

| 字段 | 类型 | 说明 |
|---|---|---|
| `photo` | string | 当前照片文件名；相册为空时为 `（相册为空）` |
| `photoCount` | number | 相册照片总数 |
| `weather` | string | 天气摘要，格式 `<城市> <天气文案> <温度>°`（如 `北京 晴 32°`）；无数据时为 `加载中…`，获取失败为 `获取失败` |
| `voice` | string | 语音状态文本，由 `VoicePipeline.stateText` 注入，取值仅 `待唤醒` / `手动模式` / `聆听中…` / `识别中…` / `播报中…`（`voice_pipeline.dart:46-51`）；未注入时为 `-`（`main.dart:48` 总是注入，实际运行中不会出现） |
| `volume` | number | 播报音量 0..1 |
| `nas` | string | NAS 相册状态（`PhotoService.nasStatus`），取值仅 `未启用` / `未配置` / `已连接 N 张` / `已连接 N 张（已过滤 M）`（有被截图过滤规则排除的文件时，`M` 为被过滤数量）/ `连接失败` |

### event 事件消息

```json
{"type": "event", "message": "已切到下一张"}
```

用途：指令执行结果（见第 2 章 action 表）、非法消息提示（`无法理解的指令`）。官方控制台页把它显示在"消息"日志区。

## 4. 照片上传：POST /api/photos

请求为 `multipart/form-data`；非 multipart 请求返回 `400 expected multipart/form-data`。服务端遍历所有表单字段，处理逻辑（`control_server.dart:83-103`）：

1. 无 `filename` 的字段（普通文本字段）跳过。
2. 扩展名过滤：扩展名转小写后须属于 `PhotoService.imageExts` —— `.jpg`、`.jpeg`、`.png`、`.webp`、`.bmp`、`.gif`，否则跳过。
3. 空文件（0 字节）跳过。
4. 通过校验的文件写入相册目录（`photoDir`，默认 `~/Pictures`），文件名经清洗（见下）。
5. 全部字段处理完后调用 `photos.rescan()`，新照片立即进入轮播。

**文件名清洗与防冲突**（`_uniquePath`，`control_server.dart:106-115`）：

- 先取 `basename` 去掉路径成分，防路径穿越（如 `../../etc/x.jpg` 只剩 `x.jpg`）。
- 非法字符替换为 `_`：保留字母数字下划线（`\w`）、`.`、`-`、汉字（`一-龥`），其余（空格、`/`、`()` 等）一律变 `_`。
- 清洗后为空名或以 `.` 开头（如 `.DS_Store`），前面补 `photo`（即 `photo<原名>`）。
- 与已有文件重名时，在主名后加 `_<毫秒时间戳>`（如 `a_1752850000000.jpg`），不覆盖旧文件。

响应 `200`，`content-type: application/json`，body 为实际保存的文件数：

```json
{"saved": 2}
```

注意：`saved` 只统计通过全部校验并成功写盘的文件数，被过滤的字段不计入。官方控制台页逐文件单独 POST（每请求一个 `file` 字段），服务端本身也支持一个请求携带多个文件字段。

## 5. 示例

### curl 上传照片

```bash
curl -F "file=@/home/user/Downloads/cat.jpg" http://192.168.1.5:8780/api/photos
# {"saved":1}
```

### WebSocket 消息对

以 `set_volume` 为例，客户端发送：

```json
{"type": "command", "action": "set_volume", "value": 0.5}
```

全部已连接客户端依次收到（先 event 后 state）：

```json
{"type": "event", "message": "音量 50%"}
{"type": "state", "photo": "IMG_20240701_123000.jpg", "photoCount": 42, "weather": "北京 晴 32°", "voice": "待唤醒", "volume": 0.5, "nas": "已连接 128 张"}
```

文字指令（与语音同一意图解析入口）：

```json
{"type": "command", "action": "text_command", "text": "今天天气怎么样"}
```

收到（state → event → state 三条，原因见第 2 章）：

```json
{"type": "state", "photo": "IMG_20240701_123000.jpg", "photoCount": 42, "weather": "北京 晴 32°", "voice": "待唤醒", "volume": 0.5, "nas": "已连接 128 张"}
{"type": "event", "message": "北京现在晴，32度，体感34度，湿度41%。今天最高36度，最低25度。"}
{"type": "state", "photo": "IMG_20240701_123000.jpg", "photoCount": 42, "weather": "北京 晴 32°", "voice": "待唤醒", "volume": 0.5, "nas": "已连接 128 张"}
```
