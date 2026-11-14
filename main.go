package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// retry нужен, потому что зависимости могут стартовать позже сервиса
// или перезапускаться одновременно с ним.
func retry(name string, attempts int, fn func() error) error {
	var err error
	for i := 1; i <= attempts; i++ {
		if err = fn(); err == nil {
			return nil
		}
		log.Printf("%s: попытка %d/%d не удалась: %v", name, i, attempts, err)
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("%s: %w", name, err)
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	amqpURL := url.URL{
		Scheme: "amqp",
		User:   url.UserPassword(os.Getenv("RABBITMQ_USER"), os.Getenv("RABBITMQ_PASSWORD")),
		Host:   env("RABBITMQ_HOST", "rabbitmq") + ":5672",
	}

	// Один образ, два режима: MODE=notifier запускает только consumer.
	// Notifier не получает ни доступа, ни паролей к Postgres и Redis.
	if env("MODE", "api") == "notifier" {
		runNotifier(ctx, amqpURL.String())
		return
	}

	// URL собираем через net/url, чтобы спецсимволы в паролях не ломали строку подключения.
	pgURL := url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(os.Getenv("POSTGRES_USER"), os.Getenv("POSTGRES_PASSWORD")),
		Host:   env("POSTGRES_HOST", "postgres") + ":5432",
		Path:   "/" + os.Getenv("POSTGRES_DB"),
	}

	// pgxpool и go-redis сами переподключаются после сбоя БД или кэша,
	// поэтому повторы нужны только при первом подключении.
	var store *Store
	if err := retry("postgres", 30, func() error {
		var err error
		store, err = NewStore(ctx, pgURL.String())
		return err
	}); err != nil {
		log.Fatal(err)
	}
	defer store.Close()

	rdb := redis.NewClient(&redis.Options{
		Addr:     env("REDIS_ADDR", "redis:6379"),
		Password: os.Getenv("REDIS_PASSWORD"),
	})
	defer rdb.Close()
	if err := retry("redis", 30, func() error { return rdb.Ping(ctx).Err() }); err != nil {
		log.Fatal(err)
	}

	var broker *Broker
	if err := retry("rabbitmq", 30, func() error {
		var err error
		broker, err = NewBroker(amqpURL.String())
		return err
	}); err != nil {
		log.Fatal(err)
	}
	defer broker.Close()
	// Клиент AMQP сам не переподключается: следим за соединением сами.
	go broker.KeepAlive(ctx)

	h := &Handler{store: store, rdb: rdb, broker: broker}
	srv := &http.Server{
		Addr:              ":8080",
		Handler:           h.routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	log.Println("booking-service запущен на :8080")
	if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
