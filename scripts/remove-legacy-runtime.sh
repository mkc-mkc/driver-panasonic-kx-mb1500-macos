#!/usr/bin/env bash
set -euo pipefail

readonly LEGACY_QUEUE="Panasonic_KX_MB1500RU"
readonly LEGACY_FILTER="/Library/Printers/Panasonic/Filter/panasonic-mb1500-docker-filter"
readonly LEGACY_AGENT_GLOB="$HOME/Library/LaunchAgents/com.local.panasonic-kx-mb1500-*.plist"
readonly LEGACY_LOG_GLOB="$HOME/Library/Logs/panasonic-kx-mb1500-*.log"

# Останавливаем пользовательский LaunchAgent, потому что он был частью старого runtime-моста.
for agent in $LEGACY_AGENT_GLOB; do
    [ -e "$agent" ] || continue
    launchctl bootout "gui/$(id -u)" "$agent" >/dev/null 2>&1 || true
done

# Удаляем очередь, чтобы macOS не продолжала отправлять задания в старый socket/backend путь.
lpadmin -x "$LEGACY_QUEUE" >/dev/null 2>&1 || true

# Пользовательские файлы можно удалить без повышения прав.
rm -f $LEGACY_AGENT_GLOB $LEGACY_LOG_GLOB

if [ -e "$LEGACY_FILTER" ]; then
    # Системный CUPS-фильтр принадлежит root, поэтому macOS запросит пароль администратора.
    osascript <<OSA
do shell script "rm -f '$LEGACY_FILTER'" with administrator privileges
OSA
fi

printf 'Removed legacy Docker runtime bridge files\n'
