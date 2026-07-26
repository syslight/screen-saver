#!/usr/bin/env bash
set -euo pipefail

VENDOR_HOME="com.alibaba.ailabs.genie.children/.activity.HomeActivity"

adb get-state >/dev/null
adb shell am force-stop com.example.smart_frame
adb shell appops set \
    com.alibaba.ailabs.genie.smartapp SYSTEM_ALERT_WINDOW default
adb shell appops set \
    com.alibaba.ailabs.genie.smartapp RECORD_AUDIO default
adb shell settings put secure screensaver_enabled 1
adb shell "su -c 'if test -f /data/local/tmp/smart-frame-kiosk.pid; then kill \$(cat /data/local/tmp/smart-frame-kiosk.pid) 2>/dev/null || true; fi; rm -f /data/local/tmp/smart-frame-kiosk.pid /data/adb/service.d/smart-frame-kiosk.sh'"
adb shell cmd package set-home-activity --user 0 "$VENDOR_HOME" >/dev/null
adb shell input keyevent 224
adb shell input keyevent 3

echo "CCL kiosk watchdog removed; vendor smartapp and screensaver restored"
echo "default HOME: $VENDOR_HOME"
