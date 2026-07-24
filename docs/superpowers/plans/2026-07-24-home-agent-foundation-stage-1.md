# 家庭 Agent 基础设施——阶段 1 实施计划

日期：2026-07-24
状态：已完成（用户批准后实施）
依据：[家庭 Agent 基础设施规格](../specs/2026-07-24-home-agent-foundation.md)

## 1. 阶段目标

建立可独立运行和测试的 Home Agent Server 与 Fake Room Node，验证未来所有房间节点共用的基础边界：

1. 独立 Python 3.12 + uv 项目。
2. 版本化 HTTP/WebSocket 节点协议。
3. 家庭初始化、2 位家长账号的最小认证。
4. 一次性配对码、设备凭据、节点注册和断线重连。
5. 独立 SQLite/WAL 持久化与审计事件。
6. 假节点与端到端合约测试。

本阶段不访问真实摄像头、麦克风、扬声器或 GPU，也不调用 GLM/Kimi/K3。

## 2. 技术选型

| 领域 | 选择 | 原因 |
|---|---|---|
| 运行时 | Python 3.12 + uv | 与现有 Python 工程一致，但环境独立 |
| HTTP/WS | FastAPI + Uvicorn | 同时支持版本化 REST、WebSocket 和 OpenAPI |
| Schema | Pydantic v2 | 所有入站/出站消息严格校验 |
| 数据库 | SQLAlchemy 2 + aiosqlite | 异步 SQLite，通过 repository 隔离持久化 |
| 迁移 | Alembic | 显式 schema 版本，不在启动时隐式改表 |
| 密码 | Argon2id | 只存储强哈希，不保存明文 |
| 会话 | 服务端保存的不透明 token | 便于立即撤销，原型不引入 JWT 刷新复杂度 |
| 测试 | pytest + pytest-asyncio + httpx | 单测、API 和 WS 端到端 |
| 质量 | Ruff + mypy | 格式、lint 和静态类型检查 |

具体依赖版本在实施时由 `uv add` 生成 lockfile，不手写未验证的版本号。

## 3. 预期目录

```text
home_agent/
  pyproject.toml
  uv.lock
  README.md
  .env.example                 # 只有变量名和假值
  alembic.ini
  migrations/
    env.py
    versions/
      0001_foundation.py
  src/home_agent/
    __init__.py
    config.py
    app.py
    db.py
    domain/
      auth.py
      household.py
      node.py
      audit.py
    repositories/
      auth.py
      household.py
      node.py
      audit.py
    services/
      auth.py
      pairing.py
      node_registry.py
      audit.py
    api/
      dependencies.py
      auth.py
      households.py
      nodes.py
      websocket.py
    protocol/
      envelope.py
      messages.py
      errors.py
  src/linux_room_node/
    __init__.py
    config.py
    fake.py
    client.py
  tests/
    fixtures/
    unit/
    integration/
    contract/
packages/
  node_protocol/
    pubspec.yaml
    lib/
    test/
```

`packages/node_protocol` 首期只实现 Dart 消息模型、解析、版本检查和共享 fixture 合约测试，不连接任何 Flutter App。

## 4. 协议基线

### 4.1 版本和信封

WebSocket 路径：`/api/v1/nodes/ws`。

每个 JSON 消息使用统一信封：

```json
{
  "protocolVersion": 1,
  "messageId": "uuid",
  "sequence": 1,
  "type": "node.hello",
  "sentAt": "2026-07-24T12:00:00Z",
  "nodeId": "uuid-or-null",
  "roomId": "uuid-or-null",
  "sessionId": "uuid-or-null",
  "payload": {}
}
```

- `messageId` 用于去重与追踪。
- `sequence` 在单连接内递增，用于发现丢消息/乱序。
- 未知 `type`、不支持版本、非法 payload 均返回结构化 `error`，不让进程崩溃。
- 序列化时间统一为 UTC ISO-8601；业务展示时再转本地时区。

### 4.2 阶段 1 消息类型

