#!/bin/sh
# Резервное копирование PostgreSQL (запускается в контейнере pg-backup).
#   - логический дамп pg_dump в сжатом custom-формате каждые BACKUP_INTERVAL секунд;
#   - проверка, что дамп читается (pg_restore --list), и контрольная сумма SHA-256;
#   - ротация: храним последние BACKUP_KEEP копий.
# Подключение берётся из переменных PGHOST, PGUSER, PGPASSWORD, PGDATABASE.
set -eu
: "${BACKUP_INTERVAL:=3600}" "${BACKUP_KEEP:=48}"
DIR=/backups
umask 077                      # копии содержат персональные данные: доступ только владельцу
mkdir -p "$DIR"

log() { echo "[backup] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

backup_once() {
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    out="$DIR/${PGDATABASE}_${ts}.dump"
    tmp="$DIR/.${PGDATABASE}_${ts}.part"

    if ! pg_dump --format=custom --compress=6 --file="$tmp"; then
        log "ОШИБКА: pg_dump завершился неудачно"; rm -f "$tmp"; return 1
    fi
    if ! pg_restore --list "$tmp" >/dev/null; then
        log "ОШИБКА: дамп повреждён и не читается"; rm -f "$tmp"; return 1
    fi
    mv "$tmp" "$out"               # атомарно: недописанный файл не попадёт в список копий
    (cd "$DIR" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")
    log "OK $(basename "$out") ($(du -h "$out" | cut -f1))"

    # Ротация: удаляем всё старше BACKUP_KEEP последних копий
    ls -1t "$DIR"/*.dump 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while read -r f; do
        rm -f "$f" "$f.sha256"
        log "удалена старая копия $(basename "$f")"
    done
}

until pg_isready -q; do sleep 2; done
log "старт: интервал ${BACKUP_INTERVAL} с, хранить ${BACKUP_KEEP} копий"
while true; do
    backup_once || log "следующая попытка через ${BACKUP_INTERVAL} с"
    sleep "$BACKUP_INTERVAL"
done
