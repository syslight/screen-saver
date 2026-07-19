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

