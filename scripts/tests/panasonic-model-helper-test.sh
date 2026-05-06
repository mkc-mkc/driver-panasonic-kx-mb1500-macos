#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Подключаем именно production-helper, чтобы тест покрывал тот же код, который используют install/verify/pkg.
source "$SCRIPT_DIR/../helper/panasonic_model.sh"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        printf 'ASSERTION FAILED: %s\nExpected: %s\nActual: %s\n' "$message" "$expected" "$actual" >&2
        exit 1
    fi
}

assert_true() {
    local message="$1"

    if ! eval "$2"; then
        printf 'ASSERTION FAILED: %s\n' "$message" >&2
        exit 1
    fi
}

assert_false() {
    local message="$1"

    if eval "$2"; then
        printf 'ASSERTION FAILED: %s\n' "$message" >&2
        exit 1
    fi
}

main() {
    # Проверяем базовую модель без регионального суффикса, потому что пользователь отдельно попросил поддержать и её.
    assert_true "base model URI must be supported" "is_supported_panasonic_mb1500_uri 'usb://Panasonic/KX-MB1500?serial=1'"
    assert_eq "KX-MB1500" "$(extract_panasonic_mb1500_model 'usb://Panasonic/KX-MB1500?serial=1')" "base model must be extracted from URI"
    assert_eq "Panasonic_KX_MB1500" "$(build_panasonic_mb1500_queue_name 'KX-MB1500')" "base model queue name must be normalized"

    # Проверяем RU-вариант, потому что он уже используется в текущей установленной очереди и не должен сломаться.
    assert_true "RU model URI must be supported" "is_supported_panasonic_mb1500_uri 'usb://Panasonic/KX-MB1500RU?serial=2'"
    assert_eq "KX-MB1500RU" "$(extract_panasonic_mb1500_model 'usb://Panasonic/KX-MB1500RU?serial=2')" "RU model must be extracted from URI"
    assert_eq "Panasonic_KX_MB1500RU" "$(build_panasonic_mb1500_queue_name 'KX-MB1500RU')" "RU model queue name must be normalized"

    # Проверяем двухбуквенный суффикс, потому что именно такой шаблон пользователь попросил поддержать явно.
    assert_true "two-letter suffix URI must be supported" "is_supported_panasonic_mb1500_uri 'usb://Panasonic/KX-MB1500CX?serial=3'"
    assert_eq "KX-MB1500CX" "$(extract_panasonic_mb1500_model 'usb://Panasonic/KX-MB1500CX?serial=3')" "two-letter suffix model must be extracted from URI"
    assert_eq "Panasonic_KX_MB1500CX" "$(build_panasonic_mb1500_queue_name 'KX-MB1500CX')" "two-letter suffix queue name must be normalized"

    # Отсекаем чужие модели, чтобы helper случайно не начал цеплять соседние серии Panasonic.
    assert_false "different Panasonic series must not match" "is_supported_panasonic_mb1500_uri 'usb://Panasonic/KX-MB1900?serial=4'"

    printf 'panasonic_model helper tests passed\n'
}

main "$@"
