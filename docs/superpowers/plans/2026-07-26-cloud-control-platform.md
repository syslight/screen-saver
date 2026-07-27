# 家庭云控制平台实施计划

1. [x] 为 Home Agent 增加 `edge/cloud` 部署模式；cloud 模式只装配认证、家庭、节点、审计和健康接口。
2. [x] 增加一次性家长端绑定码，支持创建、消费、限流、单次使用、过期和审计。
3. [x] 增加 Home Hub Connector：主动连接云端，上报 `home.hub`、`display.photo`、`audio.playback` 能力，并代理本地相册状态与命令。
4. [x] 扩展家长 App 的服务器模型，支持 HTTPS 443 云端地址、绑定码换会话、节点发现和 Home Hub 命令。
5. [x] 增加 Caddy、systemd 部署模板和最小安全组清单。
6. [x] 服务端运行 ruff、mypy、pytest；Flutter 运行 analyze/test，并做本地 cloud↔hub↔frame 端到端验证。
7. 获得 ECS SSH 主机、用户、端口及域名后部署真实阿里云，最后生成十分钟有效的一次性家长绑定码。
