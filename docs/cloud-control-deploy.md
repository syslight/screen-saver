# 阿里云 Cloud Control 部署清单

本清单部署轻量云控制平面。云端只保存家庭/账号、设备身份、能力、在线状态、命令元数据和审计；
照片、人脸、声纹、对话、作业原图及长期记忆留在家庭 Home Hub。

## 1. 前置条件

- 一台阿里云 ECS/轻量应用服务器，能够 SSH 登录。
- 一个解析到该服务器公网 IP 的域名；Caddy 用它自动申请 TLS 证书。
- 安全组公网入站仅开放 `443/tcp`；`22/tcp` 只允许可信管理 IP。不要开放 8780/8790。
- 服务器安装 Git、Python 3.12、uv 和 Caddy。

正式执行前需要明确：`SSH host/IP`、`SSH user`、`SSH port`、域名。不要在聊天或仓库中发送
密码/私钥；把本机 SSH 公钥加入服务器即可。

## 2. 云服务器目录与服务

以下命令假定系统服务用户为 `smart-frame`，仓库位于 `/opt/smart-frame`：

```bash
sudo useradd --system --create-home --home-dir /var/lib/family-cloud-control smart-frame
sudo install -d -o smart-frame -g smart-frame /opt/smart-frame /var/lib/family-cloud-control
sudo git clone <private-repository-url> /opt/smart-frame
sudo chown -R smart-frame:smart-frame /opt/smart-frame
sudo -u smart-frame uv sync --frozen --directory /opt/smart-frame/services/home_agent

sudo install -m 600 -o smart-frame -g smart-frame \
  /opt/smart-frame/deploy/cloud/cloud-control.env.example \
  /etc/family-cloud-control.env
sudo install -m 644 /opt/smart-frame/deploy/cloud-control.service \
  /etc/systemd/system/cloud-control.service
```

把 `deploy/cloud/Caddyfile` 的 `home.example.com` 换成真实域名，再安装为 `/etc/caddy/Caddyfile`：

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl daemon-reload
sudo systemctl enable --now cloud-control caddy
curl --fail http://127.0.0.1:8790/health/ready
curl --fail https://<真实域名>/health/ready
```

`cloud-control.service` 只监听回环地址，外部 HTTP/WSS 均经 Caddy 443。Caddy 原生代理 WebSocket，
不需要单独暴露节点端口。

## 3. 首次创建云家庭

空数据库只允许成功 bootstrap 一次。建议通过 SSH 在服务器本机调用，并使用足够长的随机密码：

```bash
curl --fail-with-body http://127.0.0.1:8790/api/v1/bootstrap \
  -H 'Content-Type: application/json' \
  --data '{"householdName":"我们的家","timezone":"Asia/Shanghai","username":"<家长账号>","password":"<随机长密码>"}'
```

保存响应中的 `roomId`。随后登录获得临时 bearer，用于生成 Home Hub 节点码或首台家长手机
绑定码。所有绑定码约 10 分钟内有效、只可消费一次，数据库仅保存 hash。

## 4. 配对家庭 Home Hub

在云端用家长 bearer 调用 `POST /api/v1/node-pairing-codes`，请求体为
`{"roomId":"<bootstrap 返回的 roomId>"}`。然后在当前家庭 Linux 服务器执行：

```bash
cd /home/peidong/source/screen-saver/services/home_agent
uv run home-hub-connector \
  --cloud https://<真实域名> \
  --pairing-code '<一次性节点码>'
```

确认 `~/.local/share/family-home-agent/cloud-home-hub.json` 已生成且权限为 `0600`。再创建：

```bash
mkdir -p ~/.config/systemd/user
install -m 600 /home/peidong/source/screen-saver/deploy/family-home-hub.env.example \
  ~/.config/family-home-hub.env
```

把其中地址换成真实域名，然后安装并启动用户服务：

```bash
ln -s /home/peidong/source/screen-saver/deploy/home-hub-connector.service \
  ~/.config/systemd/user/home-hub-connector.service
systemctl --user daemon-reload
systemctl --user enable --now home-hub-connector.service
journalctl --user -u home-hub-connector.service --since today
```

连接器只主动访问云 WSS、本机 `127.0.0.1:8790` 和本机相框 `127.0.0.1:8780/ws`。

## 5. 绑定家长 App

有两种首台手机登录方式：使用 bootstrap 的账号密码登录 HTTPS 云域名，或在服务器生成一次性
家长绑定码。登录后，App 右上角“绑定另一台家长手机”可直接生成新码。

新手机操作：

1. 家庭服务器地址填写 `https://<真实域名>`。
2. 选择“使用一次性绑定码连接云平台”。
3. 输入 8 位码；绑定成功后该手机获得独立、可撤销的 bearer session。
4. App 按 `display.photo` 能力寻找在线 Home Hub，通过云端执行 `frame.get_state/frame.command`。

## 6. 验收与回滚

验收：

- `https://<域名>/health/ready` 返回 200；HTTP 自动跳转 HTTPS。
- 云端作业、学生和 provider 管理接口返回 404；HomeAdmin 不把家庭密钥转发到云端。
- 云端节点列表中 Home Hub 为 `online`，包含 `home.hub/display.photo/audio.playback`。
- 手机关闭 Wi-Fi、使用蜂窝网络仍可读取当前照片并切换下一张。
- 云服务器磁盘中不存在家庭照片、音频、视频和作业原图。

若连接异常，停止 `home-hub-connector.service` 只会失去远程控制，不影响局域网相框和本地
Home Agent。停止云端 `cloud-control.service` 也不会删除家庭数据；恢复服务后节点主动重连。
