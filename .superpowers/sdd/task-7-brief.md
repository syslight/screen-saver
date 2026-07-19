### Task 7: docs/deployment.md

**Files:**
- Create: `docs/deployment.md`

**Interfaces:**
- Consumes: `README.md`、`linux/`、`windows/`、`macos/` 工程目录存在性
- Produces: 打包分发指南

- [ ] **Step 1: 写 docs/deployment.md**：
  - 三平台构建命令与产物路径（Linux：`flutter build linux --release` → `build/linux/x64/release/bundle/`；Windows/macOS 同构，需对应系统上构建，不可交叉编译桌面端）
  - 分发清单：bundle 整目录拷贝；首启注意（KWS 模型需联网下载一次、ASR 需在设置里配 API、相册默认 ~/Pictures、防火墙需放行控制台端口 8780）
  - 开机自启/无人值守：仅列出思路（各平台自启机制一句话），不展开实现
- [ ] **Step 2: 验证**：产物路径与 `flutter build linux --release` 实际输出一致（本机已有 `build/linux/x64/release/bundle/smart_frame` 可 `ls` 验证）

