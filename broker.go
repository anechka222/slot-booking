package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"sync"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

const (
	exchangeName = "booking_events"
	queueName    = "notification_queue"
)

type Event struct {
	Type       string    `json:"type"`
	BookingID  int64     `json:"booking_id"`
	ResourceID string    `json:"resource_id"`
	UserID     string    `json:"user_id"`
	SlotStart  time.Time `json:"slot_start"`
	OccurredAt time.Time `json:"occurred_at"`
}

type Broker struct {
	conn  *amqp.Connection
	pubCh *amqp.Channel
	mu    sync.Mutex // канал AMQP нельзя использовать из нескольких горутин одновременно
}

func NewBroker(uri string) (*Broker, error) {
	conn, err := amqp.Dial(uri)
	if err != nil {
		return nil, err
	}
	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return nil, err
	}
	if err := ch.ExchangeDeclare(exchangeName, "fanout", true, false, false, false, nil); err != nil {
		conn.Close()
		return nil, err
	}
	return &Broker{conn: conn, pubCh: ch}, nil
}

func (b *Broker) Close()        { b.conn.Close() }
func (b *Broker) Healthy() bool { return !b.conn.IsClosed() }

func (b *Broker) Publish(ctx context.Context, e Event) error {
	body, err := json.Marshal(e)
	if err != nil {
		return err
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.pubCh.PublishWithContext(ctx, exchangeName, "", false, false, amqp.Publishing{
		ContentType:  "application/json",
		DeliveryMode: amqp.Persistent,
		Timestamp:    e.OccurredAt,
		Body:         body,
	})
}

// Consume читает очередь и логирует события. Позже уедет в notification-service.
func (b *Broker) Consume(ctx context.Context) error {
	ch, err := b.conn.Channel()
	if err != nil {
		return err
	}
	defer ch.Close()

	q, err := ch.QueueDeclare(queueName, true, false, false, false, nil)
	if err != nil {
		return err
	}
	if err := ch.QueueBind(q.Name, "", exchangeName, false, nil); err != nil {
		return err
	}
	msgs, err := ch.Consume(q.Name, "", false, false, false, false, nil)
	if err != nil {
		return err
	}

	log.Printf("consumer слушает очередь %s", q.Name)
	for {
		select {
		case <-ctx.Done():
			return nil
		case d, ok := <-msgs:
			if !ok {
				return errors.New("канал consumer закрыт")
			}
			var e Event
			if err := json.Unmarshal(d.Body, &e); err != nil {
				log.Printf("consumer: битое сообщение: %v", err)
				_ = d.Nack(false, false) // не возвращаем в очередь
				continue
			}
			log.Printf("[notification] %s booking=%d resource=%s user=%s slot=%s",
				e.Type, e.BookingID, e.ResourceID, e.UserID, e.SlotStart.Format(time.RFC3339))
			_ = d.Ack(false)
		}
	}
}
