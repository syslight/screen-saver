# “小方”连续家庭语音实施计划

1. 扩展 Android VoiceClient：接收设备原生“天猫精灵”wake event，唤醒后才录音；App 不放置
   “小方/天猫精灵”KWS、ASR、VAD 或 TTS 模型，也不负责模型下载。
2. 增加可单测的能量 VAD：人声起点、700 ms 尾静音、8 秒等待和 12 秒最大时长。
3. 扩展语音协议：取消空白轮次、服务端指示是否继续对话，同时保持旧消息可解析。
4. Home Agent 增加设备级最近 6 轮短期上下文、退出话术和阶段耗时日志。
5. 增加火山双向接口“湾湾小何”TTS 配置并保留 Piper 可切换 provider；首期聚合 PCM 为 WAV 播放。
6. 音乐在完整语音阶段 duck，TTS 完成后才开启下一轮，避免自激。
7. 同步协议 fixture、Dart/Python 合约测试、语音文档和配置文档。
8. 全量运行 Flutter/Python/共享协议门禁，构建 armeabi-v7a APK 并部署 AILABS_S1L 实测。
