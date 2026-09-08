#!/bin/bash
set -Eeuo pipefail

NEW_RUNTIME="${HERMES_NEW_RUNTIME:-$HOME/.hermes/runtimes/hermes-v2026.8.31-69d5eed4a751}"
NEW_WORKTREE="${HERMES_NEW_WORKTREE:-$HOME/.hermes/worktrees/hermes-v0.21.0-production}"
EXPECTED_VERSION="${HERMES_EXPECTED_VERSION:-0.21.0}"
PLIST_DIR="$HOME/Library/LaunchAgents"
DESKTOP_PLIST="$PLIST_DIR/com.spencer.hermes-desktop-backend.plist"
BACKUP_ROOT="$HOME/.hermes/backups/hermes-runtime-cutover/$(date +%Y%m%d-%H%M%S)"
PLIST_BUDDY=/usr/libexec/PlistBuddy
GUI_DOMAIN="gui/$(id -u)"
USER_DOMAIN="user/$(id -u)"
OLD_LINK="$(readlink "$HOME/.local/bin/hermes" 2>/dev/null || true)"
APPLIED=0
DEFERRED_PROFILE="${HERMES_DEFERRED_PROFILE:-}"
ONLY_PROFILE="${HERMES_ONLY_PROFILE:-}"
BACKEND_ONLY="${HERMES_BACKEND_ONLY:-0}"

if [[ "$BACKEND_ONLY" == 1 && ( -n "$DEFERRED_PROFILE" || -n "$ONLY_PROFILE" ) ]]; then
  echo "HERMES_BACKEND_ONLY cannot be combined with profile selectors" >&2
  exit 2
fi
if [[ -n "$DEFERRED_PROFILE" && -n "$ONLY_PROFILE" ]]; then
  echo "HERMES_DEFERRED_PROFILE and HERMES_ONLY_PROFILE are mutually exclusive" >&2
  exit 2
fi

plists=()
restart_plists=()
PLIST_COUNT=0
RESTART_COUNT=0
if [[ -z "$ONLY_PROFILE" ]]; then
  plists+=("$DESKTOP_PLIST")
  PLIST_COUNT=$((PLIST_COUNT + 1))
  if launchctl list com.spencer.hermes-desktop-backend >/dev/null 2>&1; then
    restart_plists+=("$DESKTOP_PLIST")
    RESTART_COUNT=$((RESTART_COUNT + 1))
  fi
fi
for plist in "$PLIST_DIR"/ai.hermes.gateway*.plist; do
  [[ "$BACKEND_ONLY" == 1 ]] && continue
  [[ -f "$plist" ]] || continue
  profile="$(basename "$plist")"
  profile="${profile#ai.hermes.gateway-}"
  profile="${profile%.plist}"
  [[ "$profile" == "ai.hermes.gateway" ]] && profile="default"
  [[ -n "$DEFERRED_PROFILE" && "$profile" == "$DEFERRED_PROFILE" ]] && continue
  [[ -n "$ONLY_PROFILE" && "$profile" != "$ONLY_PROFILE" ]] && continue
  plists+=("$plist")
  PLIST_COUNT=$((PLIST_COUNT + 1))
  label="$($PLIST_BUDDY -c 'Print :Label' "$plist")"
  if launchctl list "$label" >/dev/null 2>&1; then
    restart_plists+=("$plist")
    RESTART_COUNT=$((RESTART_COUNT + 1))
  fi
done
if [[ "$PLIST_COUNT" -eq 0 ]]; then
  echo "No launchd service matched the requested runtime cutover scope" >&2
  exit 1
fi