| 方向 | `type` | 用途 |
|---|---|---|
| Node→Server | `node.hello` | 设备信息、版本、room 和凭据 |
| Node→Server | `node.capabilities` | 全量能力快照 |
| 双向 | `heartbeat.ping/pong` | 存活、RTT 和时钟偏差 |
| Server→Node | `command.request` | 使用 `commandName` + 结构化 arguments |
| Node→Server | `command.result` | 成功/失败、结果、错误码 |
| Node→Server | `node.event` | 假设备事件，为后续感知事件预留 |
| 双向 | `error` | 协议、认证和命令错误 |

阶段 1 不定义音频/视频二进制帧细节；只在信封和能力模型中预留 `mediaProtocolVersion`。

### 4.3 能力模型

能力为数组，每项包含：

- `capabilityId`：设备内稳定 ID。
- `type`：如 `camera`、`microphone_array`、`speaker`、`display`。
- `status`：`online` / `busy` / `disabled` / `error`。
- `properties`：按 type 校验的属性。
- `commands`：该能力当前支持的命令列表。

假节点仅实现 `fake.echo`、`fake.set_status` 和可配置的假 camera/microphone/speaker 能力，不访问真实硬件。

## 5. 数据库基线

初始迁移创建：

| 表 | 关键字段 | 说明 |
|---|---|---|
| `households` | id, name, timezone, created_at | 阶段 1 只允许一个 active household |
| `users` | id, household_id, username, password_hash, role, active | 家长账号，不存明文密码 |
| `auth_sessions` | token_hash, user_id, expires_at, revoked_at | 不透明 token 可撤销 |
| `rooms` | id, household_id, name, active | 首期创建客厅 |
| `pairing_codes` | code_hash, household_id, room_id, expires_at, used_at | 一次性、短过期 |
| `nodes` | id, household_id, room_id, name, platform, device_key_hash, status | 不存设备明文密钥 |
| `node_capabilities` | node_id, capability_id, type, status, properties_json | 最新能力快照 |
| `audit_events` | actor_type/id, action, resource_type/id, reason, payload_json, created_at | 认证、配对、节点和管理操作 |

记录 ID 使用 UUID；时间以 UTC 保存。所有与 household 相关的 repository 查询必须显式带 `household_id`，避免以后扩展时发生跨家庭数据泄漏。

## 6. HTTP API 基线

| 方法 | 路径 | 认证 | 用途 |
|---|---|---|---|
| `GET` | `/health/live` | 无 | 进程存活 |
| `GET` | `/health/ready` | 无 | 数据库/迁移就绪 |
| `POST` | `/api/v1/bootstrap` | 仅首次 | 创建 household、客厅和第一位家长 |
| `POST` | `/api/v1/auth/login` | 无 | 家长登录 |
| `POST` | `/api/v1/auth/logout` | 家长 | 撤销当前会话 |
| `POST` | `/api/v1/users` | 家长 | 创建第二位家长 |
| `POST` | `/api/v1/node-pairing-codes` | 家长 | 创建一次性配对码 |
| `POST` | `/api/v1/nodes/pair` | 配对码 | 换取 nodeId 和一次显示的设备凭据 |
| `GET` | `/api/v1/nodes` | 家长 | 节点列表和在线状态 |
| `GET` | `/api/v1/nodes/{id}` | 家长 | 节点详情与能力 |
| `POST` | `/api/v1/nodes/{id}/commands` | 家长 | 向在线假节点发命令 |
| `GET` | `/api/v1/audit-events` | 家长 | 分页查询审计事件 |

`bootstrap` 在家庭已存在后永久返回冲突，不允许远程重置。返回错误统一使用 `code`、`message`、`details`、`requestId`，不将异常堆栈暴露给客户端。

## 7. 认证与密钥处理

- 密码、session token、pairing code 和 device key 只保存 hash。
- token/device key 只在创建时返回明文一次。
- 比较使用常量时间操作；登录和配对接口有按 IP/账号的内存限速。
- 设备 WebSocket 连接首帧必须在超时内完成 `node.hello` 认证，未认证前不接受其他消息。
- 日志、审计 payload、错误和测试快照不得包含明文凭据。
- `.env.example` 只列变量名；真实 `.env` 加入 `.gitignore`。
- 阶段 1 本地测试使用 HTTP/WS；真实局域网部署文档必须明确说明未启用 TLS 时 bearer/device 凭据可被窃听，不得对外网暴露。TLS/反向代理在真实多终端入网前另立任务。

