-- 用户画像表：从 events 衍生，加速新增/活跃/付费分析
CREATE TABLE IF NOT EXISTS users (
    user_id         VARCHAR(128) PRIMARY KEY,
    distinct_id     VARCHAR(128),
    anonymous_id    VARCHAR(128) NOT NULL,
    first_seen_at   TIMESTAMPTZ NOT NULL,
    last_seen_at    TIMESTAMPTZ NOT NULL,
    first_open_at   TIMESTAMPTZ,
    signup_at       TIMESTAMPTZ,
    is_paid         BOOLEAN NOT NULL DEFAULT FALSE,
    total_revenue   NUMERIC(12, 2) NOT NULL DEFAULT 0,
    channel         VARCHAR(64),
    properties      JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_first_seen ON users (first_seen_at);
CREATE INDEX IF NOT EXISTS idx_users_last_seen ON users (last_seen_at);
CREATE INDEX IF NOT EXISTS idx_users_anonymous ON users (anonymous_id);
CREATE INDEX IF NOT EXISTS idx_users_is_paid ON users (is_paid) WHERE is_paid = TRUE;

-- 订阅状态表：记录当前/历史订阅，支持 MRR、活跃订阅数
CREATE TABLE IF NOT EXISTS subscriptions (
    id              BIGSERIAL PRIMARY KEY,
    user_id         VARCHAR(128) NOT NULL REFERENCES users (user_id),
    plan            VARCHAR(64) NOT NULL,
    status          VARCHAR(32) NOT NULL DEFAULT 'active',
    amount          NUMERIC(12, 2) NOT NULL DEFAULT 0,
    currency        VARCHAR(8) NOT NULL DEFAULT 'CNY',
    started_at      TIMESTAMPTZ NOT NULL,
    expires_at      TIMESTAMPTZ,
    cancelled_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_user ON subscriptions (user_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_status ON subscriptions (status);
CREATE INDEX IF NOT EXISTS idx_subscriptions_expires ON subscriptions (expires_at) WHERE status = 'active';

-- 日维度预聚合：Dashboard 秒开
CREATE TABLE IF NOT EXISTS daily_stats (
    date                    DATE PRIMARY KEY,
    dau                     BIGINT NOT NULL DEFAULT 0,
    new_users               BIGINT NOT NULL DEFAULT 0,
    installs                BIGINT NOT NULL DEFAULT 0,
    revenue                 NUMERIC(12, 2) NOT NULL DEFAULT 0,
    paying_users            BIGINT NOT NULL DEFAULT 0,
    total_events            BIGINT NOT NULL DEFAULT 0,
    active_subscriptions    BIGINT NOT NULL DEFAULT 0,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 日活去重辅助表：同一用户同一天只计一次 DAU
CREATE TABLE IF NOT EXISTS daily_active_users (
    date        DATE NOT NULL,
    user_id     VARCHAR(128) NOT NULL,
    PRIMARY KEY (date, user_id)
);

CREATE INDEX IF NOT EXISTS idx_daily_active_users_date ON daily_active_users (date);

-- 每日付费用户去重
CREATE TABLE IF NOT EXISTS daily_paying_users (
    date        DATE NOT NULL,
    user_id     VARCHAR(128) NOT NULL,
    PRIMARY KEY (date, user_id)
);
