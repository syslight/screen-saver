# 3588 / CCL 薄展示端部署

3588 Linux 和天猫精灵 CCL Android 共用 `smart_frame` 展示端代码。设备只做照片
展示与缓存、麦克风录音、音乐/TTS 播放；照片索引与去重、曲库选择、ASR、
Agent 和 TTS 合成都在独立 `home_agent` 服务中完成。

## 服务端前提

`home_agent` 默认使用 `8790` 端口，`photo_indexer` 写入服务端 SQLite。授权音乐只
安装在服务端：

```bash
python3 tool/install_licensed_music.py \
  "$HOME/.local/share/family-home-agent/music"
systemctl --user restart home-agent.service
```

ASR 与 TTS 模型只在 x86 家庭服务器本地运行；麦克风 PCM 不发给外部模型服务。文本 Agent
可通过 `HOME_AGENT_VOICE_AGENT_PROVIDER=glm|kimi` 选择 Coding API provider。密钥只放在权限为
`0600` 的 `~/.config/family-home-agent/voice.env`：GLM 使用
`HOME_AGENT_VOICE_GLM_API_KEY`，Kimi 使用 `HOME_AGENT_VOICE_KIMI_API_KEY`。写入后执行
`systemctl --user restart home-agent.service`，不要把该文件复制到 CCL/3588 或提交到仓库。

首次部署用一次性配对码，或在服务器本机生成受保护的设备凭据文件：

```bash
python3 tool/provision_display_nodes.py \
  --agent-url http://127.0.0.1:8790
```

该命令只在空库中初始化家庭，并以 `0600` 权限保存部署管理员与 CCL/3588
的独立凭据。日志和终端不会打印 device key。

## CCL Android

开发机上使用 ARMv7 APK 部署：

```bash
tool/deploy_ccl_android.sh --take-over \
  http://<home-agent-IP>:8790 \
  "$HOME/.local/share/family-home-agent/display-nodes/ccl.json"
```

脚本会验证凭据、构建 `armeabi-v7a`/`arm64-v8a` 分包、安装 ARMv7 包、安全写入
`agentUrl/nodeId/roomId/deviceKey` 并启动。`--take-over` 会关闭原厂悬浮层和屏保，
并安装 Magisk `service.d` kiosk 守护：系统启动完成后打开相册，被原厂页面抢占时
将其拉回前台。CCL 固件不能安全持久化第三方 HOME，也不能在冷启动时 suspend
原厂持久系统包，因此脚本不修改这两项、也不卸载原厂应用。恢复时执行：

```bash
tool/restore_ccl_vendor_ui.sh
```

若设备只刷入了 Magisk boot 镜像、但 `/cache/magisk.log` 报
`Magisk environment incomplete`，须先用与 `/sbin/magisk` **完全同版**的 Magisk APK
补齐运行环境，再重启：

```bash
tool/install_ccl_magisk_runtime.sh /path/to/Magisk-v30.7.apk
adb reboot
adb wait-for-device
adb shell 'su -c "grep service.d /cache/magisk.log"'
```

脚本会先校验 APK 内 `magisk` 与 boot 镜像中的二进制哈希，保留原目录备份，再写入
`/data/adb/magisk`；它不修改 system 分区，也不刷写 boot。不要用不同版本 APK 混装。

CCL 实机基线为 Android API 27、`armeabi-v7a`、1024×600、160 dpi。Android 首启时也
可手工输入 `home_agent` 地址、一次性配对码和设备名称。

## 3588 Linux

安装 Flutter 3.44+ 及 GTK/GStreamer 依赖，然后必须在 arm64 主机上构建：

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libgstreamer1.0-dev gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav
cd apps/smart_frame
flutter pub get
flutter build linux --release
```

Flutter Linux 不支持从 x86 交叉构建 arm64，产物为
`build/linux/arm64/release/bundle/`。将服务端签发的 `rk3588.json` 写入目标机的
`~/.local/share/com.example.smart_frame/config.json`，配置至少包含：

```json
{
  "serverRole": "display",
  "agentUrl": "http://<home-agent-IP>:8790",
  "nodeId": "<server-issued>",
  "roomId": "<server-issued>",
  "deviceKey": "<server-issued>",
  "musicEnabled": true,
  "musicOutputEnabled": true
}
```

也可以在 RK3588 仓库目录直接执行完整安装：

```bash
tool/deploy_rk3588_linux.sh \
  http://<home-agent-IP>:8790 \
  "$HOME/.local/share/family-home-agent/display-nodes/rk3588.json"
```

脚本拒绝在非 arm64 主机运行，先验证节点凭据，再原生构建，采用带时间戳的版本目录安装到
`~/.local/opt/smart-frame/`，以 `0600` 写配置，并启用 `smart-frame-display.service`。RK3588
服务单元沿用实机验证过的 X11、Mesa llvmpipe 与 Flutter 软件渲染参数，避免 Rockchip EGL
驱动下的黑屏或渲染进程异常。当前 HDMI 实机把 X11 固定为与可用帧缓冲一致的 1280×720，
并在启动前退出系统屏保、关闭 DPMS，避免 1920×1080 窗口等待 1280×720 OpenGL 帧而持续
高负载或露出屏保画面。

## 验收

- `GET /api/v1/media/status` 使用设备凭据返回可见/隐藏照片和服务端曲目数。
- 设备轮播 `/api/v1/media/photos` 中的已去重、未隐藏结果，不持有 NAS 凭据。
- 配乐由 `/api/v1/media/music/select` 选择并下载到本地缓存，设备不合成音乐。
- 按键启动录音后，PCM 进入 `/api/v1/media/voice/ws`，ASR/Agent/TTS 在服务端
  完成，`targetNodeId` 默认等于本轮来源 `nodeId`，音频只回到该连接。

`8780` Flutter `ControlServer` 仅保留桌面历史兼容，不再是 CCL/3588 display 的数据或
语音依赖。
