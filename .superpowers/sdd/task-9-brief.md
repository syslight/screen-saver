### Task 9: docs/README.md + 收尾验收

**Files:**
- Create: `docs/README.md`
- Modify: `README.md`（只加一行指向 docs/ 的链接，不重写）

**Interfaces:**
- Consumes: 前 8 个任务的产出
- Produces: 文档索引；完整文档体系

- [ ] **Step 1: 写 docs/README.md**：9 篇文档表格索引（文件/一句话说明/何时读）
- [ ] **Step 2: 在 README.md 的"架构速览"前加一行**：`完整文档见 [docs/](docs/README.md)（需求、架构、协议、语音、开发、部署、路线图）。`
- [ ] **Step 3: 全量验收**
  - `flutter analyze` 无问题、`env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy flutter test` 29 用例全过
  - `ls AGENTS.md docs/README.md docs/requirements.md docs/architecture.md docs/protocol.md docs/voice-pipeline.md docs/development.md docs/deployment.md docs/roadmap.md` 全部存在
  - 链接检查：docs/README.md 中所有相对链接指向存在的文件
  - 事实抽查：随机 3 条文档中的命令实际执行成功
