#!/usr/bin/env bash
# smart_frame 启动脚本
#
# 平台/硬件适配（仅在 Linux + NVIDIA + Wayland 会话下生效，其余环境保持默认）：
# 该组合下 Flutter 默认 GTK EGL 会
#   ① Wayland 原生：eglMakeCurrent failed → 窗口黑屏
#   ② XWayland：fallback 到 Mesa 软件渲染 → 5K 全屏卡顿、CPU 飙高
# 检测到该组合才注入两个环境变量启用 GPU 硬件渲染：
#   GDK_BACKEND=x11                                  绕过 Wayland EGL 崩溃
#   __EGL_VENDOR_LIBRARY_FILENAMES=10_nvidia.json    强制 NVIDIA EGL，启用 GPU
# macOS / Windows / Linux-Intel/AMD / Linux-NVIDIA-X11会话 均不触发，走各自默认。
#
# 用法：
#   tool/run.sh          跑 release bundle（生产）
#   tool/run.sh --dev    flutter run -d linux（开发）
set -euo pipefail
cd "$(dirname "$0")/.."
export DISPLAY="${DISPLAY:-:0}"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy 2>/dev/null || true

# 仅 Linux + Wayland 会话 + NVIDIA 显卡才注入渲染环境变量
if [[ "$(uname -s)" == "Linux" ]] \
   && [[ -n "${WAYLAND_DISPLAY:-}" ]] \
   && lspci 2>/dev/null | grep -qi 'nvidia'; then
  export GDK_BACKEND=x11
  NVJSON=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
  if [[ -f "$NVJSON" ]]; then
    export __EGL_VENDOR_LIBRARY_FILENAMES="$NVJSON"
  fi
  echo "[run.sh] 检测到 Linux+Wayland+NVIDIA，已启用 X11 后端 + NVIDIA EGL（GPU 硬件渲染）"
fi

if [[ "${1:-}" == "--dev" ]]; then
  exec /home/peidong/flutter/bin/flutter run -d linux
fi
exec build/linux/x64/release/bundle/smart_frame
