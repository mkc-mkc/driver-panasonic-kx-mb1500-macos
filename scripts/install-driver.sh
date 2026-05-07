#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PPD_NAME="Panasonic_KX-MB1500-haikiri.ppd"
readonly PPD_SOURCE_DIR="$(cd "$SCRIPT_DIR/../printer/ppd" && pwd)"
readonly PPD_SOURCE_PATH="$PPD_SOURCE_DIR/$PPD_NAME"
readonly PPD_INSTALL_DIR="/Library/Printers/PPDs/Contents/Resources"
readonly PPD_INSTALL_PATH="$PPD_INSTALL_DIR/$PPD_NAME"
readonly FILTER_PATH="/Library/Printers/Panasonic/Filter/panasonic-kx-mb1500-gdi"
readonly FILTER_SOURCE_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/printer/filter/bin/panasonic-kx-mb1500-gdi"
readonly REPAIR_SCANNER_SCRIPT_PATH="$SCRIPT_DIR/repair-scanner-ica.sh"

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

# Helper держит общую логику распознавания серии MB1500, чтобы install/verify/pkg использовали один и тот же контракт.
source "$SCRIPT_DIR/helper/panasonic_model.sh"

DO_PPD_ONLY=0
SKIP_SCANNER_REPAIR=0

# Поддержка нескольких флагов: ./scripts/install-driver.sh [--ppd-only] [--without-scanner-repair]
while [ $# -gt 0 ]; do
    case "$1" in
        --ppd-only) DO_PPD_ONLY=1 ;;
        --without-scanner-repair) SKIP_SCANNER_REPAIR=1 ;;
        *)
            fail "неизвестный аргумент: $1 (допустимо: --ppd-only, --without-scanner-repair)"
            ;;
    esac
    shift
done

run_admin() {
    local command="$1"

    # Если текущий пользователь уже может выполнить действие, не поднимаем лишний admin prompt.
    if bash -lc "$command" >/dev/null 2>&1; then
        return
    fi

    # Системные каталоги CUPS требуют прав администратора, поэтому macOS запросит пароль.
    osascript <<OSA
do shell script "$command" with administrator privileges
OSA
}

find_device_uri() {
    local uri

    # URI берём только из локального CUPS, чтобы не хранить серийники в репозитории и не зашивать один региональный суффикс.
    uri="$(find_available_panasonic_mb1500_uri || true)"

    if [ -z "$uri" ]; then
        fail "Поддерживаемый Panasonic серии KX-MB1500 не найден по USB. Подключи устройство и включи питание."
    fi

    printf '%s\n' "$uri"
}

install_ppd() {
    if [ ! -f "$PPD_SOURCE_PATH" ] && [ -f "$PPD_INSTALL_PATH" ]; then
        return
    fi

    if [ ! -f "$PPD_SOURCE_PATH" ]; then
        fail "PPD не найден: $PPD_SOURCE_PATH"
    fi

    # PPD публичный и не содержит локальных идентификаторов устройства.
    run_admin "install -d -m 0755 '$PPD_INSTALL_DIR' && install -m 0644 '$PPD_SOURCE_PATH' '$PPD_INSTALL_PATH' && chown root:wheel '$PPD_INSTALL_PATH'"
}

install_filter() {
    if [ ! -f "$FILTER_SOURCE_PATH" ] && [ -x "$FILTER_PATH" ]; then
        return
    fi

    if [ ! -f "$FILTER_SOURCE_PATH" ]; then
        fail "нативный фильтр не найден: $FILTER_SOURCE_PATH"
    fi

    # Фильтр кладётся в системный каталог Panasonic, чтобы PPD не зависел от пути репозитория.
    run_admin "install -d -m 0755 '/Library/Printers/Panasonic/Filter' && install -m 0755 '$FILTER_SOURCE_PATH' '$FILTER_PATH' && chown root:wheel '$FILTER_PATH'"
}

repair_scanner_backend_if_possible() {
    # Repair-step всегда пробуем запускать из основного установщика, чтобы пользователю не приходилось вспоминать отдельный скрипт.
    if [ ! -x "$REPAIR_SCANNER_SCRIPT_PATH" ]; then
        printf 'Skipped scanner ICA repair: script not found at %s\n' "$REPAIR_SCANNER_SCRIPT_PATH"
        return
    fi

    # Если официальный Panasonic scanner backend ещё не установлен, это не ошибка печатного install flow.
    if [ ! -d "/Library/Image Capture/Devices/Panasonic MFS Scanner.app" ]; then
        printf 'Skipped scanner ICA repair: Panasonic MFS Scanner.app is not installed\n'
        return
    fi

    # Ремонт scanner backend является опциональным улучшением install flow, поэтому не валим установку печати при его сбое.
    if ! "$REPAIR_SCANNER_SCRIPT_PATH"; then
        printf 'Skipped scanner ICA repair: repair script failed, print driver installation continues\n' >&2
    fi
}

create_queue() {
    local queue_name="$1"
    local model_name="$2"
    local device_uri="$3"

    # Без нативного фильтра очередь будет принимать задания, но принтер не поймёт поток данных.
    if [ ! -x "$FILTER_PATH" ]; then
        fail "нативный фильтр не установлен: $FILTER_PATH"
    fi

    # Очередь создаётся из точного имени модели, чтобы `MB1500`, `MB1500RU` и `MB1500XX` не конфликтовали именами.
    lpadmin -x "$queue_name" >/dev/null 2>&1 || true
    lpadmin -p "$queue_name" -D "$model_name" -E -v "$device_uri" -P "$PPD_INSTALL_PATH"
    lpadmin -d "$queue_name"
    cupsenable "$queue_name"
    cupsaccept "$queue_name"
}

main() {
    local device_uri
    local model_name
    local queue_name

    install_ppd
    install_filter

    if [ "$DO_PPD_ONLY" -eq 1 ]; then
        printf 'Installed PPD: %s\nInstalled filter: %s\n' "$PPD_INSTALL_PATH" "$FILTER_PATH"
        return
    fi

    if [ "$SKIP_SCANNER_REPAIR" -eq 0 ]; then
        repair_scanner_backend_if_possible
    fi

    device_uri="$(find_device_uri)"
    # Имя модели и имя очереди выводим из одного URI, чтобы не расходились описание принтера и имя CUPS-очереди.
    model_name="$(extract_panasonic_mb1500_model "$device_uri")" || fail "не удалось определить модель Panasonic по URI: $device_uri"
    queue_name="$(build_panasonic_mb1500_queue_name "$model_name")"
    create_queue "$queue_name" "$model_name" "$device_uri"

    printf 'Installed %s as %s\n' "$model_name" "$queue_name"
}

main "$@"
