# Task 2 报告：NAS 截图过滤模块（TDD）

## 产出文件

- `lib/services/nas_filter.dart`（新建）— 纯函数 `bool nasPhotoAllowed(String pathOrName, {required bool enabled, required List<String> keywords})`
- `test/nas_filter_test.dart`（新建）— 5 个用例

## 实现要点

过滤顺序（`enabled == false` 时直接放行）：

1. 路径转小写后含任一非空关键词（转小写）→ 排除；空串关键词跳过。
2. 路径含中文"截图"→ 排除（内置，不受自定义 keywords 影响）。
3. basename（按 `/`、`\` 切分）命中内置正则 `^Screenshot[_ -]` / `^Screen Shot` / `^screencap`（均大小写不敏感）→ 排除。
4. 其余放行。

## 与简报的一处偏差（已按测试契约解决）

简报 Step 3 给的 `_screenshotPatterns` 只有 3 个匹配 **basename** 的正则，但 Step 1 要求用例"传 `['自定义']` 时 `/x/截图/e.jpg` 仍命中（默认正则模式不受 keywords 影响）"——`e.jpg` 这个 basename 不可能命中那 3 个正则，关键词 `['自定义']` 也不含"截图"。两者矛盾。

以测试用例为契约，最小化解：保留简报给定的 3 个 basename 正则不变，另加一条内置规则"路径含 `截图` 即排除"（独立于 keywords，不可关闭）。该设计对 Task 3 的真实路径（如 `/nas/手机备份/截图/xxx.jpg`）也成立。若后续 Task 期望"截图"可被 keywords 完全接管，需要改这里。

## TDD 证据

### RED（Step 2，实现前）

```
$ flutter test test/nas_filter_test.dart
test/nas_filter_test.dart:70:9: Error: Method not found: 'nasPhotoAllowed'.
...
00:00 +0 -1: Some tests failed.
Failing tests:
  test/nas_filter_test.dart: loading test/nas_filter_test.dart
```

编译错误，符合预期。

### GREEN（Step 4，实现后）

```
$ flutter test test/nas_filter_test.dart
00:00 +5: All tests passed!
```

### 全量回归

```
$ flutter test
00:02 +37: All tests passed!        # 29 旧 + Task1 新增 3 + 本任务 5 = 37
```

### 静态检查

```
$ flutter analyze
No issues found! (ran in 1.3s)
```

（以上命令均带 `env -u ..._proxy` 前缀。）

## 未做事项 / 备注

- 按任务规则"只创建简报点名的两个文件"，未同步 `AGENTS.md` 测试地图（其中"共 29 个用例 / 5 个测试文件"的表述在 Task 1 后也已过时）。建议收尾任务统一更新。
- `screenshots_backup.zip` 按简报说明不在本函数职责内，未测。

## Fix 记录（2026-07-19，Controller 裁决）

- **裁决**：`keywords` 采用**替换语义**——参数即完整生效列表，不得有"路径含截图即排除"的隐藏内置规则；截图正则（`^Screenshot[_ -]` / `^Screen Shot` / `^screencap`，basename 匹配）保持内置、不受 keywords 影响。
- **改动**：
  - `lib/services/nas_filter.dart`：删除内置"截图"硬编码规则；顶部 dartdoc 写明替换语义；关键词匹配严格只来自 `keywords` 参数。
  - `test/nas_filter_test.dart`：自定义 keywords 用例改为断言替换语义——`['自定义']` 时 `/x/截图/e.jpg` 放行（默认被替换）、`['自定义','截图']` 时排除（可加回）、`Screenshot_1.png` 在 `['自定义']` 时仍排除（正则独立）。
- **验证**：全量 `flutter test` 37/37 通过；`flutter analyze` 无问题。
