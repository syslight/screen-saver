# smart_frame 照片守护进程

离线全量预处理 NAS 照片，算多模型特征（dinov2 / CLIP / insightface / minicpm-v），写入与 Flutter app **共享的 SQLite**，供 app 只读消费（去重 / 标签 / 人物 / 相似度筛选）。app 不再自己算特征。

## 为什么独立守护进程

app 内实时索引（阶段 1/2）只算播放触达的、单维度、且占 app 进程/GPU。守护进程离线全量算全部照片 + 全维度，app 纯读。

## 技术栈

- Python 3.12 + uv（独立 venv，不碰系统 Python 3.14）
- torch 2.13 + cu126（GPU，GTX 1070 Ti）
- transformers（dinov2 / CLIP）、insightface + onnxruntime（人脸）、ollama（VLM minicpm-v）
- httpx（WebDAV PROPFIND/GET，逐条复刻 app 的 `nas_photo_source._listInto` 过滤）

## 结构

```
smart_frame_photo_daemon/
  config.py     读 app config.json（NAS 凭据/过滤/VLM）
  scanner.py    NAS 递归列目录（复刻 nas_filter：@eaDir/小文件/关键词/截图/扩展名）
  db.py         共享 SQLite（WAL，photos + faces 表，与 app 同路径同 schema）
  models/
    dinov2.py   facebook/dinov2-base 768d（视觉相似度/去重/聚类）
    clip.py     CLIP 512d 图文（语义检索，如「放猫的」）
    faces.py    insightface buffalo_l 512d（人脸 + 聚类 → person_N）
    vlm.py      ollama minicpm-v（场景标签 + is_photo）
  main.py       入口（--embed/--faces/--tags 可组合；--watch 常驻；--limit 调试）
deploy/
  smart-frame-photo-daemon.service  systemd user unit
```

## 安装

```bash
cd services/photo_indexer
uv sync                   # Python 3.12 + 依赖（含 GPU torch cu126）
ollama pull minicpm-v     # VLM（仅 --tags 时需要）
```
模型首次自动下载：dinov2/CLIP（HuggingFace）、buffalo_l（insightface）。

## 跑

```bash
# 调试：小批
uv run python -m smart_frame_photo_daemon --embed --limit 10

# 全量一遍
uv run python -m smart_frame_photo_daemon --embed --faces --tags

# 常驻（systemd 或 nohup）
uv run python -m smart_frame_photo_daemon --watch --embed
```

## 共享 SQLite

`~/.local/share/com.example.smart_frame/photo_index.db`（与 app 同文件）。

- `photos`：`id`(=WebDAV path, PK)、`sha256`、`embedding_dinov2`/`embedding_clip`、`tags`、`caption`（简短照片解说）、`location_name`、`is_photo`、`hidden`、`reason`、`quality_score`、`width`/`height`、`taken_at`、`thumb_path`…
- `faces`：`photo_id`、`subject_name`(person_0/1/…，内部聚类 ID)、`face_embedding`、`bbox`
- `person_profiles`：`subject_name` → `identity_label`（如“爷爷”“弟弟”）；只有 `confirmed=1` 的家长确认映射才会显示或传给 VLM，不存姓名。

app 的 `PhotoIndexService`（apps/smart_frame/lib/features/photos/application/photo_index_service.dart）只读此库：`hidden=1` → `setHidden` 播放跳过；`tags`/`faces` → 筛选；`person_profiles` → 照片故事中的家庭身份。VLM 按“已确认人物、地点、事件/动作、画面细节”生成第三人称解说。

## systemd 常驻

```bash
mkdir -p ~/.config/systemd/user
cp ../../deploy/smart-frame-photo-daemon.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now smart-frame-photo-daemon
loginctl enable-linger $USER        # 退出登录后继续跑
# 日志：~/.local/share/com.example.smart_frame/daemon.log
```

## 速度（GTX 1070 Ti）

- dinov2 + CLIP（GPU）：~1s/张（瓶颈在 NAS WebDAV 下载）
- insightface（CPU）：~1-2s/张
- VLM minicpm-v（GPU via ollama）：~3s/张
- 7.2 万张：dinov2/clip ~20h；全套（+faces/tags）~100h → 建议分模型/分批，`--watch` 断点续传不怕中断。
