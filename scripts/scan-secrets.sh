#!/usr/bin/env bash
# scan-secrets.sh — Scan configured repositories for exposed secrets
# Reads config/repos.yaml and config/secret-patterns.yaml
# Outputs findings to data/scan-results/latest.txt and data/scan-results/<timestamp>.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

mkdir -p "$PROJECT_ROOT/data/scan-results"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_FILE="$PROJECT_ROOT/data/scan-results/${TIMESTAMP}.txt"
LATEST_FILE="$PROJECT_ROOT/data/scan-results/latest.txt"

echo "=== Secret Scan — $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | tee "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# Read repos from config
REPOS_YAML="$PROJECT_ROOT/config/repos.yaml"
if [ ! -f "$REPOS_YAML" ]; then
  echo "ERROR: config/repos.yaml not found" | tee -a "$OUTPUT_FILE"
  exit 1
fi

# Parse repos using python3 (available on all modern systems)
REPOS=$(python3 -c "
import yaml, sys
with open('$REPOS_YAML') as f:
    data = yaml.safe_load(f)
for r in data.get('repositories', []):
    print(r['repo'])
" 2>/dev/null || echo "")

if [ -z "$REPOS" ]; then
  echo "WARNING: No repositories configured in config/repos.yaml" | tee -a "$OUTPUT_FILE"
fi

# Patterns from config/secret-patterns.yaml
PATTERNS_YAML="$PROJECT_ROOT/config/secret-patterns.yaml"
PATTERNS=$(python3 -c "
import yaml
with open('$PATTERNS_YAML') as f:
    data = yaml.safe_load(f)
for p in data.get('patterns', []):
    print(p['name'] + '|' + p['regex'] + '|' + p['severity'] + '|' + p['type'])
" 2>/dev/null || echo "")

echo "--- Scanning local repository ---" | tee -a "$OUTPUT_FILE"

# Scan local files (if this is a checked-out repo)
if [ -d "$PROJECT_ROOT/.git" ]; then
  echo "Git history scan (last 50 commits):" | tee -a "$OUTPUT_FILE"
  git -C "$PROJECT_ROOT" log --all --diff-filter=A --name-only --pretty=format:"[commit %H]" -50 2>/dev/null \
    | tee -a "$OUTPUT_FILE" || echo "Git scan skipped (no history)" | tee -a "$OUTPUT_FILE"
fi

# GitHub Actions secrets enumeration
echo "" | tee -a "$OUTPUT_FILE"
echo "--- GitHub Actions Secrets ---" | tee -a "$OUTPUT_FILE"
for REPO in $REPOS; do
  echo "Repo: $REPO" | tee -a "$OUTPUT_FILE"
  gh secret list -R "$REPO" --json name,updatedAt 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for s in data:
    print(f\"  secret: {s['name']} | last_updated: {s.get('updatedAt','unknown')}\")
" 2>/dev/null | tee -a "$OUTPUT_FILE" \
    || echo "  (could not enumerate secrets for $REPO — check GITHUB_TOKEN)" | tee -a "$OUTPUT_FILE"
done

echo "" | tee -a "$OUTPUT_FILE"
echo "=== Scan complete ===" | tee -a "$OUTPUT_FILE"

# Copy to latest
cp "$OUTPUT_FILE" "$LATEST_FILE"
echo "Results written to: $OUTPUT_FILE"
echo "Latest symlink: $LATEST_FILE"
