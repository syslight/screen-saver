# 子项目 1：NAS 图源接入 + 基础过滤 — 设计规格

日期：2026-07-19
状态：已获用户批准

## 背景

smart_frame 当前相册仅支持本地目录。用户照片主体在群晖 NAS（局域网 192.168.1.22，WebDAV 服务 5005/5006 已开放，照片在共享文件夹中文件系统可直接访问）。本规格是"NAS 相册"大需求的第一期；后续子项目（2 智能索引库 / 3 主题相册生成 / 4 故事播放模式）各自另有规格。

## 目标

1. 相册新增 NAS 图片来源（WebDAV 在线拉取），与本地目录混合轮播。
2. 内容过滤：视频跳过（默认行为）；截图按规则过滤。
3. NAS 不可达时静默降级，不影响既有功能。

## 已确认的需求决策

- 访问方式：**WebDAV**（对比过 Synology Photos 私有 API、SMB/NFS 系统挂载，均否）。NAS 地址默认 `http://192.168.1.22:5005`。
- 相册构成：**本地 + NAS 混合**；手机上传仍写本地目录，不写 NAS。
- 过滤重点（用户原话）：跳过"收集截图、电脑截图"等；视频第一期跳过。
- 凭据：NAS 账号密码存本地 config.json 明文（局域网场景，与 asrApiKey 同级处理）。

## 架构

### NasPhotoSource（新建 `lib/services/nas_photo_source.dart`）

- 依赖 `webdav_client`（pub 1.2.2，SDK 约束 <4.0.0，与项目 ^3.12.2 兼容）。
- 职责：连接测试；递归遍历 `nasRemoteDir` 列出图片（按 `PhotoService.imageExts` 过滤扩展名）；按引用下载单张图片。
- 远程图片用引用表示（远程路径 + 可选大小/mtime），不预下载全量。

### PhotoService 改造（`lib/services/photo_service.dart`）

- 相册项抽象为两类来源：本地文件 / NAS 引用；轮播列表 = 本地 + NAS（过滤后）合并。
- 取图：本地直接读文件；NAS 引用先查缓存，未命中则下载入缓存后读。
- 预取：展示当前张时后台预下载下一张 NAS 图，保证轮播间隔内不卡。
- 本地 30 秒重扫逻辑不变；NAS 列表独立每 5 分钟刷新一次（固定 300 秒常量，不新增配置项）。

### 缓存

- 目录：`支持目录/nas-cache/`；文件名 = 远程路径 hash + 原扩展名。
- 上限 500MB，LRU 淘汰最久未访问文件；启动时执行一次淘汰检查。

### 内容过滤（本期重点）

- **视频**：零成本默认行为——两个来源都只认 `imageExts`，视频不进相册。
- **截图规则过滤**（`nasFilterEnabled` 默认开，仅作用于 NAS 来源）：
  - 路径或文件名含关键词即排除。关键词配置项 `nasFilterKeywords`，默认 `["截图", "screenshot", "屏幕快照", "收集"]`，大小写不敏感。
  - 文件名匹配截图正则模式：`^Screenshot[_ -]`、`^Screen Shot`、`^screencap`（大小写不敏感）。
  - 被过滤数量计入状态（控制台状态快照可见）。
- "PNG 且无 EXIF"的模型级判定明确留给子项目 2。

### 降级

- NAS 连接失败/凭据错误/单张下载失败 → 静默降级为"本地 + 已缓存 NAS 图"；不弹窗。
- 状态快照新增 `nas` 字段（如 `已连接 1234 张` / `连接失败` / `未启用`），控制台可见。

### 配置与 UI

- `AppConfig` 新增字段（均有默认，零配置可启动）：
  - `nasEnabled` = false
  - `nasWebdavUrl` = `http://192.168.1.22:5005`
  - `nasWebdavUser` = ''
  - `nasWebdavPassword` = ''
  - `nasRemoteDir` = ''（为空视为未配置：即使 `nasEnabled` 为 true 也不扫描，状态显示 `未配置`）
  - `nasFilterEnabled` = true
  - `nasFilterKeywords` = 上述默认列表
- 设置页新增"NAS 相册"区：开关、URL、账号、密码、远程目录、过滤开关与关键词、"测试连接"按钮（反馈成功/失败原因）。

## 错误处理

| 场景 | 行为 |
|---|---|
| 连接测试 401/403 | 设置页提示凭据错误；运行期转入降级 |
| 连接超时/不可达 | 降级，状态 `连接失败`，下轮刷新自动重试 |
| 单张下载失败 | 跳过该张（视同不存在），日志记录 |
| 缓存写盘失败 | 直接在线读流展示，不入缓存 |

## 测试

- 假 WebDAV 服务：用 `dart:io HttpServer` 模拟 PROPFIND（返回 multistatus XML）与 GET，测 NasPhotoSource 列目录/下载/错误分支。
- 过滤规则单测：关键词（中英文、大小写）、正则模式、开关关闭时全放行、仅作用于 NAS 来源。
- PhotoService 聚合：本地+假 NAS 混合列表、缓存命中后不重复下载、LRU 淘汰。
- 既有 29 个用例保持全绿；`flutter analyze` 无问题。

## 非目标（YAGNI）

- 不写回 NAS；不做缩略图；不支持多 NAS；不做 WebDAV HTTPS 证书配置；不做 EXIF/模型级截图判定（子项目 2）；不做主题相册/配文/音乐（子项目 3/4）。

## 文档同步义务（随代码一并完成）

- `AGENTS.md`：配置表加 7 个新字段；目录结构加 nas_photo_source。
- `docs/requirements.md`：相册 FR 增加 NAS 来源与过滤条目。
- `docs/architecture.md`：模块表与链路补充 NasPhotoSource。
- `docs/deployment.md` 首启注意：NAS 需在设置页配置后启用。
- `docs/roadmap.md`：移除"NAS 图源"相关限制（如有），子项目 2/3/4 记入候选改进。

## 验收标准

- NAS 配置正确时，轮播列表含 NAS 图片并能正常展示；断网/错凭据时本地相册不受影响。
- 截图关键词命中的文件不出现在轮播；视频文件不出现。
- `flutter analyze` 无问题；全部测试（含新增）全绿。
- 上述文档同步完成且事实与代码一致。

## 实现偏差

2026-07-19 最终审查修复后记录：

- **未实现（记入 roadmap）**：错误处理表"缓存写盘失败 → 直接在线读流展示，不入缓存"未实现——`webdav_client` 的 `read2File` 无读流 API，在线读流需绕开它另行实现，触发概率低、改造成本高；实际行为与"单张下载失败"同级：清理部分缓存文件、记日志、跳过该张。在线读流兜底已记入 `docs/roadmap.md` 候选改进。
- **已消除（2026-07-19 修复，行为与本规格一致）**：
  1. `applyNasConfig` 内联 `await` 首次 `_refreshNas()`，NAS 不可达时阻塞启动与设置保存约 8 秒 → 已改为 fire-and-forget，调用方立即返回，刷新完成后经 `notifyListeners` 更新状态。
  2. 缓存写盘失败/中断残留部分文件，`cachedFileFor` 误命中导致永久黑块 → 下载失败即清理部分文件并记 `debugPrint` 日志（补齐上表"日志记录"要求）。
  3. "被过滤数量计入状态"（内容过滤节）与"控制台可见"（降级节）未落地 → `nasStatus` 扩展为 `已连接 N 张（已过滤 M）`（M=0 时不带括号），`web_console/index.html` 状态区新增 NAS 行（`state.nas` 字段缺失的旧端不显示该行）。
