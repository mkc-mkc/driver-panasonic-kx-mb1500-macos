#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APP_INFO_PATH="$REPO_ROOT/app-info.json"
readonly PACKAGE_ID="ru.haikiri.panasonic-kx-mb1500"
readonly BUILD_DIR="$REPO_ROOT/build/pkg"
readonly SCRIPTS_DIR="$BUILD_DIR/scripts"
readonly OUTPUT_DIR="$REPO_ROOT/dist"
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

    # Берём первую полную версию вида x.y.z из app-info.json, потому что именно она нужна pkgbuild и имени итогового пакета.
    [ -f "$APP_INFO_PATH" ] || fail "не найден app-info.json: $APP_INFO_PATH"
    version="$(grep -Eo '"[0-9]+\.[0-9]+\.[0-9]+"' "$APP_INFO_PATH" | head -n 1 | tr -d '"')"

    # Если в app-info.json нет полной версии, лучше сразу остановиться, чем собрать pkg с неверной версией.
    [ -n "$version" ] || fail "в app-info.json не найдена версия формата x.y.z"
    printf '%s\n' "$version"
}

readonly VERSION="${1:-$(read_version_from_app_info)}"
readonly PKG_PATH="$OUTPUT_DIR/Panasonic-KX-MB1500-haikiri-$VERSION.pkg"

export COPYFILE_DISABLE=1
export COPY_EXTENDED_ATTRIBUTES_DISABLE=1

rm -rf "$BUILD_DIR"
mkdir -p "$SCRIPTS_DIR" "$OUTPUT_DIR"

if [ ! -x "$FILTER_PATH" ]; then
    "$REPO_ROOT/scripts/build-filter.sh"
fi

readonly PPD_BASE64="$(base64 -i "$PPD_PATH" | tr -d '\n')"
readonly INSTALL_SCRIPT_BASE64="$(base64 -i "$INSTALL_SCRIPT_PATH" | tr -d '\n')"
readonly VERIFY_SCRIPT_BASE64="$(base64 -i "$VERIFY_SCRIPT_PATH" | tr -d '\n')"
readonly REPAIR_SCRIPT_BASE64="$(base64 -i "$REPAIR_SCRIPT_PATH" | tr -d '\n')"
readonly MODEL_HELPER_BASE64="$(base64 -i "$MODEL_HELPER_PATH" | tr -d '\n')"
readonly FILTER_BASE64="$(base64 -i "$FILTER_PATH" | tr -d '\n')"

cat > "$SCRIPTS_DIR/postinstall" <<'POSTINSTALL'
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

    # Пакет без payload не тянет AppleDouble/xattr мусор, поэтому файлы раскладываются из postinstall.
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

# Helper раскладываем до запуска install-driver, потому что postinstall и сам установщик используют общий контракт распознавания модели.
source "$MODEL_HELPER_PATH"

"$INSTALL_SCRIPT_PATH" --ppd-only

# Очередь создаётся только при подключённом USB-устройстве, чтобы offline-install не падал.
if find_available_panasonic_mb1500_uri >/dev/null 2>&1; then
    "$INSTALL_SCRIPT_PATH"
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
    "$SCRIPTS_DIR/postinstall"

chmod 0755 "$SCRIPTS_DIR/postinstall"

xattr -cr "$SCRIPTS_DIR" 2>/dev/null || true
find "$SCRIPTS_DIR" \( -name ".DS_Store" -o -name "._*" \) -delete

pkgbuild \
    --nopayload \
    --scripts "$SCRIPTS_DIR" \
    --identifier "$PACKAGE_ID" \
    --version "$VERSION" \
    "$PKG_PATH"

printf '%s\n' "$PKG_PATH"
