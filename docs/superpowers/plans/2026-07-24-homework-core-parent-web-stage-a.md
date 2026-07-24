# 家庭作业闭环 A——服务端与家长 Web 实施计划

日期：2026-07-24
状态：已完成（用户批准后实施）
依据：[家庭作业 Agent 原型规格](../specs/2026-07-24-family-homework-agent-prototype.md)

## 1. 目标

在 USB 摄像头和麦克风阵列到货前，先交付不依赖硬件和模型的可用作业管理闭环：

1. 家长在 Home Agent 自带的 `/parent/` 页面登录。
2. 家长初始化家庭成员，至少包含 5 岁和 10 岁两个孩子。
3. 家长为 10 岁孩子手动创建、查看、修改和取消纸质数学作业。
4. 家长可代孩子上传一次或多次作业图片，提交版本不可覆盖。
5. 未配置模型时提交直接进入家长审核，家长可确认完成或要求重做。
6. 每次成员、任务、提交和审核写入业务事件与全局审计。
7. 现有智能屏 Web 控制台只增加家长中心入口，不承载家庭 Agent 认证状态。

本阶段不实现学生 Android App、模型调用、参考答案展示、自动评分、通知和真实房间硬件。

## 2. 已批准产品决策

- 家长 Web 由 Home Agent Server 在 `/parent/` 提供，使用现有家长 bearer session。
- 家庭成员通过初始化页面录入，不在代码中写死姓名；角色支持 parent/child/elder。
- 图片限制：单张 12 MiB、每次最多 6 张、家庭作业图片总配额 5 GiB。
- 原图只保存在家庭服务器；数据库保存服务生成路径、SHA-256、大小和媒体类型。
- provider 未接入时不伪造 AI 结果，提交状态明确为 `needs_parent_review`。

## 3. 数据库迁移

新增 Alembic `0002_homework_core`：

| 表 | 关键字段 |
|---|---|
| `household_members` | household_id, display_name, role, age, active |
| `homework_tasks` | household_id, child_id, title, subject, task_date, due_at, instructions, reference_answer, rubric, status, created_by |
| `homework_submissions` | household_id, task_id, attempt_no, submitted_by, status, submitted_at |
| `submission_assets` | household_id, submission_id, media_type, local_path, sha256, size_bytes |
| `homework_reviews` | household_id, submission_id, reviewer_id, decision, summary, quality_level, items_json |
| `homework_events` | household_id, task_id, submission_id, actor_type/id, event_type, payload_json |

约束：

- child_id 必须由 service 验证属于同一 household、role=child、active=true。
- `(task_id, attempt_no)` 唯一；每次提交新建 attempt。
- `(submission_id, local_path)` 唯一；路径只由服务生成。
- 所有 repository 查询显式带 household_id。

## 4. 状态机

本阶段允许：

```text
pending → in_progress → needs_parent_review → completed
    │           ▲                 │
    └→ cancelled                  └→ in_progress（要求重做）
```

- 创建后 `pending`。
- 家长可代孩子执行 start；未来学生端复用同一 service。
- 上传成功后提交和任务均进入 `needs_parent_review`。
- `accept`：任务进入 `completed`，提交进入 `accepted`。
- `retry`：任务回到 `in_progress`，提交进入 `changes_requested`。
- completed/cancelled 不允许继续上传；非法转换返回结构化 409。

## 5. HTTP API

全部使用 `/api/v1/homework`，除图片下载外均为 JSON：

| 方法 | 路径 | 用途 |
|---|---|---|
| GET/POST | `/members` | 查询/创建成员 |
| PATCH | `/members/{id}` | 修改姓名、年龄或 active |
| GET/POST | `/tasks` | 按 child/date/status 查询；家长创建 |
| GET/PATCH | `/tasks/{id}` | 详情；仅 pending/in_progress 可修改内容 |
| POST | `/tasks/{id}/start` | 开始任务 |
| POST | `/tasks/{id}/cancel` | 家长取消 |
| GET/POST | `/tasks/{id}/submissions` | 提交历史；multipart 图片提交 |
| GET | `/assets/{id}` | 经家长认证下载原图 |
| POST | `/submissions/{id}/review` | `accept` 或 `retry` 人工审核 |
| GET | `/events?taskId=` | 按任务查询事件 |

上传先写同数据目录临时文件，完成魔数/解码、大小、数量和配额检查后原子移动；失败清理临时文件。
只接受 JPEG、PNG、WebP，不信任扩展名或客户端 MIME。

## 6. 家长 Web

单页原生 HTML/CSS/JS，随 Home Agent Python package 打包：

- 未初始化：家庭 bootstrap 表单。
- 已初始化但未登录：家长登录。
- 成员区：录入/查看家庭成员。
- 作业区：按日期查看，创建任务，查看详情和取消。
- 提交区：选择最多 6 张图片，显示上传大小和历史 attempt。
- 审核区：查看受保护原图，填写总结和质量，确认完成或要求重做。
- token 仅保存在 `sessionStorage`；401 时清除并回登录页。
- 页面不显示 reference_answer 给孩子；本阶段页面本身仅属于家长端。

## 7. 文件边界

可修改：

- `home_agent/**`
- `web_console/index.html`（仅增加链接）
- `README.md`、`AGENTS.md`、`docs/**`

不修改：

- 现有 Flutter `lib/**` 业务逻辑
- `daemon/**`
- Android 学生 App（尚未创建）
- Node WebSocket 协议（本阶段不需要新节点消息）

## 8. 测试与验收

Python：

- migration 从 0001 升到 0002并回退。
- household 隔离、成员角色、任务状态机和非法转换。
- 重复提交 attempt、不可变历史和人工审核。
- JPEG/PNG/WebP 成功；伪 MIME、损坏图片、超 12 MiB、超过 6 张、配额、路径穿越失败。
- 无 token、撤销 token和跨家庭 id 不可读取任务或原图。
- `/parent/` 页面可访问且不包含真实凭据。

全量门禁：

```bash
cd home_agent
uv sync --frozen
uv run ruff check .
uv run ruff format --check .
uv run mypy src
uv run pytest --cov=home_agent --cov=linux_room_node

cd ../packages/node_protocol
/home/peidong/flutter/bin/dart analyze
/home/peidong/flutter/bin/dart test

cd ../..
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  -u ALL_PROXY -u all_proxy /home/peidong/flutter/bin/flutter analyze
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  -u ALL_PROXY -u all_proxy /home/peidong/flutter/bin/flutter test
git diff --check
```

## 9. 延后事项

- 学生 Android App、孩子会话和摄像头拍摄。
- GLM/Kimi/K3 registry、视觉检查和结构化报告。
- TLS/局域网正式接入。
- 微信通知、家长原生 App和长期学习档案。

未经用户确认，不执行 git commit 或 push。

## 10. 完成记录

2026-07-24 已完成阶段 A：第二版迁移、成员与作业 repository/service、人工审核状态机、
受保护图片存储与下载、Home Agent `/parent/` 家长页面，以及智能屏控制台入口。模型、学生
Android App和真实硬件均未混入本阶段。最终验证结果以本次实施交付记录为准。
