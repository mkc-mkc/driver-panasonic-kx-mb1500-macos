#!/usr/bin/env bash
set -euo pipefail

readonly APP_PATH="/Library/Image Capture/Devices/Panasonic MFS Scanner.app"
readonly BINARY_PATH="$APP_PATH/Contents/MacOS/Panasonic MFS Scanner"
readonly FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
readonly SHIM_PATH="$FRAMEWORKS_DIR/CarbonShim.dylib"
readonly OBJC_SHIM_PATH="$FRAMEWORKS_DIR/ObjCMsgFixupShim.dylib"
readonly SYSTEM_CARBON="/System/Library/Frameworks/Carbon.framework/Versions/A/Carbon"
readonly SHIM_CARBON="@executable_path/../Frameworks/CarbonShim.dylib"
readonly SYSTEM_LIBOBJC="/usr/lib/libobjc.A.dylib"
readonly SHIM_LIBOBJC="@executable_path/../Frameworks/ObjCMsgFixupShim.dylib"
readonly MODE="${1:-}"

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

quote_shell_argument() {
    local value="$1"

    printf "'%s'" "${value//\'/\'\\\'\'}"
}

escape_applescript_string() {
    local value="$1"

    value="${value//\\/\\\\}"
    printf '%s' "${value//\"/\\\"}"
}

run_as_admin_if_needed() {
    local script_path
    local admin_command
    local applescript_command

    if [ "$(id -u)" -eq 0 ]; then
        return
    fi

    if [ "$MODE" = "--as-root" ]; then
        fail "режим --as-root можно запускать только с правами root"
    fi

    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    admin_command="/bin/bash $(quote_shell_argument "$script_path") --as-root"
    applescript_command="$(escape_applescript_string "$admin_command")"

    # Приложение сканера стоит в /Library и часто принадлежит root, поэтому ремонт должен выполняться с правами администратора.
    osascript <<OSA
do shell script "$applescript_command" with administrator privileges
OSA
    exit 0
}

build_carbon_shim() {
    local source_dir
    local source_path

    source_dir="$(mktemp -d /tmp/panasonic-carbon-shim.XXXXXX)"
    source_path="$source_dir/CarbonShim.c"

    # Старый ICA backend Panasonic ищет эти CFString-константы в Carbon, хотя на новых macOS они живут в ICADevices.
    cat > "$source_path" <<'SOURCE'
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor))
static void panasonic_mfs_debug_log_init(void)
{
    const char *log_path = getenv("PANASONIC_MFS_DEBUG_LOG");
    if (log_path == NULL || log_path[0] == '\0') {
        return;
    }

    int fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) {
        return;
    }

    dprintf(fd, "\n--- Panasonic MFS Scanner started pid=%d ---\n", getpid());
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    close(fd);
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}

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

    rm -rf "$source_dir"
}

build_objc_msg_fixup_shim() {
    local source_dir
    local source_path

    source_dir="$(mktemp -d /tmp/panasonic-objc-msg-fixup.XXXXXX)"
    source_path="$source_dir/ObjCMsgFixupShim.c"

    # Panasonic собран под старый Objective-C message-ref ABI: selector лежит вторым полем, а первое поле должен заполнять libobjc.
    cat > "$source_path" <<'SOURCE'
__asm__(
    ".text\n"
    ".globl _objc_msgSend_fixup\n"
    "_objc_msgSend_fixup:\n"
    "    movq 8(%rsi), %rsi\n"
    "    jmp _objc_msgSend\n"
    ".globl _objc_msgSendSuper2_fixup\n"
    "_objc_msgSendSuper2_fixup:\n"
    "    movq 8(%rsi), %rsi\n"
    "    jmp _objc_msgSendSuper2\n"
);
SOURCE

    mkdir -p "$FRAMEWORKS_DIR"

    # На macOS 15 эти fixup-символы в libobjc больше не обслуживают старый Panasonic binary, поэтому даём тонкий x86_64 shim.
    clang -dynamiclib -arch x86_64 "$source_path" \
        -Wl,-reexport_library,/usr/lib/libobjc.A.dylib \
        -install_name "$SHIM_LIBOBJC" \
        -o "$OBJC_SHIM_PATH"

    rm -rf "$source_dir"
}

