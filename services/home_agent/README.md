# Family Home Agent

家庭 Agent 的本地优先服务端、轻量云控制平面与 Linux 节点基础。`edge` 模式提供家庭作业和
本地能力；`cloud` 模式只装配认证、家庭隔离、节点、命令路由和审计，不保存家庭原始媒体。

## 开发

```bash
uv sync --frozen
uv run alembic upgrade head
uv run home-agent
```

默认监听 `127.0.0.1:8790`，数据写入 `~/.local/share/family-home-agent`。可复制
`.env.example` 后通过环境变量覆盖。学生平板阶段 B 可在同一可信家庭 Wi-Fi 内临时使用
HTTP，但不能做端口映射或暴露到公网；远程访问前必须配置 HTTPS。

### 展示节点语音

CCL Android 与 RK3588 Linux 展示端以约 50 ms 块采集 PCM16/16 kHz/mono，并流式播放服务端
回送的 PCM。
`home_agent` 默认使用火山 ASR 2.0 优化版双向流式识别和火山 V3 单向 HTTP 流式 TTS；本地
faster-whisper/Piper 与 OpenAI ASR/TTS 均保留为可切换 provider。文字 Agent 可在 `glm` 与
`kimi` Coding API provider 之间切换：

```dotenv
HOME_AGENT_VOICE_AGENT_PROVIDER=glm
HOME_AGENT_VOICE_GLM_BASE_URL=https://open.bigmodel.cn/api/coding/paas/v4
HOME_AGENT_VOICE_GLM_API_KEY=<本机密钥>
HOME_AGENT_VOICE_GLM_MODEL=glm-5.2
HOME_AGENT_VOICE_GLM_TEMPERATURE=0.3
HOME_AGENT_VOICE_ASR_PROVIDER=volcano
HOME_AGENT_VOICE_ASR_MODEL=small
HOME_AGENT_VOICE_ASR_LANGUAGE=zh
HOME_AGENT_VOICE_ASR_DEVICE=cpu
HOME_AGENT_VOICE_ASR_COMPUTE_TYPE=int8
HOME_AGENT_VOICE_TTS_MODEL_DIR=/path/to/zh_CN-huayan-medium
HOME_AGENT_VOICE_TTS_MODEL_NAME=zh_CN-huayan-medium
HOME_AGENT_VOICE_TTS_SPEED=1.0
HOME_AGENT_VOICE_TTS_VOLUME=1.0
HOME_AGENT_VOICE_TTS_PROVIDER=volcano
HOME_AGENT_VOICE_OPENAI_API_KEY=<可选 OpenAI 密钥>
HOME_AGENT_VOICE_OPENAI_ASR_MODEL=gpt-4o-mini-transcribe
HOME_AGENT_VOICE_OPENAI_ASR_LANGUAGE=zh
HOME_AGENT_VOICE_OPENAI_TTS_MODEL=gpt-4o-mini-tts
HOME_AGENT_VOICE_OPENAI_TTS_VOICE=coral
HOME_AGENT_VOICE_OPENAI_TTS_SPEED=1.0
HOME_AGENT_VOICE_VOLCANO_ASR_AUTH_MODE=app_key
HOME_AGENT_VOICE_VOLCANO_ASR_RESOURCE_ID=volc.bigasr.sauc.duration
HOME_AGENT_VOICE_VOLCANO_ASR_LANGUAGE=zh-CN
HOME_AGENT_VOICE_VOLCANO_API_KEY=<豆包语音新版控制台当前项目的 APP Key>
HOME_AGENT_VOICE_VOLCANO_TTS_URL=https://openspeech.bytedance.com/api/v3/tts/unidirectional
HOME_AGENT_VOICE_VOLCANO_APP_ID=<火山应用 ID>
HOME_AGENT_VOICE_VOLCANO_ACCESS_TOKEN=<火山访问令牌>
HOME_AGENT_VOICE_VOLCANO_RESOURCE_ID=volc.service_type.10029
HOME_AGENT_VOICE_VOLCANO_VOICE=zh_female_wanwanxiaohe_moon_bigtts
HOME_AGENT_VOICE_VOLCANO_SAMPLE_RATE=24000
HOME_AGENT_VOICE_VOLCANO_SPEECH_RATE=0
HOME_AGENT_VOICE_VOLCANO_PITCH_RATE=0
HOME_AGENT_VOICE_VOLCANO_LOUDNESS_RATE=0
HOME_AGENT_VOICE_VOLCANO_TTS_USE_CACHE=true
HOME_AGENT_VOICE_TTS_STREAM_CHUNK_BYTES=2400
```

Kimi 对应变量为 `HOME_AGENT_VOICE_KIMI_BASE_URL`、`HOME_AGENT_VOICE_KIMI_API_KEY` 和
`HOME_AGENT_VOICE_KIMI_MODEL`。部署时把这些变量放入权限为 `0600` 的
`~/.config/family-home-agent/voice.env`，不要写入仓库或展示设备。

