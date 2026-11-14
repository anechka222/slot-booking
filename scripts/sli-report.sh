#!/usr/bin/env bash
# Расчёт SLI по логу gateway: доступность и задержка запросов к API.
# Запросы к /health не учитываются (это служебные проверки).
#   ./scripts/sli-report.sh          — за всё время жизни контейнера
#   ./scripts/sli-report.sh 1h       — за последний час (--since для docker logs)
set -eu
since=${1:-}
docker logs ${since:+--since "$since"} booking-apigw 2>/dev/null \
  | grep '^status=' | grep -v 'uri=/health ' \
  | awk '{
        split($1, s, "="); split($4, r, "=")
        n++; if (s[2] >= 500) bad++
        print r[2] > "/dev/stderr"
     }
     END {
        if (n == 0) { print "нет запросов"; exit }
        printf "запросов: %d, ошибок 5xx: %d\n", n, bad
        printf "доступность: %.3f%%  (SLO >= 99.5%%)\n", 100 * (n - bad) / n
     }' 2> >(sort -n | awk '{ a[NR] = $1 } END {
        if (NR == 0) exit
        printf "задержка p95: %d мс  (SLO <= 300 мс)\n", 1000 * a[int(NR * 0.95 + 0.5) > 0 ? int(NR * 0.95 + 0.5) : 1]
        printf "задержка p99: %d мс  (SLO <= 1000 мс)\n", 1000 * a[int(NR * 0.99 + 0.5) > 0 ? int(NR * 0.99 + 0.5) : 1]
     }')
sleep 0.2
