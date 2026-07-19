# Task 4 报告：PhotoService 聚合改造（本地 + NAS + 缓存，TDD）

## 产出文件

- `lib/services/nas_photo_source.dart`（修改）— 顶部加 `abstract class NasSource`，`NasPhotoSource implements NasSource`（另补两处 `@override` 注解消除 lint info）
- `lib/services/photo_service.dart`（重写）— `PhotoItem` + 聚合改造 + LRU 磁盘缓存
- `test/photo_service_test.dart`（新建）— 12 个用例，fake NasSource（固定 ref 列表、downloadTo 写固定字节并计数）
- `lib/ui/widgets/photo_slideshow.dart`（被迫的最小编译修复，见偏差 1）
- `test/control_server_test.dart`（被迫的一行接口适配，见偏差 2）

## 接口（与简报一致）

```dart
class PhotoItem {
  final String id;        // 本地=文件路径，NAS=远程路径
  final String name;      // 展示名（文件名）
  final File? local;
  final NasPhotoRef? nas;
  bool get isNas;
}
// 工厂：PhotoItem.fromLocal(File) / PhotoItem.fromNas(NasPhotoRef)

class PhotoService {
  PhotoService(this.photoDir, {this.cacheDir = '', this.cacheLimitBytes = defaultCacheLimitBytes});
  static const defaultCacheLimitBytes = 500 * 1024 * 1024; // 500MB
  List<PhotoItem> photos;
  PhotoItem? get current;
  String get currentName;                 // 语义不变：空='（相册为空）'，否则 item.name
  String get nasStatus;                   // '未启用'/'未配置'/'已连接 N 张'/'连接失败'
  Future<File?> fileFor(PhotoItem item);  // 本地直接返回；NAS 查缓存→未命中下载入缓存
  File? cachedFileFor(PhotoItem item);    // 纯查询不下载
  Future<void> applyNasConfig(AppConfig config, NasSource nas);
  void prefetchNext();
}

abstract class NasSource {                // nas_photo_source.dart 顶部
  Future<List<NasPhotoRef>> listPhotos();
  Future<void> downloadTo(String remotePath, String savePath);
}
```

行为要点：

- 合并列表 = 本地（按路径排序）+ NAS（按 name 排序），本地在前。
- `applyNasConfig`：先把 `nasFilterEnabled`/`nasFilterKeywords` 写入 `NasPhotoSource`（`is` 判断，fake 无此字段），再触发 `listPhotos`；立即 `_refreshNas()` 一次，之后 300 秒 Timer 周期刷新；失败置 `连接失败` 不抛异常，且保留已知引用（已缓存的仍可展示，符合规格"降级为本地+已缓存 NAS 图"）；`nasEnabled=false`→`未启用`、remoteDir 空→`未配置`，均不访问 NAS 且 NAS 项不进列表。
- 缓存文件名 = `sha256(utf8(remotePath)).substring(0,16) + 原扩展名`；命中即 touch（setLastModified=now），LRU 按 lastModified 最旧先删；淘汰在每次下载后及 applyNasConfig（启动）时执行；`cacheDir` 为空（默认）时 NAS 项 `fileFor` 返回 null 且不下载。
- 同一远程路径并发下载去重（`_downloading` 表）；单张下载失败返回 null（视同不存在）。
- 兼容红线：`rescan`/`setDir`/`startSlideshow`/`next`/`prev`/`currentName` 语义不变；30 秒重扫只扫本地（NAS 列表独立 300 秒刷新）；rescan 按 id 对齐保持当前张；上传后 rescan 语义不变（control_server 上传用例原样通过）。

## 与简报的偏差

1. **`photo_slideshow.dart` 被迫做了最小编译修复**：`current` 类型从 `File?` 变为 `PhotoItem?` 后该 widget 无法编译（`flutter analyze` 必须无问题）。改动仅 3 行：`item == null ? null : photos.cachedFileFor(item)`——本地项行为与现状完全一致（同步返回 local），NAS 项未命中缓存时暂显占位；异步取图/保持上一帧/预取接线是 Task 5 的 StatefulWidget 改造内容（其简报 Step 2 已规划），此处不越权实现。
2. **`control_server_test.dart:171` 一行接口适配**：`photos.photos.map((f) => f.path)` → `map((item) => item.id)`。`PhotoItem` 严格按简报字段定义（无 `path`），本地项 `id == path`，断言逻辑不变。除此之外 41 个旧用例零改动通过。
3. **淘汰时机**：简报只说"下载后 LRU"，规格另有"启动时执行一次淘汰检查"——启动落点为 `applyNasConfig`（main 装配时调用，Task 5），故淘汰在下载后与 applyNasConfig 各执行一次。

## 调试记录（一处真实 bug）

初版 `fileFor` 用 `_downloading.putIfAbsent(ref.path, () => _download(ref).whenComplete(() => _downloading.remove(ref.path)))` 导致**自引用死锁**：`whenComplete` 的回调返回值是 `Map.remove` 的结果——即该 future 自身，`whenComplete` 会等待回调返回的 Future，于是自己等自己，永不完成（表现为 fileFor 30 秒超时）。改为显式块体回调 `{ _downloading.remove(ref.path); }`（返回 void）后修复。用临时 repro 测试定位（`test/repro_debug_test.dart`，已删）。

## TDD 证据

### RED（实现前）

```
$ flutter test test/photo_service_test.dart
test/photo_service_test.dart:264:19: Error: The method 'applyNasConfig' isn't defined for the type 'PhotoService'.
test/photo_service_test.dart:267:13: Error: The method 'prefetchNext' isn't defined for the type 'PhotoService'.
test/photo_service_test.dart:269:40: Error: The method 'cachedFileFor' isn't defined for the type 'PhotoService'.
（另有 NasSource / PhotoItem / nasStatus 等未定义编译错误）
00:00 +0 -1: Some tests failed.
```

编译错误（接口不存在），符合预期。

### GREEN（实现后，含调试一轮）

```
$ flutter test test/photo_service_test.dart
00:00 +12: All tests passed!
```

12 个用例：混合列表排序与 id/isNas、currentName（本地/NAS/空）、fileFor 本地同一 File、fileFor NAS 首次下载+二次命中不重复（fake 计数、sha256 文件名断言）、cachedFileFor 纯查询不下载、LRU 淘汰（1KB 上限 + 600B 旧文件 + 600B 新下载）、listPhotos 抛错降级、未启用、未配置、无缓存目录不可 fileFor、rescan 只扫本地且当前张保持、next/prev 环绕 + setDir、prefetchNext（预取 NAS/跳过本地）。

### 全量回归

```
$ flutter test
00:03 +53: All tests passed!        # 41 旧 + 12 新
```

### 静态检查

```
$ flutter analyze
No issues found! (ran in 1.3s)
```

（曾报两处 `annotate_overrides` info：`NasPhotoSource.listPhotos`/`downloadTo` 补 `@override` 后消除。）

以上命令均带 `env -u ..._proxy` 前缀。

## 未做事项 / 备注

- `AGENTS.md` 测试地图（41→53、新增 photo_service_test 行）未更新，沿 Task 3 惯例留待收尾任务统一同步。
- NAS 项未命中缓存时全屏轮播暂显"空相册"占位文案（语义不精确），Task 5 StatefulWidget 改造会补齐异步取图与保持上一帧，届时该瞬态消失。
- `applyNasConfig` 的 300 秒周期刷新在测试中未等时验证（只验证立即刷新一次），Timer 存在性由实现保证。
