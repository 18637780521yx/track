package service

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/fc/track-server/internal/model"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type AnalyticsService struct {
	pool *pgxpool.Pool
}

func NewAnalyticsService(pool *pgxpool.Pool) *AnalyticsService {
	return &AnalyticsService{pool: pool}
}

func (s *AnalyticsService) Ingest(ctx context.Context, events []model.TrackEvent) (stored, dropped int, err error) {
	if len(events) == 0 {
		return 0, 0, nil
	}

	batch := &pgx.Batch{}
	queued := make([]model.TrackEvent, 0, len(events))
	for _, e := range events {
		if e.EventID == "" || e.Name == "" {
			dropped++
			continue
		}
		props, _ := json.Marshal(defaultMap(e.Properties))
		common, _ := json.Marshal(defaultMap(e.CommonProperties))
		anon := e.AnonymousID
		if anon == "" {
			anon = "unknown"
		}
		session := e.SessionID
		if session == "" {
			session = "unknown"
		}
		ts := e.Timestamp
		if ts.IsZero() {
			ts = time.Now().UTC()
		}

		batch.Queue(`
			INSERT INTO events (
				event_id, name, properties, common_properties,
				distinct_id, anonymous_id, session_id, event_time
			) VALUES ($1, $2, $3::jsonb, $4::jsonb, $5, $6, $7, $8)
			ON CONFLICT (event_id) DO NOTHING
		`, e.EventID, e.Name, string(props), string(common), e.DistinctID, anon, session, ts)
		queued = append(queued, e)
	}

	if len(queued) == 0 {
		return stored, dropped, nil
	}

	br := s.pool.SendBatch(ctx, batch)
	defer br.Close()

	for _, e := range queued {
		tag, execErr := br.Exec()
		if execErr != nil {
			return stored, dropped, execErr
		}
		if tag.RowsAffected() > 0 {
			stored++
			if syncErr := s.syncDerivedTables(ctx, e); syncErr != nil {
				// 衍生表同步失败不影响主流程，事件已落库
				_ = syncErr
			}
		} else {
			dropped++
		}
	}
	return stored, dropped, nil
}

