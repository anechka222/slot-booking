#!/usr/bin/env bash
# Проверка матрицы доступа. Запуск после `docker compose up -d --build`.
# Windows: Git Bash или WSL.
#
# Проба запускается в сетевом пространстве нужного контейнера
# (--network container:<имя>), поэтому на неё действуют правила его файрвола.
set -u
IMG=slot-booking-fw
pass=0; fail=0

tcp_from()  { docker run --rm --network "container:$1" --entrypoint nc   "$IMG" -z -w 2 "$2" "$3"; }
ping_from() { docker run --rm --network "container:$1" --entrypoint ping "$IMG" -c 1 -W 2 "$2"; }
tcp_stranger() { docker run --rm --network booking-data-net --entrypoint nc "$IMG" -z -w 2 "$1" "$2"; }

check() {  # check <ALLOW|DENY> <описание> <команда...>
    local expect=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then got=ALLOW; else got=DENY; fi
    if [ "$got" = "$expect" ]; then
        printf '  OK    %-5s  %s\n' "$expect" "$desc"; pass=$((pass+1))
    else
        printf '  FAIL  ожидалось %s, получено %s  %s\n' "$expect" "$got" "$desc"; fail=$((fail+1))
    fi
}

echo "== Явные разрешения =="
check ALLOW "host       -> apigw:8080 (/health)"      curl -fsS -m 3 http://127.0.0.1:8080/health
check ALLOW "apigw      -> app:8080"                  tcp_from  booking-apigw    10.1.2.3  8080
check ALLOW "apigw      -> app (ICMP)"                ping_from booking-apigw    10.1.2.3
check ALLOW "app        -> postgres:5432"             tcp_from  booking-app      10.1.3.10 5432
check ALLOW "app        -> redis:6379"                tcp_from  booking-app      10.1.3.11 6379
check ALLOW "app        -> rabbitmq:5672"             tcp_from  booking-app      10.1.3.12 5672
check ALLOW "notifier   -> rabbitmq:5672"             tcp_from  booking-notifier 10.1.3.12 5672

echo "== Явные запреты =="
check DENY  "notifier   -> postgres:5432"             tcp_from  booking-notifier 10.1.3.10 5432
check DENY  "notifier   -> redis:6379"                tcp_from  booking-notifier 10.1.3.11 6379
check DENY  "notifier   -> postgres (ICMP)"           ping_from booking-notifier 10.1.3.10
check DENY  "apigw      -> postgres:5432 (сегмент)"   tcp_from  booking-apigw    10.1.3.10 5432
check DENY  "app        -> rabbitmq:15672 (mgmt)"     tcp_from  booking-app      10.1.3.12 15672
check DENY  "app        -> apigw:80 (обратно)"        tcp_from  booking-app      10.1.2.2  80
check DENY  "postgres   -> redis:6379"                tcp_from  booking-postgres 10.1.3.11 6379
check DENY  "redis      -> app:8080"                  tcp_from  booking-redis    10.1.3.3  8080
check DENY  "чужой контейнер в data-net -> postgres"  tcp_stranger              10.1.3.10 5432
check DENY  "host       -> postgres:5432"             bash -c 'exec 3<>/dev/tcp/127.0.0.1/5432'

echo
echo "Итого: $pass OK, $fail FAIL"

echo
echo "== Счётчики правил на notifier (сработавшие запреты) =="
docker run --rm --network container:booking-notifier --cap-add NET_ADMIN \
    --entrypoint iptables "$IMG" -L OUTPUT -n -v
[ "$fail" -eq 0 ]
