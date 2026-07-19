# Task 1 报告：AppConfig 新增 7 个 NAS 字段（TDD）

## 状态：DONE

## 变更文件

- `lib/config/app_config.dart`：AppConfig 新增 7 个字段（构造函数默认值、字段声明 + 中文 dartdoc、fromJson `??` 默认值、toJson 全量输出，四处均加）。
- `test/app_config_test.dart`（新建）：3 个用例——默认值断言（7 字段逐一，含 keywords 列表内容与顺序）、`fromJson({})` 缺省回落默认值、toJson/fromJson 全非默认值往返逐字段相等。

## 新增字段（与简报/规格一致）

| 字段 | 类型 | 默认值 |
|---|---|---|
| `nasEnabled` | `bool` | `false` |
| `nasWebdavUrl` | `String` | `'http://192.168.1.22:5005'` |
| `nasWebdavUser` | `String` | `''` |
| `nasWebdavPassword` | `String` | `''` |
| `nasRemoteDir` | `String` | `''` |
| `nasFilterEnabled` | `bool` | `true` |
| `nasFilterKeywords` | `List<String>` | `const ['截图', 'screenshot', '屏幕快照', '收集']` |

`nasFilterKeywords` 的 fromJson 按简报要求处理 `List<dynamic>` → `List<String>`：
`(j['nasFilterKeywords'] as List?)?.cast<String>() ?? const ['截图', 'screenshot', '屏幕快照', '收集']`，toJson 直接放列表。

## TDD 证据

### RED（Step 1-2）

命令：

```bash
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy /home/peidong/flutter/bin/flutter test test/app_config_test.dart
```

输出（截取，编译错误：字段不存在）：

```
test/app_config_test.dart:41:23: Error: The getter 'nasWebdavUser' isn't defined for the type 'AppConfig'.
test/app_config_test.dart:42:23: Error: The getter 'nasWebdavPassword' isn't defined for the type 'AppConfig'.
test/app_config_test.dart:43:23: Error: The getter 'nasRemoteDir' isn't defined for the type 'AppConfig'.
test/app_config_test.dart:44:23: Error: The getter 'nasFilterEnabled' isn't defined for the type 'AppConfig'.
test/app_config_test.dart:45:23: Error: The getter 'nasFilterKeywords' isn't defined for the type 'AppConfig'.
00:00 +0 -1: Some tests failed.
```

（`nasEnabled`/`nasWebdavUrl`/`nasFilterKeywords` 等在默认值用例处同样报编译错误，上方为 tail 截取部分。）

### GREEN（Step 3-4）

同一命令实现后输出：

```
00:00 +0: AppConfig NAS 字段 默认值
00:00 +1: AppConfig NAS 字段 fromJson({}) 缺省时回落默认值
00:00 +2: AppConfig NAS 字段 toJson/fromJson 往返逐字段相等
00:00 +3: All tests passed!
```

### 全量回归

`flutter test`（同 env 前缀）：`00:02 +32: All tests passed!` —— 29 旧用例 + 3 新用例全绿。

`flutter analyze`（同 env 前缀）：`No issues found! (ran in 1.5s)`

## 未做 / 交接说明

- 按任务规则"只改简报点名的文件"，未同步文档。AGENTS.md 硬性约定要求配置项变更同步 README.md「配置」表 + AGENTS.md 配置表（当前写着"共 12 个字段"），规格文档第 91-95 行也列了 docs 更新项，建议由后续任务统一处理。
- 未做 git 操作（项目非 git 仓库）。
