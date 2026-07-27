# 端到端流式语音性能规格

## 目标

把展示 App → Home Agent → ASR → LLM → TTS → 展示 App 播放改成连续数据管线，主要优化用户
说完到听见首个声音的时间，同时限制内存和 WebSocket 缓冲增长。

## 数据流

1. App 使用 `record.startStream` 采集 PCM16/16 kHz/mono，目标 chunk 50 ms，收到即发 WebSocket。
2. Home Agent 同一 PCM chunk 同时进入端点检测、当轮回退缓冲和火山双向流式 ASR。
3. ASR 最终文本到达后，GLM/Kimi 使用 SSE token stream；服务端不请求或转发 reasoning。
4. token 按中文句末标点切分；无标点连续 40 字强制切片。LLM producer 与 TTS consumer 并行。
5. 火山/OpenAI TTS 直接产出 raw PCM；Piper 按句合成后拆 PCM，保持统一下游接口。
6. 媒体协议 v2 发送 `audio.stream.start`、约 50 ms 二进制 PCM 块、`audio.stream.end`。
7. Android 通过原生 `AudioTrack.MODE_STREAM` 边收边播；Linux 写入 `aplay` stdin。播放器写入
   期间暂停 WebSocket subscription，形成接收侧回压。其他桌面平台使用完整 WAV 降级。

## 兼容与失败

- 节点信封协议仍为 v1；流式媒体能力由 `node.hello.mediaProtocolVersion=2` 协商。
- v1 节点继续接收 `audio.play + audio/wav`，服务端不得向其发送 `audio.stream.*`。
- ASR 建连失败仍保留本轮 PCM，并按当前 provider 做完整转写。
- v2 音频流中途失败时先发送 `audio.stream.end` 释放播放器，再发送标准 error state。
- 每轮快照 Provider，运行中切换只影响下一轮。

## 性能与可观测性

- 录音目标 chunk：1600 bytes（PCM16 16 kHz mono，约 50 ms）。
- 下行目标 chunk：2400 bytes（PCM16 24 kHz mono，约 50 ms）。
- 服务端记录 `asr_ms`、`llm_first_token_ms`、`first_audio_ms`、`total_ms`。
- 指标日志不得包含原始音频、识别文字、回复正文、token 或供应商原始错误。

首包耗时受网络和供应商影响，不设伪造的绝对 SLA；验收必须证明首个 PCM chunk 在完整 LLM
回复和完整 TTS 音频完成前已经发往 v2 客户端。
