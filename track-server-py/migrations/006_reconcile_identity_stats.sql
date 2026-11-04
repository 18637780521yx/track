-- 匿名 ID 已合并进登录用户后，日活/新增/安装仍可能按两套 ID 各计一次。
-- 把明细表里残留的匿名 user_id 并到 users.user_id，再按明细回写 daily_stats。

INSERT INTO daily_active_users (date, user_id)
SELECT d.date, u.user_id
FROM daily_active_users d
JOIN users u ON u.anonymous_id = d.user_id
  AND u.anonymous_id NOT IN ('', 'unknown')
  AND u.user_id <> d.user_id
ON CONFLICT DO NOTHING;

DELETE FROM daily_active_users d
USING users u
WHERE u.anonymous_id = d.user_id
  AND u.anonymous_id NOT IN ('', 'unknown')
  AND u.user_id <> d.user_id;

INSERT INTO daily_install_users (date, user_id)
SELECT d.date, u.user_id
FROM daily_install_users d
JOIN users u ON u.anonymous_id = d.user_id
  AND u.anonymous_id NOT IN ('', 'unknown')
  AND u.user_id <> d.user_id
ON CONFLICT DO NOTHING;

DELETE FROM daily_install_users d
USING users u
WHERE u.anonymous_id = d.user_id
  AND u.anonymous_id NOT IN ('', 'unknown')
  AND u.user_id <> d.user_id;

INSERT INTO daily_paying_users (date, user_id)
SELECT d.date, u.user_id
FROM daily_paying_users d
JOIN users u ON u.anonymous_id = d.user_id
  AND u.anonymous_id NOT IN ('', 'unknown')
  AND u.user_id <> d.user_id
ON CONFLICT DO NOTHING;

DELETE FROM daily_paying_users d
USING users u
WHERE u.anonymous_id = d.user_id
  AND u.anonymous_id NOT IN ('', 'unknown')
  AND u.user_id <> d.user_id;

UPDATE daily_stats ds SET
    dau = (SELECT COUNT(*) FROM daily_active_users x WHERE x.date = ds.date),
    installs = (SELECT COUNT(*) FROM daily_install_users x WHERE x.date = ds.date),
    paying_users = (SELECT COUNT(*) FROM daily_paying_users x WHERE x.date = ds.date),
    updated_at = NOW();

UPDATE daily_stats SET new_users = 0, updated_at = NOW();

INSERT INTO daily_stats (date, new_users)
SELECT (first_seen_at AT TIME ZONE 'UTC')::date AS d, COUNT(*)::bigint
FROM users
GROUP BY 1
ON CONFLICT (date) DO UPDATE SET
    new_users = EXCLUDED.new_users,
    updated_at = NOW();
