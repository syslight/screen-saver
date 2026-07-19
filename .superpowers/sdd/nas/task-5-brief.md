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

