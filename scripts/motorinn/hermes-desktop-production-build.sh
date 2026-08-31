#!/bin/bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
BRANCH="${HERMES_PRODUCTION_BRANCH:-codex/hermes-v0.21.0-production}"
ARTIFACT_ROOT="${HERMES_PRODUCTION_ARTIFACT_ROOT:-$HOME/.hermes/production-artifacts/desktop}"
SYNC_UPSTREAM=0
DEPLOY=1

for arg in "$@"; do
  case "$arg" in
    --sync-upstream) SYNC_UPSTREAM=1 ;;
    --no-sync) SYNC_UPSTREAM=0 ;;
    --no-deploy) DEPLOY=0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

cd "$ROOT"

if [[ "$(git branch --show-current)" != "$BRANCH" ]]; then
  echo "Run this from $BRANCH, not $(git branch --show-current)." >&2
  exit 1
fi

DIRTY="$(git status --porcelain | grep -Ev '^[ MADRCU?!]{2} contributors/emails/agent@[Aa]gents-Mac-mini\.local$' || true)"
if [[ -n "$DIRTY" ]]; then
  echo "Production worktree is dirty; refusing to build an ambiguous artifact." >&2
  printf '%s\n' "$DIRTY" >&2
  exit 1
fi

BUILD_COMMIT="$(git rev-parse HEAD)"

if [[ "$SYNC_UPSTREAM" == 1 ]]; then
  git fetch --no-tags upstream main
  git rebase upstream/main
fi

if git ls-remote --exit-code production refs/heads/main >/dev/null 2>&1; then
  git fetch --no-tags production main
fi

LOCK_HASH="$(shasum -a 256 package-lock.json | awk '{print $1}')"
LOCK_MARKER="node_modules/.motorinn-production-lock-sha"

if [[ ! -d node_modules || ! -f "$LOCK_MARKER" || "$(cat "$LOCK_MARKER" 2>/dev/null || true)" != "$LOCK_HASH" ]]; then
  npm ci
  printf '%s\n' "$LOCK_HASH" > "$LOCK_MARKER"
fi

npm --prefix apps/desktop run check
GITHUB_SHA="$BUILD_COMMIT" GITHUB_REF_NAME="$BRANCH" npm --prefix apps/desktop run pack

COMMIT="$BUILD_COMMIT"
SHORT="$(git rev-parse --short=12 HEAD)"
VERSION="$(node -p "require('./apps/desktop/package.json').version")"
BUILD_ID="${VERSION}-${SHORT}"
APP="$ROOT/apps/desktop/release/mac-arm64/Hermes.app"
DEST="$ARTIFACT_ROOT/$BUILD_ID"
ARCHIVE="Hermes-${BUILD_ID}-mac-arm64.zip"

if [[ ! -d "$APP" ]]; then
  echo "Desktop build did not produce $APP" >&2
  exit 1
fi

mkdir -p "$APP/Contents/Resources" "$DEST"
python3 - "$APP/Contents/Resources/production-build.json" "$COMMIT" "$BRANCH" "$VERSION" <<'PY'
import datetime, json, pathlib, sys
path, commit, branch, version = sys.argv[1:]
payload = {
    "schemaVersion": 1,
    "commit": commit,
    "branch": branch,
    "version": version,
    "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "contract": {
        "surface": "desktop-bot-mode-group-rooms",
        "foregroundTimeoutSeconds": 180,
        "latePollLadder": [
            {"untilAgeSeconds": 3600, "intervalSeconds": 300},
            {"untilAgeSeconds": 14400, "intervalSeconds": 900},
            {"untilAgeSeconds": 43200, "intervalSeconds": 1800},
            {"untilAgeSeconds": 86400, "intervalSeconds": 3600},
        ],
        "lateTtlSeconds": 86400,
    },
}
pathlib.Path(path).write_text(json.dumps(payload, indent=2) + "\n")
PY

codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

ASAR_REL="Contents/Resources/app.asar"
RENDERER_REL="$(python3 - "$APP" <<'PY'
from pathlib import Path
import sys
app = Path(sys.argv[1])
files = list((app / "Contents/Resources/app.asar.unpacked/dist/assets").glob("index-*.js"))
if not files:
    raise SystemExit("No renderer index bundle found")
print(max(files, key=lambda path: path.stat().st_size).relative_to(app))
PY
)"
ASAR_SHA="$(shasum -a 256 "$APP/$ASAR_REL" | awk '{print $1}')"
RENDERER_SHA="$(shasum -a 256 "$APP/$RENDERER_REL" | awk '{print $1}')"

rm -f "$DEST/$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DEST/$ARCHIVE"
ARCHIVE_SHA="$(shasum -a 256 "$DEST/$ARCHIVE" | awk '{print $1}')"

python3 - "$DEST/manifest.json" "$COMMIT" "$BRANCH" "$VERSION" "$BUILD_ID" "$ARCHIVE" "$ARCHIVE_SHA" "$ASAR_REL" "$ASAR_SHA" "$RENDERER_REL" "$RENDERER_SHA" <<'PY'
import datetime, json, pathlib, sys
(path, commit, branch, version, build_id, archive, archive_sha,
 asar_rel, asar_sha, renderer_rel, renderer_sha) = sys.argv[1:]
payload = {
    "schemaVersion": 1,
    "commit": commit,
    "branch": branch,
    "version": version,
    "buildId": build_id,
    "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "artifactDir": build_id,
    "archive": archive,
    "archiveSha256": archive_sha,
    "appAsarPath": asar_rel,
    "appAsarSha256": asar_sha,
    "rendererPath": renderer_rel,
    "rendererSha256": renderer_sha,
    "contract": {
        "surface": "desktop-bot-mode-group-rooms",
        "foregroundTimeoutSeconds": 180,
        "latePollLadder": [
            {"untilAgeSeconds": 3600, "intervalSeconds": 300},
            {"untilAgeSeconds": 14400, "intervalSeconds": 900},
            {"untilAgeSeconds": 43200, "intervalSeconds": 1800},
            {"untilAgeSeconds": 86400, "intervalSeconds": 3600},
        ],
        "lateTtlSeconds": 86400,
    },
}
pathlib.Path(path).write_text(json.dumps(payload, indent=2) + "\n")
PY

cp "$DEST/manifest.json" "$ARTIFACT_ROOT/current.json.tmp"
mv "$ARTIFACT_ROOT/current.json.tmp" "$ARTIFACT_ROOT/current.json"

git push --force-with-lease production HEAD:main

printf 'Published %s\n' "$DEST/$ARCHIVE"
printf 'Archive SHA-256: %s\n' "$ARCHIVE_SHA"

if [[ "$DEPLOY" == 1 ]]; then
  "$ROOT/scripts/motorinn/hermes-desktop-production-fleet.sh"
fi
