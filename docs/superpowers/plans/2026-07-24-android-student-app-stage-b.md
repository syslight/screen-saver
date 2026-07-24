# Android 学生端阶段 B——配对、拍照提交与审核结果

状态：已完成（用户已批准“按建议”执行）

基线提交：`0ee9831 feat(homework): 建立家长管理与人工审核闭环`

依据：[家庭作业 Agent 原型规格](../specs/2026-07-24-family-homework-agent-prototype.md)

## 1. 目标

交付独立的 Flutter Android 学生端 `student_app/`，先绑定 10 岁孩子，在同一 Wi-Fi
内连接家庭服务器，完成以下闭环：

1. 家长选择孩子并生成短时一次性学生设备配对码。
2. 平板输入服务器地址与配对码，换取只显示一次的设备密钥并安全保存。
3. 学生查看自己的作业，开始任务，调用平板摄像头连续拍摄最多 6 页。
4. 学生预览、删除或重拍后提交，服务器保留不可覆盖的 attempt。
5. 学生看到“等待家长检查”“已完成”或“需要重做”及家长反馈。

## 2. 已确认决策

- 学生端是独立 Flutter 工程，不把学生模式塞进现有智能屏 App。
- 第一台平板绑定 10 岁孩子；设备不能自行切换孩子。
- 更换孩子必须由家长撤销设备，再为目标孩子生成新配对码。
- 原型仅允许同一可信 Wi-Fi 内使用 HTTP，不得映射到公网；HTTPS 后续补齐。
- 第一版不接语音、自动检查、完整答案、学习计划或远程推送。
- 学生端只能读取自己的任务、开始任务、创建图片提交和读取自己的审核结果。

## 3. 服务端数据与认证

新增 Alembic `0003_student_devices`：

| 表 | 关键字段 | 约束 |
|---|---|---|
| `student_pairing_codes` | household_id, child_id, code_hash, expires_at, used_at, created_by | code 仅存 hash，一次使用 |
| `student_devices` | household_id, child_id, name, platform, device_key_hash, active, last_seen_at | key 仅存 hash；设备固定绑定孩子 |

设备请求使用 `Authorization: Student <device-key>`。密钥是长随机值，只在配对成功时
返回一次；数据库、日志和审计均不记录明文。

家长可创建配对码、查看设备和撤销设备。撤销后旧密钥立即失效，恢复只能重新配对。

## 4. API

### 家长权限

| 方法 | 路径 | 用途 |
|---|---|---|
| POST | `/api/v1/homework/student-pairing-codes` | 为指定 active child 创建配对码 |
| GET | `/api/v1/homework/student-devices` | 查看学生设备及绑定成员 |
| POST | `/api/v1/homework/student-devices/{id}/revoke` | 撤销学生设备 |

### 学生设备权限

| 方法 | 路径 | 用途 |
|---|---|---|
| POST | `/api/v1/student/pair` | 消费配对码，换取设备密钥 |
| GET | `/api/v1/student/me` | 获取绑定孩子与设备信息 |
| GET | `/api/v1/student/homework/tasks` | 只查询绑定孩子的任务 |
| GET | `/api/v1/student/homework/tasks/{id}` | 读取自己的任务详情 |
| POST | `/api/v1/student/homework/tasks/{id}/start` | 开始自己的 pending 任务 |
| GET | `/api/v1/student/homework/tasks/{id}/submissions` | 查询自己的提交与家长反馈 |
| POST | `/api/v1/student/homework/tasks/{id}/submissions` | 上传 1–6 张作业图片 |

学生任务响应明确不包含 `referenceAnswer`、`rubric`、家长账号、其他孩子信息和内部图片
路径。所有查询先按 device 的 `household_id + child_id` 双重限定。

## 5. Android 应用

目录：`student_app/`

- `StudentApi`：HTTP、JSON、multipart、统一错误映射。
- `DeviceCredentialStore`：设备密钥使用 Android Keystore 支持的 secure storage；服务器
  地址使用普通偏好设置。
- 配对页：服务器地址、一次性配对码、设备名；校验局域网 HTTP/HTTPS URL。
- 作业首页：状态分组、下拉刷新、离线/未配对/空任务状态。
- 详情页：要求、截止时间、开始按钮、提交历史和家长反馈。
- 拍照页：调用系统相机逐页拍摄，最多 6 张，缩略图预览、删除、重新拍摄、提交进度。
- 失效凭据：遇到 401 清除设备密钥并回到配对页，不自动使用家长身份。

Android 原型声明 `INTERNET`、`CAMERA`，并仅为局域网原型允许 cleartext；文档醒目标注
不得公网暴露。

## 6. 状态与交互

| 服务端状态 | 学生文案 | 可执行操作 |
|---|---|---|
| `pending` | 待开始 | 开始 |
| `in_progress` 且无 retry | 进行中 | 拍照提交 |
| `needs_parent_review` | 等待家长检查 | 查看本次提交 |
| `in_progress` 且最新提交 `changes_requested` | 需要重做 | 查看反馈、重新拍照提交 |
| `completed` | 已完成 | 查看反馈 |
| `cancelled` | 已取消 | 无 |

提交时保持在当前页面并显示进度；成功后立即清空本地临时列表并刷新服务端状态；失败则
保留照片便于重试。应用重启后不保证恢复未提交照片，避免把作业图片长期复制到应用目录。

## 7. 测试与验收

服务端：

- 配对码错误、过期、重复消费和并发消费。
- 设备密钥 hash 存储、撤销立即失效、日志/响应不泄露。
- A 孩子设备不能读取、开始、提交 B 孩子的任务。
- 学生响应不包含参考答案和评分标准。
- start 状态限制、提交图片限制、retry 后第二 attempt、completed/cancelled 拒绝提交。

Flutter：

- URL 规范化与凭据状态。
- JSON 模型和状态文案。
- HTTP 成功、统一错误、401 失效、multipart 字段。
- 配对页、任务空状态、任务卡片、拍照上限和提交失败保留照片的 widget/controller 测试。

门禁：

```bash
cd home_agent
uv sync --frozen
uv run ruff check .
uv run ruff format --check .
uv run mypy src
uv run pytest

cd student_app
/home/peidong/flutter/bin/flutter analyze
/home/peidong/flutter/bin/flutter test
/home/peidong/flutter/bin/flutter build apk --debug

/home/peidong/flutter/bin/flutter analyze
/home/peidong/flutter/bin/flutter test
```

现有 `packages/node_protocol` 的 analyze/test 也必须保持通过。

## 8. 非目标与后续

- HTTPS、远程访问和证书自动配置。
- 人脸/声纹自动切换孩子。
- 语音开始/提交、作业提醒和主动对话。
- GLM、Kimi、K3 视觉检查与家长授权后展示完整答案。
- iOS、Flutter 家长 App 和微信通知。

## 9. 完成记录

2026-07-24 已完成阶段 B：新增学生配对码与设备表、独立学生 device key、家长设备管理、
按孩子隔离的学生作业 API，以及独立 Flutter Android App。学生端支持配对、任务列表、开始、
相机逐页拍摄、最多 6 张预览/删除、multipart 提交、家长反馈、401 自动清除失效凭据；Android
manifest 声明相机/网络、最低 API 23、禁用备份，并为可信局域网原型允许 cleartext。

验证结果：Home Agent 26 个测试通过、覆盖率 93.91%；学生端 analyze 无问题且 8 个测试通过；
debug APK 构建成功；现有智能屏 78 个测试和 node_protocol 2 个合约测试保持全绿。尚未在实际
学习平板上完成安装、镜头清晰度和权限弹窗验收，作为下一轮硬件联调项保留。
