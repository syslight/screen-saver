# Task 8 报告：docs/roadmap.md

日期：2026-07-18
状态：DONE

## 任务

按简报创建 `docs/roadmap.md`：已知限制（约 5 条，每条给代码依据）+ 候选改进（约 6 条，不承诺排期），口径与 `docs/requirements.md` 非功能需求（NFR-x）呼应、不矛盾。

## 产出

- 创建 `docs/roadmap.md`（唯一新增/修改的文件；未触碰 `lib/`、`test/`、`web_console/`、`pubspec.yaml` 等代码文件）。

### 已知限制（5 条，均含代码依据）

| 编号 | 限制 | 依据 | 呼应 NFR |
|---|---|---|---|
| L-1 | 唤醒词模型首次需访问 GitHub，release-assets 可能超时 | `lib/voice/wake_word.dart:23`（modelUrl）、`:112`（ensureKwsModel，5 分钟超时） | NFR-5、NFR-6 |
| L-2 | ASR 依赖外部 OpenAI 兼容 API | `lib/voice/asr_client.dart:8`、`:23`（isConfigured 要求 apiKey 非空） | NFR-5、NFR-6 |
| L-3 | 控制台无鉴权，局域网内任何设备可连可发指令 | `lib/server/control_server.dart:45-52`（三路由 + anyIPv4 监听，无认证中间件） | NFR-5 |
| L-4 | 照片上传无大小/配额限制 | `lib/server/control_server.dart:83-103`（_onUpload 仅校验扩展名与非空） | NFR-5 |
| L-5 | 无原生手机 App，仅浏览器控制台 | 仓库仅有 `linux/` `macos/` `windows/` 目录，无 `android/` `ios/`；`pubspec.yaml` assets 含 `web_console/` | NFR-1 |

每条限制含"依据 / 影响 / 缓解（或定位）"三段。

### 候选改进（6 条，表格形式，明确不承诺排期）

局域网 token 鉴权、本地 ASR（faster-whisper）、应用内自定义唤醒词、照片管理（删除/收藏）、Android/iOS 原生控制台、天气预警播报。

## 事实核验

- **唤醒词模型来源 GitHub**：`wake_word.dart:23-24` modelUrl 为 `github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/...`，下载逻辑在 `ensureKwsModel`（:112-133），`.timeout(const Duration(minutes: 5))` 在 :119。✓
- **无鉴权**：`control_server.dart:45-50` 仅注册 `/`、`/ws`、`/api/photos`；:52 `shelf_io.serve(router.call, InternetAddress.anyIPv4, port)`；全文无 auth/token 校验逻辑。✓
- **上传无限制**：`_onUpload`（:83-103）只查 `PhotoService.imageExts` 扩展名白名单与 `bytes.isEmpty`，无大小/总量/频率限制。✓
- **ASR 外部依赖**：`asr_client.dart` 整个类为 OpenAI 兼容 Whisper API 客户端（:8 注释、:9 类定义），`isConfigured => apiKey.isNotEmpty`（:23）。✓
- **无原生手机 App**：`ls -d */` 输出仅 build/ docs/ lib/ linux/ macos/ test/ web_console/ windows/，无 android/ ios/。✓
- **与 requirements.md 一致性**：
  - L-1 与 NFR-5（唤醒词模型首次下载为例外联网项）、NFR-6（KWS 失败→手动模式）一致；
  - L-2 与 NFR-6（ASR 未配置降级）、FR-V-4（asrBaseUrl 可指向本地 faster-whisper）一致；
  - "应用内自定义唤醒词"改进项刻意标注"当前需手工编辑 `kws-model/keywords.txt`（FR-V-2）"，避免与已实现功能矛盾；
  - 候选改进未承诺排期，符合简报要求。✓

## 验证

```
env -u http_proxy ... /home/peidong/flutter/bin/flutter analyze
→ No issues found! (ran in 1.2s)
```

纯文档改动，不影响代码；`flutter test` 未重跑（前序任务基线 29 用例全绿，本次未触碰任何代码/测试文件）。

## 疑虑

- 无。简报要求的 5 条限制、6 条改进全部覆盖，事实均能在代码中定位。

## 遗留 / 后续

- 规格文件 `docs/superpowers/specs/2026-07-18-project-docs-design.md` 的文档清单中还列有 `docs/README.md`（文档索引），不属于本任务范围（roadmap.md 为其最后一篇内容文档，索引页应由后续任务完成）。
