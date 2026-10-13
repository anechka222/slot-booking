package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
)

const cacheTTL = 5 * time.Minute

type Handler struct {
	store  *Store
	rdb    *redis.Client
	broker *Broker
}

func (h *Handler) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "hello-world")
	})
	mux.HandleFunc("GET /health", h.health)
	mux.HandleFunc("POST /bookings", h.create)
	mux.HandleFunc("GET /bookings/{id}", h.get)
	mux.HandleFunc("DELETE /bookings/{id}", h.cancel)
	return mux
}

func cacheKey(id int64) string { return fmt.Sprintf("booking:%d", id) }

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

type createRequest struct {
	ResourceID string    `json:"resource_id"`
	UserID     string    `json:"user_id"`
	SlotStart  time.Time `json:"slot_start"`
}

func (r *createRequest) validate() error {
	if r.ResourceID == "" || len(r.ResourceID) > 64 {
		return errors.New("resource_id: от 1 до 64 символов")
	}
	if r.UserID == "" || len(r.UserID) > 64 {
		return errors.New("user_id: от 1 до 64 символов")
	}
	r.SlotStart = r.SlotStart.UTC()
	if !r.SlotStart.Truncate(time.Hour).Equal(r.SlotStart) {
		return errors.New("slot_start: слоты начинаются в начале часа")
	}
	if !r.SlotStart.After(time.Now()) {
		return errors.New("slot_start: слот должен быть в будущем")
	}
	return nil
}

// Запись: БД -> инвалидация кэша -> событие в брокер.
func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()

	var req createRequest
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "некорректный JSON")
		return
	}
	if err := req.validate(); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	b, err := h.store.Create(r.Context(), req.ResourceID, req.UserID, req.SlotStart)
	switch {
	case errors.Is(err, errSlotTaken):
		writeError(w, http.StatusConflict, "слот уже занят")
		return
	case err != nil:
		log.Printf("create: %v", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}

	h.invalidate(r.Context(), b.ID)
	h.publish(r.Context(), "BookingCreated", b)
	writeJSON(w, http.StatusCreated, b)
}

// Чтение: кэш -> если промах, БД -> запись в кэш.
func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeError(w, http.StatusBadRequest, "некорректный id")
		return
	}

	key := cacheKey(id)
	cached, err := h.rdb.Get(r.Context(), key).Bytes()
	if err == nil {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Cache", "HIT")
		_, _ = w.Write(cached)
		return
	}
	if !errors.Is(err, redis.Nil) {
		// Redis не источник истины: если он недоступен, читаем из БД.
		log.Printf("redis get %s: %v", key, err)
	}

	b, err := h.store.Get(r.Context(), id)
	switch {
	case errors.Is(err, errNotFound):
		writeError(w, http.StatusNotFound, "бронь не найдена")
		return
	case err != nil:
		log.Printf("get: %v", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}

	data, _ := json.Marshal(b)
	if err := h.rdb.Set(r.Context(), key, data, cacheTTL).Err(); err != nil {
		log.Printf("redis set %s: %v", key, err)
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Cache", "MISS")
	_, _ = w.Write(data)
}

func (h *Handler) cancel(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeError(w, http.StatusBadRequest, "некорректный id")
		return
	}

	b, err := h.store.Cancel(r.Context(), id)
	switch {
	case errors.Is(err, errNotFound):
		writeError(w, http.StatusNotFound, "активная бронь не найдена")
		return
	case err != nil:
		log.Printf("cancel: %v", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}

	h.invalidate(r.Context(), id)
	h.publish(r.Context(), "BookingCancelled", b)
	writeJSON(w, http.StatusOK, b)
}

func (h *Handler) health(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	status := map[string]string{"postgres": "ok", "redis": "ok", "rabbitmq": "ok"}
	code := http.StatusOK
	if err := h.store.Ping(ctx); err != nil {
		status["postgres"], code = "down", http.StatusServiceUnavailable
	}
	if err := h.rdb.Ping(ctx).Err(); err != nil {
		status["redis"], code = "down", http.StatusServiceUnavailable
	}
	if !h.broker.Healthy() {
		status["rabbitmq"], code = "down", http.StatusServiceUnavailable
	}
	writeJSON(w, code, status)
}

func (h *Handler) invalidate(ctx context.Context, id int64) {
	if err := h.rdb.Del(ctx, cacheKey(id)).Err(); err != nil {
		log.Printf("redis del %d: %v", id, err)
	}
}

func (h *Handler) publish(ctx context.Context, typ string, b Booking) {
	// запрос клиента мог уже завершиться, а событие отправить всё равно нужно
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
	defer cancel()

	e := Event{
		Type:       typ,
		BookingID:  b.ID,
		ResourceID: b.ResourceID,
		UserID:     b.UserID,
		SlotStart:  b.SlotStart,
		OccurredAt: time.Now().UTC(),
	}
	if err := h.broker.Publish(ctx, e); err != nil {
		log.Printf("publish %s booking=%d: %v", typ, b.ID, err)
	}
}
