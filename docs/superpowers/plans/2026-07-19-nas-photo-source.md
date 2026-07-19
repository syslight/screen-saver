# 子项目 1：NAS 图源接入 + 基础过滤 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 相册新增 NAS（WebDAV）图片来源，与本地混合轮播，带截图过滤与磁盘缓存。

**Architecture:** 新增 `NasPhotoSource`（WebDAV 封装）与 `nas_filter`（纯函数过滤）；`PhotoService` 改为聚合本地文件 + NAS 引用，NAS 图经磁盘缓存供 UI 同步读取；设置页加 NAS 配置区。

**Tech Stack:** Flutter 3.44+ / Dart ^3.12.2、`webdav_client` 1.2.2（新增依赖）、`crypto`（已有）、`flutter_test`。

## Global Constraints

- 规格：`docs/superpowers/specs/2026-07-19-nas-photo-source-design.md`，功能/字段名/默认值以它为准。
- 遵守 `AGENTS.md` 硬性约定：`flutter analyze` 无问题、`flutter test` 全绿是完成门槛。
- flutter 二进制：`/home/peidong/flutter/bin/flutter`；跑 test/analyze 前必须 `env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy`。
- 项目**不是 git 仓库**：所有 "commit" 步骤跳过。
- 代码注释用中文，风格与现有代码一致；新指令不得绕过 CommandService（本期无新指令）。
- 现有 29 个测试保持全绿；现有公共行为（`currentState()` 既有字段、上传接口、轮播语义）不得破坏。
- **YAGNI**：不写回 NAS、不做缩略图、不多 NAS、不做 EXIF 判定。

---

### Task 1: AppConfig 新增 7 个 NAS 字段

**Files:**
- Modify: `lib/config/app_config.dart`（AppConfig 构造函数、字段、fromJson、toJson 四处都要加）
- Test: `test/app_config_test.dart`（新建）

**Interfaces:**
- Produces（后续任务依赖的确切签名）:
  - `AppConfig.nasEnabled` (`bool`, 默认 `false`)
  - `AppConfig.nasWebdavUrl` (`String`, 默认 `'http://192.168.1.22:5005'`)
  - `AppConfig.nasWebdavUser` / `nasWebdavPassword` / `nasRemoteDir` (`String`, 默认 `''`)
  - `AppConfig.nasFilterEnabled` (`bool`, 默认 `true`)
  - `AppConfig.nasFilterKeywords` (`List<String>`, 默认 `const ['截图', 'screenshot', '屏幕快照', '收集']`)

- [ ] **Step 1: 写失败测试** `test/app_config_test.dart`：
  - 默认值断言（7 字段逐一，含 keywords 列表内容与顺序）
  - fromJson/toJson 往返：设置全非默认值 → toJson → fromJson → 逐字段相等
  - fromJson 缺省时回落默认值（`AppConfig.fromJson({})`）
  - 参考现有测试风格（看 `test/calendar_service_test.dart` 的写法）
- [ ] **Step 2: 跑测试确认失败**：`env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy /home/peidong/flutter/bin/flutter test test/app_config_test.dart` → 编译错误（字段不存在）
- [ ] **Step 3: 实现**：`app_config.dart` 加 7 个字段（dartdoc 注释与现有字段同风格），fromJson 用 `??` 默认值、toJson 全量输出；`nasFilterKeywords` fromJson 处理 `List<dynamic>` → `List<String>`（`(j['nasFilterKeywords'] as List?)?.cast<String>() ?? 默认列表`），toJson 直接放列表。
- [ ] **Step 4: 跑测试确认通过**：同 Step 2 命令 → 全过；再跑全量 `flutter test` 确认 29 个旧用例不破。

### Task 2: NAS 截图过滤模块

**Files:**
- Create: `lib/services/nas_filter.dart`
- Test: `test/nas_filter_test.dart`（新建）

**Interfaces:**
- Consumes: `AppConfig.nasFilterEnabled` / `nasFilterKeywords`（Task 1）
- Produces: `bool nasPhotoAllowed(String pathOrName, {required bool enabled, required List<String> keywords})` — Task 3 列目录时逐文件调用

