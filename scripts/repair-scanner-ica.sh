#!/usr/bin/env bash
set -euo pipefail

readonly APP_PATH="/Library/Image Capture/Devices/Panasonic MFS Scanner.app"
readonly BINARY_PATH="$APP_PATH/Contents/MacOS/Panasonic MFS Scanner"
readonly FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
readonly SHIM_PATH="$FRAMEWORKS_DIR/CarbonShim.dylib"
readonly SYSTEM_CARBON="/System/Library/Frameworks/Carbon.framework/Versions/A/Carbon"
readonly SHIM_CARBON="@executable_path/../Frameworks/CarbonShim.dylib"

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

require_tool() {
    local tool="$1"

    # Без этих системных инструментов нельзя собрать shim и переподписать старый ICA backend.
    if ! command -v "$tool" >/dev/null 2>&1; then
        fail "не найден инструмент: $tool"
    fi
}

build_carbon_shim() {
    local source_path

    source_path="$(mktemp /tmp/panasonic-carbon-shim.XXXXXX.c)"

    # Старый ICA backend Panasonic ищет эти CFString-константы в Carbon, хотя на новых macOS они живут в ICADevices.
    cat > "$source_path" <<'SOURCE'
#include <CoreFoundation/CoreFoundation.h>

const CFStringRef kICAIPAddressKey = CFSTR("ipAddress");
const CFStringRef kICAIPPortKey = CFSTR("ipPort");
const CFStringRef kICAUSBLocationIDKey = CFSTR("usbLocationID");
const CFStringRef kICANotificationICAObjectKey = CFSTR("ICANotificationICAObjectKey");
const CFStringRef kICANotificationImageHeightKey = CFSTR("ICANotificationImageHeightKey");
const CFStringRef kICANotificationImageWidthKey = CFSTR("ICANotificationImageWidthKey");
const CFStringRef kICANotificationScannerDocumentNameKey = CFSTR("ICANotificationScannerDocumentNameKey");
const CFStringRef kICANotificationTypeKey = CFSTR("ICANotificationTypeKey");
const CFStringRef kICANotificationTypeObjectAdded = CFSTR("ICANotificationTypeObjectAdded");
const CFStringRef kICANotificationTypeObjectRemoved = CFSTR("ICANotificationTypeObjectRemoved");
const CFStringRef kICANotificationTypeScanProgressStatus = CFSTR("ICANotificationTypeScanProgressStatus");
const CFStringRef kICANotificationTypeScannerPageDone = CFSTR("ICANotificationTypeScannerPageDone");
const CFStringRef kICANotificationTypeScannerScanDone = CFSTR("ICANotificationTypeScannerScanDone");
const CFStringRef kICANotificationTypeTransactionCanceled = CFSTR("ICANotificationTypeTransactionCanceled");
SOURCE

    mkdir -p "$FRAMEWORKS_DIR"

    # Шим остаётся x86_64, потому что официальный Panasonic ICA binary не имеет arm64-среза.
    clang -dynamiclib -arch x86_64 "$source_path" \
        -framework CoreFoundation \
        -framework Carbon \
        -framework ICADevices \
        -Wl,-reexport_framework,Carbon \
        -Wl,-reexport_framework,ICADevices \
        -install_name "$SHIM_CARBON" \
        -o "$SHIM_PATH"

    rm -f "$source_path"
}

patch_binary_linkage() {
    # Если бинарник уже указывает на shim, повторная установка не должна падать.
    install_name_tool -change "$SYSTEM_CARBON" "$SHIM_CARBON" "$BINARY_PATH" 2>/dev/null || true
}

sign_scanner_app() {
    codesign --force --sign - "$SHIM_PATH"
    codesign --force --deep --sign - "$APP_PATH"
}

restart_image_capture_services() {
    # icdd кеширует ICA modules; перезапуск заставляет Image Capture увидеть переподписанный backend.
    killall "Panasonic MFS Scanner" "Image Capture" icdd >/dev/null 2>&1 || true
}

main() {
    # Ремонтируем только уже установленный официальный Panasonic ICA backend.
    [ -d "$APP_PATH" ] || fail "Panasonic MFS Scanner.app не найден: $APP_PATH"
    # Исполняемый файл нужен отдельно, потому что именно его load command указывает на устаревший Carbon.
    [ -f "$BINARY_PATH" ] || fail "исполняемый файл сканера не найден: $BINARY_PATH"

    require_tool clang
    require_tool install_name_tool
    require_tool codesign

    build_carbon_shim
    patch_binary_linkage
    sign_scanner_app
    restart_image_capture_services

    printf 'Repaired Panasonic Image Capture backend: %s\n' "$APP_PATH"
}

main "$@"
