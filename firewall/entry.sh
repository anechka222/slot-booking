#!/bin/sh
# Точка входа каждого контейнера:
#   1) применить файрвол (FW_HOST — имя набора правил);
#   2) убрать у процесса право менять файрвол (NET_ADMIN);
#   3) запустить штатную команду образа.
#
# Скрипт выполняется при КАЖДОМ старте контейнера, в том числе после
# автоперезапуска (restart: unless-stopped). Если правила применить не удалось,
# контейнер не запускается вообще (fail-closed): сервис не работает без защиты.
set -eu

/bin/sh /fw/apply.sh "${FW_HOST:?FW_HOST не задан}"

if [ -n "${FW_USER:-}" ]; then
    # Свой сервис: переключиться на непривилегированного пользователя без capabilities
    exec setpriv --reuid="$FW_USER" --regid="$FW_USER" --clear-groups \
        --inh-caps=-all --bounding-set=-all -- "$@"
fi
# Сторонние образы сами понижают права (su-exec); убираем только NET_ADMIN
exec setpriv --inh-caps=-net_admin --bounding-set=-net_admin -- "$@"
