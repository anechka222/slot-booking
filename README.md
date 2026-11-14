# Система бронирования слотов

Микросервисы на Go: booking API (2 реплики), notification-service, PostgreSQL, Redis,
RabbitMQ, API gateway на nginx, резервное копирование БД.

- Параметры надёжности (SLO, MTBF, MTTR, RPO/RTO) и бэкапы описаны в [RELIABILITY.md](RELIABILITY.md).

## Схема

```
                     host (127.0.0.1:8080)
                             │
  edge-net 10.1.1.0/28        │
                     ┌───────▼───────┐
                     │ apigw (nginx) │ 10.1.1.2 / 10.1.2.2
                     └──┬─────────┬──┘
  app-net 10.1.2.0/28   │internal │
               ┌────────▼┐      ┌─▼───────┐
               │  app-1  │      │  app-2  │  .3 / .4
               └────┬────┘      └────┬────┘
  data-net 10.1.3.0/28  │  internal │   (app-1 .3, app-2 .5)
   ┌────────┬───────────┼───────────┴──┬────────────┐
 postgres  redis     rabbitmq ◄── notifier     pg-backup ──► postgres
 .10       .11       .12          .4           .6
```

Защита:
1. **Сегментация.** Три docker-сети. `app-net` и `data-net` — `internal: true`.
2. **Файрвол в каждом контейнере.** `firewall/entry.sh` при каждом старте применяет
   правила из `firewall/rules/<сервис>.sh` (по умолчанию DROP, затем явные запреты и
   разрешения), убирает у процесса `NET_ADMIN` и только потом запускает сервис.
   Официальные образы обёрнуты в `firewall/Dockerfile`.

## Матрица доступа

| Откуда → куда | Порт | Решение |
|---|---|---|
| клиент → apigw | 80 (8080 на хосте) | разрешено |
| apigw → app-1, app-2 | 8080 | разрешено |
| app-1, app-2 → postgres / redis / rabbitmq | 5432 / 6379 / 5672 | разрешено |
| notifier → rabbitmq | 5672 | разрешено |
| pg-backup → postgres | 5432 | разрешено |
| notifier → postgres / redis | 5432 / 6379 | **явный запрет** |
| pg-backup → redis / rabbitmq | 6379 / 5672 | **явный запрет** |
| apigw → слой данных | любой | **явный запрет** и нет маршрута |
| app → rabbitmq management | 15672 | **явный запрет** |
| app → apigw (инициирование) | любой | **явный запрет** |
| слой данных → кто угодно (инициирование) | любой | **явный запрет** |
| чужой контейнер в data-net → postgres | 5432 | запрет (default deny) |
| host → postgres / redis / rabbitmq | — | порты не опубликованы |

## Запуск

```bash
cp .env.example .env                 # задать пароли
docker compose down                  # остановить старую версию (тома с данными сохранятся)
docker compose up -d --build --remove-orphans   # удалит старые fw-* sidecar из ДЗ 4
docker compose ps                    # все сервисы Up / healthy
```

## Проверка (Git Bash или WSL)

```bash
./test-firewall.sh                   # сетевой доступ
./scripts/chaos-test.sh              # отказоустойчивость, замер MTTR
./scripts/sli-report.sh              # доступность и задержка
./scripts/restore.sh                 # список резервных копий
./scripts/restore.sh <файл.dump>     # проверочное восстановление
docker exec booking-postgres iptables -L -n -v   # правила файрвола со счётчиками
```

## API

```bash
curl -X POST localhost:8080/bookings -H 'Content-Type: application/json' \
  -d '{"resource_id":"room-1","user_id":"anna","slot_start":"2026-12-01T10:00:00Z"}'
curl -i localhost:8080/bookings/1        # X-Cache: MISS, затем HIT
curl -X DELETE localhost:8080/bookings/1
curl localhost:8080/health
```
