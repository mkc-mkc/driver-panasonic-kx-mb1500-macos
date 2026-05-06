#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-30}"
readonly POLL_INTERVAL_SECONDS=1

# Helper нужен, чтобы проверка печати распознавала всю серию MB1500 тем же способом, что и установщик.
source "$SCRIPT_DIR/helper/panasonic_model.sh"

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

find_error_log() {
    # На разных сборках macOS лог CUPS может лежать в двух путях, поэтому выбираем первый существующий.
    if [ -f /var/log/cups/error_log ]; then
        printf '%s\n' /var/log/cups/error_log
        return
    fi

    # Старый приватный путь оставляем как fallback, чтобы скрипт не зависел от конкретной раскладки каталогов.
    if [ -f /private/var/log/cups/error_log ]; then
        printf '%s\n' /private/var/log/cups/error_log
        return
    fi

    fail "не найден error_log CUPS"
}

ensure_queue_exists() {
    local queue_name="$1"

    # Проверяем именно системную очередь, потому что без неё тестовая отправка даст ложную ошибку уровня CLI.
    if ! lpstat -p "$queue_name" >/dev/null 2>&1; then
        fail "очередь $queue_name не найдена. Сначала установи драйвер через ./scripts/install-driver.sh"
    fi
}

ensure_device_connected() {
    local queue_name="$1"
    local device_uri="$2"

    # Сверяем точный USB URI очереди, чтобы проверка не дала ложный успех на другой модели той же серии.
    if ! lpstat -v "$queue_name" | grep -Fq "$device_uri"; then
        fail "очередь $queue_name не привязана к ожидаемому USB URI $device_uri"
    fi
}

create_test_page() {
    local model_name="$1"
    local queue_name="$2"
    local output_path="$3"

    # Пишем короткую страницу с точной моделью и именем очереди, чтобы на бумаге было видно, какой вариант серии проверялся.
    cat >"$output_path" <<EOF
Panasonic $model_name test page
Queue: $queue_name
Generated: $(date '+%Y-%m-%d %H:%M:%S %z')

If you see this page, the native CUPS pipeline is working.
EOF
}

submit_test_job() {
    local queue_name="$1"
    local input_path="$2"
    local submit_output
    local job_name

    # В заголовок задания кладём стабильное имя, чтобы его было легко найти и в очереди, и в логе CUPS.
    job_name="haikiri-verify-print"
    submit_output="$(lp -d "$queue_name" -t "$job_name" "$input_path")" || fail "не удалось отправить тестовое задание в CUPS"

    # Локализация CLI меняется, поэтому вытаскиваем id задания не по фразе, а по шаблону queue-id.
    if ! grep -Eo "${queue_name}-[0-9]+" <<<"$submit_output" | tail -n 1; then
        fail "не удалось определить id тестового задания из вывода lp"
    fi
}

job_number_from_request_id() {
    local request_id="$1"

    # Для поиска в error_log CUPS нужен только числовой id без имени очереди.
    printf '%s\n' "${request_id##*-}"
}

wait_for_completion() {
    local queue_name="$1"
    local request_id="$2"
    local started_at

    started_at="$(date +%s)"

    while true; do
        # Если задание уже попало в completed, тракт печати отработал до конца со стороны CUPS/backend.
        if lpstat -W completed -o "$queue_name" | grep -Fq "$request_id"; then
            return
        fi

        # Если задание пропало из активной очереди и не появилось в completed, это ненормальный сценарий.
        if ! lpstat -W not-completed -o "$queue_name" | grep -Fq "$request_id"; then
            break
        fi

        # Не ждём бесконечно, чтобы скрипт оставался пригодным и для CI-подобной ручной проверки, и для локальной диагностики.
        if [ "$(( $(date +%s) - started_at ))" -ge "$WAIT_TIMEOUT_SECONDS" ]; then
            break
        fi

        sleep "$POLL_INTERVAL_SECONDS"
    done

    return 1
}

print_job_log_excerpt() {
    local job_number="$1"
    local error_log_path="$2"

    # При сбое показываем только строки конкретного job, чтобы не зашумлять диагностику чужими заданиями.
    grep -F "[Job $job_number]" "$error_log_path" | tail -n 40 || true
}

main() {
    local device_uri
    local model_name
    local queue_name
    local error_log_path
    local temp_file
    local request_id
    local job_number

    # Сначала определяем реально подключённый USB-принтер серии, чтобы и очередь, и тестовая страница относились к одному устройству.
    device_uri="$(find_installed_panasonic_mb1500_uri || true)"
    if [ -z "$device_uri" ]; then
        fail "Поддерживаемый Panasonic серии KX-MB1500 не найден по USB"
    fi
    model_name="$(extract_panasonic_mb1500_model "$device_uri")" || fail "не удалось определить модель Panasonic по URI: $device_uri"
    queue_name="$(build_panasonic_mb1500_queue_name "$model_name")"

    ensure_queue_exists "$queue_name"
    ensure_device_connected "$queue_name" "$device_uri"

    error_log_path="$(find_error_log)"
    # Шаблон без пользовательского суффикса работает надёжно и на BSD `mktemp`, который использует macOS.
    temp_file="$(mktemp /tmp/panasonic-kx-mb1500-test.XXXXXX)"
    # Подставляем путь сразу в trap, потому что к моменту EXIT локальная переменная уже может выйти из области видимости.
    trap "rm -f '$temp_file'" EXIT

    create_test_page "$model_name" "$queue_name" "$temp_file"
    request_id="$(submit_test_job "$queue_name" "$temp_file")"
    job_number="$(job_number_from_request_id "$request_id")"

    if ! wait_for_completion "$queue_name" "$request_id"; then
        print_job_log_excerpt "$job_number" "$error_log_path"
        printf 'ERROR: тестовое задание %s не дошло до статуса completed за %s секунд\n' "$request_id" "$WAIT_TIMEOUT_SECONDS" >&2
        exit 1
    fi

    # Дополнительно подтверждаем факт завершения именно по CUPS-логу, чтобы в отчёте было на что ссылаться.
    if ! grep -Fq "[Job $job_number] Job completed." "$error_log_path"; then
        fail "задание $request_id дошло до completed, но подтверждение в error_log не найдено"
    fi

    printf 'Verified print path for %s via job %s\n' "$queue_name" "$request_id"
}

main "$@"
