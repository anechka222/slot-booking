FROM golang:1.27-alpine AS build
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -o /server .

FROM alpine:3
# iptables — встроенный файрвол, setpriv — сброс прав после его настройки
RUN apk add --no-cache iptables setpriv wget \
    && adduser -D -u 10001 app
COPY firewall/apply.sh firewall/entry.sh /fw/
COPY firewall/rules/ /fw/rules/
COPY --from=build /server /server
# Контейнер стартует от root только чтобы применить файрвол;
# затем entry.sh переключается на пользователя app (uid 10001) без capabilities.
ENV FW_USER=10001
EXPOSE 8080
ENTRYPOINT ["/bin/sh", "/fw/entry.sh"]
CMD ["/server"]
