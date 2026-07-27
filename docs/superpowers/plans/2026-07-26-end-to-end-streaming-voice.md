# 端到端流式语音实施计划

1. [x] 审计录音、ASR、LLM、TTS 和播放等待点。
2. [x] GLM/Kimi 改为 SSE token stream，增加句界切分和并行 TTS 队列。
3. [x] 火山/OpenAI 输出 raw PCM stream，Piper 增加按句 PCM 降级适配。
4. [x] 增加媒体协议 v2 `audio.stream.start/end` 与 v1 WAV 兼容路径。
5. [x] Android 增加低延迟 AudioTrack bridge，Linux 增加 aplay stdin 输出。
6. [x] 客户端录音 buffer 调整到约 50 ms，并对播放写入实施回压。
7. [x] 更新协议/语音文档，补充流式顺序、兼容和 PCM 工具测试。
8. [x] 执行 Home Agent、node_protocol、Flutter analyze/test 和 Android APK 构建。
