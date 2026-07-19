# Task 6 报告：文档同步 + 全量验收（子项目 1 NAS 相册收尾）

日期：2026-07-19
状态：DONE

## 1. 代码事实核对（同步前的基准）

- `AppConfig` 共 19 个字段（原 12 + NAS 新增 7），默认值与规格一致（`lib/config/app_config.dart:10-28`，`grep -c 'this\.'` 计 20，其中 1 个属 `ConfigService.supportDir`）。
- `NasSource` / `NasPhotoSource` / `NasPhotoRef` 在 `lib/services/nas_photo_source.dart`；`nasPhotoAllowed` 在 `lib/services/nas_filter.dart`（空串关键词跳过、keywords 替换语义、内置截图正则独立于 keywords）。
- `PhotoService`：混合轮播（本地在前按路径、NAS 在后按 name）、`nasStatus` 四值（未启用/未配置/已连接 N 张/连接失败）、nas-cache 500MB LRU、NAS 列表 300 秒刷新、prefetchNext 预取。
- `main.dart`：nasSource 装配 L35-43、`applyNasConfig` L64、9 个 provider（L87-97，新增 `Provider.value(nasSource)`）。
- 测试：9 个文件 53 例（app_config 3 / calendar 5 / control_server 8 / intent_parser 9 / nas_filter 5 / nas_photo_source 4 / photo_service 12 / protocol 5 / weather 2），本任务 +1 → 54。
- `docs/protocol.md` 经核对已被 Task 5 同步（state 快照含 `nas` 字段，行号引用 `command_service.dart:151-159`、`control_server.dart:65` 均仍准确），本任务未再改动。

## 2. 改动清单（仅文档 + 一处测试，无其他代码改动）

- `test/nas_filter_test.dart`：新增用例「空字符串关键词被跳过，普通照片放行」（keywords: [''] 时普通照片放行，钉住 `nas_filter.dart:29` 的 `if (keyword.isEmpty) continue` 行为）。5 → 6 例。
- `AGENTS.md`：目录结构 services 行加 nas_photo_source/nas_filter、test 行 5→9 个文件并补 webdav_client 依赖说明；硬性约定 29→54 用例；配置表 12→19 字段（补 7 个 NAS 字段行）；测试地图更新为 9 文件 54 用例及各文件覆盖点。
- `docs/requirements.md`：2.3 相册新增 FR-P-7（NAS 来源/混合轮播/300 秒刷新/未配置语义）、FR-P-8（nas-cache 500MB LRU + 预取）、FR-P-9（截图过滤规则）、FR-P-10（nas 状态快照字段）；NFR-3 改 19 字段；NFR-7 改 54 用例；新增 NFR-8 NAS 相册逐层降级。
- `docs/architecture.md`：模块表 app_config 改 19 字段、photo_service 职责改写、新增 nas_photo_source/nas_filter 两行；启动装配顺序按现 `main.dart` 重写为 13 步（行号全部核对）；provider 8→9 并补 nasSource 行；新增「7. 链路三：相册 NAS 数据流」（含 settings_sheet.dart:87-106/145-151、photo_service.dart:165-179/222-235 行号引用，均已核对）；依赖选型改 8 章、provider 行 3→4 纯服务对象、crypto 行补 NAS 缓存哈希用途、新增 webdav_client 行。
- `docs/deployment.md`：首启注意事项新增「NAS 相册需在设置里配置」条目（默认关闭、远程目录留空=未配置、失败自动降级、nas-cache 500MB）。
- `docs/roadmap.md`：候选改进标注 NAS 子项目 1 已完成（2026-07-19，附规格路径）；表格末补三行：子项目 2 智能索引库 / 子项目 3 主题相册生成 / 子项目 4 故事播放模式。
- `README.md`（最小改动）：功能列表「相册」一行补 NAS 混合轮播与截图过滤；配置节段末补两句 NAS 开启方式与降级行为。
- `docs/development.md`（brief 清单外顺手修正的失同步事实）：三处「29 个用例」→54；测试表补 4 个新文件行；日志表 `lib/main.dart:67` → `:79`（行号已漂）。

## 3. 全量验收记录

1. `env -u http_proxy ... flutter analyze` → **No issues found!**（1.3s）。
2. `env -u http_proxy ... flutter test` → **+54: All tests passed!**（54 例全绿）。
3. 文档事实抽查 3 处（grep 验证）：
   - 配置字段数：`app_config.dart` 构造器 19 个 `this.` 参数（L10-28），与 AGENTS.md「共 19 个字段」、requirements NFR-3、architecture 模块表一致 ✓
   - 依赖：`pubspec.yaml` 含 `webdav_client: ^1.2.2`，AGENTS.md:62 与 architecture.md:13/212 均已提及 ✓
   - nasStatus 取值与行号：`photo_service.dart` 四值（L145/147/172/175）与 protocol.md state 表、FR-P-10 一致；`main.dart:64` 确为 `applyNasConfig`、`main.dart:79` 确为启动失败 debugPrint（development.md 已同步）✓

## 4. 说明与遗留

- 未做任何 git 操作（项目非 git 仓库）。
- 除清单中文档与 `test/nas_filter_test.dart` 一处外未改代码；`docs/development.md` 不在 brief 清单内，但属「改了就要同步文档」覆盖的失同步事实（用例数/行号），一并修正。
- 规格「文档同步义务」全部落实；子项目 1 至此收尾。