func (s *AnalyticsService) Overview(ctx context.Context, from, to time.Time) (*model.OverviewStats, error) {
	stats := &model.OverviewStats{}
	fromDate, toDate := inclusiveDateRange(from, to)

	// 优先从 daily_stats 预聚合表读取
	err := s.pool.QueryRow(ctx, `
		SELECT
			COALESCE(SUM(dau), 0),
			COALESCE(SUM(new_users), 0),
			COALESCE(SUM(installs), 0),
			COALESCE(SUM(revenue), 0),
			COALESCE(SUM(paying_users), 0),
			COALESCE(SUM(total_events), 0)
		FROM daily_stats
		WHERE date >= $1::date AND date <= $2::date
	`, fromDate, toDate).Scan(
		&stats.DAU, &stats.NewUsers, &stats.Installs,
		&stats.Revenue, &stats.PayingUsers, &stats.TotalEvents,
	)
	if err != nil {
		return nil, err
	}

	// 活跃订阅取范围内最后一天快照
	_ = s.pool.QueryRow(ctx, `
		SELECT COALESCE(active_subscriptions, 0)
		FROM daily_stats
		WHERE date >= $1::date AND date <= $2::date
		ORDER BY date DESC
		LIMIT 1
	`, fromDate, toDate).Scan(&stats.ActiveSubscriptions)

	// daily_stats 为空时回退到 events 实时计算
	if stats.TotalEvents == 0 {
		err = s.pool.QueryRow(ctx, `
			SELECT COUNT(*) FROM events
			WHERE event_time >= $1 AND event_time < $2
		`, from, to).Scan(&stats.TotalEvents)
		if err != nil {
			return nil, err
		}
		err = s.pool.QueryRow(ctx, `
			SELECT COUNT(DISTINCT COALESCE(NULLIF(distinct_id, ''), anonymous_id))
			FROM events
			WHERE event_time >= $1 AND event_time < $2
		`, from, to).Scan(&stats.DAU)
		if err != nil {
			return nil, err
		}
	}

	rows, err := s.pool.Query(ctx, `
		SELECT name, COUNT(*) AS cnt
		FROM events
		WHERE event_time >= $1 AND event_time < $2
		GROUP BY name
		ORDER BY cnt DESC
		LIMIT 10
	`, from, to)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var item model.NamedCount
		if err := rows.Scan(&item.Name, &item.Count); err != nil {
			return nil, err
		}
		stats.TopEvents = append(stats.TopEvents, item)
	}

	trendRows, err := s.pool.Query(ctx, `
		SELECT
			TO_CHAR(ds.date, 'YYYY-MM-DD') AS day,
			COALESCE(ds.total_events, 0) AS cnt,
			COALESCE(ds.dau, 0) AS users,
			COALESCE(ds.new_users, 0),
			COALESCE(ds.installs, 0),
			COALESCE(ds.revenue, 0),
			COALESCE(ds.active_subscriptions, 0)
		FROM daily_stats ds
		WHERE ds.date >= $1::date AND ds.date <= $2::date
		ORDER BY ds.date
	`, fromDate, toDate)
	if err != nil {
		return nil, err
	}
	defer trendRows.Close()
	for trendRows.Next() {
		var point model.DailyEventStat
		if err := trendRows.Scan(
			&point.Date, &point.Count, &point.Users,
			&point.NewUsers, &point.Installs, &point.Revenue, &point.ActiveSubscriptions,
		); err != nil {
			return nil, err
		}
		stats.Trend = append(stats.Trend, point)
	}

	// daily_stats 无趋势数据时回退 events
	if len(stats.Trend) == 0 {
		fallbackRows, err := s.pool.Query(ctx, `
			SELECT
				TO_CHAR(DATE(event_time AT TIME ZONE 'UTC'), 'YYYY-MM-DD') AS day,
				COUNT(*) AS cnt,
				COUNT(DISTINCT COALESCE(NULLIF(distinct_id, ''), anonymous_id)) AS users
			FROM events
			WHERE event_time >= $1 AND event_time < $2
			GROUP BY day
			ORDER BY day
		`, from, to)
		if err != nil {
			return nil, err
		}
		defer fallbackRows.Close()
		for fallbackRows.Next() {
			var point model.DailyEventStat
			if err := fallbackRows.Scan(&point.Date, &point.Count, &point.Users); err != nil {
				return nil, err
			}
			stats.Trend = append(stats.Trend, point)
		}
	}

	return stats, nil
}

func (s *AnalyticsService) EventTrend(ctx context.Context, eventName string, from, to time.Time, unit string) ([]model.EventTrendPoint, error) {
	trunc := "day"
	switch unit {
	case "hour":
		trunc = "hour"
	case "week":
		trunc = "week"
	}

	query := fmt.Sprintf(`
		SELECT
			TO_CHAR(DATE_TRUNC('%s', event_time AT TIME ZONE 'UTC'), 'YYYY-MM-DD HH24:MI') AS bucket,
			COUNT(*) AS cnt,
			COUNT(DISTINCT COALESCE(NULLIF(distinct_id, ''), anonymous_id)) AS users
		FROM events
		WHERE event_time >= $1 AND event_time < $2
	`, trunc)
	args := []any{from, to}
	if eventName != "" {
		query += " AND name = $3"
		args = append(args, eventName)
	}
	query += " GROUP BY bucket ORDER BY bucket"

	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	points := make([]model.EventTrendPoint, 0)
	for rows.Next() {
		var p model.EventTrendPoint
		if err := rows.Scan(&p.Bucket, &p.Count, &p.Users); err != nil {
			return nil, err
		}
		points = append(points, p)
	}
	return points, nil
}

