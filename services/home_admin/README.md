# HomeAdmin WebUI

HomeAdmin 是家庭产品的统一管理入口。本服务只负责 WebUI 与到 Home Agent 的同源 BFF 代理，
不连接或写入 Home Agent 数据库，也不保存 provider 明文密钥。

Provider 页面按 ASR/TTS/LLM 和供应商分组。每张 Provider 卡片独立保存凭据、模型、语言、
音色及参数，并调用该 Provider 自己的检测；同一供应商的 ASR 与 TTS 配置不会互相覆盖。

```bash
cd services/home_admin
uv sync
uv run home-admin
```

默认访问 `http://127.0.0.1:8800/`。默认上游是 `http://127.0.0.1:8790`，可通过
`HOME_ADMIN_HOME_AGENT_URL` 修改。服务默认只监听回环地址，不应直接暴露到公网。
