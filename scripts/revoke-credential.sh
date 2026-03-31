#!/usr/bin/env bash
# revoke-credential.sh — Mark old credential as revoked and optionally delete GitHub secrets
# Usage: revoke-credential.sh '<dispatch_input_json>'
# Reads data/rotations/in-progress.json for context, logs revocation to rotation-log.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

DISPATCH_INPUT="${1:-{}}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

IN_PROGRESS="$PROJECT_ROOT/data/rotations/in-progress.json"

if [ ! -f "$IN_PROGRESS" ]; then
  echo "ERROR: data/rotations/in-progress.json not found — nothing to revoke"
  exit 1
fi

SECRET_ID=$(python3 -c "import json; d=json.load(open('$IN_PROGRESS')); print(d.get('secret_id','unknown'))")
SECRET_TYPE=$(python3 -c "import json; d=json.load(open('$IN_PROGRESS')); print(d.get('secret_type','unknown'))")
REPO=$(python3 -c "import json; d=json.load(open('$IN_PROGRESS')); print(d.get('repo',''))")
OLD_SECRET_NAME=$(python3 -c "import json; d=json.load(open('$IN_PROGRESS')); print(d.get('old_secret_name',''))" 2>/dev/null || echo "")

echo "Revoking old credential: $SECRET_ID (type: $SECRET_TYPE)"

# For GitHub Actions secrets, we don't delete the old secret (it was already overwritten)
# Just log the revocation
REVOCATION_STATUS="revoked"
REVOCATION_NOTE="Credential overwritten via rotation. Old value no longer active."

if [ -n "$OLD_SECRET_NAME" ] && [ -n "$REPO" ] && [ "$OLD_SECRET_NAME" != "" ]; then
  echo "Attempting to delete old GitHub Actions secret: $OLD_SECRET_NAME in $REPO"
  gh secret delete "$OLD_SECRET_NAME" -R "$REPO" 2>/dev/null \
    && echo "Deleted old secret: $OLD_SECRET_NAME" \
    || echo "Could not delete old secret (may not exist or insufficient permissions)"
fi

# Append revocation log entry
python3 - <<PYEOF
import json, os
from datetime import datetime

log_file = '$PROJECT_ROOT/data/rotations/rotation-log.json'

try:
    with open(log_file) as f:
        log = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    log = []

log.append({
    'timestamp': '$TIMESTAMP',
    'secret_id': '$SECRET_ID',
    'action': 'revoke',
    'secret_type': '$SECRET_TYPE',
    'repo': '$REPO',
    'operator': 'ao-agent',
    'status': '$REVOCATION_STATUS',
    'note': '$REVOCATION_NOTE'
})

with open(log_file, 'w') as f:
    json.dump(log, f, indent=2)

print(f'Revocation logged to {log_file}')
PYEOF

echo "Revocation complete for: $SECRET_ID"