active_turns() {
  local now db rows lease_scope
  now="$(date +%s)"
  lease_scope=""
  if [[ "$BACKEND_ONLY" == 1 ]]; then
    lease_scope=" AND holder LIKE '%platform=desktop%'"
  fi
  for db in "$HOME/.hermes/state.db" "$HOME"/.hermes/profiles/*/state.db; do
    [[ -f "$db" ]] || continue
    if [[ -n "$DEFERRED_PROFILE" && "$db" == "$HOME/.hermes/profiles/$DEFERRED_PROFILE/state.db" ]]; then
      continue
    fi
    if [[ -n "$ONLY_PROFILE" && "$db" != "$HOME/.hermes/profiles/$ONLY_PROFILE/state.db" ]]; then
      continue
    fi
    rows="$(sqlite3 -separator $'\t' "$db" \
      "SELECT conversation_id, holder, expires_at FROM session_turn_leases WHERE expires_at > $now$lease_scope;" 2>/dev/null || true)"
    [[ -n "$rows" ]] && printf '%s\t%s\n' "$db" "$rows"
  done
  return 0
}

label_for() {
  "$PLIST_BUDDY" -c 'Print :Label' "$1"
}

domain_for_label() {
  case "$1" in
    ai.hermes.gateway*|com.spencer.hermes-desktop-backend) printf '%s' "$USER_DOMAIN" ;;
    *) printf '%s' "$GUI_DOMAIN" ;;
  esac
}

restart_plist() {
  local plist="$1" label domain attempt state old_pid old_pgid
  label="$(label_for "$plist")"
  domain="$(domain_for_label "$label")"
  state="$(launchctl list "$label" 2>/dev/null || true)"
  old_pid="$(printf '%s\n' "$state" | sed -n 's/^[[:space:]]*"PID" = \([0-9][0-9]*\);/\1/p')"
  old_pgid=""
  if [[ -n "$old_pid" ]]; then
    old_pgid="$(ps -p "$old_pid" -o pgid= 2>/dev/null | tr -d ' ' || true)"
  fi
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true

  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    if [[ -n "$old_pgid" ]]; then
      kill -TERM -- "-$old_pgid" 2>/dev/null || true
    else
      kill -TERM "$old_pid" 2>/dev/null || true
    fi
  fi

  for attempt in $(seq 1 30); do
    if ! launchctl list "$label" >/dev/null 2>&1 && \
       { [[ -z "$old_pid" ]] || ! kill -0 "$old_pid" 2>/dev/null; }; then
      break
    fi
    sleep 1
  done
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    [[ -n "$old_pgid" ]] && kill -KILL -- "-$old_pgid" 2>/dev/null || kill -KILL "$old_pid" 2>/dev/null || true
  fi
  for attempt in $(seq 1 10); do
    launchctl list "$label" >/dev/null 2>&1 || break
    sleep 1
  done
  if launchctl list "$label" >/dev/null 2>&1; then
    echo "Failed to unload $label before runtime cutover" >&2
    return 1
  fi

  for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "$domain" "$plist"; then
      return 0
    fi
    sleep $((attempt * 2))
  done
  echo "Failed to bootstrap $label after 5 attempts" >&2
  return 1
}

restore_previous() {
  local plist label
  [[ "$APPLIED" == 1 ]] || return 0
  (
    set +e
    if [[ "$RESTART_COUNT" -gt 0 ]]; then
      for plist in "${restart_plists[@]}"; do
        label="$(label_for "$plist" 2>/dev/null || true)"
        [[ -n "$label" ]] && launchctl bootout "$(domain_for_label "$label")/$label" >/dev/null 2>&1 || true
      done
    fi
    for plist in "${plists[@]}"; do
      cp -p "$BACKUP_ROOT/$(basename "$plist")" "$plist"
    done
    if [[ -n "$OLD_LINK" ]]; then
      ln -sfn "$OLD_LINK" "$HOME/.local/bin/hermes"
    fi
    if [[ "$RESTART_COUNT" -gt 0 ]]; then
      for plist in "${restart_plists[@]}"; do
        restart_plist "$plist" >/dev/null 2>&1 || true
      done
    fi
    echo "Hermes v0.21 runtime cutover failed; prior launchd definitions were restored." >&2
  )
}
trap restore_previous ERR

VERSION="$($NEW_RUNTIME/bin/python -c 'import importlib.metadata as m; print(m.version("hermes-agent"))')"
if [[ "$VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "Expected Hermes $EXPECTED_VERSION at $NEW_RUNTIME, found $VERSION" >&2
  exit 1
fi
[[ -x "$NEW_RUNTIME/bin/hermes" ]]
[[ -d "$NEW_WORKTREE" ]]

for check in 1 2; do
  ACTIVE="$(active_turns)"
  if [[ -n "$ACTIVE" ]]; then
    printf 'Hermes v0.21 runtime cutover deferred; active turn:\n%s\n' "$ACTIVE"
    exit 75
  fi
  [[ "$check" == 1 ]] && sleep 5
done

mkdir -p "$BACKUP_ROOT" "$HOME/.local/bin"
for plist in "${plists[@]}"; do
  cp -p "$plist" "$BACKUP_ROOT/$(basename "$plist")"
done
APPLIED=1

replace_value() {
  local value="$1"
  value="${value//$HOME\/.hermes\/runtimes\/hermes-v2026.8.27-8f0fb6c72b6e/$NEW_RUNTIME}"
  value="${value//$HOME\/.hermes\/hermes-agent\/venv/$NEW_RUNTIME}"
  value="${value//$HOME\/.hermes\/worktrees\/hermes-real-profile-v0206/$NEW_WORKTREE}"
  printf '%s' "$value"
}

for plist in "${plists[@]}"; do
  for index in $(seq 0 24); do
    value="$($PLIST_BUDDY -c "Print :ProgramArguments:$index" "$plist" 2>/dev/null || true)"
    [[ -n "$value" ]] || continue
    replaced="$(replace_value "$value")"
    [[ "$replaced" == "$value" ]] || "$PLIST_BUDDY" -c "Set :ProgramArguments:$index $replaced" "$plist"
  done
  for key in VIRTUAL_ENV PATH; do
    value="$($PLIST_BUDDY -c "Print :EnvironmentVariables:$key" "$plist" 2>/dev/null || true)"
    [[ -n "$value" ]] || continue
    replaced="$(replace_value "$value")"
    [[ "$replaced" == "$value" ]] || "$PLIST_BUDDY" -c "Set :EnvironmentVariables:$key $replaced" "$plist"
  done
  value="$($PLIST_BUDDY -c 'Print :WorkingDirectory' "$plist" 2>/dev/null || true)"
  if [[ -n "$value" ]]; then
    replaced="$(replace_value "$value")"
    [[ "$replaced" == "$value" ]] || "$PLIST_BUDDY" -c "Set :WorkingDirectory $replaced" "$plist"
  fi
  plutil -lint "$plist" >/dev/null
done

ln -sfn "$NEW_RUNTIME/bin/hermes" "$HOME/.local/bin/hermes"

if [[ "$RESTART_COUNT" -gt 0 ]]; then
  for plist in "${restart_plists[@]}"; do
    restart_plist "$plist"
  done
fi

health=""
for attempt in $(seq 1 18); do
  if health="$(/usr/bin/curl -fsS --max-time 5 http://127.0.0.1:9119/api/health 2>/dev/null)"; then
    break
  fi
  sleep 5
done
printf '%s' "$health" | /usr/bin/grep -q "\"version\":\"$EXPECTED_VERSION\""

# A listening socket is not sufficient for Desktop: the client depends on
# status, and large profile stores can expose a backend that accepts HTTP but
# never completes its session inventory. Keep rollback armed until status is
# both responsive and stamped with the candidate version.
status="$(/usr/bin/curl -fsS --max-time 30 http://127.0.0.1:9119/api/status)"
printf '%s' "$status" | /usr/bin/grep -q "\"version\":\"$EXPECTED_VERSION\""

if [[ "$RESTART_COUNT" -gt 0 ]]; then
  for plist in "${restart_plists[@]}"; do
    label="$(label_for "$plist")"
    pid="$(launchctl list | awk -v label="$label" '$3 == label && $1 ~ /^[0-9]+$/ { print $1 }')"
    if [[ -z "$pid" ]]; then
      echo "$label did not start" >&2
      false
    fi
    configured="$($PLIST_BUDDY -c 'Print :ProgramArguments:0' "$plist")"
    if [[ "$configured" != "$NEW_RUNTIME"/* ]]; then
      echo "$label is not configured for $NEW_RUNTIME: $configured" >&2
      false
    fi
    printf '%s\t%s\n' "$label" "$pid"
  done
fi

APPLIED=0
trap - ERR
printf 'Hermes runtime cutover complete: %s (%s)\n' "$NEW_RUNTIME" "$VERSION"
printf 'Backup: %s\n' "$BACKUP_ROOT"
