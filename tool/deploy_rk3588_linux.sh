#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_DIR/apps/smart_frame"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
AGENT_URL="${1:-${SMART_FRAME_AGENT_URL:-}}"
CREDENTIAL_FILE="${2:-${SMART_FRAME_NODE_CREDENTIAL_FILE:-}}"

if [[ -z "$AGENT_URL" || -z "$CREDENTIAL_FILE" ]]; then
    echo "usage: $0 http://<home-agent>:8790 <rk3588-credentials.json>" >&2
    exit 2
fi
if [[ "$(uname -m)" != aarch64 && "$(uname -m)" != arm64 ]]; then
    echo "this script must run natively on the RK3588 arm64 host" >&2
    exit 1
fi
if [[ ! "$AGENT_URL" =~ ^https?://[^/]+(:[0-9]+)?/?$ ]]; then
    echo "invalid home-agent URL: $AGENT_URL" >&2
    exit 2
fi
if [[ ! -f "$CREDENTIAL_FILE" ]]; then
    echo "missing node credential file: $CREDENTIAL_FILE" >&2
    exit 2
fi
for command in curl jq systemctl "$FLUTTER_BIN"; do
    command -v "$command" >/dev/null || {
        echo "missing required command: $command" >&2
        exit 1
    }
done

AGENT_URL="${AGENT_URL%/}"
NODE_ID="$(jq -er '.nodeId' "$CREDENTIAL_FILE")"
ROOM_ID="$(jq -er '.roomId' "$CREDENTIAL_FILE")"
DEVICE_KEY="$(jq -er '.deviceKey' "$CREDENTIAL_FILE")"
curl --fail --silent --show-error --max-time 8 \
    -H "Authorization: Node $NODE_ID:$DEVICE_KEY" \
    "$AGENT_URL/api/v1/media/status" >/dev/null

(
    cd "$APP_DIR"
    env \
        -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
        -u ALL_PROXY -u all_proxy \
        "$FLUTTER_BIN" pub get
    env \
        -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
        -u ALL_PROXY -u all_proxy \
        "$FLUTTER_BIN" build linux --release \
        --dart-define="SMART_FRAME_AGENT_URL=$AGENT_URL"
)

BUNDLE="$APP_DIR/build/linux/arm64/release/bundle"
if [[ ! -x "$BUNDLE/smart_frame" ]]; then
    echo "missing arm64 bundle: $BUNDLE" >&2
    exit 1
fi

INSTALL_ROOT="$HOME/.local/opt/smart-frame"
RELEASE_DIR="$INSTALL_ROOT/releases/$(date +%Y%m%d-%H%M%S)"
CONFIG_DIR="$HOME/.local/share/com.example.smart_frame"
CONFIG_PATH="$CONFIG_DIR/config.json"
SERVICE_DIR="$HOME/.config/systemd/user"
TEMP_CONFIG="$(mktemp)"
trap 'rm -f "$TEMP_CONFIG" "$TEMP_CONFIG.next"' EXIT

install -d -m 0755 "$RELEASE_DIR" "$CONFIG_DIR" "$SERVICE_DIR"
cp -a "$BUNDLE/." "$RELEASE_DIR/"
if [[ -f "$CONFIG_PATH" ]] && jq -e . "$CONFIG_PATH" >/dev/null 2>&1; then
    cp "$CONFIG_PATH" "$TEMP_CONFIG"
else
    jq -n '{}' >"$TEMP_CONFIG"
fi
jq \
    --arg agentUrl "$AGENT_URL" \
    --arg nodeId "$NODE_ID" \
    --arg roomId "$ROOM_ID" \
    --arg deviceKey "$DEVICE_KEY" \
    '. + {serverRole:"display", agentUrl:$agentUrl, nodeId:$nodeId, roomId:$roomId, deviceKey:$deviceKey, musicOutputEnabled:true}' \
    "$TEMP_CONFIG" >"$TEMP_CONFIG.next"
install -m 0600 "$TEMP_CONFIG.next" "$CONFIG_PATH"
install -m 0644 \
    "$REPO_DIR/deploy/smart-frame-display-rk3588.service" \
    "$SERVICE_DIR/smart-frame-display.service"
ln -sfn "$RELEASE_DIR" "$INSTALL_ROOT/current"

systemctl --user daemon-reload
systemctl --user enable --now smart-frame-display.service
systemctl --user restart smart-frame-display.service
systemctl --user is-active --quiet smart-frame-display.service

echo "RK3588 smart_frame deployed: $RELEASE_DIR"
echo "home agent: $AGENT_URL"
echo "node credential: installed with mode 0600 (not printed)"