## 8. 实施任务

### Task 1：项目骨架与质量门禁

**新建**：`home_agent/pyproject.toml`、`home_agent/src/...`、`home_agent/tests/...`、`home_agent/README.md`、`home_agent/.env.example`。

1. `uv init --package --python 3.12`，添加运行和开发依赖。
2. 配置 Ruff、mypy、pytest 和 coverage。
3. 实现 `config.py`：数据目录、数据库 URL、session/pairing TTL、日志级别。
4. 补骨架测试：配置默认值、环境覆盖、敏感值不进 repr/log。

**验证**：

```bash
cd home_agent
uv run ruff check .
uv run ruff format --check .
uv run mypy src
uv run pytest
```

### Task 2：SQLite、迁移与 repository

1. 实现数据库 session factory，连接时启用 foreign keys、WAL 和 busy timeout。
2. 建立第一个 Alembic migration，创建第 5 章全部表、约束和索引。
3. 实现 repository 接口与 SQLAlchemy 后端；service 不接触 ORM query。
4. 测试迁移从空库升级/回退、唯一约束、外键、跨 household 查询隔离。

### Task 3：家庭初始化与家长认证

1. 实现密码 hash/verify、安全随机 token 产生和 hash。
2. 实现仅可调一次的 `bootstrap`，原子创建 household、客厅、第一位家长和审计事件。
3. 实现 login/logout、session 过期/撤销和第二位家长创建。
4. 实现 FastAPI 认证依赖和家长权限校验。
5. 测试重复 bootstrap、错误密码、过期/撤销 token、禁用用户、无权访问和日志脱敏。

### Task 4：节点配对与设备凭据

1. 家长创建指定 room 的短时一次性 pairing code。
2. 节点使用 code 交换 `nodeId` + device key，明文 key 仅返回一次。
3. 在同一事务中消费 code、创建 node 和写审计，避免并发重复使用。
4. 测试错误/过期/已使用 code、并发配对、错误 room 和 key 不入日志。

### Task 5：节点协议 Schema

1. 实现 Pydantic 信封、discriminated union 消息和按 capability type 验证的 properties。
2. 所有消息拒绝未声明字段，但对能力 `properties` 保留可版本化扩展策略。
3. 建立 canonical JSON fixtures：每种合法消息、非法版本、缺字段、错 payload。
4. 测试 Python encode/decode 往返和结构化错误。

### Task 6：WebSocket registry 与命令闭环

1. 连接建立后要求 `node.hello`，验证 nodeId/device key、协议版本和节点启用状态。
2. 注册单实例在线连接；新合法连接替换旧连接并记审计。
3. 心跳超时后标记 node offline，但不生成成员离开事件。
4. `node.capabilities` 全量替换该节点快照。
5. HTTP command API 发 `command.request`，以 `messageId` 匹配 `command.result`，带超时和取消。
6. 测试未认证消息、错 key、重连替换、心跳超时、能力替换、命令成功/失败/超时。

### Task 7：Fake Room Node

1. 实现 CLI：配对、凭据持久化、连接、心跳、能力上报、断线指数退避。
2. 假节点声明 camera/microphone_array/speaker，实现 `fake.echo` 命令。
3. 凭据文件权限限制为当前用户读写；CLI 不打印 device key。
4. 测试 Server 重启、Node 重启、网络中断重连和命令往返。

### Task 8：Dart `node_protocol` 合约包

1. 创建独立 Dart package，不依赖 Flutter UI。
2. 实现信封、阶段 1 消息和能力模型。
3. 读取与 Python 相同的 canonical fixtures，验证合法消息和错误 fixture。
4. 添加 package `dart analyze` / `dart test` 验证命令。

### Task 9：集成验收与文档

1. 编写一条可重复的本地演示：Server 启动 → bootstrap → login → 创建 pairing code → Fake Node 配对/上线 → 上报能力 → 发 echo 命令 → 查审计。
2. 添加端到端自动化测试，不依赖外网、GPU 或真实硬件。
3. 同步 `README.md`、`AGENTS.md`、`docs/architecture.md`、`docs/development.md`和本计划的实际偏差。
4. 记录局域网 HTTP 风险，明确阶段 2 真机部署前的 TLS 任务。

