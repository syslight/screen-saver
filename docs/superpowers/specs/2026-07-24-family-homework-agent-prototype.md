# 家庭作业 Agent 原型——设计规格

日期：2026-07-24
状态：已获用户批准

## 1. 背景与长期方向

`smart_frame` 已具备智能屏、Web 控制台、语音链路、照片管理和计算节点。长期方向是在此基础上建立“家庭智能管家平台”：一个家庭 Agent 中枢通过受限工具调用作业、提醒、对话、摄像头和其他家庭能力，智能屏、家长端和未来的房间终端均为客户端。

本规格依赖 [家庭 Agent 基础设施规格](2026-07-24-home-agent-foundation.md)；共用的节点、身份、语音、归档、认证和模型路由以该规格为权威来源。

长期愿景不属于本期交付。本规格只定义第一个可验证的纵向闭环：**10 岁孩子的纸质数学作业录入、提交、Agent 检查和家长报告**。

## 2. 已确认的产品决策

- 家庭成员：2 位同权限家长、2 位孩子（5 岁、10 岁）、1 位老人。
- 原型先服务 10 岁孩子，5 岁儿童的图片/语音交互不在本期实现。
- 作业来源本期仅支持家长手动录入。拍照识别布置、微信转发、口头布置和自动学习计划为后续能力。
- 本期核心场景是纸质数学作业拍照检查；家长可填写要求、参考答案或评分标准。
- 辅导遵循固定梯度：指出需检查部分 → 给思路 → 给类似例子 → 分步引导。本期不自动展示完整答案。
- 家长端本期仅扩展现有 Web 控制台。原生 App 和微信只预留通知/客户端边界。
- Agent 运行在家庭服务器的独立 Python 服务中；Flutter App 不内置 Agent 推理。
- 模型通过可替换的 provider 适配器调用。原型可使用 OpenAI 兼容视觉 API，后续可切换本地模型或混合模式。

## 3. 原型目标

1. 家长能在 Web 控制台创建、查看和关闭作业任务。
2. 公共智能屏和学生 Android App 能显示当日待完成作业和当前状态。
3. 孩子能在学生 App 开始任务，并使用平板摄像头拍摄/上传纸质作业照片。
4. Agent 能结合任务要求、参考信息和提交图片输出结构化检查结果。
5. 孩子能看到不直接泄露完整答案的改进提示。
6. 家长能查看原始提交、Agent 判断、不确定项和整体完成质量，并可确认或纠正结果。
7. 任务与 Agent 工具调用有可追溯的事件记录。

## 4. 非目标

本期明确不实现：

- 本作业子项目不重复实现人脸/声纹、房间节点或家庭历史；它们由基础设施独立交付。
- 根据在场或专注状态自动判定作业完成。
- 语音朗读、背诵、手工、绘画、运动等非纸质数学作业的检查。
- 作业来源自动解析、微信接入和家长原生应用；学生 Android App 属于本期交付。
- Agent 自主制定正式学习计划，或根据单次作业形成长期能力结论。
- 老人陪聊、主动情绪管理、多房间对话迁移。
- Agent 人格、声音、记忆保留周期和家庭详细提醒规则的最终产品定义。
- 模型训练、微调或根据家庭数据更新模型参数。

## 5. 总体架构

```text
家长 Web 控制台              学生 Android App / 智能屏
  创建/查看/审核作业          查看/开始/提交/接收提示
          │                              │
          └────── HTTP / WebSocket ──────┘
                         │
                  Home Agent Server
           API / 任务 / 工具 / 审计 / 模型适配
                         │
              ┌──────────┤──────────┐
              │                     │
       SQLite + 本地文件       Vision Model Provider
       任务/提交/报告          本地或云端
```

### 5.1 部署边界

- Home Agent Server 是家庭业务的权威数据源。
- Flutter 终端不直接读写 Agent 数据库，仅通过版本化 API 交互。
- 作业原图保存在家庭服务器本地。是否将图像发送给云端由 provider 和运行配置决定。
- Home Agent Server 使用新的顶层 `home_agent/` Python 项目；与现有照片 daemon 的环境、数据库和生命周期分离。

### 5.2 Agent 边界

Agent 不获得数据库、文件系统或 shell 的通用访问权。Agent 只能调用经服务注册的结构化工具：

