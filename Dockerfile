FROM golang:1.27-alpine AS build
WORKDIR /app
COPY . .
RUN go mod tidy && CGO_ENABLED=0 go build -o /server .

FROM alpine:3
RUN adduser -D -u 10001 app
USER app
COPY --from=build /server /server
EXPOSE 8080
CMD ["/server"]
