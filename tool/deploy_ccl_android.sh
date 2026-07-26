#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_DIR/apps/smart_frame"
FLUTTER_BIN="${FLUTTER_BIN:-/home/peidong/flutter/bin/flutter}"
TAKE_OVER=false
if [[ "${1:-}" == "--take-over" ]]; then
    TAKE_OVER=true
    shift
fi
AGENT_URL="${1:-${SMART_FRAME_AGENT_URL:-}}"
CREDENTIAL_FILE="${2:-${SMART_FRAME_NODE_CREDENTIAL_FILE:-}}"
PACKAGE="com.example.smart_frame"
HOME_COMPONENT="$PACKAGE/.MainActivity"
KIOSK_SCRIPT="$REPO_DIR/tool/ccl-smart-frame-kiosk.sh"
APK="$APP_DIR/build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk"

if [[ -z "$AGENT_URL" || -z "$CREDENTIAL_FILE" ]]; then
    echo "usage: $0 [--take-over] http://<home-agent>:8790 <node-credentials.json>" >&2
    exit 2
fi
if [[ ! "$AGENT_URL" =~ ^https?://[^/]+(:[0-9]+)?/?$ ]]; then
    echo "invalid home-agent URL: $AGENT_URL" >&2
    exit 2
fi
if [[ ! -f "$CREDENTIAL_FILE" ]]; then
    echo "missing node credential file: $CREDENTIAL_FILE" >&2
    exit 2
fi
AGENT_URL="${AGENT_URL%/}"
NODE_ID="$(jq -er '.nodeId' "$CREDENTIAL_FILE")"
ROOM_ID="$(jq -er '.roomId' "$CREDENTIAL_FILE")"
DEVICE_KEY="$(jq -er '.deviceKey' "$CREDENTIAL_FILE")"

adb get-state >/dev/null
curl --fail --silent --show-error --max-time 8 \
    -H "Authorization: Node $NODE_ID:$DEVICE_KEY" \
    "$AGENT_URL/api/v1/media/status" >/dev/null

(
    cd "$APP_DIR"
    env \
        -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
        -u ALL_PROXY -u all_proxy \
        "$FLUTTER_BIN" build apk \
        --release \
        --split-per-abi \
        --target-platform android-arm,android-arm64 \
        --dart-define="SMART_FRAME_AGENT_URL=$AGENT_URL"
)

if [[ ! -f "$APK" ]]; then
    echo "missing ARMv7 APK: $APK" >&2
    exit 1
fi
if ! unzip -Z1 "$APK" | grep -q '^lib/armeabi-v7a/libflutter\.so$'; then
    echo "APK does not contain the ARMv7 Flutter engine" >&2
    exit 1
fi

# CCL /data 只有约 1.7 GiB；旧照片缓存和已停用的本地生成音乐可重建。
adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
adb shell "su -c 'rm -rf /data/user/0/$PACKAGE/files/nas-cache /data/user/0/$PACKAGE/files/generated-music'" \
    >/dev/null 2>&1 || true
adb install -r -g "$APK"
CONFIG_PATH="/data/user/0/$PACKAGE/files/config.json"
TEMP_CONFIG="$(mktemp)"
trap 'rm -f "$TEMP_CONFIG"' EXIT
if ! adb shell "su -c 'cat $CONFIG_PATH'" >"$TEMP_CONFIG" 2>/dev/null; then
    jq -n '{}' >"$TEMP_CONFIG"
fi
jq \
    --arg agentUrl "$AGENT_URL" \
    --arg nodeId "$NODE_ID" \
    --arg roomId "$ROOM_ID" \
    --arg deviceKey "$DEVICE_KEY" \
    '. + {serverRole:"display", agentUrl:$agentUrl, nodeId:$nodeId, roomId:$roomId, deviceKey:$deviceKey, musicOutputEnabled:true}' \
    "$TEMP_CONFIG" >"$TEMP_CONFIG.next"
mv "$TEMP_CONFIG.next" "$TEMP_CONFIG"
adb push "$TEMP_CONFIG" /data/local/tmp/smart_frame_config.json >/dev/null
adb shell "su -c 'mkdir -p /data/user/0/$PACKAGE/files; cp /data/local/tmp/smart_frame_config.json $CONFIG_PATH; owner=\$(stat -c %u:%g /data/user/0/$PACKAGE/files); chown \$owner $CONFIG_PATH; chmod 600 $CONFIG_PATH; restorecon -F $CONFIG_PATH; rm /data/local/tmp/smart_frame_config.json'"
if $TAKE_OVER; then
    if ! adb shell "su -c 'test -x /data/adb/magisk/magisk -a -x /data/adb/magisk/busybox'"; then
        echo "Magisk runtime is incomplete; service.d cannot start the kiosk watchdog." >&2
        echo "Run tool/install_ccl_magisk_runtime.sh with the APK matching /sbin/magisk, reboot, then deploy again." >&2
        exit 1
    fi
    adb shell appops set \
        com.alibaba.ailabs.genie.smartapp SYSTEM_ALERT_WINDOW deny
    adb shell appops set \
        com.alibaba.ailabs.genie.smartapp RECORD_AUDIO deny
    adb shell settings put secure screensaver_enabled 0
    adb push "$KIOSK_SCRIPT" /data/local/tmp/smart-frame-kiosk.sh >/dev/null
    adb shell "su -c 'mkdir -p /data/adb/service.d; cp /data/local/tmp/smart-frame-kiosk.sh /data/adb/service.d/smart-frame-kiosk.sh; chown root:root /data/adb/service.d/smart-frame-kiosk.sh; chmod 755 /data/adb/service.d/smart-frame-kiosk.sh; rm /data/local/tmp/smart-frame-kiosk.sh; if test -f /data/local/tmp/smart-frame-kiosk.pid; then kill \$(cat /data/local/tmp/smart-frame-kiosk.pid) 2>/dev/null || true; fi; sh /data/adb/service.d/smart-frame-kiosk.sh >/dev/null 2>&1 &'"
fi
adb shell am force-stop "$PACKAGE"
adb shell input keyevent 224
adb shell am start -n "$HOME_COMPONENT" >/dev/null

echo "CCL smart_frame deployed: $APK"
echo "home agent: $AGENT_URL"
echo "node credential: installed (not printed)"
echo "vendor UI takeover: $TAKE_OVER"
if $TAKE_OVER; then
    echo "Magisk kiosk watchdog: installed"
fi
