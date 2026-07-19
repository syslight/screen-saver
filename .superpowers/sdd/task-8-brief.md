### Task 8: docs/roadmap.md

**Files:**
- Create: `docs/roadmap.md`

**Interfaces:**
- Consumes: 已写好的 requirements.md（保持口径）；`lib/server/control_server.dart`（无鉴权事实）；`lib/voice/wake_word.dart`（模型来源）
- Produces: 已知限制 + 候选改进清单

- [ ] **Step 1: 写 docs/roadmap.md**：
  - 已知限制（每条给依据）：唤醒词模型首次需访问 GitHub（release-assets 可能超时）；ASR 依赖外部 OpenAI 兼容 API；控制台无鉴权（局域网内任何设备可连可发指令，依据：`control_server.dart` 无 auth 中间件）；上传无大小/配额限制；无原生手机 App（浏览器控制台）
  - 候选改进（不承诺排期）：局域网 token 鉴权、本地 ASR（faster-whisper）、自定义唤醒词、照片管理（删除/收藏）、Android/iOS 原生控制台、天气预警播报
- [ ] **Step 2: 验证**：限制项与 requirements.md 非功能需求不矛盾；无鉴权表述与代码一致

