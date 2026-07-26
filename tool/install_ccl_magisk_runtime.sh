#!/usr/bin/env bash
set -euo pipefail

MAGISK_APK="${1:-${MAGISK_APK:-}}"
SERIAL="${ANDROID_SERIAL:-}"

if [[ -z "$MAGISK_APK" || ! -f "$MAGISK_APK" ]]; then
    echo "usage: $0 /path/to/Magisk.apk" >&2
    exit 2
fi

ADB=(adb)
if [[ -n "$SERIAL" ]]; then
    ADB+=( -s "$SERIAL" )
fi
"${ADB[@]}" get-state >/dev/null

DEVICE_ABI="$("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$DEVICE_ABI" in
    armeabi-v7a|armeabi)
        APK_ABI=armeabi-v7a
        ;;
    arm64-v8a)
        APK_ABI=arm64-v8a
        ;;
    *)
        echo "unsupported CCL ABI: $DEVICE_ABI" >&2
        exit 1
        ;;
esac

WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT
RUNTIME_DIR="$WORK_DIR/runtime"
ASSET_DIR="$WORK_DIR/assets"
mkdir -p "$RUNTIME_DIR" "$ASSET_DIR"

unzip -q "$MAGISK_APK" 'assets/*' -d "$ASSET_DIR"
for binary in init-ld magisk magiskboot magiskinit magiskpolicy busybox; do
    unzip -qj "$MAGISK_APK" "lib/$APK_ABI/lib$binary.so" -d "$RUNTIME_DIR"
    mv "$RUNTIME_DIR/lib$binary.so" "$RUNTIME_DIR/$binary"
done
cp -a "$ASSET_DIR/assets/." "$RUNTIME_DIR/"

if [[ "$APK_ABI" == arm64-v8a ]]; then
    unzip -qj "$MAGISK_APK" \
        'lib/armeabi-v7a/libmagisk.so' -d "$RUNTIME_DIR"
    mv "$RUNTIME_DIR/libmagisk.so" "$RUNTIME_DIR/magisk32"
fi
rm -f \
    "$RUNTIME_DIR/bootctl" \
    "$RUNTIME_DIR/main.jar" \
    "$RUNTIME_DIR/module_installer.sh" \
    "$RUNTIME_DIR/uninstaller.sh"
chmod -R 0755 "$RUNTIME_DIR"

LOCAL_HASH="$(sha256sum "$RUNTIME_DIR/magisk" | awk '{print $1}')"
BOOT_HASH="$("${ADB[@]}" shell \
    'su -c "sha256sum /sbin/magisk 2>/dev/null"' | awk '{print $1}' | tr -d '\r')"
if [[ -z "$BOOT_HASH" || "$LOCAL_HASH" != "$BOOT_HASH" ]]; then
    echo "Magisk APK does not match the Magisk binary in the CCL boot image" >&2
    exit 1
fi

REMOTE_STAGE="/data/local/tmp/ccl-magisk-runtime-$$"
BACKUP="/data/adb/magisk.before-runtime-$(date +%Y%m%d-%H%M%S)"
"${ADB[@]}" shell \
    "su -c 'mkdir -p $REMOTE_STAGE && chmod 0777 $REMOTE_STAGE'"
"${ADB[@]}" push "$RUNTIME_DIR/." "$REMOTE_STAGE/" >/dev/null
"${ADB[@]}" shell "su -c '
    if test -d /data/adb/magisk; then mv /data/adb/magisk $BACKUP; fi
    mv $REMOTE_STAGE /data/adb/magisk
    chown -R 0:0 /data/adb/magisk
    chmod -R 0755 /data/adb/magisk
    chcon -R u:object_r:system_file:s0 /data/adb/magisk
'"

echo "CCL Magisk runtime installed from matching APK"
echo "previous runtime backup: $BACKUP"
echo "reboot the CCL and verify /cache/magisk.log before relying on service.d"
