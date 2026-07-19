### Task 6: 文档同步 + 全量验收

**Files:**
- Modify: `AGENTS.md`（配置表 +7 字段、目录结构加 nas_photo_source/nas_filter、依赖加 webdav_client）
- Modify: `docs/requirements.md`（相册 FR 加 NAS 来源/缓存/过滤条目，NFR 降级补 NAS 降级）
- Modify: `docs/architecture.md`（模块表 + 相册链路含 NasPhotoSource）
- Modify: `docs/deployment.md`（首启注意加 NAS 配置）
- Modify: `docs/roadmap.md`（候选改进更新：划掉 NAS 接入，标注子项目 2/3/4）
- Modify: `README.md`（相册一行与手机控制台功能列表如涉 NAS 状态可提一句，保持最小改动）

**Interfaces:**
- Consumes: Task 1-5 完成的全部代码事实
- Produces: 文档与代码一致的最终态

- [ ] **Step 1: 逐文件同步**，事实以最终代码为准（字段名/默认值/类名/行号引用）
- [ ] **Step 2: 全量验收**：`flutter analyze` 无问题；`flutter test` 全绿；文档中 3 处随机事实抽查（grep 验证）
