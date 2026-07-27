# HomeAdmin 产品与服务边界

## 定义

HomeAdmin 是家庭产品唯一的管理入口，家长只是授权角色，不是产品名。产品包含两种客户端形态：

- `apps/home_admin/`：Flutter Android App；
- `services/home_admin/`：WebUI 与同源 BFF，默认入口 `http://127.0.0.1:8800/`。

原 `apps/parent/`、Home Agent 内嵌 `/parent/` 与 `/admin/` 页面直接移除，不提供兼容路由。

## 数据与调用边界

`services/home_agent/` 是家庭、设备、作业、审计、Provider 选择和 Provider 密钥的唯一 owner。
HomeAdmin App/WebUI 只调用版本化 Home Agent API，不连接数据库，不共享 ORM，不直接读取数据目录。

```text
HomeAdmin App ──────┐
                    ├── Home Agent API ── Home Agent DB / Provider Secrets
HomeAdmin WebUI/BFF ┘
```

Web BFF 只做静态页面托管和 `/api/v1/*` 同源流式代理，保留家长 bearer 与上游状态码。默认只监听
回环地址；家庭局域网开放时仍不得端口映射到公网。

## 密钥边界

- Provider 密钥由 Home Agent 的家长鉴权 API 设置或清除，并立即对后续调用生效。
- Home Agent 用权限为 `0600` 的 `voice-provider-secrets.json` 保存管理值；管理值覆盖环境配置。
- 查询只返回 `configured`、`source` 和脱敏 `hint`；WebUI、App、日志和审计均不能读到明文。
- 审计只记录更新/清除的字段名。
- Cloud Control 不提供家庭 Provider 密钥管理 API；App 仅在局域网 edge 模式展示该入口。

## 命名

代码中的 `parent` 可继续表示认证角色、家庭成员角色或家长会话，例如 `role=parent`；不得再用于
产品目录、应用名称、页面路由或部署服务名称。
