#!/bin/bash
set -euo pipefail

SOURCE_HOST="${HERMES_PRODUCTION_SOURCE_HOST:-spencerheywood@100.98.90.106}"
SOURCE_ROOT="${HERMES_PRODUCTION_ARTIFACT_ROOT:-/Users/spencerheywood/.hermes/production-artifacts/desktop}"
TARGET_APP="/Applications/Hermes.app"
INSTALL_SELF="$HOME/.local/bin/hermes-desktop-production-ensure"
LABEL="com.spencer.hermes-desktop-production"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.hermes/logs"

install_guard() {
  mkdir -p "$(dirname "$INSTALL_SELF")" "$(dirname "$PLIST")" "$LOG_DIR"
  if [[ "$0" != "$INSTALL_SELF" ]]; then
    cp "$0" "$INSTALL_SELF"
  fi
  chmod 755 "$INSTALL_SELF"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$INSTALL_SELF</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>3600</integer>
  <key>WatchPaths</key>
  <array><string>/Applications/Hermes.app/Contents/Resources</string></array>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$LOG_DIR/hermes-desktop-production.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/hermes-desktop-production.error.log</string>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
}

if [[ "${1:-}" == "--install-guard" ]]; then
  install_guard
  exit 0
fi

LOCK_DIR="${TMPDIR:-/tmp}/$LABEL.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hermes-production.XXXXXX")"
cleanup() {
  rm -rf "$TMP" "$LOCK_DIR"
}
trap cleanup EXIT

if ssh -o BatchMode=yes -o ConnectTimeout=10 "$SOURCE_HOST" "cat '$SOURCE_ROOT/current.json'" > "$TMP/manifest.json" 2>/dev/null; then
  SOURCE_MODE=remote
elif [[ -f "$SOURCE_ROOT/current.json" ]]; then
  cp "$SOURCE_ROOT/current.json" "$TMP/manifest.json"
  SOURCE_MODE=local
else
  echo "Hermes production manifest is unavailable from both source host and local cache" >&2
  exit 1
fi

read_json() {
  python3 - "$TMP/manifest.json" "$1" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
for part in sys.argv[2].split('.'):
    value = value[part]
print(value)
PY
}

COMMIT="$(read_json commit)"
ARTIFACT_DIR="$(read_json artifactDir)"
ARCHIVE="$(read_json archive)"
ARCHIVE_SHA="$(read_json archiveSha256)"
ASAR_REL="$(read_json appAsarPath)"
ASAR_SHA="$(read_json appAsarSha256)"
RENDERER_REL="$(read_json rendererPath)"
RENDERER_SHA="$(read_json rendererSha256)"

current_matches() {
  [[ -f "$TARGET_APP/Contents/Resources/production-build.json" ]] || return 1
  [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$TARGET_APP/Contents/Resources/production-build.json" 2>/dev/null || true)" == "$COMMIT" ]] || return 1
  [[ "$(shasum -a 256 "$TARGET_APP/$ASAR_REL" 2>/dev/null | awk '{print $1}')" == "$ASAR_SHA" ]] || return 1
  [[ "$(shasum -a 256 "$TARGET_APP/$RENDERER_REL" 2>/dev/null | awk '{print $1}')" == "$RENDERER_SHA" ]] || return 1
}

desktop_turns_active() {
  # No live Desktop process means no Desktop turn can still be executing.
  # This also avoids false deferrals when an old WAL-mode database is readable
  # as a file but cannot be opened read-only without its missing sidecars.
  if ! pgrep -x Hermes >/dev/null 2>&1; then
    return 0
  fi
  python3 - <<'PY'
import glob
import pathlib
import sqlite3
import time

now = time.time()
active = []
paths = glob.glob(str(pathlib.Path.home() / '.hermes/profiles/*/state.db'))
paths.append(str(pathlib.Path.home() / '.hermes/state.db'))
for path in paths:
    try:
        db = sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=2)
        rows = db.execute(
            "SELECT conversation_id, holder, expires_at FROM session_turn_leases "
            "WHERE expires_at > ? AND holder LIKE '%platform=desktop%'",
            (now,),
        ).fetchall()
        db.close()
        active.extend((path, *row) for row in rows)
    except sqlite3.OperationalError as exc:
        if 'no such table' not in str(exc).lower():
            active.append((path, 'READ_ERROR', str(exc), now + 300))
    except OSError as exc:
        active.append((path, 'READ_ERROR', str(exc), now + 300))

