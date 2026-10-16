#!/usr/bin/env bash
# Publish com.wenrai:fast-track to local maven-repo, then sync to OTA public/maven
# (same layout as ota-sdk: https://ota.h10wanren.com:8443/maven/).
#
# Usage:
#   ./scripts/publish-to-maven.sh
#   ./scripts/publish-to-maven.sh --skip-remote   # only local + workspace public/maven
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="$(cd "$ROOT/../.." && pwd)"
LOCAL_REPO="$ROOT/maven-repo"
PUBLIC_MAVEN="$WORKSPACE/rcstarsota/public/maven"
REMOTE_MAVEN="${REMOTE_MAVEN:-wanren:/root/wanxin_workdir/rcstarsota/public/maven}"

SKIP_REMOTE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-remote) SKIP_REMOTE=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

cd "$ROOT"
echo "Publishing :fast-track …"
./gradlew :fast-track:publish --no-daemon

if [[ ! -d "$LOCAL_REPO/com/wenrai/fast-track" ]]; then
  echo "Publish output missing under $LOCAL_REPO" >&2
  exit 1
fi

mkdir -p "$PUBLIC_MAVEN"
echo "Sync → $PUBLIC_MAVEN"
rsync -a --delete "$LOCAL_REPO/com/wenrai/fast-track/" "$PUBLIC_MAVEN/com/wenrai/fast-track/"

# keep group metadata if gradle wrote it
if [[ -d "$LOCAL_REPO/com/wenrai" ]]; then
  # only copy fast-track tree; do not wipe ota-sdk
  :
fi

VER="$(grep -E '^fastTrackVersion=' "$ROOT/gradle.properties" | cut -d= -f2)"
echo "Local OK: com.wenrai:fast-track:$VER"

if [[ "$SKIP_REMOTE" -eq 1 ]]; then
  echo "Skip remote sync."
  exit 0
fi

echo "Sync → $REMOTE_MAVEN"
rsync -az "$PUBLIC_MAVEN/com/wenrai/fast-track/" "$REMOTE_MAVEN/com/wenrai/fast-track/"
echo "Remote OK. Resolve via:"
echo "  maven { url = uri(\"https://ota.h10wanren.com:8443/maven/\") }"
echo "  implementation(\"com.wenrai:fast-track:$VER\")"
