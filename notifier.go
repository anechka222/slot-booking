package main

import (
	"context"
	"log"
)

// runNotifier — notification-service: подключается только к RabbitMQ
// и обрабатывает события бронирований.
//
// Стратегия отказоустойчивости — fail fast: при обрыве связи с брокером
// процесс завершается с ошибкой, Docker перезапускает его (restart: unless-stopped).
// Сообщения не теряются: очередь durable, подтверждение (ack) ручное.
func runNotifier(ctx context.Context, amqpURI string) {
	var broker *Broker
	if err := retry("rabbitmq", 30, func() error {
		var err error
		broker, err = NewBroker(amqpURI)
		return err
	}); err != nil {
		log.Fatal(err)
	}
	defer broker.Close()

	log.Println("notification-service запущен")
	if err := broker.Consume(ctx); err != nil {
		log.Fatalf("consumer остановлен: %v — завершаюсь, Docker перезапустит сервис", err)
	}
}
