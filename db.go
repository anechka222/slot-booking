package main

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	errNotFound  = errors.New("not found")
	errSlotTaken = errors.New("slot already taken")
)

type Booking struct {
	ID         int64     `json:"id"`
	ResourceID string    `json:"resource_id"`
	UserID     string    `json:"user_id"`
	SlotStart  time.Time `json:"slot_start"`
	Status     string    `json:"status"`
	CreatedAt  time.Time `json:"created_at"`
}

type Store struct {
	pool *pgxpool.Pool
}

const schema = `
CREATE TABLE IF NOT EXISTS bookings (
	id          BIGSERIAL PRIMARY KEY,
	resource_id TEXT        NOT NULL,
	user_id     TEXT        NOT NULL,
	slot_start  TIMESTAMPTZ NOT NULL,
	status      TEXT        NOT NULL DEFAULT 'active',
	created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- один активный слот на ресурс; защита от гонки на уровне БД
CREATE UNIQUE INDEX IF NOT EXISTS bookings_active_slot
	ON bookings (resource_id, slot_start) WHERE status = 'active';
`

const columns = `id, resource_id, user_id, slot_start, status, created_at`

func NewStore(ctx context.Context, dsn string) (*Store, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	if err := migrate(ctx, pool); err != nil {
		pool.Close()
		return nil, err
	}
	return &Store{pool: pool}, nil
}

// migrate создаёт схему. Реплик app несколько, и они стартуют одновременно:
// advisory-блокировка не даёт им выполнять CREATE параллельно.
func migrate(ctx context.Context, pool *pgxpool.Pool) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(424242)`); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, schema); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *Store) Close()                         { s.pool.Close() }
func (s *Store) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

func scan(row pgx.Row) (Booking, error) {
	var b Booking
	err := row.Scan(&b.ID, &b.ResourceID, &b.UserID, &b.SlotStart, &b.Status, &b.CreatedAt)
	return b, err
}

func (s *Store) Create(ctx context.Context, resourceID, userID string, slot time.Time) (Booking, error) {
	b, err := scan(s.pool.QueryRow(ctx,
		`INSERT INTO bookings (resource_id, user_id, slot_start)
		 VALUES ($1, $2, $3) RETURNING `+columns,
		resourceID, userID, slot))
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
		return Booking{}, errSlotTaken
	}
	return b, err
}

func (s *Store) Get(ctx context.Context, id int64) (Booking, error) {
	b, err := scan(s.pool.QueryRow(ctx,
		`SELECT `+columns+` FROM bookings WHERE id = $1`, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return Booking{}, errNotFound
	}
	return b, err
}

func (s *Store) Cancel(ctx context.Context, id int64) (Booking, error) {
	b, err := scan(s.pool.QueryRow(ctx,
		`UPDATE bookings SET status = 'cancelled'
		 WHERE id = $1 AND status = 'active' RETURNING `+columns, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return Booking{}, errNotFound
	}
	return b, err
}
