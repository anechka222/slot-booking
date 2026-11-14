# Обёртка над официальными образами (postgres, redis, rabbitmq, nginx):
# добавляет встроенный файрвол. Базовый образ передаётся через BASE.
ARG BASE=alpine:3
FROM ${BASE}
USER root
RUN apk add --no-cache iptables setpriv
COPY apply.sh entry.sh /fw/
COPY rules/ /fw/rules/
