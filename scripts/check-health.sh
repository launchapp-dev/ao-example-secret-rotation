#!/usr/bin/env bash
# check-health.sh — Verify service health after credential rotation
# Reads config/health-checks.yaml and tests each endpoint
# Outputs results to stdout (captured by AO phase to data/rotations/health-check-output.txt)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

HEALTH_CHECKS_YAML="$PROJECT_ROOT/config/health-checks.yaml"

echo "=== Health Check — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo ""

OVERALL_STATUS="healthy"

# Parse health checks config
python3 - <<'PYEOF'
import yaml, subprocess, sys

with open('config/health-checks.yaml') as f:
    config = yaml.safe_load(f)

checks = config.get('health_checks', {})
results = []

for name, check in checks.items():
    method = check.get('method', 'http')
    criticality = check.get('criticality', 'medium')

    if method == 'gh-workflow':
        repo = check.get('repo', '')
        n = check.get('check_last_n_runs', 3)
        print(f"Checking GitHub Actions: {repo} (last {n} runs)")
        try:
            result = subprocess.run(
                ['gh', 'run', 'list', '-R', repo, '--status', 'completed', '-L', str(n),
                 '--json', 'conclusion,startedAt,displayTitle'],
                capture_output=True, text=True, timeout=30
            )
            runs = __import__('json').loads(result.stdout or '[]')
            failed = [r for r in runs if r.get('conclusion') not in ('success', 'skipped')]
            if failed:
                print(f"  DEGRADED: {len(failed)}/{len(runs)} recent runs failed")
                results.append({'check': name, 'status': 'degraded', 'criticality': criticality,
                                'detail': f'{len(failed)} failed runs'})
            else:
                print(f"  HEALTHY: {len(runs)} recent runs all passed")
                results.append({'check': name, 'status': 'healthy', 'criticality': criticality,
                                'detail': f'{len(runs)} runs passing'})
        except Exception as e:
            print(f"  WARNING: Could not check GitHub Actions for {repo}: {e}")
            results.append({'check': name, 'status': 'unknown', 'criticality': criticality,
                            'detail': str(e)})

    else:
        url = check.get('url', '')
        timeout = check.get('timeout_seconds', 10)
        expected = check.get('expected_status', 200)
        print(f"Checking HTTP: {url}")
        try:
            result = subprocess.run(
                ['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', '--max-time', str(timeout), url],
                capture_output=True, text=True, timeout=timeout + 5
            )
            status_code = int(result.stdout.strip() or '0')
            if status_code == expected:
                print(f"  HEALTHY: HTTP {status_code}")
                results.append({'check': name, 'status': 'healthy', 'criticality': criticality,
                                'detail': f'HTTP {status_code}'})
            else:
                print(f"  DEGRADED: HTTP {status_code} (expected {expected})")
                results.append({'check': name, 'status': 'degraded', 'criticality': criticality,
                                'detail': f'HTTP {status_code} (expected {expected})'})
        except Exception as e:
            print(f"  FAILED: {e}")
            results.append({'check': name, 'status': 'failed', 'criticality': criticality,
                            'detail': str(e)})

print("")
print("=== Health Check Summary ===")
healthy = [r for r in results if r['status'] == 'healthy']
degraded = [r for r in results if r['status'] == 'degraded']
failed = [r for r in results if r['status'] == 'failed']
unknown = [r for r in results if r['status'] == 'unknown']
print(f"Healthy: {len(healthy)}, Degraded: {len(degraded)}, Failed: {len(failed)}, Unknown: {len(unknown)}")

critical_failures = [r for r in failed if r['criticality'] == 'critical']
if critical_failures:
    print(f"CRITICAL FAILURE: {[r['check'] for r in critical_failures]}")
    sys.exit(2)
elif failed or degraded:
    print(f"DEGRADED: Some checks failed")
    sys.exit(1)
else:
    print("ALL CHECKS PASSED")
    sys.exit(0)
PYEOF

EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
  echo ""
  echo "OVERALL_STATUS=healthy"
elif [ $EXIT_CODE -eq 2 ]; then
  echo ""
  echo "OVERALL_STATUS=critical_failure"
else
  echo ""
  echo "OVERALL_STATUS=degraded"
fi
exit 0  # Always exit 0 — let the agent phase interpret the output
