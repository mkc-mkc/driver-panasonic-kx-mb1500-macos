#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APP_INFO_PATH="$REPO_ROOT/app-info.json"
readonly PRINT_PKG_ID="ru.haikiri.panasonic-kx-mb1500.print"
readonly MFS_PKG_ID="ru.haikiri.panasonic-kx-mb1500.mfs"
readonly REPAIR_PKG_ID="ru.haikiri.panasonic-kx-mb1500.repair"
readonly BUILD_DIR="$REPO_ROOT/build/pkg"
readonly COMPONENTS_DIR="$BUILD_DIR/components"
readonly SCRIPTS_PRINT="$BUILD_DIR/scripts-print"
readonly SCRIPTS_MFS="$BUILD_DIR/scripts-mfs"
readonly SCRIPTS_REPAIR="$BUILD_DIR/scripts-repair"
readonly PAYLOAD_MFS="$BUILD_DIR/payload-mfs"
readonly RESOURCES_DIR="$BUILD_DIR/resources"
readonly OUTPUT_DIR="$REPO_ROOT/dist"
readonly DMG_PATH="$REPO_ROOT/artifacts/Mac_1.15.2.dmg"
readonly VENDOR_INSTALL_BASENAME="Panasonic-MFS-1.15.2-Install.pkg"
readonly PPD_PATH="$REPO_ROOT/printer/ppd/Panasonic_KX-MB1500-haikiri.ppd"
readonly INSTALL_SCRIPT_PATH="$REPO_ROOT/scripts/install-driver.sh"
readonly VERIFY_SCRIPT_PATH="$REPO_ROOT/scripts/verify-print.sh"
readonly REPAIR_SCRIPT_PATH="$REPO_ROOT/scripts/repair-scanner-ica.sh"
readonly MODEL_HELPER_PATH="$REPO_ROOT/scripts/helper/panasonic_model.sh"
readonly FILTER_PATH="$REPO_ROOT/printer/filter/bin/panasonic-kx-mb1500-gdi"

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

read_version_from_app_info() {
    local version

    [ -f "$APP_INFO_PATH" ] || fail "не найден app-info.json: $APP_INFO_PATH"
    version="$(grep -Eo '"[0-9]+\.[0-9]+\.[0-9]+"' "$APP_INFO_PATH" | head -n 1 | tr -d '"')"
    [ -n "$version" ] || fail "в app-info.json не найдена версия формата x.y.z"
    printf '%s\n' "$version"
}

copy_vendor_install_pkg() {
    local mount

    [ -f "$DMG_PATH" ] || fail "не найден образ Panasonic MFS (ожидался $DMG_PATH)"
    mount="$(mktemp -d /tmp/haikiri-mfs-mount.XXXXXX)"
    hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$DMG_PATH" >/dev/null
    mkdir -p "$PAYLOAD_MFS/usr/local/haikiri/panasonic-kx-mb1500/vendor"
    [ -f "$mount/Install.pkg" ] || fail "внутри $DMG_PATH нет Install.pkg (ожидался $mount/Install.pkg)"
    cp -f "$mount/Install.pkg" "$PAYLOAD_MFS/usr/local/haikiri/panasonic-kx-mb1500/vendor/$VENDOR_INSTALL_BASENAME"
    hdiutil detach "$mount" >/dev/null
    rm -rf "$mount"
}

readonly VERSION="${1:-$(read_version_from_app_info)}"
readonly PKG_PATH="$OUTPUT_DIR/Panasonic-KX-MB1500-haikiri-$VERSION.pkg"
readonly PRINT_PKG_PATH="$COMPONENTS_DIR/print.pkg"
readonly MFS_PKG_PATH="$COMPONENTS_DIR/mfs.pkg"
readonly REPAIR_PKG_PATH="$COMPONENTS_DIR/repair.pkg"

export COPYFILE_DISABLE=1
export COPY_EXTENDED_ATTRIBUTES_DISABLE=1

rm -rf "$BUILD_DIR"
mkdir -p "$SCRIPTS_PRINT" "$SCRIPTS_MFS" "$SCRIPTS_REPAIR" "$COMPONENTS_DIR" "$OUTPUT_DIR" "$RESOURCES_DIR" "$PAYLOAD_MFS"

if [ ! -x "$FILTER_PATH" ]; then
    "$REPO_ROOT/scripts/build-filter.sh"
fi

copy_vendor_install_pkg

readonly PPD_BASE64="$(base64 -i "$PPD_PATH" | tr -d '\n')"
readonly INSTALL_SCRIPT_BASE64="$(base64 -i "$INSTALL_SCRIPT_PATH" | tr -d '\n')"
readonly VERIFY_SCRIPT_BASE64="$(base64 -i "$VERIFY_SCRIPT_PATH" | tr -d '\n')"
readonly REPAIR_SCRIPT_BASE64="$(base64 -i "$REPAIR_SCRIPT_PATH" | tr -d '\n')"
readonly MODEL_HELPER_BASE64="$(base64 -i "$MODEL_HELPER_PATH" | tr -d '\n')"
readonly FILTER_BASE64="$(base64 -i "$FILTER_PATH" | tr -d '\n')"

