# pg-backup — резервное копирование БД. data-net 10.1.3.6
# Ничего не слушает, ходит только в PostgreSQL.

# Явные запреты
deny_out tcp 10.1.3.11 6379 "ЗАПРЕТ: pg-backup -> Redis"
deny_out tcp 10.1.3.12 5672 "ЗАПРЕТ: pg-backup -> RabbitMQ"

# Явные разрешения
allow_out tcp 10.1.3.10 5432 "pg-backup -> PostgreSQL"
