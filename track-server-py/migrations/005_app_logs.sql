-- app_log 与业务 events 隔离：减负 events / daily_stats / overview

CREATE TABLE IF NOT EXISTS app_logs (
    id                  BIGSERIAL PRIMARY KEY,
    event_id            VARCHAR(64) NOT NULL UNIQUE,
    level               VARCHAR(8) NOT NULL DEFAULT '',
    tag                 VARCHAR(128) NOT NULL DEFAULT '',
    message             TEXT NOT NULL DEFAULT '',
    source              VARCHAR(64) NOT NULL DEFAULT 'app_log',
    properties          JSONB NOT NULL DEFAULT '{}',
    common_properties   JSONB NOT NULL DEFAULT '{}',
    distinct_id         VARCHAR(128),
    anonymous_id        VARCHAR(128) NOT NULL DEFAULT '',
    session_id          VARCHAR(128) NOT NULL DEFAULT '',
    user_id             VARCHAR(128) NOT NULL DEFAULT '',
    event_time          TIMESTAMPTZ NOT NULL,
    received_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_app_logs_user_time
    ON app_logs (user_id, event_time DESC)
    WHERE user_id IS NOT NULL AND user_id != '';
CREATE INDEX IF NOT EXISTS idx_app_logs_anon_time
    ON app_logs (anonymous_id, event_time DESC);
CREATE INDEX IF NOT EXISTS idx_app_logs_time
    ON app_logs (event_time DESC);
CREATE INDEX IF NOT EXISTS idx_app_logs_level_time
    ON app_logs (level, event_time DESC);

-- 历史数据迁出（幂等：event_id 冲突跳过）
INSERT INTO app_logs (
    event_id, level, tag, message, source,
    properties, common_properties,
    distinct_id, anonymous_id, session_id, user_id, event_time, received_at
)
SELECT
    e.event_id,
    COALESCE(NULLIF(e.properties->>'level', ''), ''),
    COALESCE(NULLIF(e.properties->>'tag', ''), '') ,
    COALESCE(NULLIF(e.properties->>'message', ''), ''),
    COALESCE(NULLIF(e.properties->>'source', ''), 'app_log'),
    e.properties,
    e.common_properties,
    e.distinct_id,
    e.anonymous_id,
    e.session_id,
    COALESCE(NULLIF(e.distinct_id, ''), NULLIF(e.anonymous_id, ''), 'unknown'),
    e.event_time,
    e.received_at
FROM events e
WHERE e.name = 'app_log'
ON CONFLICT (event_id) DO NOTHING;

DELETE FROM events WHERE name = 'app_log';
