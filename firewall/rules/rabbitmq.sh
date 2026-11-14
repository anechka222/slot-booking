# rabbitmq — data-net 10.1.3.12

# Явные запреты
deny_in  tcp 10.1.3.3  15672 "ЗАПРЕТ: app-1 -> management API"
deny_in  tcp 10.1.3.5  15672 "ЗАПРЕТ: app-2 -> management API"
deny_in  tcp 10.1.3.6  5672  "ЗАПРЕТ: pg-backup -> AMQP"
deny_out all 0.0.0.0/0 ""    "ЗАПРЕТ: брокер не инициирует соединения"

# Явные разрешения
allow_in tcp  10.1.3.3 5672 "app-1 -> AMQP"
allow_in tcp  10.1.3.5 5672 "app-2 -> AMQP"
allow_in tcp  10.1.3.4 5672 "notifier -> AMQP"
allow_in icmp 10.1.3.3 ""   "ping от app-1"
allow_in icmp 10.1.3.5 ""   "ping от app-2"
