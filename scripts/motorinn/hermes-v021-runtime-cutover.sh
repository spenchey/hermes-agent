#!/bin/bash
set -euo pipefail

NEW_RUNTIME="${HERMES_NEW_RUNTIME:-$HOME/.hermes/runtimes/hermes-v2026.8.31-69d5eed4a751}"
NEW_WORKTREE="${HERMES_NEW_WORKTREE:-$HOME/.hermes/worktrees/hermes-v0.21.0-production}"
EXPECTED_VERSION="${HERMES_EXPECTED_VERSION:-0.21.0}"
PLIST_DIR="$HOME/Library/LaunchAgents"
DESKTOP_PLIST="$PLIST_DIR/com.spencer.hermes-desktop-backend.plist"
BACKUP_ROOT="$HOME/.hermes/backups/hermes-runtime-cutover/$(date +%Y%m%d-%H%M%S)"
PLIST_BUDDY=/usr/libexec/PlistBuddy
DOMAIN="gui/$(id -u)"
OLD_LINK="$(readlink "$HOME/.local/bin/hermes" 2>/dev/null || true)"
APPLIED=0

plists=("$DESKTOP_PLIST")
for plist in "$PLIST_DIR"/ai.hermes.gateway*.plist; do
  [[ -f "$plist" ]] && plists+=("$plist")
done

active_turns() {
  local now db rows
  now="$(date +%s)"
  for db in "$HOME/.hermes/state.db" "$HOME"/.hermes/profiles/*/state.db; do
    [[ -f "$db" ]] || continue
    rows="$(sqlite3 -separator $'\t' "$db" \
      "SELECT conversation_id, holder, expires_at FROM session_turn_leases WHERE expires_at > $now;" 2>/dev/null || true)"
    [[ -n "$rows" ]] && printf '%s\t%s\n' "$db" "$rows"
  done
  return 0
}

label_for() {
  "$PLIST_BUDDY" -c 'Print :Label' "$1"
}

restart_plist() {
  local plist="$1" label
  label="$(label_for "$plist")"
  launchctl bootout "$DOMAIN/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "$DOMAIN" "$plist"
}

restore_previous() {
  local plist label
  [[ "$APPLIED" == 1 ]] || return 0
  set +e
  for plist in "${plists[@]}"; do
    label="$(label_for "$plist" 2>/dev/null || true)"
    [[ -n "$label" ]] && launchctl bootout "$DOMAIN/$label" >/dev/null 2>&1 || true
  done
  for plist in "${plists[@]}"; do
    cp -p "$BACKUP_ROOT/$(basename "$plist")" "$plist"
  done
  if [[ -n "$OLD_LINK" ]]; then
    ln -sfn "$OLD_LINK" "$HOME/.local/bin/hermes"
  fi
  for plist in "${plists[@]}"; do
    launchctl bootstrap "$DOMAIN" "$plist" >/dev/null 2>&1 || true
  done
  echo "Hermes v0.21 runtime cutover failed; prior launchd definitions were restored." >&2
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

for plist in "${plists[@]}"; do
  restart_plist "$plist"
done

sleep 8
health="$(curl -fsS --max-time 5 http://127.0.0.1:9119/api/health)"
printf '%s' "$health" | grep -q '"version":"0.21.0"'

for plist in "${plists[@]}"; do
  label="$(label_for "$plist")"
  pid="$(launchctl list | awk -v label="$label" '$3 == label && $1 ~ /^[0-9]+$/ { print $1 }')"
  if [[ -z "$pid" ]]; then
    echo "$label did not start" >&2
    false
  fi
  command="$(ps -p "$pid" -o command=)"
  if [[ "$command" != *"$NEW_RUNTIME"* ]]; then
    echo "$label is not using $NEW_RUNTIME: $command" >&2
    false
  fi
  printf '%s\t%s\n' "$label" "$pid"
done

APPLIED=0
trap - ERR
printf 'Hermes runtime cutover complete: %s (%s)\n' "$NEW_RUNTIME" "$VERSION"
printf 'Backup: %s\n' "$BACKUP_ROOT"
