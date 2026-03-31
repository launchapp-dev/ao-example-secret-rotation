#!/usr/bin/env bash
# generate-credential.sh — Generate a new credential based on secret type
# Usage: generate-credential.sh '<dispatch_input_json>'
# Reads the secret type from dispatch_input and generates an appropriate new credential.
# Writes metadata (not the secret value) to data/rotations/in-progress.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

mkdir -p "$PROJECT_ROOT/data/rotations"

DISPATCH_INPUT="${1:-{}}"

# Parse dispatch input
SECRET_ID=$(echo "$DISPATCH_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('secret_id','unknown'))" 2>/dev/null || echo "unknown")
SECRET_TYPE=$(echo "$DISPATCH_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('secret_type','api-key'))" 2>/dev/null || echo "api-key")
REPO=$(echo "$DISPATCH_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('repo',''))" 2>/dev/null || echo "")
SECRET_NAME=$(echo "$DISPATCH_INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('secret_name',''))" 2>/dev/null || echo "")

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "Generating credential for: $SECRET_ID (type: $SECRET_TYPE)"

case "$SECRET_TYPE" in
  api-key|jwt-secret)
    NEW_KEY=$(openssl rand -hex 32)
    KEY_ID="key-$(openssl rand -hex 4)"
    echo "Generated: $SECRET_TYPE token ($KEY_ID)"

    # Set in GitHub Actions if repo and secret name provided
    if [ -n "$REPO" ] && [ -n "$SECRET_NAME" ]; then
      echo "$NEW_KEY" | gh secret set "$SECRET_NAME" -R "$REPO" 2>/dev/null \
        && echo "Set GitHub Actions secret: $SECRET_NAME in $REPO" \
        || echo "WARNING: Could not set GitHub Actions secret (check GITHUB_TOKEN and permissions)"
    fi

    python3 -c "
import json
data = {
    'secret_id': '$SECRET_ID',
    'secret_type': '$SECRET_TYPE',
    'key_id': '$KEY_ID',
    'repo': '$REPO',
    'secret_name': '$SECRET_NAME',
    'generated_at': '$TIMESTAMP',
    'rotation_method': 'openssl-token',
    'status': 'generated',
    'services_updated': []
}
import sys
json.dump(data, sys.stdout, indent=2)
" > "$PROJECT_ROOT/data/rotations/in-progress.json"
    ;;

  ssh-key)
    KEY_FILE="$TEMP_DIR/id_ed25519"
    ssh-keygen -t ed25519 -N "" -f "$KEY_FILE" -C "ao-rotation-$TIMESTAMP" 2>/dev/null
    KEY_FINGERPRINT=$(ssh-keygen -lf "${KEY_FILE}.pub" | awk '{print $2}')
    echo "Generated: SSH ed25519 key ($KEY_FINGERPRINT)"

    python3 -c "
import json
data = {
    'secret_id': '$SECRET_ID',
    'secret_type': 'ssh-key',
    'key_fingerprint': '$KEY_FINGERPRINT',
    'repo': '$REPO',
    'generated_at': '$TIMESTAMP',
    'rotation_method': 'ssh-keygen',
    'key_type': 'ed25519',
    'status': 'generated',
    'services_updated': [],
    'note': 'Public key must be deployed to target servers manually or via config management'
}
import sys
json.dump(data, sys.stdout, indent=2)
" > "$PROJECT_ROOT/data/rotations/in-progress.json"
    ;;

  tls-cert)
    CERT_FILE="$TEMP_DIR/self-signed.crt"
    KEY_FILE_TLS="$TEMP_DIR/self-signed.key"
    openssl req -x509 -newkey rsa:4096 -keyout "$KEY_FILE_TLS" -out "$CERT_FILE" \
      -days 365 -nodes -subj "/CN=ao-rotation/O=MyOrg" 2>/dev/null
    CERT_FINGERPRINT=$(openssl x509 -in "$CERT_FILE" -fingerprint -sha256 -noout | cut -d= -f2)
    echo "Generated: TLS certificate ($CERT_FINGERPRINT)"

    python3 -c "
import json
data = {
    'secret_id': '$SECRET_ID',
    'secret_type': 'tls-cert',
    'cert_fingerprint': '$CERT_FINGERPRINT',
    'repo': '$REPO',
    'generated_at': '$TIMESTAMP',
    'rotation_method': 'openssl-cert',
    'valid_days': 365,
    'status': 'generated',
    'services_updated': [],
    'note': 'Self-signed cert generated. For production, replace with CA-signed cert.'
}
import sys
json.dump(data, sys.stdout, indent=2)
" > "$PROJECT_ROOT/data/rotations/in-progress.json"
    ;;

  aws-access-key)
    echo "AWS access key rotation requires AWS CLI and appropriate IAM permissions."
    echo "Generating placeholder — update manually or configure aws-cli."
    KEY_ID="PLACEHOLDER-$(openssl rand -hex 4 | tr '[:lower:]' '[:upper:]')"

    python3 -c "
import json
data = {
    'secret_id': '$SECRET_ID',
    'secret_type': 'aws-access-key',
    'key_id': '$KEY_ID',
    'repo': '$REPO',
    'secret_name': '$SECRET_NAME',
    'generated_at': '$TIMESTAMP',
    'rotation_method': 'gh-secret',
    'status': 'needs-aws-cli',
    'services_updated': [],
    'note': 'Use aws iam create-access-key to generate, then set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY via gh secret set'
}
import sys
json.dump(data, sys.stdout, indent=2)
" > "$PROJECT_ROOT/data/rotations/in-progress.json"
    ;;

  *)
    echo "Unknown secret type: $SECRET_TYPE — marking for manual rotation"
    python3 -c "
import json
data = {
    'secret_id': '$SECRET_ID',
    'secret_type': '$SECRET_TYPE',
    'generated_at': '$TIMESTAMP',
    'rotation_method': 'manual',
    'status': 'manual-required',
    'services_updated': [],
    'note': 'No automated rotation available for this type'
}
import sys
json.dump(data, sys.stdout, indent=2)
" > "$PROJECT_ROOT/data/rotations/in-progress.json"
    ;;
esac

echo "Credential metadata written to data/rotations/in-progress.json"
cat "$PROJECT_ROOT/data/rotations/in-progress.json"