cat > "$SCRIPTS_PRINT/postinstall" <<'POSTINSTALL'
#!/usr/bin/env bash
set -euo pipefail

readonly INSTALL_ROOT="/usr/local/haikiri/panasonic-kx-mb1500"
readonly PPD_INSTALL_DIR="/Library/Printers/PPDs/Contents/Resources"
readonly PPD_INSTALL_PATH="$PPD_INSTALL_DIR/Panasonic_KX-MB1500-haikiri.ppd"
readonly INSTALL_SCRIPT_PATH="$INSTALL_ROOT/scripts/install-driver.sh"
readonly VERIFY_SCRIPT_PATH="$INSTALL_ROOT/scripts/verify-print.sh"
readonly REPAIR_SCRIPT_PATH="$INSTALL_ROOT/scripts/repair-scanner-ica.sh"
readonly MODEL_HELPER_PATH="$INSTALL_ROOT/scripts/helper/panasonic_model.sh"
readonly FILTER_PATH="/Library/Printers/Panasonic/Filter/panasonic-kx-mb1500-gdi"

install_base64_file() {
    local mode="$1"
    local target_path="$2"
    local payload="$3"

    mkdir -p "$(dirname "$target_path")"
    printf '%s' "$payload" | /usr/bin/base64 -D > "$target_path"
    chmod "$mode" "$target_path"
    chown root:wheel "$target_path"
}

install_base64_file 0644 "$PPD_INSTALL_PATH" "__PPD_BASE64__"
install_base64_file 0755 "$INSTALL_SCRIPT_PATH" "__INSTALL_SCRIPT_BASE64__"
install_base64_file 0755 "$VERIFY_SCRIPT_PATH" "__VERIFY_SCRIPT_BASE64__"
install_base64_file 0755 "$REPAIR_SCRIPT_PATH" "__REPAIR_SCRIPT_BASE64__"
install_base64_file 0644 "$MODEL_HELPER_PATH" "__MODEL_HELPER_BASE64__"
install_base64_file 0755 "$FILTER_PATH" "__FILTER_BASE64__"

source "$MODEL_HELPER_PATH"

"$INSTALL_SCRIPT_PATH" --ppd-only

if find_available_panasonic_mb1500_uri >/dev/null 2>&1; then
    "$INSTALL_SCRIPT_PATH" --without-scanner-repair
fi

POSTINSTALL

PKG_PPD_BASE64="$PPD_BASE64" \
PKG_INSTALL_SCRIPT_BASE64="$INSTALL_SCRIPT_BASE64" \
PKG_VERIFY_SCRIPT_BASE64="$VERIFY_SCRIPT_BASE64" \
PKG_REPAIR_SCRIPT_BASE64="$REPAIR_SCRIPT_BASE64" \
PKG_MODEL_HELPER_BASE64="$MODEL_HELPER_BASE64" \
PKG_FILTER_BASE64="$FILTER_BASE64" \
perl -0pi \
    -e 's/__PPD_BASE64__/$ENV{"PKG_PPD_BASE64"}/g;' \
    -e 's/__INSTALL_SCRIPT_BASE64__/$ENV{"PKG_INSTALL_SCRIPT_BASE64"}/g;' \
    -e 's/__VERIFY_SCRIPT_BASE64__/$ENV{"PKG_VERIFY_SCRIPT_BASE64"}/g;' \
    -e 's/__REPAIR_SCRIPT_BASE64__/$ENV{"PKG_REPAIR_SCRIPT_BASE64"}/g;' \
    -e 's/__MODEL_HELPER_BASE64__/$ENV{"PKG_MODEL_HELPER_BASE64"}/g;' \
    -e 's/__FILTER_BASE64__/$ENV{"PKG_FILTER_BASE64"}/g;' \
    "$SCRIPTS_PRINT/postinstall"

chmod 0755 "$SCRIPTS_PRINT/postinstall"

cat > "$SCRIPTS_MFS/postinstall" <<POSTINSTALL_MFS
#!/usr/bin/env bash
set -euo pipefail

readonly VENDOR_PKG="/usr/local/haikiri/panasonic-kx-mb1500/vendor/$VENDOR_INSTALL_BASENAME"

[ -f "\$VENDOR_PKG" ] || { printf 'ERROR: нет вложенного пакета Panasonic: %s\n' "\$VENDOR_PKG" >&2; exit 1; }

/usr/sbin/installer -pkg "\$VENDOR_PKG" -target /
POSTINSTALL_MFS

chmod 0755 "$SCRIPTS_MFS/postinstall"

cat > "$SCRIPTS_REPAIR/postinstall" <<'POSTINSTALL_REPAIR'
#!/usr/bin/env bash
set -euo pipefail

readonly DECODE_DIR="$(mktemp -d /tmp/haikiri-repair.XXXXXX)"
readonly REPAIR_SCRIPT_PATH="$DECODE_DIR/repair-scanner-ica.sh"

