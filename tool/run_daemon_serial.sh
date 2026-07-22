#!/usr/bin/env bash
# 守护进程串行调度（OOM 兜底）：分阶段单模型，每阶段 GPU 独占，避免全套同时
# 加载（dinov2/clip + ollama VLM + app 渲染）撑爆 8GB 显存。
#
# 顺序：dinov2+CLIP（torch GPU）→ insightface（CPU）→ VLM（ollama GPU）
# 每阶段全量一遍，断点续传（_needs 跳已算列）；无限循环，间隔 1h。
#
# 用法（OOM 时切换）：
#   pkill -f smart_frame_photo_daemon   # 停当前全套
#   nohup setsid tool/run_daemon_serial.sh > /dev/null 2>&1 &
set -uo pipefail
cd /home/peidong/source/screen-saver/daemon
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy 2>/dev/null || true
LOG=/home/peidong/.local/share/com.example.smart_frame/daemon.log
UV=/home/peidong/.local/bin/uv

while true; do
  echo "=== [串行] 阶段 dinov2+CLIP（GPU torch）$(date) ===" >> "$LOG"
  "$UV" run python -m smart_frame_photo_daemon --embed >> "$LOG" 2>&1 \
    || echo "[串行] embed 阶段异常 exit=$?" >> "$LOG"
  echo "=== [串行] 阶段 insightface 人脸（CPU）$(date) ===" >> "$LOG"
  "$UV" run python -m smart_frame_photo_daemon --faces >> "$LOG" 2>&1 \
    || echo "[串行] faces 阶段异常 exit=$?" >> "$LOG"
  echo "=== [串行] 阶段 VLM 标签（ollama GPU）$(date) ===" >> "$LOG"
  "$UV" run python -m smart_frame_photo_daemon --tags >> "$LOG" 2>&1 \
    || echo "[串行] tags 阶段异常 exit=$?" >> "$LOG"
  echo "=== [串行] 一轮完成，休眠 1h $(date) ===" >> "$LOG"
  sleep 3600
done
