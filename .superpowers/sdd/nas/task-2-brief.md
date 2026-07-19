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

