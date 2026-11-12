FROM alpine:3
RUN apk add --no-cache iptables netcat-openbsd iputils-ping
COPY apply.sh /apply.sh
COPY rules/ /rules/
ENTRYPOINT ["/bin/sh", "/apply.sh"]