## 9. 验证门禁

阶段 1 完成时必须全部通过：

```bash
cd home_agent
uv sync --frozen
uv run ruff check .
uv run ruff format --check .
uv run mypy src
uv run pytest --cov=home_agent --cov=linux_room_node

cd ../packages/node_protocol
/home/peidong/flutter/bin/dart pub get
/home/peidong/flutter/bin/dart analyze
/home/peidong/flutter/bin/dart test

cd ../..
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  -u ALL_PROXY -u all_proxy /home/peidong/flutter/bin/flutter analyze
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  -u ALL_PROXY -u all_proxy /home/peidong/flutter/bin/flutter test
git diff --check
```

Python 覆盖率门槛：总体不低于 85%；认证、配对、协议解析和权限 service 分支覆盖率 100%。覆盖率不代替端到端验收。

## 10. 验收场景

1. 空数据目录启动 Server，`ready` 只在迁移完成后返回成功。
2. 首次 bootstrap 创建家庭、客厅和家长；第二次被拒绝。
3. 家长登录并创建短时配对码。
4. Fake Node 消费配对码后获得一次性设备凭据，连接 WebSocket 并上报三类假能力。
5. 家长在 HTTP API 查到节点在线与能力，发送 `fake.echo`，得到匹配结果。
6. 中断 Fake Node 后 Server 标记 offline；重启节点后使用原凭据自动恢复。
7. 使用过期 code、错 device key、无家长 token 的命令均被拒绝。
8. 审计日志包含 bootstrap、login、pair、connect、disconnect、command，不含任何明文凭据。
9. Python 和 Dart 对同一组 canonical fixtures 解析结果一致。
10. 既有 smart_frame 静态分析和全部 Dart 测试保持全绿。

## 11. 风险与明确延后

- **TLS**：阶段 1 本地测试不部署 PKI；真节点入网前必须完成 TLS/证书方案。
- **媒体协议**：二进制音频帧、片段上传、补传和配额在阶段 2/5 详化。
- **真硬件**：V4L2、ALSA、AEC 和驱动不进入本阶段依赖。
- **Agent/模型**：本阶段不调模型；只保留包边界，避免在设备协议中泄漏厂商语义。
- **媒体加密**：归档文件静态加密在家庭历史阶段实现；阶段 1 不产生真媒体。
- **工作区现状**：开始时必须再次检查未提交改动，只修改本计划声明的新目录和文档，不覆盖既有工作。

## 12. 文件所有权与实施边界

阶段 1 可修改：

- 新建 `home_agent/**`。
- 新建 `packages/node_protocol/**`。
- 同步 `README.md`、`AGENTS.md`、`docs/architecture.md`、`docs/development.md`和本计划。
- 必要的顶层 `.gitignore` 条目。

阶段 1 不修改：

- 现有 `lib/**`、`android/**`、`web_console/**`、`daemon/**` 业务代码。
- 学生/家长 App 代码。
- 真实硬件、ASR/TTS、人脸/声纹、媒体归档和 Agent 调用。

未经用户确认，不执行 `git commit`、`git push`、分支合并或工作树删除。

## 13. 完成记录

2026-07-24 按用户批准完成：

- 已建立 `home_agent/` 独立 uv 工程、Alembic schema、认证/配对/审计 API、节点 WebSocket
  registry、Fake Room Node 和真实 localhost 端到端测试。
- 已建立 `packages/node_protocol/` Dart 包，并让 Python/Dart 共用 canonical fixtures。
- 实际领域 ORM 集中在 `domain/models.py`，API DTO 集中在 `api/schemas.py`；这是对第 3 章
  预期文件拆分的收敛，不改变 repository/service 边界。
- 断线清理额外加入 ASGI cancellation shielding，避免网络断开时离线事务被取消。
- Python 20 个测试全绿，综合覆盖率超过 85% 门槛；Dart 协议包静态分析和 2 个合约测试全绿。
- 未接入真实硬件、媒体、模型、学生/家长 App；TLS 仍是阶段 2 真节点入网前的硬条件。
