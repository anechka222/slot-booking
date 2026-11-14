# apigw — API gateway, единственная публичная точка входа.
# edge-net 10.1.1.2, app-net 10.1.2.2

# Явные запреты
deny_out all  10.1.3.0/28 ""   "ЗАПРЕТ: gateway -> слой данных"

# Явные разрешения
allow_in  tcp  0.0.0.0/0   80   "клиенты -> HTTP gateway"
allow_in  icmp 10.1.1.0/28 ""   "ping из edge-сегмента"
allow_out tcp  10.1.2.3    8080 "gateway -> app-1 API"
allow_out tcp  10.1.2.4    8080 "gateway -> app-2 API"
allow_out icmp 10.1.2.3    ""   "ping app-1"
allow_out icmp 10.1.2.4    ""   "ping app-2"
