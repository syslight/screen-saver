# NAS 相册最终审查修复报告

日期：2026-07-19
范围：子项目 1（NAS 图源）最终整体审查后的 5 项修复，使实现回到用户批准的规格基线
（`docs/superpowers/specs/2026-07-19-nas-photo-source-design.md`）。
流程：严格 TDD（先改/加失败测试 → 实现 → 全量回归），非 git 仓库不 commit。

## 改动清单

### 代码（lib/）

| 文件 | 改动 |
|---|---|
| `lib/services/photo_service.dart` | ① `applyNasConfig` 首次 `_refreshNas()` 由 `await` 改为 `unawaited`（fire-and-forget），NAS 不可达时启动/设置保存不再阻塞约 8 秒；刷新完成后由 `_refreshNas` 内部 `notifyListeners` 更新。② `_refreshNas` 成功分支读取 `nas.lastFilteredCount`，M>0 时状态为 `已连接 N 张（已过滤 M）`，M=0 保持 `已连接 N 张`。③ `_download` catch 分支清理残留部分文件（`File(path).delete()` 包 try）+ `debugPrint('NAS 下载失败: ...')`（补齐规格"日志记录"）。doc 注释同步。 |
| `lib/services/nas_photo_source.dart` | 抽象 `NasSource` 新增 `int get lastFilteredCount => 0;`（默认 0，fake 可覆盖）；`NasPhotoSource` 增加 `_filteredCount` 计数：每次 `listPhotos` 归零，`_listInto` 中被 `nasPhotoAllowed` 排除时 +1。 |

调用方（`lib/main.dart:64`、`lib/ui/widgets/settings_sheet.dart:151`）签名不变、无需改动：
`applyNasConfig` 仍是 `Future<void>`，但不再阻塞在 NAS I/O 上。

### 测试（test/）

| 文件 | 改动 |
|---|---|
| `test/photo_service_test.dart` | 12 → 15 例。`FakeNasSource` 新增 `listGate`（挂起闸门）、`downloadThrowsPartial`（写一半字节后抛异常）、`filteredCount`/`lastFilteredCount` 覆盖；新增 `pumpNasRefresh` 轮询辅助（fire-and-forget 刷新后等状态到位）；7 处既有用例在 `applyNasConfig` 后补 pump（行为适配，非断言放松）。新增 3 例：applyNasConfig 挂起时 100ms 内返回、下载中断不留部分文件且恢复后可重试、`已连接 3 张（已过滤 1）` 状态格式。 |
| `test/nas_photo_source_test.dart` | 4 例不变，首例补断言 `source.lastFilteredCount == 1`（真实源计数验证）。 |
| `test/control_server_test.dart` | 未受影响（`nas` 断言为 `未启用`，与新格式无交集），未改。 |

### 控制台与文档

| 文件 | 改动 |
|---|---|
| `web_console/index.html` | 状态区新增 NAS 行（`st-nas-dt`/`st-nas`，默认 `display:none`）；`state.nas` 非空时才显示，字段缺失的旧端不显示该行（兼容）。 |
| `docs/protocol.md` | state 表 `nas` 行取值补 `已连接 N 张（已过滤 M）`。 |
| `docs/requirements.md` | FR-P-10 取值同步补 `已连接 N 张（已过滤 M）`。 |
| `docs/architecture.md` | 第 7 章链路图：首次刷新标注 fire-and-forget、过滤计数、状态格式、下载失败清理+日志。 |
| `docs/superpowers/specs/2026-07-19-nas-photo-source-design.md` | 末尾新增"实现偏差"节：spec 错误处理表"缓存写盘失败直接在线读流展示"未实现（`webdav_client` `read2File` 无读流 API，概率低成本高，行为=清理部分文件+跳过该张，记入 roadmap）；其余三项偏差已由本次修复消除。 |
| `docs/roadmap.md` | 候选改进表新增"NAS 缓存写失败的在线读流兜底"。 |
| `AGENTS.md` | 用例总数 54 → 57（两处）；测试地图 photo_service_test 12 → 15 及覆盖描述、nas_photo_source_test 覆盖描述同步。 |

## TDD 证据

1. **基线**：改动前全量 `flutter test` → `+54: All tests passed!`。
2. **RED**（只改测试后跑两个目标文件）：4 处失败，与修复项一一对应——
   - `applyNasConfig 不阻塞在 NAS I/O 上` → `Expected: true / Actual: <false>`（100ms 内未返回）；
   - `NAS 下载中途失败` → `部分文件应被清理 Expected: false / Actual: <true>`（残留部分文件）；
   - `NAS 状态含被过滤数量` → `期望「已连接 3 张（已过滤 1）」，实际「已连接 3 张」`；
   - `nas_photo_source_test.dart` 加载失败（`lastFilteredCount` 未定义，编译错误）。
3. **GREEN**（实现后同两文件）：`+19: All tests passed!`（日志中可见 `NAS 下载失败: /photo/c.jpg, Bad state: 下载中断`，证明 debugPrint 生效）。
4. **全量回归**：`flutter analyze` → `No issues found!`；`flutter test` → `+57: All tests passed!`。

## 完成门槛核对

- `flutter analyze` 无问题 ✓
- 全量 `flutter test` 57 例全绿（原 54 + 新增 3）✓
- 规格五项修复全部落地，剩余偏差（在线读流兜底）已在规格"实现偏差"节注明并记入 roadmap ✓

## 遗留与说明

- spec"缓存写盘失败直接在线读流展示"有意不实现，理由与去向见规格"实现偏差"节与 `docs/roadmap.md`。
- fire-and-forget 语义下，启动后 NAS 状态短暂为旧值（默认 `未启用`→ 刷新完成后更新为真实状态），由 `_refreshNas` 内 `notifyListeners` 保证 UI 与广播最终一致；测试用 `pumpNasRefresh` 轮询对齐该语义。
- `.superpowers/sdd/nas/task-*` 与 `docs/superpowers/plans/` 为历史过程文档，未回改。
