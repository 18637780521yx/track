package model

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

type ingestEventJSON struct {
	EventID          string          `json:"event_id"`
	Name             string          `json:"name"`
	Properties       map[string]any  `json:"properties"`
	CommonProperties map[string]any  `json:"common_properties"`
	DistinctID       *string         `json:"distinct_id"`
	AnonymousID      string          `json:"anonymous_id"`
	SessionID        string          `json:"session_id"`
	Timestamp        json.RawMessage `json:"timestamp"`
}

type ingestRequestJSON struct {
	Events []ingestEventJSON `json:"events"`
}

func ParseIngestRequest(body []byte) ([]TrackEvent, error) {
	var raw ingestRequestJSON
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, err
	}

	events := make([]TrackEvent, 0, len(raw.Events))
	for i, item := range raw.Events {
		ts, err := parseFlexibleTime(item.Timestamp)
		if err != nil {
			return nil, fmt.Errorf("events[%d].timestamp: %w", i, err)
		}
		events = append(events, TrackEvent{
			EventID:          item.EventID,
			Name:             item.Name,
			Properties:       item.Properties,
			CommonProperties: item.CommonProperties,
			DistinctID:       item.DistinctID,
			AnonymousID:      item.AnonymousID,
			SessionID:        item.SessionID,
			Timestamp:        ts,
		})
	}
	return events, nil
}

func parseFlexibleTime(raw json.RawMessage) (time.Time, error) {
	if len(raw) == 0 {
		return time.Time{}, nil
	}

	var asString string
	if err := json.Unmarshal(raw, &asString); err == nil {
		return parseTimeString(asString)
	}

	var asNumber float64
	if err := json.Unmarshal(raw, &asNumber); err == nil {
		sec := int64(asNumber)
		nsec := int64((asNumber - float64(sec)) * 1e9)
		return time.Unix(sec, nsec).UTC(), nil
	}

	return time.Time{}, fmt.Errorf("unsupported timestamp format")
}

func parseTimeString(value string) (time.Time, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return time.Time{}, nil
	}

	layouts := []string{
		time.RFC3339Nano,
		time.RFC3339,
		"2006-01-02T15:04:05.000",
		"2006-01-02T15:04:05",
		"2006-01-02 15:04:05",
	}
	for _, layout := range layouts {
		if t, err := time.Parse(layout, value); err == nil {
			return t.UTC(), nil
		}
	}
	return time.Time{}, fmt.Errorf("invalid time %q", value)
}