- [ ] **Step 1: 写失败测试** `test/nas_filter_test.dart`，用例：
  - 关键词命中路径任意段：`/photo/收集截图/a.jpg`（"截图"）、`/photo/screenshots/b.jpg`（"screenshot" 子串）、`/Photo/SCREENSHOTS/c.jpg`（大小写不敏感）
  - 文件名模式：`Screenshot_20240101_123456.png`、`Screen Shot 2024-01-01 at 12.00.00.png`、`screencap-123.png` 命中；`screenshots_backup.zip`（非图片场景不在此函数职责内，不测）
  - 不命中：`/photo/2024春节/IMG_0001.jpg`、`全家福.png`
  - `enabled: false` 时全部放行（含截图）
  - 自定义 keywords：传 `['自定义']` 时 `/x/自定义目录/d.jpg` 排除、`/x/截图/e.jpg` 仍命中（默认正则模式不受 keywords 影响）
- [ ] **Step 2: 跑测试确认失败**（命令同 Task 1 Step 2，路径换）→ 编译错误
- [ ] **Step 3: 实现** `nas_filter.dart`：
  - 顶部注释说明职责；`final _screenshotPatterns = [RegExp(r'^Screenshot[_ -]', caseSensitive: false), RegExp(r'^Screen Shot', caseSensitive: false), RegExp(r'^screencap', caseSensitive: false)];`（匹配文件名 basename）
  - 函数：`enabled == false` 返回 true；lowercase 路径含任一 lowercase keyword（keyword 为空串跳过）返回 false；basename 命中任一正则返回 false；否则 true。
- [ ] **Step 4: 跑测试确认通过** + 全量回归

### Task 3: NasPhotoSource（WebDAV 封装）

**Files:**
- Modify: `pubspec.yaml`（dependencies 加 `webdav_client: ^1.2.2`）
- Create: `lib/services/nas_photo_source.dart`
- Test: `test/nas_photo_source_test.dart`（新建）

**Interfaces:**
- Consumes: `nasPhotoAllowed`（Task 2）、`PhotoService.imageExts`
- Produces（Task 4 依赖）:
  - `class NasPhotoRef { final String path; final int size; final DateTime? mtime; String get name; }`（path 为 WebDAV 远程路径）
  - `class NasPhotoSource { void configure({required String url, required String user, required String password, required String remoteDir}); Future<void> ping(); Future<List<NasPhotoRef>> listPhotos(); Future<void> downloadTo(String remotePath, String savePath); }`
  - 未 configure 或 remoteDir 为空时 `listPhotos()` 返回 `[]`

- [ ] **Step 1: 加依赖**：pubspec.yaml dependencies 加 `webdav_client: ^1.2.2`，`env -u ... /home/peidong/flutter/bin/flutter pub get`
- [ ] **Step 2: 写失败测试** `test/nas_photo_source_test.dart`：
  - 用 `dart:io HttpServer` 起假 WebDAV（参考 `test/control_server_test.dart` 起真实服务器的模式）：
    - PROPFIND（method='PROPFIND'）对 `/photo/` 返回 207 + multistatus XML：两个文件 `a.jpg`(1000B)、`b.png`(2000B)、一个子目录 `sub/`；对 `/photo/sub/` 返回 `Screenshot_1.png`(500B)、`c.jpg`(3000B)
    - GET `/photo/a.jpg` 返回 1000 字节
  - 用例：递归列出 3 张（a.jpg、b.png、c.jpg；Screenshot_1.png 被 nasPhotoAllowed 过滤——keywords 用默认）；downloadTo 写盘内容长度正确；401 响应时 ping 抛异常；未配置 remoteDir 时 listPhotos 返回空
  - multistatus XML 样例（放在测试文件里）：
    ```xml
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
      <D:response><D:href>/photo/a.jpg</D:href><D:propstat><D:prop><D:getcontentlength>1000</D:getcontentlength><D:resourcetype/></D:prop></D:propstat></D:response>
    </D:multistatus>
    ```
  - 注意：先实际跑通一次假服务器+webdav_client 的解析（webdav_client 用 dio 发 PROPFIND），XML 细节以客户端真实能解析为准，可在实现时微调样例