ASR 可选 `volcano/local/openai`，TTS 可选 `volcano/piper/openai`，默认均为 `volcano`。
环境变量是启动基线；HomeAdmin 按 `能力 + Provider` 独立保存覆盖值，因此火山 ASR/TTS、
OpenAI ASR/TTS 不会互相覆盖密钥或参数。火山 ASR 的鉴权方式必须明确选择：新版豆包语音项目用
`app_key` 和当前项目 API Key 页面中的 APP Key（不是 IAM Access Key），旧版语音应用才用
`app_id_token` 和 App ID + Access Token；火山 TTS 使用自己独立保存的 APP Key，通过
`/api/v3/tts/unidirectional` 按行接收 Base64 PCM 分片。密钥写入权限为 `0600` 的
`voice-provider-secrets.json`，模型、语言、音色、Base URL 和生成参数写入同权限的
`voice-provider-config.json`；两者均热生效，密钥不写日志或返回明文。旧版扁平密钥文件会在
内存中映射到对应 Provider，并在首次保存时升级为分组结构。

管理页面由独立 `services/home_admin/` 提供，Home Agent 不托管 WebUI。HomeAdmin 可查看所有
ASR/TTS/LLM provider 的独立凭据、模型、语言、音色、参数、最近调用状态和耗时；每个
Provider 可分别保存、清除和真实检测，也可切换当前 provider。选择结果以 `0600` 权限
写入数据目录的 `voice-providers.json`，立即对下一轮语音生效；文件中只有 provider 名称，
不含密钥。媒体协议 v2 将 GLM/Kimi SSE token 按句送入 TTS，并以 PCM chunk 回送；协议 v1
节点仍降级为完整 WAV。

### Cloud Control 与 Home Hub

云端设置 `HOME_AGENT_DEPLOYMENT_MODE=cloud`，只让 Caddy 反向代理到本机 `127.0.0.1:8790`。
公网仅开放 HTTPS/WSS 443。首次空库在服务器本机调用一次 `/api/v1/bootstrap`，之后使用家长
登录或 App 生成的一次性绑定码；作业、学生和 provider 接口在 cloud 模式不存在。

家庭 Home Hub 先在云端创建节点配对码，再执行一次：

```bash
uv run home-hub-connector \
  --cloud https://home.example.com \
  --pairing-code '<10 分钟一次性节点码>'
```

凭据默认以 `0600` 权限保存到
`~/.local/share/family-home-agent/cloud-home-hub.json`。后续启动省略 `--pairing-code`；连接器主动
建立 WSS，上报 `home.hub`、`display.photo`、`audio.playback`，并且只访问本机
`ws://127.0.0.1:8780/ws` 和 `http://127.0.0.1:8790`。不提供摄像头原始流命令。

启动 HomeAdmin 后访问 `http://127.0.0.1:8800/`。第一次使用可在页面初始化家庭和第一位家长，
登录后录入家庭成员、布置作业、上传作业图片并进行人工审核。模型检查
默认关闭；提交会明确进入“待家长审核”，不会生成模拟 AI 判断或自动外发图片。

作业图片只接受 JPEG/PNG/WebP，单张最大 12 MiB、每次最多 6 张，家庭总配额 5 GiB。
原图下载同样要求家长登录。

### 可选 Agent 作业检查

阶段 C 通过 OpenAI-compatible Chat Completions 接入视觉模型，默认配置为 Kimi 的具体模型
`kimi-k3`。先在 `.env` 配置并重启服务：

```dotenv
HOME_AGENT_HOMEWORK_MODEL_ENABLED=true
HOME_AGENT_HOMEWORK_MODEL_BASE_URL=https://api.moonshot.ai/v1
HOME_AGENT_HOMEWORK_MODEL_API_KEY=<本机密钥>
HOME_AGENT_HOMEWORK_MODEL_NAME=kimi-k3
```

GLM 使用同一客户端，只需将 base URL 改为 `https://open.bigmodel.cn/api/paas/v4`，并选择支持
图像输入的具体模型名（例如 `glm-5v-turbo`）。每次发送都必须由家长在某次提交下点击授权；
发送内容包括压缩后的作业图片、任务要求、参考答案和评分标准。服务端只保存严格校验后的结构化
建议及归一化错误码，不保存 API Key 或供应商原始响应。Agent 不会自动接受/退回作业。

学生平板联调时运行：

```bash
HOME_AGENT_HOST=0.0.0.0 uv run home-agent
```

家长在 HomeAdmin 的“学生平板”区选择孩子，生成 8 位、10 分钟有效、只能使用一次的配对码。
学生设备换取独立 device key 后只能查看、开始和提交绑定孩子的作业，不能读取参考答案、评分
标准、其他孩子任务或家长审核 API；家长撤销设备后旧 key 立即失效。

质量检查：

```bash
uv run ruff check .
uv run ruff format --check .
uv run mypy src
uv run pytest --cov=home_agent --cov=linux_room_node --cov=home_hub_connector
```

## 可重复闭环演示

以下测试会在临时目录启动真实 Uvicorn、初始化家庭、登录、创建配对码、启动 Fake Room Node、
上报三类能力并完成一次 `fake.echo` 命令；结束后自动清理，不使用现有家庭数据：

```bash
uv run pytest tests/integration/test_live_fake_node.py -q
```

HTTP 字段、WebSocket 信封和手动调用顺序见 `../docs/home-agent-protocol.md`。
