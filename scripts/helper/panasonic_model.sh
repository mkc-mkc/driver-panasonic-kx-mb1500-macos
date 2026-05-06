#!/usr/bin/env bash

readonly PANASONIC_MB1500_USB_URI_REGEX='^usb://Panasonic/(KX-MB1500([A-Z]{0,2}))([?].*)?$'

is_supported_panasonic_mb1500_uri() {
    local device_uri="$1"

    # Поддерживаем базовую модель без суффикса и региональные варианты с одной или двумя латинскими буквами.
    [[ "$device_uri" =~ $PANASONIC_MB1500_USB_URI_REGEX ]]
}

extract_panasonic_mb1500_model() {
    local device_uri="$1"

    # Возвращаем точное имя модели из USB URI, чтобы остальные скрипты не дублировали парсинг.
    if [[ "$device_uri" =~ $PANASONIC_MB1500_USB_URI_REGEX ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return
    fi

    return 1
}

find_supported_panasonic_mb1500_uri() {
    local device_uri

    # Ищем только прямые USB-устройства CUPS, потому что репозиторий рассчитан именно на локальное USB-подключение.
    while read -r _ device_uri; do
        if is_supported_panasonic_mb1500_uri "$device_uri"; then
            printf '%s\n' "$device_uri"
            return
        fi
    done < <(lpinfo -v 2>/dev/null)

    return 1
}

find_installed_panasonic_mb1500_uri() {
    local printer_line
    local device_uri

    # После установки очереди безопаснее брать URI через `lpstat -v`, потому что на некоторых macOS `lpinfo -v` может подвисать.
    while IFS= read -r printer_line; do
        device_uri="${printer_line##*: }"
        if is_supported_panasonic_mb1500_uri "$device_uri"; then
            printf '%s\n' "$device_uri"
            return
        fi
    done < <(lpstat -v 2>/dev/null)

    return 1
}

find_available_panasonic_mb1500_uri() {
    local device_uri

    # Сначала пробуем уже установленную очередь, потому что это самый быстрый и стабильный путь на рабочей системе.
    device_uri="$(find_installed_panasonic_mb1500_uri || true)"
    if [ -n "$device_uri" ]; then
        printf '%s\n' "$device_uri"
        return
    fi

    # Если очереди ещё нет, делаем ограниченную по времени попытку обнаружить «сырой» USB URI через `lpinfo -v`.
    while read -r _ device_uri; do
        if is_supported_panasonic_mb1500_uri "$device_uri"; then
            printf '%s\n' "$device_uri"
            return
        fi
    done < <(perl -e 'alarm 10; exec @ARGV' lpinfo -v 2>/dev/null || true)

    return 1
}

build_panasonic_mb1500_queue_name() {
    local model_name="$1"

    # Имя очереди строим из точного имени модели, чтобы разные региональные варианты не конфликтовали между собой.
    printf 'Panasonic_%s\n' "${model_name//-/_}"
}
