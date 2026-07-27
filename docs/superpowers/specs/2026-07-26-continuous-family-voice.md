# “小方”连续家庭语音规格

## 目标

让 AILABS_S1L Android 展示终端从“手动点击、固定录音五秒、单轮问答”升级为可自然使用的
家庭语音入口：复用设备原生唤醒、Home Agent 自动断句、连续对话、低延迟回复，并支持火山引擎
“湾湾小何”音色。原始麦克风 PCM 只在唤醒后的对话轮次发送到家庭局域网 Home Agent。

## 唤醒与天猫精灵共存

- 当前 AILABS 终端复用 AliTVASR/XEGNLocalEngine 已有“天猫精灵”唤醒能力。
- 原生服务绑定成功与固件日志识别成功只是中间检查点；只有 App 收到 wake event 并启动 Home
  Agent voice turn 才算自动唤醒验收通过。厂商账号状态不得成为最终架构依赖。
- App 通过导出的 Binder 服务接收唤醒状态，不修改、不卸载固件引擎，不读取厂商识别文本。
- “小方”作为家庭 Agent 名称保留；需要自定义词时由 Home Agent KWS 实现，不在 App 内放模型。
- 手动点击继续保留为诊断和降级入口。

## 自动断句

- Android 空闲时不由 App 占用麦克风；原生唤醒后才采集 16 kHz、单声道、PCM16。
- 唤醒后发送 `voice.turn.start`，并把本轮 PCM 发送给家庭服务器。
- Home Agent VAD 先等待有效人声；检测到人声后，连续静音约 700 ms 自动进入 processing。
- 单轮最长 12 秒；连续对话等待下一句话最长 8 秒，无人说话则由服务端退出，不调用 ASR/LLM/TTS。
- 音乐在 listening/processing/speaking 全阶段压低，避免回声和误断句。

## 连续对话

- 一次唤醒建立设备级短期会话；服务端保留最近 6 轮 user/assistant 文本，默认 5 分钟过期。
- TTS 播放完成后自动进入下一轮聆听，无需重复唤醒。
- 用户说“退出对话 / 不聊了 / 先这样”时，服务端清理短期上下文并返回 idle，不再续听。
- 不将短期上下文写入云控制平面；服务重启后可丢失。

## TTS

- 当前 Piper `zh_CN-huayan-medium` 保留为无网络/无凭据降级。
- 首选火山引擎大模型语音合成“湾湾小何”：
  `zh_female_wanwanxiaohe_moon_bigtts`。
- 凭据只从 Home Agent 私密环境变量读取，不进入 Android、不写日志、不提交仓库。
- Piper 保留为管理后台可显式切换的离线 provider；默认火山未配置或调用失败时明确上报状态。

## 延迟目标

- 唤醒命中到 listening：小于 300 ms。
- 说完到自动断句：约 700 ms，而非固定等待 5 秒。
- ASR、LLM、TTS 分段记录耗时；不得记录原始音频、API Key 或供应商原始响应。
- 火山供应商链路使用 V3 单向 HTTP 流式 TTS；媒体协议 v2 展示节点直接接收 PCM 流，v1 节点降级为
  聚合后的完整 WAV。

## 安全与失败模式

- App 不包含 KWS/VAD/ASR/TTS 模型，idle 时不上传 PCM。
- WebSocket 使用已配对 node/device key；服务端不信任客户端声明的 nodeId。
- 原生唤醒服务不可用或 Home Agent 断句异常时显示明确状态并保留手动点击。
- 原生天猫精灵占用麦克风时，本轮家庭语音可失败并自动恢复，不杀死厂商进程。
