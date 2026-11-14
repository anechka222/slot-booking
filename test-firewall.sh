#!/usr/bin/env bash
# Проверка матрицы доступа. Запуск после `docker compose up -d --build`.
# Windows: Git Bash или WSL.
#
# Проба запускается в сетевом пространстве нужного контейнера
# (--network container:<имя>), поэтому на неё действуют правила его файрвола.
set -u
export MSYS_NO_PATHCONV=1
IMG=booking-fw-tools
docker build -q -t "$IMG" -f firewall/Dockerfile.tools firewall >/dev/null
pass=0; fail=0

tcp_from()     { docker run --rm --network "container:$1" "$IMG" nc -z -w 2 "$2" "$3"; }
ping_from()    { docker run --rm --network "container:$1" "$IMG" ping -c 1 -W 2 "$2"; }
tcp_stranger() { docker run --rm --network booking-data-net "$IMG" nc -z -w 2 "$1" "$2"; }

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
check ALLOW "apigw      -> app-1:8080"                tcp_from  booking-apigw     10.1.2.3  8080
check ALLOW "apigw      -> app-2:8080"                tcp_from  booking-apigw     10.1.2.4  8080
check ALLOW "apigw      -> app-1 (ICMP)"              ping_from booking-apigw     10.1.2.3
check ALLOW "app-1      -> postgres:5432"             tcp_from  booking-app-1     10.1.3.10 5432
check ALLOW "app-2      -> postgres:5432"             tcp_from  booking-app-2     10.1.3.10 5432
check ALLOW "app-1      -> redis:6379"                tcp_from  booking-app-1     10.1.3.11 6379
check ALLOW "app-2      -> rabbitmq:5672"             tcp_from  booking-app-2     10.1.3.12 5672
check ALLOW "notifier   -> rabbitmq:5672"             tcp_from  booking-notifier  10.1.3.12 5672
check ALLOW "pg-backup  -> postgres:5432"             tcp_from  booking-pg-backup 10.1.3.10 5432

echo "== Явные запреты =="
check DENY  "notifier   -> postgres:5432"             tcp_from  booking-notifier  10.1.3.10 5432
check DENY  "notifier   -> redis:6379"                tcp_from  booking-notifier  10.1.3.11 6379
check DENY  "notifier   -> postgres (ICMP)"           ping_from booking-notifier  10.1.3.10
check DENY  "pg-backup  -> redis:6379"                tcp_from  booking-pg-backup 10.1.3.11 6379
check DENY  "pg-backup  -> rabbitmq:5672"             tcp_from  booking-pg-backup 10.1.3.12 5672
check DENY  "apigw      -> postgres:5432 (сегмент)"   tcp_from  booking-apigw     10.1.3.10 5432
check DENY  "app-1      -> rabbitmq:15672 (mgmt)"     tcp_from  booking-app-1     10.1.3.12 15672
check DENY  "app-1      -> apigw:80 (обратно)"        tcp_from  booking-app-1     10.1.2.2  80
check DENY  "app-1      -> app-2:8080"                tcp_from  booking-app-1     10.1.2.4  8080
check DENY  "postgres   -> redis:6379"                tcp_from  booking-postgres  10.1.3.11 6379
check DENY  "redis      -> app-1:8080"                tcp_from  booking-redis     10.1.3.3  8080
check DENY  "чужой контейнер в data-net -> postgres"  tcp_stranger                10.1.3.10 5432
check DENY  "host       -> postgres:5432"             bash -c 'exec 3<>/dev/tcp/127.0.0.1/5432'

echo
echo "Итого: $pass OK, $fail FAIL"

echo
echo "== Счётчики правил на notifier (сработавшие запреты) =="
docker exec booking-notifier iptables -L OUTPUT -n -v
[ "$fail" -eq 0 ]
