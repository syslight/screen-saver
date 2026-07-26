# 智能相册配乐实施计划

1. 扩展 `AppConfig`：音乐目录、开关、静音、独立音量、输出节点和夜间时段。
2. 新增 music feature：情境分类、故事段落、真实授权曲库与用户音乐扫描、SoundFont/WAV 离线回退、循环播放、淡入淡出、夜间静音和 TTS ducking。
3. 在 dashboard 左下区域增加常驻轻量音乐控制条，在设置页增加音乐目录和输出配置。
4. 扩展统一 `CommandService` 和 WS 状态协议；display 节点新增控制桥，保证家长端命令控制 RK3588 实际播放。
5. 扩展家长 Android App 的状态模型与音乐控制卡片。
6. 增加 Dart 单测，同步 README、架构、协议、需求、开发和部署文档。
7. 运行两个 Flutter 工程的 analyze/test/build，在 RK3588 构建部署并验证音频输出。