- [ ] **Step 3: 跑测试确认失败** → 编译错误（类不存在）
- [ ] **Step 4: 实现** `nas_photo_source.dart`：
  - `configure` 里 `newClient(url, user: user, password: password)`，`setConnectTimeout(8000)`/`setReceiveTimeout(60000)`
  - `listPhotos`：递归 `readDir`（目录项 `isDir` 则递归，文件按 `PhotoService.imageExts` 扩展名 + `nasPhotoAllowed` 过滤），每文件构造 NasPhotoRef（size 来自 webdav File.size，mtime 来自 File.mTime）
  - `downloadTo`：`read2File(remotePath, savePath)`
  - 错误不内部吞掉（ping/listPhotos 抛出让调用方处理——Task 4 的降级逻辑负责捕获）
- [ ] **Step 5: 跑测试确认通过** + 全量回归

### Task 4: PhotoService 聚合改造（本地 + NAS + 缓存）

**Files:**
- Modify: `lib/services/photo_service.dart`
- Test: `test/photo_service_test.dart`（新建）

**Interfaces:**
- Consumes: `NasPhotoSource` / `NasPhotoRef`（Task 3）、`AppConfig` NAS 字段（Task 1）
- Produces（Task 5 依赖）:
  - `class PhotoItem { final String id; final String name; final File? local; final NasPhotoRef? nas; bool get isNas; }`
  - `PhotoService.photos` → `List<PhotoItem>`；`current` → `PhotoItem?`；`currentName` 语义不变
  - `Future<File?> fileFor(PhotoItem item)` — 本地直接返回 local；NAS 查缓存（命中直接返回缓存 File）否则 downloadTo 缓存后返回
  - `File? cachedFileFor(PhotoItem item)` — 纯查询缓存是否已存在（不触发下载），UI 同步判断用
  - `String get nasStatus` — `'未启用'` / `'未配置'` / `'已连接 N 张'` / `'连接失败'`
  - `Future<void> applyNasConfig(AppConfig config, NasSource nas)` — 配置来源并触发刷新
  - `void prefetchNext()` — 预取下一张 NAS 图

- [ ] **Step 1: 写失败测试** `test/photo_service_test.dart`：
  - 用临时目录造本地图片（写 2 个假 jpg 文件）；用**假 NasPhotoSource**（定义接口 `NasSource` 抽象类，NasPhotoSource 实现它，测试用 fake 实现返回固定 ref 列表/把固定字节写 savePath——注意 Step 3 需先在 nas_photo_source.dart 定义该抽象）
  - 用例：混合列表（本地 2 + NAS 2，本地在前 NAS 在后按 name 排序）；currentName 对 NAS 项返回 ref.name；fileFor 本地直接返回同一 File；fileFor NAS 首次触发 downloadTo、第二次不重复下载（fake 计数）；缓存目录 LRU：构造超上限小目录（测试用小上限注入，如 1KB）验证最久未访问文件被删；NAS listPhotos 抛错时本地列表仍在且 nasStatus='连接失败'；nasEnabled=false 时 NAS 项不进列表、nasStatus='未启用'
- [ ] **Step 2: 跑测试确认失败** → 编译错误
- [ ] **Step 3: 实现**：
  - `nas_photo_source.dart` 顶部加 `abstract class NasSource { Future<List<NasPhotoRef>> listPhotos(); Future<void> downloadTo(String remotePath, String savePath); }`，`NasPhotoSource implements NasSource`
  - `photo_service.dart` 改造：PhotoItem；`photos` 列表 = 本地（File→PhotoItem）+ NAS（启用时 ref→PhotoItem）；`fileFor` 缓存逻辑（缓存目录构造参数注入，默认空表示未初始化时 NAS 项不可 fileFor）；缓存文件名 = `sha256.convert(utf8.encode(remotePath)).toString().substring(0,16) + 扩展名`（crypto 已在依赖）；LRU 上限构造参数（默认 500MB），淘汰按 lastModified 最旧先删；`_refreshNas()` 每 300 秒 Timer + applyNasConfig 时立即一次，失败置 nasStatus 不抛；`prefetchNext()` 对下一张 isNas 项 unawaited fileFor
  - 保持 `rescan()`/`setDir`/`startSlideshow`/next/prev 既有语义（轮播索引、30 秒重扫仅扫本地）
  - **兼容红线**：`currentName` 行为不变；上传后 rescan 语义不变
- [ ] **Step 4: 跑测试确认通过** + 全量回归（29 旧 + 新增）

