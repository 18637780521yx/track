package service

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"github.com/fc/track-server/internal/model"
	"github.com/jackc/pgx/v5"
)

func resolveUserID(e model.TrackEvent) string {
	if e.DistinctID != nil && *e.DistinctID != "" {
		return *e.DistinctID
	}
	if e.AnonymousID != "" {
		return e.AnonymousID
	}
	return "unknown"
}

func (s *AnalyticsService) syncDerivedTables(ctx context.Context, e model.TrackEvent) error {
	userID := resolveUserID(e)
	ts := e.Timestamp
	if ts.IsZero() {
		ts = time.Now().UTC()
	}
	day := ts.UTC().Truncate(24 * time.Hour)

	isNewUser, err := s.upsertUser(ctx, e, userID, ts)
	if err != nil {
		return fmt.Errorf("upsert user: %w", err)
	}

	if err := s.touchDailyStats(ctx, day, userID, isNewUser); err != nil {
		return fmt.Errorf("touch daily stats: %w", err)
	}

	switch e.Name {
	case EventPaymentSuccess:
		amount := propFloat(e.Properties, "amount")
		if amount > 0 {
			if err := s.bumpDailyRevenue(ctx, day, amount); err != nil {
				return err
			}
			if err := s.bumpDailyPayingUser(ctx, day, userID); err != nil {
				return err
			}
		}
	case EventSubscriptionStart:
		if err := s.handleSubscriptionStart(ctx, e, userID, ts); err != nil {
			return err
		}
	case EventSubscriptionRenew:
		if err := s.handleSubscriptionRenew(ctx, e, userID, ts); err != nil {
			return err
		}
	case EventSubscriptionCancel:
		if err := s.handleSubscriptionCancel(ctx, userID, ts); err != nil {
			return err
		}
	}

	return s.refreshActiveSubscriptions(ctx, day)
}

func (s *AnalyticsService) upsertUser(ctx context.Context, e model.TrackEvent, userID string, ts time.Time) (bool, error) {
	channel := propString(e.CommonProperties, "channel")
	if channel == "" {
		channel = propString(e.Properties, "channel")
	}

	var isNew bool
	err := s.pool.QueryRow(ctx, `
		INSERT INTO users (
			user_id, distinct_id, anonymous_id,
			first_seen_at, last_seen_at, channel
		) VALUES ($1, $2, $3, $4, $4, NULLIF($5, ''))
		ON CONFLICT (user_id) DO UPDATE SET
			distinct_id = COALESCE(EXCLUDED.distinct_id, users.distinct_id),
			last_seen_at = GREATEST(users.last_seen_at, EXCLUDED.last_seen_at),
			channel = COALESCE(users.channel, EXCLUDED.channel),
			updated_at = NOW()
		RETURNING (xmax = 0) AS is_new
	`, userID, e.DistinctID, e.AnonymousID, ts, channel).Scan(&isNew)
	if err != nil {
		return false, err
	}

	switch e.Name {
	case EventAppFirstOpen:
		var hadFirstOpen bool
		err = s.pool.QueryRow(ctx, `
			SELECT first_open_at IS NOT NULL FROM users WHERE user_id = $1
		`, userID).Scan(&hadFirstOpen)
		if err != nil {
			return isNew, err
		}
		_, err = s.pool.Exec(ctx, `
			UPDATE users SET first_open_at = LEAST(COALESCE(first_open_at, $2), $2), updated_at = NOW()
			WHERE user_id = $1
		`, userID, ts)
		if err != nil {
			return isNew, err
		}
		if !hadFirstOpen {
			day := ts.UTC().Truncate(24 * time.Hour)
			if err := s.bumpDailyInstall(ctx, day, userID); err != nil {
				return isNew, err
			}
		}
	case EventUserSignup:
		_, err = s.pool.Exec(ctx, `
			UPDATE users SET signup_at = LEAST(COALESCE(signup_at, $2), $2), updated_at = NOW()
			WHERE user_id = $1
		`, userID, ts)
	case EventPaymentSuccess:
		amount := propFloat(e.Properties, "amount")
		if amount > 0 {
			_, err = s.pool.Exec(ctx, `
				UPDATE users SET
					is_paid = TRUE,
					total_revenue = total_revenue + $2,
					updated_at = NOW()
				WHERE user_id = $1
			`, userID, amount)
		}
	}

	if err != nil {
		return isNew, err
	}

	if isNew {
		if err := s.bumpDailyCounter(ctx, ts.UTC().Truncate(24*time.Hour), "new_users", 1); err != nil {
			return isNew, err
		}
	}

	return isNew, nil
}

