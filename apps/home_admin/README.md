# HomeAdmin App

独立 Android 家长控制 App。在家可填写家庭服务器局域网地址，App 自动使用同一主机的
`8790` 登录家庭 Agent，并连接 `8780/ws` 控制智能屏；外网填写 HTTPS 云平台地址，通过
Cloud Control 和 Home Hub Connector 转发结构化命令，不公开家庭端口。

当前阶段支持：

- 首次初始化家庭、家长账号登录、会话安全保存与退出撤销；
- HTTPS 云平台一次性绑定码的生成和消费（10 分钟、单次使用）；
- 按 `display.photo` 能力发现在线 Home Hub，云端查询状态和控制相册；
- 查看客厅智能屏连接、当前照片、天气、语音、NAS 和音量状态；
- 上一张、下一张、刷新天气和调节播报音量；
- 播放/暂停、静音和调节相册背景音乐，查看当前音乐主题；
- 局域网断线后每 2 秒自动重连，云端模式每 4 秒同步状态并自动重试。
- 按 ASR/TTS/LLM 的每个 Provider 独立管理密钥、模型、识别语言、TTS 音色/角色和运行参数，
  并分别保存、清除与真实检测；密钥只写入 Home Agent，不在 App 中回读或持久化。

局域网开发构建：

```bash
cd apps/home_admin
/home/peidong/flutter/bin/flutter pub get
/home/peidong/flutter/bin/flutter analyze
/home/peidong/flutter/bin/flutter test
/home/peidong/flutter/bin/flutter build apk --debug
/home/peidong/flutter/bin/flutter build apk --release --split-per-abi
```

现代 Android 手机优先安装 `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`。
当前原型发布包使用本机 debug key 签名；正式分发前需要配置独立发布签名。

HTTP/WS 只允许用于可信家庭 Wi-Fi，不得把 8780/8790 映射到公网。外网模式必须使用具有
有效证书的 HTTPS/WSS 云平台；照片、人脸、声纹、对话和作业原图不会经该控制链路上传。
