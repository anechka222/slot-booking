# postgres — data-net 10.1.3.10

# Явные запреты
deny_in  tcp 10.1.3.4  5432 "ЗАПРЕТ: notifier -> PostgreSQL"
deny_out all 0.0.0.0/0 ""   "ЗАПРЕТ: БД не инициирует соединения"

# Явные разрешения
allow_in tcp  10.1.3.3 5432 "app -> PostgreSQL"
allow_in icmp 10.1.3.3 ""   "ping от app"
