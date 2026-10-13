#!/usr/bin/env bash
# 在 101.126.68.169 上发布 track-server-py。
#
#   deploy.sh <release.tgz> <git-sha>
#
# 压缩包根目录要有 app/、migrations/、requirements.txt。
# 不改 .env、.venv，不重启别的服务，也不动 ota-pg 容器本身。
# 代码与线上一致时直接退出，不重启。
# /health 失败时先恢复代码；若库备份已生成，再把 track 库恢复到发布前。
set -euo pipefail

RELEASE_TGZ="${1:?usage: deploy.sh <release.tgz> <git-sha>}"
SHA="${2:?usage: deploy.sh <release.tgz> <git-sha>}"

ROOT=/opt/track/server
UNIT=track-server-py
HEALTH_URL=http://127.0.0.1:18100/health
BACKUP_DIR=/opt/track/backups
LOG=/opt/track/logs/deploy.log
PG_CONTAINER=ota-pg
PG_DB=track
PG_USER=track
KEEP=5

DOCKER=/usr/bin/docker
SYSTEMCTL=/usr/bin/systemctl
CURL=/usr/bin/curl
RSYNC=/usr/bin/rsync
MKDIR=/usr/bin/mkdir
TAR=/usr/bin/tar
DATE=/usr/bin/date

log() { printf '%s %s\n' "$("$DATE" '+%Y-%m-%dT%H:%M:%S')" "$*" | tee -a "$LOG"; }

"$MKDIR" -p "$BACKUP_DIR" /opt/track/logs

STAGE="$("$MKDIR" -d)"
trap 'rm -rf "$STAGE"' EXIT
"$TAR" -xzf "$RELEASE_TGZ" -C "$STAGE"
test -d "$STAGE/app"
test -d "$STAGE/migrations"
test -f "$STAGE/requirements.txt"

changed=$("$RSYNC" -ain --delete --exclude '__pycache__/' "$STAGE/app/" "$ROOT/app/" || true)
changed+=$'\n'
changed+=$("$RSYNC" -ain "$STAGE/migrations/" "$ROOT/migrations/" || true)
real=$(printf '%s\n' "$changed" | grep -E '^[<>ch*]' || true)
req_changed=0
if ! cmp -s "$STAGE/requirements.txt" "$ROOT/requirements.txt"; then
  req_changed=1
fi
if [ -z "$real" ] && [ "$req_changed" -eq 0 ]; then
  log "skip ${SHA}: code matches the running tree"
  printf '%s\n' "$SHA" > "$ROOT/.deployed-sha"
  exit 0
fi

STAMP=$("$DATE" '+%Y%m%d%H%M%S')
SNAP="$BACKUP_DIR/code-${STAMP}-${SHA}.tgz"
DUMP="$BACKUP_DIR/track-${STAMP}-${SHA}.dump"

log "backup code -> $SNAP"
"$TAR" -C "$ROOT" -czf "$SNAP" app migrations requirements.txt

log "backup database track -> $DUMP"
"$DOCKER" exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" -Fc > "$DUMP"
test -s "$DUMP"

apply_tree() {
  local src="$1"
  "$RSYNC" -a --delete --exclude '__pycache__/' "$src/app/" "$ROOT/app/"
  "$RSYNC" -a "$src/migrations/" "$ROOT/migrations/"
  cp "$src/requirements.txt" "$ROOT/requirements.txt"
}

restore_code() {
  local tmp
  tmp=$("$MKDIR" -d)
  "$TAR" -xzf "$SNAP" -C "$tmp"
  "$RSYNC" -a --delete --exclude '__pycache__/' "$tmp/app/" "$ROOT/app/"
  "$RSYNC" -a --delete "$tmp/migrations/" "$ROOT/migrations/"
  cp "$tmp/requirements.txt" "$ROOT/requirements.txt"
  rm -rf "$tmp"
}

healthy() {
  "$CURL" -sf --max-time 3 "$HEALTH_URL" >/dev/null || return 1
  sleep 2
  "$CURL" -sf --max-time 3 "$HEALTH_URL" >/dev/null || return 1
  "$SYSTEMCTL" is-active --quiet "$UNIT"
}

wait_healthy() {
  local i
  for i in $(seq 1 30); do
    if "$CURL" -sf --max-time 3 "$HEALTH_URL" >/dev/null; then
      sleep 2
      "$CURL" -sf --max-time 3 "$HEALTH_URL" >/dev/null || return 1
      "$SYSTEMCTL" is-active --quiet "$UNIT" || return 1
      return 0
    fi
    sleep 1
  done
  return 1
}

rollback() {
  log "health check failed, restoring previous code"
  "$JOURNALCTL" -u "$UNIT" -n 60 --no-pager >> "$LOG" || true
  restore_code
  if [ "$req_changed" -eq 1 ]; then
    "$ROOT/.venv/bin/pip" install -r "$ROOT/requirements.txt"
  fi
  "$SYSTEMCTL" restart "$UNIT"
  if ! wait_healthy; then
    log "previous code did not become healthy"
    return 1
  fi
  log "restoring database $DUMP"
  "$SYSTEMCTL" stop "$UNIT"
  "$DOCKER" exec "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$PG_DB' AND pid <> pg_backend_pid();" \
    >/dev/null
  "$DOCKER" exec -i "$PG_CONTAINER" pg_restore -U "$PG_USER" -d "$PG_DB" --clean --if-exists < "$DUMP" || true
  "$SYSTEMCTL" start "$UNIT"
  wait_healthy || return 1
}

JOURNALCTL=/usr/bin/journalctl

log "install ${SHA}"
apply_tree "$STAGE"
if [ "$req_changed" -eq 1 ]; then
  log "pip install"
  "$ROOT/.venv/bin/pip" install -r "$ROOT/requirements.txt"
fi
"$SYSTEMCTL" restart "$UNIT"
if wait_healthy; then
  printf '%s\n' "$SHA" > "$ROOT/.deployed-sha"
  log "deployed ${SHA}"
  ls -1t "$BACKUP_DIR"/track-*.dump 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
  ls -1t "$BACKUP_DIR"/code-*.tgz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
  exit 0
fi

if rollback && healthy; then
  log "rolled back ${SHA}"
  exit 1
fi
log "rollback failed for ${SHA}; dump kept at $DUMP"
exit 1
