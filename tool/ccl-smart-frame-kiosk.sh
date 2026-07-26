#!/system/bin/sh

PID_FILE=/data/local/tmp/smart-frame-kiosk.pid
COMPONENT=com.example.smart_frame/.MainActivity

echo $$ > "$PID_FILE"
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done
sleep 12

while true; do
    if ! dumpsys window windows 2>/dev/null \
        | grep -m1 'mCurrentFocus' \
        | grep -q 'com.example.smart_frame'; then
        am start -n "$COMPONENT" >/dev/null 2>&1
    fi
    sleep 5
done
