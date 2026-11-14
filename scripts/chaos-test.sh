#!/usr/bin/env bash
# Проверка отказоустойчивости и замер MTTR.
# Каждый сценарий «роняет» контейнер: SIGKILL главного процесса, как при OOM или падении.
# (docker kill не подходит: Docker считает это ручной остановкой и не перезапускает.)
# Во время сбоя скрипт непрерывно шлёт запросы через gateway и считает ошибки.
#
# Запуск: ./scripts/chaos-test.sh            — все сценарии
#         ./scripts/chaos-test.sh app-1      — один сценарий (app-1|apigw|postgres|redis|rabbitmq|notifier)
set -u
export MSYS_NO_PATHCONV=1
URL=http://127.0.0.1:8080
LOG=$(mktemp)
TOOLS=booking-fw-tools
docker build -q -t "$TOOLS" -f firewall/Dockerfile.tools firewall >/dev/null

now_ms()   { date +%s%3N; }
sec()      { awk -v ms="$1" 'BEGIN { printf "%.1f", ms / 1000 }'; }
restarts() { docker inspect -f '{{.RestartCount}}' "$1"; }
state()    { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1"; }
crash()    { docker run --rm --pid=host "$TOOLS" kill -9 "$(docker inspect -f '{{.State.Pid}}' "$1")"; }

load_start() {   # фоновые запросы к /health каждые 50 мс (/health проверяет все зависимости)
    : > "$LOG"
    ( while :; do curl -s -o /dev/null -m 2 -w '%{http_code}\n' "$URL/health" >> "$LOG"; sleep 0.05; done ) &
    LOAD_PID=$!
}
load_stop() { kill "$LOAD_PID" 2>/dev/null; wait "$LOAD_PID" 2>/dev/null; }

scenario() {
    local svc=$1 c="booking-$1" title=$2
    echo "== $title ($c) =="
    local before; before=$(restarts "$c")
    load_start; sleep 1
    local t0; t0=$(now_ms)
    crash "$c"

    # MTTR контейнера: от падения до состояния healthy (или running, если healthcheck нет)
    until [ "$(restarts "$c")" -gt "$before" ] && [[ "$(state "$c")" =~ ^(healthy|running)$ ]]; do
        sleep 0.2
        if (( $(now_ms) - t0 > 180000 )); then echo "  ТАЙМАУТ: $c не восстановился"; load_stop; return; fi
    done
    local t1; t1=$(now_ms)
    # Время до полного восстановления API (все зависимости доступны)
    until curl -fs -m 2 "$URL/health" >/dev/null; do sleep 0.2; done
    local t2; t2=$(now_ms)
    sleep 1; load_stop

    local total bad
    total=$(wc -l < "$LOG"); bad=$(grep -vc '^200$' "$LOG")
    echo "  MTTR контейнера:           $(sec $((t1 - t0))) с"
    echo "  API полностью здоров через: $(sec $((t2 - t0))) с"
    echo "  запросов: $total, неуспешных: $bad"
}

firewall_after_restart() {
    echo "== Файрвол после автоперезапуска =="
    if docker run --rm --network container:booking-notifier "$TOOLS" nc -z -w 2 10.1.3.10 5432 >/dev/null 2>&1; then
        echo "  FAIL  notifier -> postgres открыт после перезапуска"
    else
        echo "  OK    notifier -> postgres по-прежнему запрещён"
    fi
    local cap; cap=$(docker exec booking-postgres awk '/CapBnd/ {print $2}' /proc/1/status)
    if (( 0x$cap & 0x1000 )); then
        echo "  FAIL  у процесса postgres есть NET_ADMIN"
    else
        echo "  OK    у процесса postgres нет NET_ADMIN (CapBnd=$cap)"
    fi
}

run() {
    case $1 in
        app-1)    scenario app-1    "Падение одной реплики API" ;;
        apigw)    scenario apigw    "Падение gateway" ;;
        postgres) scenario postgres "Падение PostgreSQL"; firewall_after_restart ;;
        redis)    scenario redis    "Падение Redis" ;;
        rabbitmq) scenario rabbitmq "Падение RabbitMQ" ;;
        notifier) scenario notifier "Падение notification-service" ;;
        *) echo "неизвестный сценарий $1"; exit 1 ;;
    esac
    echo
}

if [ $# -gt 0 ]; then run "$1"; else
    for s in app-1 apigw postgres redis rabbitmq notifier; do run "$s"; sleep 5; done
fi
rm -f "$LOG"
