# Family Home Agent

家庭 Agent 的本地优先服务端与 Linux 房间节点基础。当前阶段只包含家庭初始化、家长认证、
节点配对、能力上报、命令闭环和审计，不访问真实硬件或云端模型。

## 开发

```bash
uv sync --frozen
uv run alembic upgrade head
uv run home-agent
```

默认监听 `127.0.0.1:8790`，数据写入 `~/.local/share/family-home-agent`。可复制
`.env.example` 后通过环境变量覆盖。局域网正式使用前必须配置 TLS；当前 HTTP/WS 仅用于
本机开发，不能暴露到公网。

质量检查：

```bash
uv run ruff check .
uv run ruff format --check .
uv run mypy src
uv run pytest --cov=home_agent --cov=linux_room_node
```

## 可重复闭环演示

以下测试会在临时目录启动真实 Uvicorn、初始化家庭、登录、创建配对码、启动 Fake Room Node、
上报三类能力并完成一次 `fake.echo` 命令；结束后自动清理，不使用现有家庭数据：

```bash
uv run pytest tests/integration/test_live_fake_node.py -q
```

HTTP 字段、WebSocket 信封和手动调用顺序见 `../docs/home-agent-protocol.md`。
