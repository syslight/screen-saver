# 家庭语音链路

本文是当前语音架构的权威说明。智能屏 App 是薄终端：只接收设备原生唤醒事件、采集麦克风
PCM、展示状态并播放服务端音频。唤醒词检测（KWS）与语音转文字（ASR）是两层能力：AILABS
设备优先复用固件 KWS；VAD、ASR、Agent 和 TTS 均由 `services/home_agent/` 承担。App 不实现
或承载 KWS/VAD/ASR/Agent/TTS 模型。

## 1. 边界

| 层 | 负责 | 不负责 |
|---|---|---|
| AILABS Android 终端 | 绑定固件 AliTVASR 服务；接收“天猫精灵”唤醒状态；按需录制 PCM16/16 kHz/mono；播放 TTS | 不包含 sherpa/ONNX，不下载模型，不做 VAD、ASR、LLM 或 TTS 合成 |
| Home Agent | 服务端端点检测、ASR、短期会话、Agent 调用、TTS 合成与来源节点路由 | 不常驻接收未唤醒设备的音频 |
| 云模型 | 按 Home Agent 授权完成复杂理解 | 不直接连接房间节点，不保存节点密钥 |

`apps/smart_frame/pubspec.yaml` 不依赖 `sherpa_onnx`；发布 APK 中不得出现
`libsherpa-onnx*` 或 `libonnxruntime*`。历史配置字段 `listenSeconds`、`asr*` 和
`wakeWordModelDir` 仅为旧配置文件兼容保留，当前 App 不读取它们执行语音计算。

## 2. 原生唤醒

AILABS_S1L 固件导出服务：

```text
action:    com.yunos.tv.alitvasr.service
component: com.alibaba.ailabs.genie.smartapp/
           com.alibaba.ailabs.geniesdk.NativeService
```

`NativeWakeBridge.kt` 提供两个同级的厂商适配入口：优先绑定 AliTVASR 服务并注册
`IAliTVASRCallback`；在当前厂商账号不可用的 AILABS_S1L 上，通过 Magisk 只读订阅系统
`WakeupManager` 日志标签。两者只把固件已经完成的 KWS 结果转换成 Flutter EventChannel 事件：

```json
{"event":"wake","wakeWord":"天猫精灵","source":100,"adapter":"firmware_log"}
```

桥接层只匹配 `wakeup word is 天猫精灵`，不转发其他日志、厂商识别文字，不读取固件原始音频，
也不调用厂商 TTS。服务不存在或注册失败时，
Flutter 显示“原生唤醒不可用”，触屏、空格键和控制端 `listen` 仍可手动开始录音。其他品牌或
不带固件唤醒的终端，后续若需要自定义“小方”唤醒，应把空闲音频送到局域网 Home Agent 的
独立 KWS 入口；不得把模型重新塞进 App。

当前 AILABS_S1L 真机验证结果：厂商账号未登录时会以 `no user login` 中止语音 session，公开
Binder 不会发出较晚的 `start_recording` callback；但固件 KWS 事件仍然产生。版本 1005 的
`firmware_log` 适配器已在真机收到 wake event，并在约 150 ms 后启动 Android `AudioRecord`。
该适配器要求 Magisk 对 App UID 授予 root；权限仅用于运行按标签过滤的只读 `logcat`。

## 3. 一轮对话

```text
固件“天猫精灵”唤醒 / 手动 listen
          │
          ▼
Android VoiceClient ── voice.turn.start ──▶ Home Agent
          │                                  │ listening
          └── PCM16/16k/mono（二进制块）──────▶│
                                             │ 服务端 VAD
                                             ├─ PCM 同步送火山流式 ASR（默认）
                                             │ 人声后约 700ms 静音
          ◀──────── voice.turn.state ─────────┤ processing
          │ 立即停止并释放麦克风               │
                                             │                                  ├─ 火山 / faster-whisper / OpenAI ASR
          │                                  ├─ GLM/Kimi 等 Agent
          │                                  └─ 火山/Piper TTS
          ◀──── speaking + audio.play + bytes ┤
          │ 播放服务端音频                     │
          ◀──────────── idle ─────────────────┘
          └─ continueDialog=true 时开始下一轮按需录音
```

