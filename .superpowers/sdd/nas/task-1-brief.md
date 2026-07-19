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