patch_binary_linkage() {
    # Если бинарник уже указывает на shim, повторная установка не должна менять load commands.
    if ! otool -L "$BINARY_PATH" | grep -F "$SHIM_CARBON" >/dev/null 2>&1; then
        install_name_tool -change "$SYSTEM_CARBON" "$SHIM_CARBON" "$BINARY_PATH"
    fi

    # Подменяем только зависимость самого Panasonic backend; системный libobjc остаётся реальным reexport внутри shim.
    if ! otool -L "$BINARY_PATH" | grep -F "$SHIM_LIBOBJC" >/dev/null 2>&1; then
        install_name_tool -change "$SYSTEM_LIBOBJC" "$SHIM_LIBOBJC" "$BINARY_PATH"
    fi

    # Без этой проверки install_name_tool может тихо оставить backend привязанным к старому Carbon.
    if ! otool -L "$BINARY_PATH" | grep -F "$SHIM_CARBON" >/dev/null 2>&1; then
        fail "не удалось перепривязать Panasonic scanner backend на CarbonShim"
    fi

    # Если старые Objective-C message refs останутся без shim, scan падает прыжком в NULL при notifyWarmUpStarted.
    if ! otool -L "$BINARY_PATH" | grep -F "$SHIM_LIBOBJC" >/dev/null 2>&1; then
        fail "не удалось перепривязать Panasonic scanner backend на ObjCMsgFixupShim"
    fi
}

read_binary_hex() {
    local offset="$1"
    local length="$2"

    xxd -p -l "$length" -s "$offset" "$BINARY_PATH" | tr -d '\n'
}

write_binary_hex() {
    local offset="$1"
    local hex="$2"

    printf '%s' "$hex" | xxd -r -p | dd of="$BINARY_PATH" bs=1 seek="$offset" conv=notrunc status=none
}

get_x86_64_slice_offset() {
    local slice_offset

    slice_offset="$(lipo -detailed_info "$BINARY_PATH" | awk '
        /architecture x86_64/ { found = 1; next }
        found && $1 == "offset" { print $2; exit }
    ')"

    # Эти offsets относятся к x86_64-срезу официального Panasonic 1.02 binary; без среза патчить нечего.
    [ -n "$slice_offset" ] || fail "не найден x86_64-срез Panasonic scanner backend"
    printf '%s\n' "$slice_offset"
}

patch_expected_bytes() {
    local offset="$1"
    local original_hex="$2"
    local patched_hex="$3"
    local description="$4"
    local length
    local current_hex

    length="$((${#original_hex} / 2))"
    current_hex="$(read_binary_hex "$offset" "$length")"

    if [ "$current_hex" = "$patched_hex" ]; then
        return
    fi

    if [ "$current_hex" != "$original_hex" ]; then
        fail "неожиданные байты для $description по offset $offset: $current_hex"
    fi

    write_binary_hex "$offset" "$patched_hex"
}

patch_legacy_open_device_handshake() {
    local x86_64_offset

    x86_64_offset="$(get_x86_64_slice_offset)"

    # Старый ICA handshake ждёт повторного входа через ICDScannerConnectUSBDevice; на macOS 15 UI остаётся в ожидании.
    patch_expected_bytes "$((x86_64_offset + 0xb77d))" "e8f2550100" "9090909090" "ICDScannerConnectUSBDevice call"
    # После отключения callback идём в существующий путь createDevice, чтобы backend сам открыл USB-сканер.
    patch_expected_bytes "$((x86_64_offset + 0xb79e))" "eb4d" "eb1c" "open-device createDevice jump"
}

sign_scanner_app() {
    codesign --force --sign - "$SHIM_PATH"
    codesign --force --sign - "$OBJC_SHIM_PATH"
    codesign --force --deep --sign - "$APP_PATH"
}

restart_image_capture_services() {
    # icdd кеширует ICA modules; перезапуск заставляет Image Capture увидеть переподписанный backend.
    killall "Panasonic MFS Scanner" "Image Capture" icdd >/dev/null 2>&1 || true
}

main() {
    run_as_admin_if_needed

    # Ремонтируем только уже установленный официальный Panasonic ICA backend.
    [ -d "$APP_PATH" ] || fail "Panasonic MFS Scanner.app не найден: $APP_PATH"
    # Исполняемый файл нужен отдельно, потому что именно его load command указывает на устаревший Carbon.
    [ -f "$BINARY_PATH" ] || fail "исполняемый файл сканера не найден: $BINARY_PATH"

    require_tool clang
    require_tool install_name_tool
    require_tool codesign
    require_tool lipo
    require_tool xxd

    build_carbon_shim
    build_objc_msg_fixup_shim
    patch_binary_linkage
    patch_legacy_open_device_handshake
    sign_scanner_app
    restart_image_capture_services

    printf 'Repaired Panasonic Image Capture backend: %s\n' "$APP_PATH"
}

main "$@"
