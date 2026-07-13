package model

import "time"

type TrackEvent struct {
	EventID          string         `json:"event_id"`
	Name             string         `json:"name"`
	Properties       map[string]any `json:"properties"`
	CommonProperties map[string]any `json:"common_properties"`
	DistinctID       *string        `json:"distinct_id"`
	AnonymousID      string         `json:"anonymous_id"`
	SessionID        string         `json:"session_id"`
	Timestamp        time.Time      `json:"timestamp"`
}

type IngestRequest struct {
	Events []TrackEvent `json:"events"`
}

type IngestResponse struct {
	OK      bool `json:"ok"`
	Total   int  `json:"total"`
	Stored  int  `json:"stored"`
	Dropped int  `json:"dropped"`
}

type OverviewStats struct {
	DAU                 int64            `json:"dau"`
	NewUsers            int64            `json:"new_users"`
	Installs            int64            `json:"installs"`
	Revenue             float64          `json:"revenue"`
	PayingUsers         int64            `json:"paying_users"`
	ActiveSubscriptions int64            `json:"active_subscriptions"`
	TotalEvents         int64            `json:"total_events"`
	TopEvents           []NamedCount     `json:"top_events"`
	Trend               []DailyEventStat `json:"trend"`
}

type NamedCount struct {
	Name  string `json:"name"`
	Count int64  `json:"count"`
}

type DailyEventStat struct {
	Date                string  `json:"date"`
	Count               int64   `json:"count"`
	Users               int64   `json:"users"`
	NewUsers            int64   `json:"new_users"`
	Installs            int64   `json:"installs"`
	Revenue             float64 `json:"revenue"`
	ActiveSubscriptions int64   `json:"active_subscriptions"`
}

type EventTrendPoint struct {
	Bucket string `json:"bucket"`
	Count  int64  `json:"count"`
	Users  int64  `json:"users"`
}

type EventRecord struct {
	EventID          string         `json:"event_id"`
	Name             string         `json:"name"`
	Properties       map[string]any `json:"properties"`
	CommonProperties map[string]any `json:"common_properties,omitempty"`
	DistinctID       *string        `json:"distinct_id"`
	AnonymousID      string         `json:"anonymous_id"`
	SessionID        string         `json:"session_id"`
	EventTime        time.Time      `json:"event_time"`
	ReceivedAt       time.Time      `json:"received_at"`
}

type FunnelStep struct {
	Name       string  `json:"name"`
	Users      int64   `json:"users"`
	Conversion float64 `json:"conversion"`
}

type FunnelResult struct {
	Steps []FunnelStep `json:"steps"`
}

type RetentionRow struct {
	CohortDate string    `json:"cohort_date"`
	CohortSize int64     `json:"cohort_size"`
	Retention  []float64 `json:"retention"`
}

type RetentionResult struct {
	Days []int          `json:"days"`
	Rows []RetentionRow `json:"rows"`
}

type UserRecord struct {
	UserID        string     `json:"user_id"`
	DistinctID    *string    `json:"distinct_id"`
	AnonymousID   string     `json:"anonymous_id"`
	FirstSeenAt   time.Time  `json:"first_seen_at"`
	LastSeenAt    time.Time  `json:"last_seen_at"`
	FirstOpenAt   *time.Time `json:"first_open_at"`
	SignupAt      *time.Time `json:"signup_at"`
	IsPaid        bool       `json:"is_paid"`
	TotalRevenue  float64    `json:"total_revenue"`
	Channel       *string    `json:"channel"`
}
