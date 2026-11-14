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

var errBrokerDown = errors.New("rabbitmq недоступен")

type Event struct {
	Type       string    `json:"type"`
	BookingID  int64     `json:"booking_id"`
	ResourceID string    `json:"resource_id"`
	UserID     string    `json:"user_id"`
	SlotStart  time.Time `json:"slot_start"`
	OccurredAt time.Time `json:"occurred_at"`
}

type Broker struct {
	uri   string
	mu    sync.Mutex // защищает conn и pubCh; канал AMQP нельзя использовать из нескольких горутин одновременно
	conn  *amqp.Connection
	pubCh *amqp.Channel
}

func NewBroker(uri string) (*Broker, error) {
	b := &Broker{uri: uri}
	if err := b.connect(); err != nil {
		return nil, err
	}
	return b, nil
}

func (b *Broker) connect() error {
	conn, err := amqp.Dial(b.uri)
	if err != nil {
		return err
	}
	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return err
	}
	if err := ch.ExchangeDeclare(exchangeName, "fanout", true, false, false, false, nil); err != nil {
		conn.Close()
		return err
	}
	b.mu.Lock()
	b.conn, b.pubCh = conn, ch
	b.mu.Unlock()
	return nil
}

func (b *Broker) Close() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.conn != nil {
		b.conn.Close()
	}
}

func (b *Broker) Healthy() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.conn != nil && !b.conn.IsClosed()
}

// KeepAlive следит за соединением и после обрыва переподключается
// с экспоненциальной задержкой: 1 с, 2 с, 4 с ... не больше 30 с.
// Пока брокера нет, API продолжает принимать брони (публикация вернёт ошибку в лог).
func (b *Broker) KeepAlive(ctx context.Context) {
	for {
		b.mu.Lock()
		closed := b.conn.NotifyClose(make(chan *amqp.Error, 1))
		b.mu.Unlock()

		select {
		case <-ctx.Done():
			return
		case err := <-closed:
			if ctx.Err() != nil {
				return
			}
			log.Printf("rabbitmq: соединение потеряно: %v", err)
		}

		for delay := time.Second; ; delay = min(2*delay, 30*time.Second) {
			select {
			case <-ctx.Done():
				return
			case <-time.After(delay):
			}
			if err := b.connect(); err != nil {
				log.Printf("rabbitmq: переподключение не удалось: %v", err)
				continue
			}
			log.Println("rabbitmq: соединение восстановлено")
			break
		}
	}
}

func (b *Broker) Publish(ctx context.Context, e Event) error {
	body, err := json.Marshal(e)
	if err != nil {
		return err
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.pubCh == nil || b.pubCh.IsClosed() {
		return errBrokerDown
	}
	return b.pubCh.PublishWithContext(ctx, exchangeName, "", false, false, amqp.Publishing{
		ContentType:  "application/json",
		DeliveryMode: amqp.Persistent, // сообщение переживёт перезапуск брокера
		Timestamp:    e.OccurredAt,
		Body:         body,
	})
}

// Consume читает очередь и логирует события (используется notification-service).
// Возвращает ошибку, если соединение с брокером оборвалось.
func (b *Broker) Consume(ctx context.Context) error {
	b.mu.Lock()
	conn := b.conn
	b.mu.Unlock()

	ch, err := conn.Channel()
	if err != nil {
		return err
	}
	defer ch.Close()

	// Не больше 10 неподтверждённых сообщений одновременно (защита от перегрузки).
	if err := ch.Qos(10, 0, false); err != nil {
		return err
	}
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
			// lag — задержка от события до обработки (SLI свежести уведомлений)
			log.Printf("[notification] %s booking=%d resource=%s user=%s slot=%s lag=%s",
				e.Type, e.BookingID, e.ResourceID, e.UserID,
				e.SlotStart.Format(time.RFC3339), time.Since(e.OccurredAt).Round(time.Millisecond))
			_ = d.Ack(false)
		}
	}
}
