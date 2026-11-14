#!/bin/sh
# Применяет правила файрвола в сетевом пространстве текущего контейнера.
# Вызывается из entry.sh при каждом старте контейнера.
set -eu

HOST="${1:?укажи набор правил: apigw | app | notifier | postgres | redis | rabbitmq | backup}"
RULES="/fw/rules/${HOST}.sh"
[ -f "$RULES" ] || { echo "[fw] нет файла правил $RULES" >&2; exit 1; }

ipt() { iptables -w "$@"; }

# rule <chain> <target> <proto> <addr> <port> <comment>
# INPUT  -> addr = источник (SRC IP), OUTPUT -> addr = получатель (DST IP)
rule() {
    chain=$1; target=$2; proto=$3; addr=$4; port=$5; comment=$6
    if [ "$chain" = "INPUT" ]; then flag="-s"; else flag="-d"; fi
    set -- -A "$chain" "$flag" "$addr"
    if [ "$proto" != "all" ]; then set -- "$@" -p "$proto"; fi
    if [ -n "$port" ]; then set -- "$@" --dport "$port"; fi
    set -- "$@" -m comment --comment "$comment" -j "$target"
    ipt "$@"
}

# Явное разрешение / явный запрет.
# Входящие запреты — DROP (не раскрываем, что порт существует),
# исходящие — REJECT (сервис сразу получает ошибку, а не висит в таймауте).
allow_in()  { rule INPUT  ACCEPT "$@"; }
allow_out() { rule OUTPUT ACCEPT "$@"; }
deny_in()   { rule INPUT  DROP   "$@"; }
deny_out()  { rule OUTPUT REJECT "$@"; }

# 1. Сброс и политика по умолчанию: запрещено всё
ipt -F
ipt -X
ipt -P INPUT   DROP
ipt -P OUTPUT  DROP
ipt -P FORWARD DROP

# 2. Базовые правила
ipt -A INPUT  -i lo -m comment --comment "loopback: healthcheck, Docker DNS" -j ACCEPT
ipt -A OUTPUT -o lo -m comment --comment "loopback: healthcheck, Docker DNS" -j ACCEPT
ipt -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "ответы на разрешённые соединения" -j ACCEPT
ipt -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "ответы на разрешённые соединения" -j ACCEPT
ipt -A INPUT  -m conntrack --ctstate INVALID -m comment --comment "битые пакеты" -j DROP

# 3. Правила конкретного хоста: сначала явные запреты, потом разрешения
. "$RULES"

# 4. Явный default deny в конце цепочек (видно в счётчиках iptables -L -v)
ipt -A INPUT  -m comment --comment "DEFAULT DENY" -j DROP
ipt -A OUTPUT -m comment --comment "DEFAULT DENY" -j DROP

echo "[fw:$HOST] правила применены ($(ipt -S | wc -l) шт.)"