func (s *AnalyticsService) touchDailyStats(ctx context.Context, day time.Time, userID string, isNewUser bool) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO daily_stats (date, total_events)
		VALUES ($1::date, 1)
		ON CONFLICT (date) DO UPDATE SET
			total_events = daily_stats.total_events + 1,
			updated_at = NOW()
	`, day)
	if err != nil {
		return err
	}

	var inserted bool
	err = s.pool.QueryRow(ctx, `
		INSERT INTO daily_active_users (date, user_id)
		VALUES ($1::date, $2)
		ON CONFLICT DO NOTHING
		RETURNING TRUE
	`, day, userID).Scan(&inserted)
	if err == pgx.ErrNoRows {
		return nil
	}
	if err != nil {
		return err
	}
	if inserted {
		return s.bumpDailyCounter(ctx, day, "dau", 1)
	}
	_ = isNewUser
	return nil
}

func (s *AnalyticsService) bumpDailyCounter(ctx context.Context, day time.Time, column string, delta int64) error {
	query := fmt.Sprintf(`
		INSERT INTO daily_stats (date, %s)
		VALUES ($1::date, $2)
		ON CONFLICT (date) DO UPDATE SET
			%s = daily_stats.%s + $2,
			updated_at = NOW()
	`, column, column, column)
	_, err := s.pool.Exec(ctx, query, day, delta)
	return err
}

func (s *AnalyticsService) bumpDailyRevenue(ctx context.Context, day time.Time, amount float64) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO daily_stats (date, revenue)
		VALUES ($1::date, $2)
		ON CONFLICT (date) DO UPDATE SET
			revenue = daily_stats.revenue + $2,
			updated_at = NOW()
	`, day, amount)
	return err
}

func (s *AnalyticsService) bumpDailyInstall(ctx context.Context, day time.Time, userID string) error {
	var inserted bool
	err := s.pool.QueryRow(ctx, `
		INSERT INTO daily_install_users (date, user_id)
		VALUES ($1::date, $2)
		ON CONFLICT DO NOTHING
		RETURNING TRUE
	`, day, userID).Scan(&inserted)
	if err == pgx.ErrNoRows {
		return nil
	}
	if err != nil {
		return err
	}
	if inserted {
		return s.bumpDailyCounter(ctx, day, "installs", 1)
	}
	return nil
}

func (s *AnalyticsService) bumpDailyPayingUser(ctx context.Context, day time.Time, userID string) error {
	var inserted bool
	err := s.pool.QueryRow(ctx, `
		INSERT INTO daily_paying_users (date, user_id)
		VALUES ($1::date, $2)
		ON CONFLICT DO NOTHING
		RETURNING TRUE
	`, day, userID).Scan(&inserted)
	if err == pgx.ErrNoRows {
		return nil
	}
	if err != nil {
		return err
	}
	if inserted {
		return s.bumpDailyCounter(ctx, day, "paying_users", 1)
	}
	return nil
}

func (s *AnalyticsService) handleSubscriptionStart(ctx context.Context, e model.TrackEvent, userID string, ts time.Time) error {
	plan := propString(e.Properties, "plan")
	if plan == "" {
		plan = "unknown"
	}
	amount := propFloat(e.Properties, "amount")
	currency := propString(e.Properties, "currency")
	if currency == "" {
		currency = "CNY"
	}
	expiresAt := propTime(e.Properties, "expires_at")

	_, err := s.pool.Exec(ctx, `
		INSERT INTO subscriptions (user_id, plan, status, amount, currency, started_at, expires_at)
		VALUES ($1, $2, 'active', $3, $4, $5, $6)
	`, userID, plan, amount, currency, ts, expiresAt)
	return err
}

func (s *AnalyticsService) handleSubscriptionRenew(ctx context.Context, e model.TrackEvent, userID string, ts time.Time) error {
	expiresAt := propTime(e.Properties, "expires_at")
	_, err := s.pool.Exec(ctx, `
		UPDATE subscriptions SET
			status = 'active',
			expires_at = COALESCE($3, expires_at),
			updated_at = NOW()
		WHERE id = (
			SELECT id FROM subscriptions WHERE user_id = $1 ORDER BY started_at DESC LIMIT 1
		)
	`, userID, ts, expiresAt)
	return err
}

func (s *AnalyticsService) handleSubscriptionCancel(ctx context.Context, userID string, ts time.Time) error {
	_, err := s.pool.Exec(ctx, `
		UPDATE subscriptions SET
			status = 'cancelled',
			cancelled_at = $2,
			updated_at = NOW()
		WHERE user_id = $1 AND status = 'active'
	`, userID, ts)
	return err
}

func (s *AnalyticsService) refreshActiveSubscriptions(ctx context.Context, day time.Time) error {
	var count int64
	err := s.pool.QueryRow(ctx, `
		SELECT COUNT(*) FROM subscriptions WHERE status = 'active'
	`).Scan(&count)
	if err != nil {
		return err
	}

	_, err = s.pool.Exec(ctx, `
		INSERT INTO daily_stats (date, active_subscriptions)
		VALUES ($1::date, $2)
		ON CONFLICT (date) DO UPDATE SET
			active_subscriptions = $2,
			updated_at = NOW()
	`, day, count)
	return err
}

func propString(m map[string]any, key string) string {
	if m == nil {
		return ""
	}
	v, ok := m[key]
	if !ok || v == nil {
		return ""
	}
	switch t := v.(type) {
	case string:
		return t
	default:
		return fmt.Sprint(t)
	}
}

func propFloat(m map[string]any, key string) float64 {
	if m == nil {
		return 0
	}
	v, ok := m[key]
	if !ok || v == nil {
		return 0
	}
	switch t := v.(type) {
	case float64:
		return t
	case float32:
		return float64(t)
	case int:
		return float64(t)
	case int64:
		return float64(t)
	case json.Number:
		f, _ := t.Float64()
		return f
	case string:
		f, _ := strconv.ParseFloat(t, 64)
		return f
	default:
		return 0
	}
}

func propTime(m map[string]any, key string) *time.Time {
	s := propString(m, key)
	if s == "" {
		return nil
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return nil
	}
	return &t
}
