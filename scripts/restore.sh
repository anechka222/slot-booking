#!/usr/bin/env bash
# Восстановление PostgreSQL из резервной копии.
#
#   ./scripts/restore.sh                         — список копий
#   ./scripts/restore.sh <файл.dump>             — проверочное восстановление в БД restore_check
#   ./scripts/restore.sh <файл.dump> slotdb      — восстановление рабочей БД (сначала останови app!)
#
# По умолчанию копия разворачивается в отдельную БД: так регулярно проверяем,
# что бэкапы действительно восстанавливаются, не трогая рабочие данные.
set -euo pipefail
export MSYS_NO_PATHCONV=1          # Git Bash: не превращать /backups/... в путь Windows
cd "$(dirname "$0")/.."
C=booking-pg-backup

if [ $# -eq 0 ]; then
    ls -lht backups/*.dump
    exit 0
fi

file=$(basename "$1")
target=${2:-restore_check}
start=$(date +%s)

echo "[restore] проверка контрольной суммы"
docker exec -w /backups "$C" sha256sum -c "$file.sha256"

echo "[restore] восстановление $file -> БД $target"
docker exec -e TARGET="$target" -e FILE="/backups/$file" "$C" sh -c '
    set -e
    if [ "$TARGET" != "$PGDATABASE" ]; then
        psql -d postgres -q -c "DROP DATABASE IF EXISTS \"$TARGET\"" -c "CREATE DATABASE \"$TARGET\""
    fi
    pg_restore --clean --if-exists --no-owner --exit-on-error -d "$TARGET" "$FILE"
    echo "[restore] строк в bookings: $(psql -d "$TARGET" -Atc "SELECT count(*) FROM bookings")"
'
echo "[restore] готово за $(( $(date +%s) - start )) с"
