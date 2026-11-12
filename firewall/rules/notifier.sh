# notifier — notification-service. data-net 10.1.3.4
# Ничего не слушает, ходит только в брокер.

# Явные запреты (notifier в одном сегменте с БД и кэшем, но доступа к ним не имеет)
deny_out tcp  10.1.3.10 5432 "ЗАПРЕТ: notifier -> PostgreSQL"
deny_out tcp  10.1.3.11 6379 "ЗАПРЕТ: notifier -> Redis"
deny_out icmp 10.1.3.10 ""   "ЗАПРЕТ: notifier ping PostgreSQL"

# Явные разрешения
allow_out tcp 10.1.3.12 5672 "notifier -> RabbitMQ (AMQP)"
