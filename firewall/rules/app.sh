# app — booking-service, общий набор для реплик:
#   app-1: app-net 10.1.2.3, data-net 10.1.3.3
#   app-2: app-net 10.1.2.4, data-net 10.1.3.5

# Явные запреты
deny_out all  10.1.2.2    ""    "ЗАПРЕТ: app не инициирует соединения к gateway"
deny_out tcp  10.1.3.12   15672 "ЗАПРЕТ: app -> management API RabbitMQ"
deny_in  all  10.1.3.0/28 ""    "ЗАПРЕТ: слой данных не инициирует соединения к app"

# Явные разрешения
allow_in  tcp  10.1.2.2    8080 "gateway -> API"
allow_in  icmp 10.1.2.2    ""   "ping от gateway"
allow_out tcp  10.1.3.10   5432 "app -> PostgreSQL"
allow_out tcp  10.1.3.11   6379 "app -> Redis"
allow_out tcp  10.1.3.12   5672 "app -> RabbitMQ (AMQP)"
allow_out icmp 10.1.3.0/28 ""   "ping слоя данных"