### Task 5: UI 装配（轮播异步取图 + 设置页 NAS 区 + 状态字段）

**Files:**
- Modify: `lib/ui/widgets/photo_slideshow.dart`（StatelessWidget→StatefulWidget）
- Modify: `lib/ui/widgets/settings_sheet.dart`
- Modify: `lib/services/command_service.dart`（currentState 加 nas 字段）
- Modify: `lib/main.dart`（装配 NasPhotoSource、缓存目录、applyNasConfig）
- Modify: `lib/config/app_config.dart`（ConfigService 如需暴露支持目录已有）
- Test: `test/control_server_test.dart`（如 state 断言需更新）、`test/protocol_test.dart`（同）

**Interfaces:**
- Consumes: Task 4 的全部 Produces
- Produces: `CommandService.currentState()` 新增 `'nas': photos.nasStatus`；UI 完整 NAS 配置链路

- [ ] **Step 1: 检查并更新受影响的既有测试**：先跑全量 `flutter test` 看 control_server/protocol 测试是否因 currentState 加字段而失败（JSON 断言为子集匹配则应无恙；精确匹配则更新期望）
- [ ] **Step 2: photo_slideshow 改造**：
  - StatefulWidget；`context.watch<PhotoService>()` 取 current（PhotoItem）
  - item.local != null → 直接 `Image.file`（现状不变）
  - NAS 项：同步检查 `photos.cachedFileFor(item)`（Task 4 已暴露）→ 命中直接显示；未命中 → 保持上一帧（AnimatedSwitcher gaplessPlayback 语义），`fileFor(item)` 完成后 setState 显示；item 变化时取消过期请求（用递增序号丢弃旧结果）
  - 每次展示完成后调用 `photos.prefetchNext()`
  - 占位逻辑（相册为空）保持不变
- [ ] **Step 3: settings_sheet 加 NAS 区**：
  - 7 个字段控件（开关用 SwitchListTile；密码 obscure；关键词用逗号分隔的 TextField，保存时 split/trim/去空）
  - "测试连接"按钮：调用 `NasPhotoSource.ping()`，SnackBar 或行内文本显示"连接成功"/"连接失败：$e"
  - `_save()`：写回 7 字段 + `configService.save()` + 调 `photos.applyNasConfig(c, nas)`（nas 从 context.read 拿，需 main.dart 先 Provider 注入）
- [ ] **Step 4: main.dart 装配**：
  - `final nasSource = NasPhotoSource()`；`PhotoService` 构造给缓存目录（`p.join(supportDir.path, 'nas-cache')`）；init 后 `await photos.applyNasConfig(config, nasSource)`（内部按 nasEnabled 决定是否真连）
  - MultiProvider 加 `Provider.value(value: nasSource)`
  - command_service.currentState() 加 `'nas': photos.nasStatus`（CommandService 已持有 photos）
- [ ] **Step 5: 全量验证**：`flutter analyze` 无问题 + `flutter test` 全绿；手动 `flutter run -d linux` 冒烟（设置页打开 NAS 区可交互）——此步由 controller 在任务完成后实机做，implementer 只需保证 analyze/test

### Task 6: 文档同步 + 全量验收

**Files:**
- Modify: `AGENTS.md`（配置表 +7 字段、目录结构加 nas_photo_source/nas_filter、依赖加 webdav_client）
- Modify: `docs/requirements.md`（相册 FR 加 NAS 来源/缓存/过滤条目，NFR 降级补 NAS 降级）
- Modify: `docs/architecture.md`（模块表 + 相册链路含 NasPhotoSource）
- Modify: `docs/deployment.md`（首启注意加 NAS 配置）
- Modify: `docs/roadmap.md`（候选改进更新：划掉 NAS 接入，标注子项目 2/3/4）
- Modify: `README.md`（相册一行与手机控制台功能列表如涉 NAS 状态可提一句，保持最小改动）

**Interfaces:**
- Consumes: Task 1-5 完成的全部代码事实
- Produces: 文档与代码一致的最终态

- [ ] **Step 1: 逐文件同步**，事实以最终代码为准（字段名/默认值/类名/行号引用）
- [ ] **Step 2: 全量验收**：`flutter analyze` 无问题；`flutter test` 全绿；文档中 3 处随机事实抽查（grep 验证）
