CREATE TABLE IF NOT EXISTS events (
    id              BIGSERIAL PRIMARY KEY,
    event_id        VARCHAR(64) NOT NULL UNIQUE,
    name            VARCHAR(128) NOT NULL,
    properties      JSONB NOT NULL DEFAULT '{}',
    common_properties JSONB NOT NULL DEFAULT '{}',
    distinct_id     VARCHAR(128),
    anonymous_id    VARCHAR(128) NOT NULL,
    session_id      VARCHAR(128) NOT NULL,
    event_time      TIMESTAMPTZ NOT NULL,
    received_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_events_name_time ON events (name, event_time DESC);
CREATE INDEX IF NOT EXISTS idx_events_time ON events (event_time DESC);
CREATE INDEX IF NOT EXISTS idx_events_distinct_id ON events (distinct_id) WHERE distinct_id IS NOT NULL AND distinct_id != '';
CREATE INDEX IF NOT EXISTS idx_events_anonymous_id ON events (anonymous_id);
CREATE INDEX IF NOT EXISTS idx_events_received_at ON events (received_at DESC);