func (s *AnalyticsService) ListEvents(ctx context.Context, eventName string, from, to time.Time, limit, offset int) ([]model.EventRecord, int64, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}

	countQuery := `
		SELECT COUNT(*) FROM events
		WHERE event_time >= $1 AND event_time < $2
	`
	args := []any{from, to}
	if eventName != "" {
		countQuery += " AND name = $3"
		args = append(args, eventName)
	}

	var total int64
	if err := s.pool.QueryRow(ctx, countQuery, args...).Scan(&total); err != nil {
		return nil, 0, err
	}

	listQuery := `
		SELECT event_id, name, properties, distinct_id, anonymous_id, session_id, event_time, received_at
		FROM events
		WHERE event_time >= $1 AND event_time < $2
	`
	listArgs := []any{from, to}
	argIdx := 3
	if eventName != "" {
		listQuery += fmt.Sprintf(" AND name = $%d", argIdx)
		listArgs = append(listArgs, eventName)
		argIdx++
	}
	listQuery += fmt.Sprintf(" ORDER BY event_time DESC LIMIT $%d OFFSET $%d", argIdx, argIdx+1)
	listArgs = append(listArgs, limit, offset)

	rows, err := s.pool.Query(ctx, listQuery, listArgs...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var records []model.EventRecord
	for rows.Next() {
		var rec model.EventRecord
		var props []byte
		if err := rows.Scan(
			&rec.EventID, &rec.Name, &props, &rec.DistinctID,
			&rec.AnonymousID, &rec.SessionID, &rec.EventTime, &rec.ReceivedAt,
		); err != nil {
			return nil, 0, err
		}
		_ = json.Unmarshal(props, &rec.Properties)
		if rec.Properties == nil {
			rec.Properties = map[string]any{}
		}
		records = append(records, rec)
	}
	return records, total, nil
}

