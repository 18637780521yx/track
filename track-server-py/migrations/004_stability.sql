-- 稳定性：崩溃 / 非致命异常 / ANR（与业务 events 隔离）

CREATE TABLE IF NOT EXISTS stability_issues (
    fingerprint         VARCHAR(64) PRIMARY KEY,
    kind                VARCHAR(16) NOT NULL,
    exception_type      VARCHAR(256) NOT NULL DEFAULT '',
    sample_message      TEXT NOT NULL DEFAULT '',
    sample_stack        TEXT NOT NULL DEFAULT '',
    occurrence_count    BIGINT NOT NULL DEFAULT 0,
    user_count          BIGINT NOT NULL DEFAULT 0,
    first_seen_at       TIMESTAMPTZ NOT NULL,
    last_seen_at        TIMESTAMPTZ NOT NULL,
    status              VARCHAR(16) NOT NULL DEFAULT 'open',
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stability_issues_kind_last
    ON stability_issues (kind, last_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_stability_issues_count
    ON stability_issues (occurrence_count DESC);

CREATE TABLE IF NOT EXISTS stability_events (
    id                  BIGSERIAL PRIMARY KEY,
    event_id            VARCHAR(64) NOT NULL UNIQUE,
    kind                VARCHAR(16) NOT NULL,
    fingerprint         VARCHAR(64) NOT NULL REFERENCES stability_issues (fingerprint),
    exception_type      VARCHAR(256) NOT NULL DEFAULT '',
    message             TEXT NOT NULL DEFAULT '',
    stack               TEXT NOT NULL DEFAULT '',
    thread              VARCHAR(128) NOT NULL DEFAULT '',
    is_fatal            BOOLEAN NOT NULL DEFAULT FALSE,
    blocked_ms          BIGINT,
    anr_source          VARCHAR(32),
    app_version         VARCHAR(64) NOT NULL DEFAULT '',
    app_build           VARCHAR(64) NOT NULL DEFAULT '',
    device_model        VARCHAR(128) NOT NULL DEFAULT '',
    device_os_version   VARCHAR(64) NOT NULL DEFAULT '',
    distinct_id         VARCHAR(128),
    anonymous_id        VARCHAR(128) NOT NULL DEFAULT '',
    session_id          VARCHAR(128) NOT NULL DEFAULT '',
    user_id             VARCHAR(128) NOT NULL DEFAULT '',
    extras              JSONB NOT NULL DEFAULT '{}',
    event_time          TIMESTAMPTZ NOT NULL,
    received_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stability_events_kind_time
    ON stability_events (kind, event_time DESC);
CREATE INDEX IF NOT EXISTS idx_stability_events_fp_time
    ON stability_events (fingerprint, event_time DESC);
CREATE INDEX IF NOT EXISTS idx_stability_events_user_time
    ON stability_events (user_id, event_time DESC)
    WHERE user_id IS NOT NULL AND user_id != '';

CREATE TABLE IF NOT EXISTS stability_issue_users (
    fingerprint         VARCHAR(64) NOT NULL REFERENCES stability_issues (fingerprint),
    user_id             VARCHAR(128) NOT NULL,
    first_seen_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (fingerprint, user_id)
);
