# 作业 Agent 自动检查阶段 C——兼容 Kimi K3 与 GLM

状态：已完成（2026-07-24；用户确认 K3 为 Kimi 具体模型）

基线提交：`53c8019 feat(student): 跑通 Android 作业拍照提交闭环`

依据：[家庭作业 Agent 原型规格](../specs/2026-07-24-family-homework-agent-prototype.md)

官方接口依据：

- [Kimi API](https://www.kimi.com/help/kimi-api/api-overview) 使用 OpenAI-compatible Chat
  Completions；K3 model id 为 `kimi-k3`，原生支持视觉。默认 base URL：
  `https://api.moonshot.ai/v1`。
- [智谱 OpenAI SDK 兼容说明](https://docs.bigmodel.cn/cn/guide/develop/openai/introduction)中的
  通用 base URL 为 `https://open.bigmodel.cn/api/paas/v4`；视觉模型示例
  `glm-5v-turbo`，支持 `data:image/...;base64,...` 图像输入。

## 1. 本阶段目标

在现有“学生提交、家长人工审核”之间加入可选的 Agent 检查：家长在作业中心对某次提交
点击“Agent 检查”，明确授权把该次作业图片、任务要求、参考答案和评分标准发送到已配置的
云端模型。模型输出保存为可审计的结构化检查建议，家长确认后仍使用既有 accept/retry 流程。

本阶段不让模型直接改变任务状态，不把完整答案或模型内部原始回复发送给孩子，也不在未授权
时自动上传家庭图片。

## 2. 模型配置与授权

环境变量：

| 字段 | 默认值 | 含义 |
|---|---|---|
| `HOME_AGENT_HOMEWORK_MODEL_ENABLED` | `false` | 云端图片发送总开关 |
| `HOME_AGENT_HOMEWORK_MODEL_BASE_URL` | `https://api.moonshot.ai/v1` | OpenAI-compatible base URL |
| `HOME_AGENT_HOMEWORK_MODEL_API_KEY` | 空 | 只从本地环境读取，不经 API 返回 |
| `HOME_AGENT_HOMEWORK_MODEL_NAME` | `kimi-k3` | 当前启用模型；可改 `glm-5v-turbo` |
| `HOME_AGENT_HOMEWORK_MODEL_TIMEOUT_SECONDS` | `90` | 单次检查超时 |

`enabled=true`、key 非空、base URL 与 model 非空才视为 configured。家长状态 API 只返回 enabled、
configured、base URL host 和 model，不返回 key。阶段 C 的每一次真实发送仍需家长点击触发；以后
如增加自动检查，必须另设显式授权开关。

## 3. 数据模型

新增 Alembic `0004_homework_inspections`：

| 字段 | 含义 |
|---|---|
| id / household_id / submission_id | 家庭隔离与提交关联 |
| requested_by | 触发检查的家长 |
| status | `running/completed/needs_parent_review/failed` |
| model_name / prompt_version | 可审计的模型与提示版本，不保存 key |
| image_quality / summary / confidence | 总体判断 |
| suggested_decision | `accept/retry/review`，仅建议 |
| items_json | 错误位置、问题、提示、类似例子、步骤、置信度 |
| error_code | 归一化失败码，不保存供应商原始响应 |
| created_at / completed_at | 检查时间 |

允许同一 submission 重试检查并保留多条记录，不覆盖历史。

## 4. 结构化结果

模型必须只返回 JSON：

```json
{
  "imageQuality": "clear|unclear|incomplete",
  "summary": "给家长的总体完成质量摘要",
  "confidence": 0.0,
  "suggestedDecision": "accept|retry|review",
  "items": [
    {
      "location": "第3题",
      "issue": "需要检查的部分",
      "hint": "只给思路",
      "similarExample": "不复用原题数字的类似例子",
      "steps": ["第一步", "第二步"],
      "confidence": 0.0
    }
  ]
}
```

服务端使用 Pydantic 严格解析并限制长度/数量；拒绝 markdown 外壳之外的额外文本、未知字段、
越界 confidence、未知枚举或超过 100 项。解析失败归一化为 `invalid_model_output`。输出 schema
不含 `answer/fullAnswer/correctAnswer`，提示词明确禁止复述完整参考答案。

规则：图片不清/不全、总体 confidence < 0.75、任一 item confidence < 0.65，或模型建议 review，
服务端状态一律 `needs_parent_review`；否则为 `completed`。这两个状态只描述“检查记录”，不改变
作业任务或提交状态。

## 5. 模型客户端

直接使用现有 `httpx`，调用 `<baseUrl>/chat/completions`：

- `Authorization: Bearer <key>`，JSON 请求，非流式。
- system message 固定安全与 JSON 规则。
- user content 由文本说明和本地预处理后的 `data:image/jpeg;base64,<bytes>` 组成；原图不修改。
- 不启用厂商专属 thinking/response_format 参数，保证 Kimi/GLM 最小公共兼容面。
- 只读取 `choices[0].message.content`；供应商错误归一化为 timeout/auth/rate_limited/
  provider_error，不把响应正文返回浏览器或写日志。
- 发送前再次用受约束路径解析图片，不接受客户端路径。

## 6. API 与家长 Web

全部要求当前家长 bearer：

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/v1/homework/model-status` | 安全展示模型开关、configured、host、model |
| POST | `/api/v1/homework/submissions/{id}/inspect` | 明确授权并同步执行一次检查 |
| GET | `/api/v1/homework/submissions/{id}/inspections` | 查看不可覆盖的检查历史 |

家长 Web 在提交记录中显示模型状态和“Agent 检查”按钮。点击前提示将把本次图片、作业要求、
参考答案和评分标准发送给配置的云端模型；结果展示图片质量、置信度、建议、每一处问题、提示、类似例子和步骤。
模型建议不能自动点击“确认完成/要求重做”，家长仍需人工决定并可自行填写审核摘要。

## 7. 测试与验收

- 默认 disabled、缺 key、非法 base URL 不发网络请求。
- 请求格式包含所有图片 data URL、任务要求、参考答案/评分标准，但测试日志不含 key/图片。
- Kimi/GLM 共用 fake OpenAI-compatible 端点成功解析。
- 401、429、5xx、超时、非法 JSON、未知字段和越界结果安全降级。
- 图片路径逃逸继续被拒绝；A 家庭不能检查 B 家庭提交。
- 多次检查保留历史；模型检查不改变 task/submission 状态。
- 家长页面无 key，结构化字段全部转义，失败后仍可人工审核。
- Home Agent、学生端、现有智能屏与 node_protocol 全量门禁保持通过。

## 8. 非目标

- 学生提交后自动外发图片、后台持久队列和自动重试。
- Agent 自动代表家长 accept/retry。
- 向孩子展示完整参考答案。
- 长期能力画像、学习计划、语音讲题和微信通知。
- 厂商专属工具调用、联网搜索或 thinking 参数。

## 9. 实施结果

- 已新增 `homework_inspections` 迁移、OpenAI-compatible 视觉客户端、严格结果 schema、检查服务、
  家长 API 与 Web 授权/展示闭环。
- 已覆盖成功、低置信度、失败持久化、禁用/未配置、HTTP 错误、超时、非法输出、图片预处理、
  状态隔离及密钥不泄漏；测试只使用 fake provider，未消耗真实 API。
- 验收通过：Home Agent ruff/mypy/43 tests（94.3% coverage）、智能屏 analyze/78 tests、
  node_protocol analyze/2 tests、学生端 analyze/8 tests 和 debug APK 构建。
