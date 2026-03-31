# Secret Rotation Pipeline — Agent Context

This is an automated secret lifecycle management system. It scans repositories for exposed credentials, tracks expiration, rotates secrets via CLI tools, verifies service health, and produces compliance reports.

## Architecture

**4 workflows, 5 agents, 13 phases:**

1. `secret-audit` (daily) — Scan → classify → plan rotations → alert
2. `rotate-secret` (on-demand) — Generate → update configs → verify health → revoke old → inventory update
3. `weekly-rotation-batch` (weekly) — Collect due rotations → queue individual rotate-secret workflows
4. `monthly-compliance-audit` (monthly) — Deep scan → compliance report → risk assessment → human gate

## Critical Files

- `config/repos.yaml` — Repositories to scan; update to add/remove repos
- `config/rotation-policy.yaml` — Max age per secret type; governs urgency classification
- `config/secret-patterns.yaml` — Regex patterns for secret detection in scan phase
- `config/health-checks.yaml` — Service endpoints to verify post-rotation
- `data/inventory/secret-inventory.json` — Master secret inventory; always write atomically
- `data/rotations/in-progress.json` — Current rotation context; read by update-configurations and health-verifier
- `data/rotations/rotation-log.json` — Append-only audit log of every rotation action
- `data/rotations/history.json` — Append-only completed rotation history

## Agent Rules

- **secret-auditor**: Never overwrite inventory without reading it first. Merge updates, don't replace.
- **rotation-planner**: Always order rotations least-critical first. Confirm auto_rotate: true before queuing.
- **credential-rotator**: Never log raw secret values — only key IDs, names, and metadata.
- **health-verifier**: Distinguish transient (retry) from config errors (rework). Be specific about which service failed.
- **compliance-reporter**: Compliance rate = rotated_on_time / total_due * 100. Flag violations prominently.

## Secret Inventory Schema

```json
{
  "id": "<type>-<sha8>",
  "type": "api-key | database-url | jwt-secret | ssh-key | tls-cert | aws-access-key | oauth-client-secret",
  "status": "exposed | valid | expiring | expired | rotated",
  "location": "github-actions:<repo> | file:<path>",
  "repo": "org/repo",
  "secret_name": "GITHUB_ACTIONS_SECRET_NAME",
  "owner": "team-name",
  "created_at": "ISO8601",
  "expires_at": "ISO8601",
  "last_rotated": "ISO8601 or null",
  "finding_severity": "critical | high | medium | low",
  "rotation_method": "openssl-token | openssl-cert | ssh-keygen | gh-secret | manual"
}
```

## Rotation Decision Contract

The `analyze-findings` phase emits:
```json
{ "verdict": "all-clear" | "action-needed", "exposed_count": N, "expiring_count": N, "expired_count": N }
```

The `verify-health` phase emits:
```json
{ "verdict": "verified" | "degraded" | "failed", "healthy_services": [...], "failed_services": [...], "details": "..." }
```

## Environment Variables Required

- `GITHUB_TOKEN` — PAT with repo, secrets, actions:read scopes

## Tools Used

Scripts in `scripts/` use: `openssl`, `ssh-keygen`, `gh`, `curl`, `python3`, `jq`
These must be installed and on PATH when ao daemon runs.
