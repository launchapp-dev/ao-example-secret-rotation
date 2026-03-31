# Secret Rotation Pipeline

Automated secret lifecycle management — audit repositories for exposed credentials, track expiration dates, rotate secrets via CLI tools, verify service health post-rotation, and produce compliance audit trails.

## Workflow Diagram

```
DAILY (06:00 UTC)
─────────────────
scan-secrets (command)
    │
    ▼
analyze-findings (secret-auditor)
    │
    ├─ all-clear ──────────────────────────────────┐
    │                                              │
    └─ action-needed                               │
          │                                        │
          ▼                                        │
    plan-rotations (rotation-planner)              │
    [creates GitHub issues for immediate]          │
          │                                        │
          ▼                                        ▼
    generate-alerts (compliance-reporter) ─────────┘
    [reports/daily-alert.md]


ON-DEMAND (ao queue enqueue --workflow-ref rotate-secret)
──────────────────────────────────────────────────────────
generate-credential (command: openssl / ssh-keygen / gh)
    │
    ▼
update-configurations (credential-rotator)
    │                   ▲
    ├─ updated          │ failed (max 2 rework attempts)
    │   │               │
    │   ▼               │
    │  run-health-checks (command: curl + gh run list)
    │   │
    │   ▼
    │  verify-health (health-verifier)
    │   │
    │   ├─ verified / degraded
    │   │       │
    │   │       ▼
    │   │  revoke-old-credential (command)
    │   │       │
    │   │       ▼
    │   │  update-inventory (secret-auditor)
    │   │
    │   └─ failed ──────────────────────────┘ (rework → update-configurations)


WEEKLY (Mon 08:00 UTC)
───────────────────────
collect-pending (command: python3 filter)
    │
    ▼
execute-batch (rotation-planner)
[queues individual rotate-secret workflows]
    │
    ▼
batch-summary (compliance-reporter)
[reports/weekly-rotation-summary.md]


MONTHLY (1st 09:00 UTC)
────────────────────────
full-scan (command: deep scan + gh secret list)
    │
    ▼
compliance-report (compliance-reporter)
[reports/monthly-compliance-audit.md]
    │
    ▼
risk-assessment (rotation-planner)
[reports/risk-assessment.md + proposed policy changes]
    │
    ▼
approve-policy-changes ← MANUAL GATE (human reviews proposed policy updates)
```

## Quick Start

```bash
cd examples/secret-rotation

# Configure your repositories
edit config/repos.yaml       # Add your GitHub repos to scan
edit config/health-checks.yaml  # Add your service health endpoints

# Required environment variables
export GITHUB_TOKEN=<your-github-pat>

# Start the daemon (runs all scheduled workflows automatically)
ao daemon start

# Watch logs
ao daemon stream --pretty

# Manually trigger a secret audit now
ao workflow run secret-audit

# Queue a specific credential for rotation
ao queue enqueue \
  --title "jwt-secret-e5f6g7h8" \
  --description "Rotate JWT secret for api-service" \
  --workflow-ref rotate-secret \
  --input '{"secret_id":"jwt-secret-e5f6g7h8","secret_type":"jwt-secret","repo":"myorg/api-service","secret_name":"JWT_SECRET"}'
```

## Agents

| Agent | Model | Role |
|---|---|---|
| **secret-auditor** | claude-sonnet-4-6 | Scans for exposed secrets, classifies findings, maintains inventory |
| **rotation-planner** | claude-sonnet-4-6 | Assigns rotation urgency, generates plans, queues weekly batches |
| **credential-rotator** | claude-haiku-4-5 | Updates service configs and GitHub Actions secrets post-rotation |
| **health-verifier** | claude-haiku-4-5 | Verifies services are healthy after rotation via HTTP + GitHub Actions |
| **compliance-reporter** | claude-sonnet-4-6 | Produces daily alerts, weekly summaries, monthly audit reports |

## AO Features Demonstrated

- **Scheduled workflows** — Daily audit at 06:00, weekly batch on Mondays, monthly audit on the 1st
- **Decision routing** — `analyze-findings` routes to `plan-rotations` or directly to `generate-alerts` based on verdict
- **Rework loops** — Failed health verification reroutes back to `update-configurations` (max 2 attempts)
- **Manual gate** — Monthly audit requires human approval before applying policy changes
- **Command phases** — Real CLI tools: `openssl`, `ssh-keygen`, `gh`, `curl`, `python3`, `jq`
- **Multi-agent pipeline** — 5 specialized agents with distinct security roles
- **Multi-model routing** — Sonnet for reasoning, Haiku for fast execution tasks
- **GitHub integration** — Secret management, issue creation, workflow health checks

## Directory Structure

```
secret-rotation/
├── .ao/workflows/
│   ├── agents.yaml           # 5 agent profiles
│   ├── phases.yaml           # 13 phases across 4 workflows
│   ├── workflows.yaml        # 4 workflow pipelines
│   ├── mcp-servers.yaml      # filesystem, github, sequential-thinking
│   └── schedules.yaml        # daily, weekly, monthly schedules
├── config/
│   ├── repos.yaml            # Repositories to scan
│   ├── rotation-policy.yaml  # Max age and auto-rotate settings per type
│   ├── secret-patterns.yaml  # Regex patterns for secret detection
│   └── health-checks.yaml    # Service health endpoints
├── scripts/
│   ├── scan-secrets.sh       # Git history + GitHub Actions secret enumeration
│   ├── generate-credential.sh # New credential generation (openssl/ssh-keygen/gh)
│   ├── check-health.sh       # HTTP and GitHub Actions health verification
│   └── revoke-credential.sh  # Old credential revocation + audit log
├── data/
│   ├── inventory/            # secret-inventory.json (current state)
│   ├── scan-results/         # Raw scan output per run
│   ├── rotations/            # pending.json, in-progress.json, history.json, log
│   ├── audit/                # Monthly deep scan data
│   └── metrics/              # compliance-trends.json (historical metrics)
├── reports/                  # Generated daily alerts, weekly summaries, audits
└── templates/                # Report templates
```

## Requirements

| Requirement | Details |
|---|---|
| `GITHUB_TOKEN` | GitHub PAT with `repo`, `secrets`, `actions:read` scopes |
| `openssl` | For generating API keys, JWT secrets, TLS certs |
| `ssh-keygen` | For SSH key rotation |
| `gh` CLI | For GitHub secrets management and Actions status |
| `curl` | For service health checks |
| `python3` | For JSON/YAML processing in scripts |
| `jq` | For JSON processing in scripts |

## Supported Secret Types

| Type | Auto-Rotate | Max Age | Method |
|---|---|---|---|
| api-key | Yes | 90 days | `openssl rand -hex 32` |
| jwt-secret | Yes | 30 days | `openssl rand -hex 32` |
| ssh-key | Yes | 365 days | `ssh-keygen -t ed25519` |
| aws-access-key | Yes | 90 days | AWS CLI + `gh secret set` |
| database-url | No (manual) | 180 days | Requires coordinated rollout |
| tls-cert | No (manual) | 365 days | cert-manager handles |
| oauth-client-secret | No (manual) | 180 days | Provider coordination required |
