#!/usr/bin/env bash
# Demo: 探活 → e2e 冒烟 → 打开最新 HTML 报告
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${FLUTTER_BIN:-$HOME/fvm/default/bin}:$HOME/.pub-cache/bin:$PATH"

echo "== Flutter-Perf-Agent demo =="
echo "root: $ROOT"

if ! curl -sf --max-time 2 http://127.0.0.1:19288/health >/dev/null; then
  cat <<EOF
Bridge 未就绪 (http://127.0.0.1:19288/health)。

请另开终端先启动 Demo App：
  cd "$ROOT/example_app"
  flutter run -d macos --profile
  # 或 debug：flutter run -d macos --debug

然后再跑：
  $0
EOF
  exit 2
fi

echo "== health =="
curl -sS http://127.0.0.1:19288/health | python3 -m json.tool | head -20

echo "== e2e smoke =="
cd "$ROOT/mcp_server"
dart run tool/e2e_smoke.dart

HTML="$(ls -t "$ROOT/reports"/*e2e_login_scroll_smoke*.html 2>/dev/null | head -1 || true)"
if [[ -n "${HTML}" ]]; then
  echo "== open report =="
  echo "$HTML"
  if command -v open >/dev/null 2>&1; then
    open "$HTML" || true
  fi
fi

echo "DEMO_OK"