for row in active:
    print('\t'.join(map(str, row)))
PY
}

if current_matches; then
  printf '%s Hermes production artifact %s verified\n' "$(date -u +%FT%TZ)" "$COMMIT"
  exit 0
fi

# Never replace Desktop underneath an active agent turn. The launchd guard
# retries hourly, and an explicit fleet deployment can be rerun later.
for check in 1 2; do
  ACTIVE="$(desktop_turns_active)"
  if [[ -n "$ACTIVE" ]]; then
    printf '%s Hermes production update deferred; active Desktop turn: %s\n' "$(date -u +%FT%TZ)" "${ACTIVE//$'\n'/; }"
    exit 0
  fi
  [[ "$check" == 1 ]] && sleep 5
done

if [[ "$SOURCE_MODE" == local ]]; then
  cp "$SOURCE_ROOT/$ARTIFACT_DIR/$ARCHIVE" "$TMP/$ARCHIVE"
else
  scp -q "$SOURCE_HOST:$SOURCE_ROOT/$ARTIFACT_DIR/$ARCHIVE" "$TMP/$ARCHIVE"
fi

if [[ "$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')" != "$ARCHIVE_SHA" ]]; then
  echo "Production archive checksum mismatch" >&2
  exit 1
fi

mkdir -p "$TMP/extract"
ditto -x -k "$TMP/$ARCHIVE" "$TMP/extract"
CANDIDATE="$TMP/extract/Hermes.app"
[[ -d "$CANDIDATE" ]]
codesign --verify --deep --strict "$CANDIDATE"
[[ "$(shasum -a 256 "$CANDIDATE/$ASAR_REL" | awk '{print $1}')" == "$ASAR_SHA" ]]
[[ "$(shasum -a 256 "$CANDIDATE/$RENDERER_REL" | awk '{print $1}')" == "$RENDERER_SHA" ]]

OLD_PID="$(pgrep -f '^/Applications/Hermes.app/Contents/MacOS/Hermes$' | head -1 || true)"
if [[ -n "$OLD_PID" ]]; then
  osascript -e 'tell application "Hermes" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    kill -0 "$OLD_PID" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$OLD_PID" 2>/dev/null; then
    kill -TERM "$OLD_PID" 2>/dev/null || true
    for _ in $(seq 1 60); do
      kill -0 "$OLD_PID" 2>/dev/null || break
      sleep 0.5
    done
  fi
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Hermes ignored both application quit and TERM; update deferred" >&2
    exit 0
  fi
fi

BACKUP="$HOME/.hermes/backups/hermes-desktop-production/$(date +%Y%m%d-%H%M%S)"
STAGED="/Applications/.Hermes-production-$$.app"
mkdir -p "$BACKUP"
ditto "$CANDIDATE" "$STAGED"

if [[ -d "$TARGET_APP" ]]; then
  mv "$TARGET_APP" "$BACKUP/Hermes.app"
fi

if ! mv "$STAGED" "$TARGET_APP"; then
  [[ -d "$BACKUP/Hermes.app" ]] && mv "$BACKUP/Hermes.app" "$TARGET_APP"
  exit 1
fi

codesign --verify --deep --strict "$TARGET_APP"
if ! current_matches; then
  echo "Installed production artifact failed verification" >&2
  exit 1
fi

open -a "$TARGET_APP"
NEW_PID=""
for _ in $(seq 1 60); do
  NEW_PID="$(pgrep -f '^/Applications/Hermes.app/Contents/MacOS/Hermes$' | head -1 || true)"
  [[ -n "$NEW_PID" ]] && break
  sleep 0.5
done
if [[ -z "$NEW_PID" ]]; then
  echo "New Hermes app failed to launch; restoring previous build" >&2
  rm -rf "$TARGET_APP"
  if [[ -d "$BACKUP/Hermes.app" ]]; then
    mv "$BACKUP/Hermes.app" "$TARGET_APP"
    open -a "$TARGET_APP" || true
  fi
  exit 1
fi
printf '%s installed Hermes production artifact %s (pid %s -> %s)\n' "$(date -u +%FT%TZ)" "$COMMIT" "${OLD_PID:-none}" "$NEW_PID"