| 工具 | 用途 | 写操作 |
|---|---|---|
| `homework.list` | 查询任务 | 否 |
| `homework.get` | 读取任务要求与参考信息 | 否 |
| `homework.start` | 记录开始 | 是 |
| `homework.submit` | 建立提交并关联图片 | 是 |
| `homework.inspect` | 调用视觉模型并产生检查结果 | 是 |
| `homework.request_review` | 将不确定结果提交家长 | 是 |

所有写工具必须校验参数、当前状态和调用者角色，并记录审计事件。

## 6. 原型业务流程

### 6.1 家长录入

1. 家长在 Web 控制台创建任务。
2. 必填：标题、所属日期、任务说明。
3. 可选：截止时间、参考答案、评分要求。
4. 任务创建后进入 `pending`。

### 6.2 孩子执行与提交

1. 智能屏显示今日 `pending` / `in_progress` 任务。
2. 孩子点击或说“开始数学作业”，任务进入 `in_progress`。
3. 孩子完成后点击或说“提交作业”。
4. 原型允许从智能屏选择/拍摄图片，也允许家长从 Web 上传，两者走相同提交 API。
5. 服务器完成文件类型、大小和归属校验后，建立不可变提交版本。

### 6.3 Agent 检查

1. 服务器建立检查作业，状态进入 `checking`。
2. provider 接收任务说明、参考信息和提交图像，返回约束 JSON，不允许自由文本直接写入业务状态。
3. 服务器校验 schema；校验失败可有限重试，仍失败则转 `needs_parent_review`。
4. 低置信度、图像不清、题目缺失或标准不足均不得判定正确，转家长确认。
5. 检查结果向孩子暴露的只是问题位置和第一级提示；家长端可看完整判断与模型原始响应的受控调试视图。

### 6.4 家长审核

1. 家长查看提交原图、分项结果、总体评价和不确定项。
2. 家长可接受结果、修正分项判断或要求重新提交。
3. 审核后任务进入 `completed` 或回到 `in_progress`。
4. 每次审核保留操作者、时间和前后差异。

## 7. 状态模型

```text
pending ──▶ in_progress ──▶ submitted ──▶ checking
   │              ▲                         │
   └──▶ cancelled  │                         ├──▶ needs_parent_review
                  └── resubmit ◀────────────┘
                                             │
                                             └──▶ completed
```

- `pending`：已录入，未开始。
- `in_progress`：已开始或被要求重新提交。
- `submitted`：提交已持久化，等待检查作业取走。
- `checking`：模型检查中。
- `needs_parent_review`：模型不确定、执行失败或业务要求家长复核。
- `completed`：家长已确认完成。
- `cancelled`：家长取消。

## 8. 最小数据模型

### `household_members`

- `id`、`display_name`、`role`（`parent` / `child`）、`active`。
- 原型预置 2 位家长和 10 岁孩子；不实现通用家庭成员管理 UI。

### `homework_tasks`

- `id`、`child_id`、`title`、`subject`、`task_date`、`due_at`、`instructions`、`reference_answer`、`rubric`、`status`、`created_by`、`created_at`、`updated_at`。

### `homework_submissions`

- `id`、`task_id`、`attempt_no`、`submitted_by`、`submitted_at`、`status`。
- 每次提交为独立版本，不覆盖上一次。

### `submission_assets`

- `id`、`submission_id`、`media_type`、`local_path`、`sha256`、`size_bytes`、`created_at`。
- 原型仅接受 JPEG / PNG / WebP，服务器不信任客户端的 MIME 声明。

### `inspection_reports`

- `id`、`submission_id`、`provider`、`model`、`status`、`confidence`、`summary`、`quality_level`、`items_json`、`child_hint`、`uncertainties_json`、`created_at`。
- `items_json` 每项至少包含题号/区域、判断、置信度、说明和提示级别。

### `homework_events`

- `id`、`task_id`、`submission_id`、`actor_type`、`actor_id`、`event_type`、`payload_json`、`created_at`。
- 用于业务追溯，不代替当前状态表。

## 9. API 边界（原型）