cleanup() {
    rm -rf "$DECODE_DIR"
}

trap cleanup EXIT

printf '%s' "__REPAIR_SCRIPT_BASE64__" | /usr/bin/base64 -D > "$REPAIR_SCRIPT_PATH"
chmod 0755 "$REPAIR_SCRIPT_PATH"

/bin/bash "$REPAIR_SCRIPT_PATH"
POSTINSTALL_REPAIR

PKG_REPAIR_SCRIPT_BASE64="$REPAIR_SCRIPT_BASE64" \
perl -0pi \
    -e 's/__REPAIR_SCRIPT_BASE64__/$ENV{"PKG_REPAIR_SCRIPT_BASE64"}/g;' \
    "$SCRIPTS_REPAIR/postinstall"

chmod 0755 "$SCRIPTS_REPAIR/postinstall"

cat > "$RESOURCES_DIR/Welcome.html" <<'HTML'
<!DOCTYPE html>
<html><head><meta charset="utf-8"/></head><body style="font-family: system-ui; font-size: 13px;">
<p>Шаг «Настроить»: по умолчанию отмечено всё — лишнее снимайте сами.</p>
<ul>
<li><b>Полная установка:</b> «Драйвер печати», «Panasonic MFS» и «Исправить ПО Panasonic».</li>
<li><b>Только печать:</b> одна галочка — «Драйвер печати».</li>
<li><b>Только сканер:</b> «Драйвер печати» выключить, две ниже оставить. На Apple Silicon без Rosetta сканер не взлетит.</li>
<li><b>Починить то, что уже стоит:</b> только «Исправить ПО Panasonic». Имеет смысл, если MFS на диске уже есть или ставите его в этой же сессии.</li>
</ul>
<p>У Panasonic после установки иногда вылезает требование перезагрузить Mac — их инсталлятор, не наша придумка.</p>
</body></html>
HTML

cat > "$BUILD_DIR/Distribution.xml" <<DISTXML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>Panasonic KX-MB1500 — драйвер Haikiri</title>
    <welcome file="Welcome.html" mime-type="text/html"/>
    <options customize="always" require-scripts="false" rootVolumeOnly="true"/>
    <domains enable_localSystem="true"/>
    <choices-outline>
        <line choice="choice_print"/>
        <line choice="choice_mfs"/>
        <line choice="choice_repair"/>
    </choices-outline>
    <choice id="choice_print" title="Драйвер печати"
        description="PPD и CUPS-фильтр. Принтер в USB — появится очередь печати."
        start_selected="true">
        <pkg-ref id="$PRINT_PKG_ID"/>
    </choice>
    <choice id="choice_mfs" title="Panasonic MFS (сканер)"
        description="Тот самый Install.pkg с официального образа Mac_1.15.2, лежит внутри этого пакета."
        start_selected="true">
        <pkg-ref id="$MFS_PKG_ID"/>
    </choice>
    <choice id="choice_repair" title="Исправить ПО Panasonic"
        description="Под новые macOS, иначе «Захват изображений» с этим сканером часто падает."
        start_selected="true"
        enabled="choices.choice_mfs.selected || system.files.fileExistsAtPath('/Library/Image Capture/Devices/Panasonic MFS Scanner.app')">
        <pkg-ref id="$REPAIR_PKG_ID"/>
    </choice>
    <pkg-ref id="$PRINT_PKG_ID" version="$VERSION" auth="Root">#print.pkg</pkg-ref>
    <pkg-ref id="$MFS_PKG_ID" version="$VERSION" auth="Root">#mfs.pkg</pkg-ref>
    <pkg-ref id="$REPAIR_PKG_ID" version="$VERSION" auth="Root">#repair.pkg</pkg-ref>
</installer-gui-script>
DISTXML

xattr -cr "$SCRIPTS_PRINT" "$SCRIPTS_MFS" "$SCRIPTS_REPAIR" "$RESOURCES_DIR" 2>/dev/null || true
find "$SCRIPTS_PRINT" "$SCRIPTS_MFS" "$SCRIPTS_REPAIR" \( -name ".DS_Store" -o -name "._*" \) -delete

pkgbuild \
    --nopayload \
    --scripts "$SCRIPTS_PRINT" \
    --identifier "$PRINT_PKG_ID" \
    --version "$VERSION" \
    "$PRINT_PKG_PATH"

pkgbuild \
    --root "$PAYLOAD_MFS" \
    --scripts "$SCRIPTS_MFS" \
    --identifier "$MFS_PKG_ID" \
    --version "$VERSION" \
    "$MFS_PKG_PATH"

pkgbuild \
    --nopayload \
    --scripts "$SCRIPTS_REPAIR" \
    --identifier "$REPAIR_PKG_ID" \
    --version "$VERSION" \
    "$REPAIR_PKG_PATH"

productbuild \
    --distribution "$BUILD_DIR/Distribution.xml" \
    --package-path "$COMPONENTS_DIR" \
    --resources "$RESOURCES_DIR" \
    "$PKG_PATH"

printf '%s\n' "$PKG_PATH"
