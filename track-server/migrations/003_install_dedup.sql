-- 安装用户去重：同一用户只计一次安装
CREATE TABLE IF NOT EXISTS daily_install_users (
    date        DATE NOT NULL,
    user_id     VARCHAR(128) NOT NULL,
    PRIMARY KEY (date, user_id)
);

CREATE INDEX IF NOT EXISTS idx_daily_install_users_date ON daily_install_users (date);

-- 从 users.first_open_at 回填历史数据
INSERT INTO daily_install_users (date, user_id)
SELECT DATE(first_open_at AT TIME ZONE 'UTC'), user_id
FROM users
WHERE first_open_at IS NOT NULL
ON CONFLICT DO NOTHING;

UPDATE daily_stats ds
SET installs = COALESCE((
    SELECT COUNT(*)::bigint FROM daily_install_users diu WHERE diu.date = ds.date
), 0),
updated_at = NOW()
WHERE EXISTS (SELECT 1 FROM daily_stats);