func (s *AnalyticsService) EventNames(ctx context.Context, query string) ([]model.NamedCount, error) {
	query = strings.TrimSpace(query)

	var (
		rows pgx.Rows
		err  error
	)
	if query == "" {
		rows, err = s.pool.Query(ctx, `
			SELECT name, COUNT(*) AS cnt
			FROM events
			GROUP BY name
			ORDER BY cnt DESC
			LIMIT 100
		`)
	} else {
		rows, err = s.pool.Query(ctx, `
			SELECT name, COUNT(*) AS cnt
			FROM events
			WHERE name ILIKE $1
			GROUP BY name
			ORDER BY cnt DESC
			LIMIT 100
		`, "%"+query+"%")
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	names := make([]model.NamedCount, 0)
	for rows.Next() {
		var n model.NamedCount
		if err := rows.Scan(&n.Name, &n.Count); err != nil {
			return nil, err
		}
		names = append(names, n)
	}
	return names, nil
}

func (s *AnalyticsService) Funnel(ctx context.Context, steps []string, from, to time.Time, windowHours int) (*model.FunnelResult, error) {
	if len(steps) == 0 {
		return &model.FunnelResult{Steps: []model.FunnelStep{}}, nil
	}
	if windowHours <= 0 {
		windowHours = 24
	}

	window := fmt.Sprintf("%d hours", windowHours)

	// Build sequential funnel: each step must occur after previous step within window.
	cte := "WITH "
	args := []any{from, to}
	argIdx := 3

	for i, step := range steps {
		if i == 0 {
			cte += fmt.Sprintf(`
				step%d AS (
					SELECT DISTINCT COALESCE(NULLIF(distinct_id, ''), anonymous_id) AS user_id,
					       MIN(event_time) AS step_time
					FROM events
					WHERE event_time >= $1 AND event_time < $2 AND name = $%d
					GROUP BY 1
				)`, i, argIdx)
			args = append(args, step)
			argIdx++
			continue
		}

		cte += fmt.Sprintf(`
			, step%d AS (
				SELECT s.user_id, MIN(e.event_time) AS step_time
				FROM step%d s
				JOIN events e ON COALESCE(NULLIF(e.distinct_id, ''), e.anonymous_id) = s.user_id
				WHERE e.name = $%d
				  AND e.event_time > s.step_time
				  AND e.event_time <= s.step_time + INTERVAL '%s'
				GROUP BY s.user_id
			)`, i, i-1, argIdx, window)
		args = append(args, step)
		argIdx++
	}

	var unionParts []string
	for i := range steps {
		unionParts = append(unionParts, fmt.Sprintf("SELECT %d AS step_idx, COUNT(*) AS users FROM step%d", i, i))
	}
	query := cte + " " + strings.Join(unionParts, " UNION ALL ") + " ORDER BY step_idx"

	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	result := &model.FunnelResult{Steps: make([]model.FunnelStep, 0, len(steps))}
	var firstUsers int64 = 1
	for rows.Next() {
		var idx int
		var users int64
		if err := rows.Scan(&idx, &users); err != nil {
			return nil, err
		}
		if idx == 0 {
			firstUsers = users
			if firstUsers == 0 {
				firstUsers = 1
			}
		}
		conv := float64(users) / float64(firstUsers) * 100
		result.Steps = append(result.Steps, model.FunnelStep{
			Name:       steps[idx],
			Users:      users,
			Conversion: conv,
		})
	}
	return result, nil
}

func (s *AnalyticsService) Retention(ctx context.Context, cohortEvent string, returnEvent string, from, to time.Time, days int) (*model.RetentionResult, error) {
	if days <= 0 {
		days = 7
	}
	if cohortEvent == "" {
		cohortEvent = "app_start"
	}
	if returnEvent == "" {
		returnEvent = cohortEvent
	}

	dayList := make([]int, days+1)
	for i := range dayList {
		dayList[i] = i
	}

	rows, err := s.pool.Query(ctx, `
		WITH cohort AS (
			SELECT
				COALESCE(NULLIF(distinct_id, ''), anonymous_id) AS user_id,
				DATE(MIN(event_time) AT TIME ZONE 'UTC') AS cohort_date
			FROM events
			WHERE name = $1
			  AND event_time >= $2 AND event_time < $3
			GROUP BY 1
		),
		returns AS (
			SELECT
				c.cohort_date,
				c.user_id,
				DATE(e.event_time AT TIME ZONE 'UTC') AS return_date
			FROM cohort c
			JOIN events e ON COALESCE(NULLIF(e.distinct_id, ''), e.anonymous_id) = c.user_id
			WHERE e.name = $4
			  AND e.event_time >= $2 AND e.event_time < $3
		)
		SELECT
			TO_CHAR(cohort_date, 'YYYY-MM-DD') AS cohort_date,
			COUNT(DISTINCT user_id) AS cohort_size,
			day_offset,
			COUNT(DISTINCT user_id) FILTER (WHERE returned) AS retained
		FROM (
			SELECT
				c.cohort_date,
				c.user_id,
				d.day_offset,
				EXISTS (
					SELECT 1 FROM returns r
					WHERE r.user_id = c.user_id
					  AND r.cohort_date = c.cohort_date
					  AND r.return_date = c.cohort_date + (d.day_offset || ' days')::interval
				) AS returned
			FROM cohort c
			CROSS JOIN generate_series(0, $5) AS d(day_offset)
		) t
		GROUP BY cohort_date, day_offset
		ORDER BY cohort_date, day_offset
	`, cohortEvent, from, to, returnEvent, days)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	rowMap := map[string]*model.RetentionRow{}
	order := []string{}
	for rows.Next() {
		var cohortDate string
		var cohortSize int64
		var dayOffset int
		var retained int64
		if err := rows.Scan(&cohortDate, &cohortSize, &dayOffset, &retained); err != nil {
			return nil, err
		}
		row, ok := rowMap[cohortDate]
		if !ok {
			row = &model.RetentionRow{
				CohortDate: cohortDate,
				CohortSize: cohortSize,
				Retention:  make([]float64, days+1),
			}
			rowMap[cohortDate] = row
			order = append(order, cohortDate)
		}
		if cohortSize > 0 {
			row.Retention[dayOffset] = float64(retained) / float64(cohortSize) * 100
		}
	}

	result := &model.RetentionResult{Days: dayList, Rows: make([]model.RetentionRow, 0, len(order))}
	for _, d := range order {
		result.Rows = append(result.Rows, *rowMap[d])
	}
	return result, nil
}

func (s *AnalyticsService) ListUsers(ctx context.Context, query string, limit, offset int) ([]model.UserRecord, int64, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}

	countQuery := `SELECT COUNT(*) FROM users`
	listQuery := `
		SELECT user_id, distinct_id, anonymous_id, first_seen_at, last_seen_at,
		       first_open_at, signup_at, is_paid, total_revenue, channel
		FROM users
	`
	args := []any{}
	if query != "" {
		filter := `
			WHERE user_id ILIKE $1
			   OR COALESCE(distinct_id, '') ILIKE $1
			   OR anonymous_id ILIKE $1
		`
		pattern := "%" + query + "%"
		countQuery += filter
		listQuery += filter
		args = append(args, pattern)
	}
	listQuery += fmt.Sprintf(" ORDER BY last_seen_at DESC LIMIT $%d OFFSET $%d", len(args)+1, len(args)+2)
	listArgs := append(append([]any{}, args...), limit, offset)

	var total int64
	if err := s.pool.QueryRow(ctx, countQuery, args...).Scan(&total); err != nil {
		return nil, 0, err
	}

	rows, err := s.pool.Query(ctx, listQuery, listArgs...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var users []model.UserRecord
	for rows.Next() {
		var u model.UserRecord
		if err := rows.Scan(
			&u.UserID, &u.DistinctID, &u.AnonymousID, &u.FirstSeenAt, &u.LastSeenAt,
			&u.FirstOpenAt, &u.SignupAt, &u.IsPaid, &u.TotalRevenue, &u.Channel,
		); err != nil {
			return nil, 0, err
		}
		users = append(users, u)
	}
	return users, total, nil
}

func (s *AnalyticsService) GetUser(ctx context.Context, userID string) (*model.UserRecord, error) {
	var u model.UserRecord
	err := s.pool.QueryRow(ctx, `
		SELECT user_id, distinct_id, anonymous_id, first_seen_at, last_seen_at,
		       first_open_at, signup_at, is_paid, total_revenue, channel
		FROM users WHERE user_id = $1
	`, userID).Scan(
		&u.UserID, &u.DistinctID, &u.AnonymousID, &u.FirstSeenAt, &u.LastSeenAt,
		&u.FirstOpenAt, &u.SignupAt, &u.IsPaid, &u.TotalRevenue, &u.Channel,
	)
	if err != nil {
		return nil, err
	}
	return &u, nil
}

func (s *AnalyticsService) ListUserEvents(ctx context.Context, userID string, from, to time.Time, limit, offset int) ([]model.EventRecord, int64, error) {
	if limit <= 0 {
		limit = 200
	}
	if limit > 1000 {
		limit = 1000
	}

	user, err := s.GetUser(ctx, userID)
	if err != nil {
		return nil, 0, err
	}

	ids := uniqueStrings(user.UserID, user.AnonymousID, derefString(user.DistinctID))

	var total int64
	if err := s.pool.QueryRow(ctx, `
		SELECT COUNT(*) FROM events
		WHERE event_time >= $1 AND event_time < $2
		  AND (distinct_id = ANY($3) OR anonymous_id = ANY($3))
	`, from, to, ids).Scan(&total); err != nil {
		return nil, 0, err
	}

	rows, err := s.pool.Query(ctx, `
		SELECT event_id, name, properties, common_properties, distinct_id, anonymous_id, session_id, event_time, received_at
		FROM events
		WHERE event_time >= $1 AND event_time < $2
		  AND (distinct_id = ANY($3) OR anonymous_id = ANY($3))
		ORDER BY event_time ASC
		LIMIT $4 OFFSET $5
	`, from, to, ids, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	records, err := scanEventRecords(rows)
	if err != nil {
		return nil, 0, err
	}
	return records, total, nil
}

func uniqueStrings(values ...string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(values))
	for _, v := range values {
		if v == "" {
			continue
		}
		if _, ok := seen[v]; ok {
			continue
		}
		seen[v] = struct{}{}
		out = append(out, v)
	}
	return out
}

func derefString(v *string) string {
	if v == nil {
		return ""
	}
	return *v
}

func scanEventRecords(rows interface {
	Next() bool
	Scan(dest ...any) error
}) ([]model.EventRecord, error) {
	var records []model.EventRecord
	for rows.Next() {
		var rec model.EventRecord
		var props, common []byte
		if err := rows.Scan(
			&rec.EventID, &rec.Name, &props, &common, &rec.DistinctID,
			&rec.AnonymousID, &rec.SessionID, &rec.EventTime, &rec.ReceivedAt,
		); err != nil {
			return nil, err
		}
		_ = json.Unmarshal(props, &rec.Properties)
		_ = json.Unmarshal(common, &rec.CommonProperties)
		if rec.Properties == nil {
			rec.Properties = map[string]any{}
		}
		if rec.CommonProperties == nil {
			rec.CommonProperties = map[string]any{}
		}
		records = append(records, rec)
	}
	return records, nil
}

func defaultMap(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

func inclusiveDateRange(from, to time.Time) (time.Time, time.Time) {
	f := from.UTC()
	t := to.UTC()
	fromDate := time.Date(f.Year(), f.Month(), f.Day(), 0, 0, 0, 0, time.UTC)
	toDate := time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
	return fromDate, toDate
}
