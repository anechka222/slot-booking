# rabbitmq — data-net 10.1.3.12

# Явные запреты
deny_in  tcp 10.1.3.3  15672 "ЗАПРЕТ: app -> management API"
deny_out all 0.0.0.0/0 ""    "ЗАПРЕТ: брокер не инициирует соединения"

# Явные разрешения
allow_in tcp  10.1.3.3 5672 "app -> AMQP"
allow_in tcp  10.1.3.4 5672 "notifier -> AMQP"
allow_in icmp 10.1.3.3 ""   "ping от app"
