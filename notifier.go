package main

import (
	"context"
	"log"
)

// runNotifier — notification-service: подключается только к RabbitMQ
// и обрабатывает события бронирований.
func runNotifier(ctx context.Context, amqpURI string) {
	var broker *Broker
	if err := retry("rabbitmq", 10, func() error {
		var err error
		broker, err = NewBroker(amqpURI)
		return err
	}); err != nil {
		log.Fatal(err)
	}
	defer broker.Close()

	log.Println("notification-service запущен")
	if err := broker.Consume(ctx); err != nil {
		log.Printf("consumer остановлен: %v", err)
	}
}