所有端点属于 `/api/v1/homework`，避免与当前照片 API 混杂。

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/tasks?childId=&date=` | 查询某日任务 |
| `POST` | `/tasks` | 家长创建任务 |
| `GET` | `/tasks/{id}` | 任务详情 |
| `POST` | `/tasks/{id}/start` | 开始任务 |
| `POST` | `/tasks/{id}/submissions` | multipart 建立提交 |
| `GET` | `/tasks/{id}/submissions` | 提交历史 |
| `GET` | `/submissions/{id}/report` | 检查报告 |
| `POST` | `/submissions/{id}/review` | 家长确认/纠正/驳回 |
| `GET` | `/events?taskId=` | 任务事件记录 |

原型期间可由当前 `ControlServer` 代理这些 API，但业务实现和数据必须属于 Home Agent Server。Flutter/Web 不得绕过 API 直连 SQLite。

## 10. 检查输出约束

provider 的结果必须通过 schema 校验，最少表达：

```json
{
  "status": "checked|uncertain|unreadable",
  "qualityLevel": "excellent|good|needs_revision|unknown",
  "confidence": 0.0,
  "summary": "",
  "items": [
    {
      "label": "第3题",
      "verdict": "correct|incorrect|uncertain|missing",
      "confidence": 0.0,
      "reason": "",
      "hint": ""
    }
  ],
  "childHint": "",
  "uncertainties": []
}
```

服务器必须自己决定业务状态，不得让模型输出直接修改任务。

## 11. 原型权限与安全底线

- 家长：创建、取消、审核和纠正。
- 孩子：查看、开始和提交；不能修改任务要求或参考答案。
- 对孩子的默认输出不含完整参考答案。
- 所有模型结果均标记为 AI 检查，家长纠正不被后续重跑覆盖。
- 本地文件使用服务生成的 id 寻址，不接受客户端传入任意保存路径。
- 上传必须有单文件大小、单次数量和总配额限制；具体数值在实施计划中确定。
- provider 日志不记录原始图像、参考答案或完整提示词。

## 12. 失败与降级

| 场景 | 行为 |
|---|---|
| Agent Server 不可达 | 智能屏保留相册/天气等现有功能；作业区显示离线 |
| provider 未配置 | 提交可保存，状态转家长复核，不丢失图片 |
| provider 超时/失败 | 有限重试后转家长复核 |
| 图片不清或页面不全 | 要求重拍，不给出猜测结论 |
| 无参考答案且模型无法判定 | 标记不确定，请家长复核 |
| 重复提交 | 创建新 attempt，不覆盖旧报告 |

## 13. 测试策略

### Python

- 状态机合法/非法转换。
- 任务、提交、报告和事件的持久化。
- 文件类型、大小、数量、路径穿越与重复请求。
- provider 假实现：成功、不确定、非法 JSON、超时和异常。
- 家长/孩子权限边界。

### Dart / Web

- 任务 API client 的解析和错误降级。
- 当日任务展示、状态更新和提交流程。
- Web 录入必填项、审核操作和失败反馈。
- 既有 `flutter analyze` 无问题，既有 `flutter test` 保持全绿。

## 14. 原型验收场景

1. 家长创建“数学练习第 10 页 1—6 题”，填写参考答案。
2. 智能屏显示该任务，孩子开始作业。
3. 孩子完成后上传一张或多张作业照片。
4. Agent 输出分项检查、总体质量和第一级提示；不确定项明确标记。
5. 家长在 Web 查看报告，修正一项判断并要求孩子重新提交。
6. 第二次提交保留为新版本，家长确认后任务完成。
7. 事件记录能还原创建、开始、两次提交、Agent 检查和家长审核过程。

## 15. 延后到后续规格的问题

下列事项有意不在原型建设阶段定死：

- Agent 名称、形象、声音、人格和对不同成员的说话方式。
- 长期记忆和情绪信息的产品保留策略；房间音视频归档按基础设施规格执行。
- 主动对话、作业延后、通知升级和家庭静音时段。
- 用在场或专注判断自动认定作业完成。
- 微信和原生家长 App 的具体实现。
- 长期学习档案、能力模型、计划生成与效果评估。

## 16. 实施前仍需确认

在进入实施计划前，只需再确认以下与原型直接相关的信息：

1. 学生 Android 平板的型号、Android 版本与前/后摄像头能力。
2. 原型实际配置的 GLM/Kimi/K3 端点、模型 ID 和通过能力检测的项目。
3. 作业业务实施阶段依赖的基础设施版本与已可用能力。
4. 作业图片的单文件大小、单次数量和家庭总配额。

这四项会改变代码边界、依赖或验收方式，不应在实施时由开发者自行假设。
