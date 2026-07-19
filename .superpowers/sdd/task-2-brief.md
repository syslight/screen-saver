### Task 2: docs/requirements.md

**Files:**
- Create: `docs/requirements.md`

**Interfaces:**
- Consumes: `README.md`、`lib/config/app_config.dart`、`lib/main.dart`（失败隔离注释）、`lib/voice/voice_pipeline.dart`（降级逻辑）
- Produces: 需求基线；roadmap 中的限制项须与本文档非功能需求呼应

- [ ] **Step 1: 写 docs/requirements.md**：
  - 功能需求（按模块列可勾选项）：天气（Open-Meteo、免 key、城市名地理编码、定时刷新）、日历（公历/农历/干支生肖/节气/节日）、相册（本地目录轮播、交叉渐变、jpg/png/webp/bmp/gif——实际扩展名以 `lib/services/photo_service.dart` 的 `imageExts` 为准，写文档前先读它）、语音交互（唤醒词/空格/手机按钮三触发、文字指令、意图种类）、TTS（edge-tts 主用、系统 TTS 兜底）、手机控制（扫码进控制台、多设备同时在线、状态实时同步、上传照片）
  - 非功能需求：三平台桌面、全屏常驻（wakelock）、零配置可启动、单服务初始化失败不影响整体（`main.dart` 注释为据）、局域网内工作、语音链路逐层降级（KWS 模型缺失→手动模式；ASR 未配置→文字指令仍可用；TTS 网络失败→系统 TTS）
- [ ] **Step 2: 验证**：`grep imageExts lib/services/photo_service.dart` 核对扩展名清单；需求条目与 README 功能列表无矛盾

