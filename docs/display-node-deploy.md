# ARM / Android 展示节点部署

ARM 开发板（arm64 Ubuntu）跑展示 app，照片/索引/语音模型全从 x86 计算节点拉。
ARM 只做：展示轮播 + 录音采集 + 播放，不需要 sherpa_onnx / sqflite / heif-convert / NAS 直连。

Android 版同样固定为 display 角色。首次启动会要求输入
`http://<x86-IP>:8780`，通过 `/api/index/status` 验证后保存并进入主界面。
Android Manifest 允许家庭局域网的明文 HTTP；不应将计算节点暴露到不可信网络。

## 前提
- x86 计算节点已跑：`serverRole=compute`，`control_server :8780` 提供 `/api/photos/*` `/api/index/*` `/api/voice`，daemon 后台算索引
- ARM 与 x86 同局域网，能 `ping <x86-IP>`

## ARM 主机准备（arm64 Ubuntu）
```bash
# Flutter 3.44+（同 x86）
# 构建依赖
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
# record/audioplayers 的 GStreamer（arm64 成熟）
sudo apt install libgstreamer1.0-dev gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
                 gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav
```
clone 项目后进入 `apps/smart_frame/` 执行 `flutter pub get`。

## 构建
```bash
cd apps/smart_frame
flutter build linux --release    # 出 build/linux/arm64/release/bundle/
```
> Flutter 桌面不可交叉编译，必须在 arm64 主机上 build。

Android APK 可在开发机构建：

```bash
cd apps/smart_frame
flutter build apk --release
```

产物为 `build/app/outputs/flutter-apk/app-release.apk`，当前仅包含
`arm64-v8a`。首次启动时确保 Android 设备和计算节点在同一局域网。

## 配置（display 角色）
`~/.local/share/com.example.smart_frame/config.json`：
```json
{
  "serverRole": "display",
  "computeNodeUrl": "http://<x86-IP>:8780",
  "slideshowSeconds": 10,
  "volume": 0.8
}
```
照片/索引/语音全从 computeNodeUrl，`nasEnabled`/`nasWebdav*`/`wakeWordModelDir` 不需要。

## 启动
```bash
build/linux/arm64/release/bundle/smart_frame
```
若 ARM GPU 渲染有问题，参考 x86 的 `tool/run.sh` 思路（GDK_BACKEND / EGL 适配）。

## 验证
- **相册**：轮播出 x86 的照片（HttpPhotoSource 拉 `/api/photos/list` + `/file`），重启后按 ID 续播
- **照片说明**：从 `/api/index/description` 拉索引时间/地点/解说，缺失时用文件名和明确目录安全回退
- **跳过**：hidden/非照片被跳过（HttpIndexBackend 拉 `/api/index/hidden`）
- **语音**：对 ARM 麦克风说唤醒词 → 音频推 x86 KWS → ASR → TTS mp3 回 ARM 播

## ARM 不需要（全部在 x86）
- `sherpa_onnx`（KWS 在 x86）—— arm64 .so 高风险，C/S 后规避
- `sqflite_common_ffi`（索引在 x86）—— C/S 后规避
- `heif-convert`（HEIC 由 x86 转 jpg 再传）
- NAS WebDAV 直连（照片从 x86 HTTP）

## 协议（control_server 端点）
| 端点 | 方向 | 用途 |
|---|---|---|
| `GET /api/photos/list` | x86→ARM | 照片列表（id/name/isNas/modifiedAt） |
| `GET /api/photos/file?id=` | x86→ARM | 照片字节（已转 jpg） |
| `GET /api/index/status\|hidden\|bytag\|byperson\|persons` | x86→ARM | 索引查询 |
| `GET /api/index/description?id=` | x86→ARM | 当前照片时间、地点、文字解说 |
| `WS /api/voice` | 双向 | ARM 推 PCM/trigger；x86 推 state/TTS |
