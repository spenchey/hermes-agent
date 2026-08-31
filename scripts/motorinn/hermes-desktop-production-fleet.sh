#!/bin/bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
ENSURE="$ROOT/scripts/motorinn/hermes-desktop-production-ensure.sh"
REMOTE_PATH="/Users/spencerheywood/.local/bin/hermes-desktop-production-ensure"
HOSTS=(
  "work-macbook.tailc83035.ts.net"
  "spencers-macbook-pro.tailc83035.ts.net"
)

mkdir -p "$HOME/.local/bin"
cp "$ENSURE" "$HOME/.local/bin/hermes-desktop-production-ensure"
chmod 755 "$HOME/.local/bin/hermes-desktop-production-ensure"
"$HOME/.local/bin/hermes-desktop-production-ensure" --install-guard
"$HOME/.local/bin/hermes-desktop-production-ensure"

for host in "${HOSTS[@]}"; do
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "spencerheywood@$host" 'mkdir -p /Users/spencerheywood/.local/bin'; then
    printf 'Deferred %s: host unavailable. Its launchd guard will install the current artifact when reachable.\n' "$host" >&2
    continue
  fi
  scp -q "$ENSURE" "spencerheywood@$host:$REMOTE_PATH"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "spencerheywood@$host" "chmod 755 '$REMOTE_PATH' && '$REMOTE_PATH' --install-guard && '$REMOTE_PATH'"
done

printf 'Hermes production artifact deployment attempted on Studio and both MacBooks; each installer reports its verified or deferred state.\n'
