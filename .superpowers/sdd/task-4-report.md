# Task 4 报告：docs/protocol.md

日期：2026-07-18
状态：DONE

## 交付物

- 新建 `docs/protocol.md`（约 8.2KB），手机控制协议权威文档，共 5 章：
  1. **连接与路由**：`ControlServer` 监听 `0.0.0.0`，端口取 `serverPort`（默认 8780），`ControlServer.url` 形如 `http://192.168.1.5:8780`；路由表 `GET /`（控制台页，text/html; charset=utf-8）、`GET /ws`（WebSocket）、`POST /api/photos`（multipart 上传）；多客户端广播、连接即推状态、非法消息不断连、官方页 2 秒自动重连。
  2. **客户端→服务器 command 消息**：`{"type":"command","action":...,"text"?,"value"?}` 字段表与解析规则；action 全表 9 个（next_photo / prev_photo / refresh_weather / set_volume / announce / text_command / show_qr / hide_qr / listen）+ 未知 action 行为，每行含参数、效果、广播的 event 消息；非法消息回 `无法理解的指令` 且不断连。文中明确标注 protocol.dart 注释漏了 `hide_qr`，以代码为准。
  3. **服务器→客户端 state/event**：state 发送时机（连接时单发 + 指令后广播）与 5 个字段（photo / photoCount / weather / voice / volume，以 `currentState()` 为准，含空相册 `（相册为空）`、`加载中…`/`获取失败` 等兜底值）；event 消息格式与用途。
  4. **照片上传**：multipart 处理流程（无 filename 跳过、imageExts 过滤 `.jpg/.jpeg/.png/.webp/.bmp/.gif`、空文件跳过、写 photoDir、`photos.rescan()`），文件名清洗规则（basename 防路径穿越、非法字符→`_`、空名/点开头补 `photo`、重名加毫秒时间戳），响应 `{"saved": N}` 及计数口径。
  5. **示例**：curl 上传、set_volume 与 text_command 两组 WS 消息对（先 event 后 state，与 `command_service.dart:85-86` 回调顺序一致）。

## 事实来源与交叉验证

- 读了全部指定 sources of truth：`lib/server/protocol.dart`、`lib/server/control_server.dart`、`lib/services/command_service.dart`、`lib/services/photo_service.dart`（imageExts、currentName）、`web_console/index.html`（客户端实际收发的消息、重连逻辑、逐文件上传）、另参考 `lib/main.dart`（装配、url）、`lib/services/weather_service.dart`（summary 格式）。
- `grep -n "case '" lib/services/command_service.dart` → 9 个 case，与文档 action 表逐一对应（表内另有"其他任意值"一行对应 default 分支）。✓
- `grep -n "..get(/..post(" lib/server/control_server.dart` → `GET /`、`GET /ws`、`POST /api/photos`，与文档路由表一致。✓
- 文档中全部 JSON 示例经 `python3 json.loads` 校验合法。✓

## 验证命令与结果

```
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
  /home/peidong/flutter/bin/flutter analyze
→ No issues found! (ran in 5.2s)
```

纯文档任务，未改任何代码，`flutter test` 不涉及（全局约束允许只创建 `docs/**`）。

## 疑虑

无。`listen` action 在当前官方控制台页没有对应按钮（main.dart 注释称其为"按住说话"按钮预留），但它是 `executeCommand` 的真实分支，按简报要求如实收录。

## 审查修正（2026-07-18，第二轮）

审查发现 2 项 Important + 1 项 Minor，已全部修正（只改 `docs/protocol.md`）：

1. **text_command 广播序列**（Important）：`executeIntent` 在 `command_service.dart:147` 先调 `onStateChanged`，回到 `executeCommand` 后 :85-86 再 `onEvent` → `onStateChanged`，实际为 **state → event → state** 三条。已改：§2 广播总述区分"其他 action 为 event → state 两条 / text_command 为 state → event → state 三条"并注明行号依据；§5 text_command 示例"收到"改为如实列出三条消息。
2. **虚构的 voice 取值**（Important）：`voice_pipeline.dart:46-51` 的 `stateText` 只可能是 `待唤醒` / `手动模式` / `聆听中…` / `识别中…` / `播报中…`，原文 `"voice": "待机"` 系虚构。已改：§3 state 示例与字段表、§5 全部三处 state 示例统一改为 `待唤醒`；字段表 voice 行补全五个真实取值及出处，并注明 `-` 因 `main.dart:48` 总是注入而实际不会出现。
3. **交叉引用章号**（Minor）：§0 引言"装配顺序见 architecture.md 第 6 章"有误（装配顺序在其第 3 章，第 6 章是手机控制数据流）。已改为"高层数据流见第 6 章（装配顺序见第 3 章）"。

复检：新增/修改的 JSON 示例经 `python3 json.loads` 校验合法；`flutter analyze` → No issues found! (ran in 5.0s)。