客户端不发送“我判断说完了”的语义事件。Home Agent 的 `VoiceEndpointDetector` 根据收到的
PCM 判断：至少约 120ms 有效人声后，尾部连续静音约 700ms 自动结束；8 秒无人说话退出；单轮
最长 12 秒。服务端发出 `processing` 后客户端停止录音。旧客户端主动发送
`voice.turn.stop` 仍受支持，保证协议向后兼容。

## 4. 连续对话

- 一次唤醒建立节点级短期上下文，默认保留最近 6 轮，约 5 分钟过期。
- TTS 播放完成且 `continueDialog=true` 时，终端自动开始下一轮，无需重复唤醒。
- “退出对话 / 不聊了 / 先这样”会清除上下文，服务端返回 `continueDialog=false`。
- 音乐在 listening / processing / speaking 阶段 duck，语音结束后恢复。
- 短期上下文只含文字，不写云控制平面；原始音频当前只存在于本轮内存缓冲，处理完清空。

## 5. ASR 与 TTS

ASR 默认 provider 是火山 ASR 2.0 的优化版双向流式接口
`/api/v3/sauc/bigmodel_async`。Home Agent 在 listening 阶段把节点 PCM 同步送入供应商连接，
本地 VAD 判停后发送负 sequence 结束帧并使用最终结果。可切换到本地 `faster-whisper` 或
OpenAI-compatible `/audio/transcriptions`。

TTS 默认 provider 是火山 V3 双向流式接口，保留本地 Piper 和 OpenAI-compatible
`/audio/speech`。火山返回的 PCM 在 Home Agent 聚合为 WAV 后按现有 `audio.play` 协议发给节点；
因此供应商侧已流式，节点侧仍是完整音频播放。Agent provider 可选 GLM/Kimi。所有供应商密钥
只从 Home Agent 环境变量读取，不能进入 APK、管理页响应、日志或仓库。

家长登录 `/admin/` 可查看 provider 的 `unconfigured / ready / healthy / error` 状态、最近检测
时间与耗时，主动检测，并切换 ASR/TTS/LLM。切换结果写入服务端数据目录
`voice-providers.json`，仅保存 provider 名称并设为 `0600`；切换对下一轮语音生效。管理 API
要求家长 bearer，切换操作写审计日志。

## 6. 状态和降级

| 状态 | 屏幕文案 | 行为 |
|---|---|---|
| native adapter ready + idle | `待唤醒：天猫精灵` | 等待固件 KWS 事件，不占用 App 麦克风 |
| native unavailable + idle | `手动对话` | 保留触屏/空格/控制端入口 |
| listening | `聆听中…` | 按需录音并上传本轮 PCM |
| processing | `识别中…` | 麦克风已释放，等待服务器 |
| speaking | `播报中…` | 播放服务器返回音频 |
| error | `语音服务异常` | 停止录音，等待 WebSocket 恢复 |

没有麦克风权限、节点凭据缺失、Home Agent 不可达和厂商服务不可用互不混淆，均通过右下角
`VoiceIndicator` 的 `statusMessage` 呈现。手动入口只用于降级和诊断，不改变计算边界。

## 7. 验证

```bash
cd apps/smart_frame
/home/peidong/flutter/bin/flutter analyze
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  -u ALL_PROXY -u all_proxy /home/peidong/flutter/bin/flutter test
/home/peidong/flutter/bin/flutter build apk --release --target-platform android-arm
unzip -l build/app/outputs/flutter-apk/app-release.apk | rg -i 'sherpa|onnx'

cd ../../services/home_agent
uv run ruff check .
uv run ruff format --check .
uv run mypy src
uv run pytest --cov=home_agent --cov=linux_room_node --cov=home_hub_connector
```

最后一条 APK 检查必须无输出。真机验证必须同时确认：固件日志出现 App callback 注册；唤醒后
App 出现 `native wake adapter=...`；随后 Android `AudioRecord` 启动；App 只在 listening 时持有
录音。只有服务绑定或固件 KWS 日志，不算 App 侧链路通过。
