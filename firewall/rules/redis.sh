# redis — data-net 10.1.3.11

# Явные запреты
deny_in  tcp 10.1.3.4  6379 "ЗАПРЕТ: notifier -> Redis"
deny_out all 0.0.0.0/0 ""   "ЗАПРЕТ: кэш не инициирует соединения"

# Явные разрешения
allow_in tcp  10.1.3.3 6379 "app -> Redis"
allow_in icmp 10.1.3.3 ""   "ping от app"
