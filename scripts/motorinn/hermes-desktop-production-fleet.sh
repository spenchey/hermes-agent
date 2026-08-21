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
  ssh -o BatchMode=yes "spencerheywood@$host" 'mkdir -p /Users/spencerheywood/.local/bin'
  scp -q "$ENSURE" "spencerheywood@$host:$REMOTE_PATH"
  ssh -o BatchMode=yes "spencerheywood@$host" "chmod 755 '$REMOTE_PATH' && '$REMOTE_PATH' --install-guard && '$REMOTE_PATH'"
done

printf 'Hermes production artifact verified on Studio and both MacBooks.\n'
