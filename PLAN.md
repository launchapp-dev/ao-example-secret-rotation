# Secret Rotation Pipeline — Workflow Plan

## Overview

Automated secret lifecycle management for DevOps/Security teams. Audits repositories for exposed secrets using trufflehog patterns, tracks credential expiration dates, plans rotation schedules, rotates credentials via provider CLIs (gh, openssl, aws-cli patterns), verifies service health post-rotation, revokes old credentials, and produces compliance audit trails. Built entirely on real CLI tools (`git`, `gh`, `openssl`, `jq`, `curl`) and filesystem/github MCP servers.

## Agents

| Agent | Model | Role |
|---|---|---|
| **secret-auditor** | claude-sonnet-4-6 | Scans repos for exposed secrets, classifies findings, maintains secret inventory |
| **rotation-planner** | claude-sonnet-4-6 | Decides rotation urgency, generates rotation plan with scheduling |
| **credential-rotator** | claude-haiku-4-5 | Executes rotation: generates new credentials, updates configs, sets GitHub secrets |
| **health-verifier** | claude-haiku-4-5 | Verifies services still function after credential rotation |
| **compliance-reporter** | claude-sonnet-4-6 | Produces audit logs, compliance reports, expiration forecasts |

## Phase Pipeline

### Workflow 1: `secret-audit` (daily — scheduled)

1. **scan-secrets** (command phase)
   - Runs `git log --diff-filter=A --name-only` to find recently added files
   - Runs regex-based secret pattern matching via grep for common key patterns (AWS keys, API tokens, private keys)
   - Runs `gh secret list` to enumerate GitHub Actions secrets per repo
   - Outputs raw findings to `data/scan-results/`

2. **analyze-findings** (agent: secret-auditor)
   - Reads scan results, classifies each finding: `exposed` | `valid` | `expiring` | `expired` | `rotated`
   - Cross-references against `data/inventory/secret-inventory.json` for known secrets
   - Updates inventory with new findings, expiry dates, ownership
   - Decision contract: `{ verdict: "all-clear" | "action-needed", exposed_count: N, expiring_count: N }`

3. **plan-rotations** (agent: rotation-planner)
   - Only runs if analyze-findings verdict = `action-needed`
   - For each finding, assigns urgency: `immediate` (exposed/expired) | `scheduled` (expiring <14d) | `deferred` (expiring <30d) | `exempt` (manually managed)
   - Generates rotation plan: `data/rotations/pending.json`
   - Creates GitHub issues for `immediate` findings
   - Decision contract: `{ verdict: "rotations-planned" | "escalation-needed", immediate_count: N, scheduled_count: N }`

4. **generate-alerts** (agent: compliance-reporter)
   - Reads inventory + rotation plan
   - Produces daily alert: `reports/daily-alert.md`
   - Categorizes by urgency window: immediate, 7-day, 14-day, 30-day

### Workflow 2: `rotate-secret` (on-demand, queued per credential)

1. **generate-credential** (command phase)
   - Based on secret type, generates new credential:
     - `openssl rand -hex 32` for API keys/tokens
     - `openssl req -x509 -newkey rsa:4096` for self-signed certs
     - `gh secret set <NAME>` for GitHub Actions secrets
     - `ssh-keygen -t ed25519` for SSH keys
   - Saves new credential metadata (not the secret itself) to `data/rotations/in-progress.json`

2. **update-configurations** (agent: credential-rotator)
   - Reads rotation plan for this credential
   - Updates service configuration files via filesystem MCP
   - Sets GitHub secrets via github MCP
   - Logs all changes to `data/rotations/rotation-log.json`
   - Decision contract: `{ verdict: "updated" | "failed", services_updated: [...] }`

3. **verify-health** (agent: health-verifier)
   - Runs `curl -s -o /dev/null -w "%{http_code}"` against service endpoints
   - Checks service status via configured health check URLs
   - Verifies GitHub Actions workflows still pass via `gh run list --status`
   - Decision contract: `{ verdict: "verified" | "degraded" | "failed", details: "..." }`
   - On `failed`: rework to update-configurations (max 2 attempts), then rollback

4. **revoke-old-credential** (command phase)
   - Only runs after successful verification
   - Marks old credential as revoked in inventory
   - Logs revocation in `data/rotations/rotation-log.json`

5. **update-inventory** (agent: secret-auditor)
   - Updates `data/inventory/secret-inventory.json` with new credential details
   - Records rotation in `data/rotations/history.json`
   - Closes associated GitHub issue if one exists

### Workflow 3: `weekly-rotation-batch` (weekly — scheduled)

1. **collect-pending** (command phase)
   - Reads `data/inventory/secret-inventory.json`
   - Filters secrets with `scheduled` urgency and upcoming expiry
   - Writes batch plan to `data/rotations/weekly-batch.json`

2. **execute-batch** (agent: rotation-planner)
   - Reviews batch plan, confirms rotation order (least-critical first)
   - Queues individual `rotate-secret` workflows for each credential
   - Decision contract: `{ verdict: "batch-queued" | "batch-empty", queued_count: N }`

3. **batch-summary** (agent: compliance-reporter)
   - Produces weekly rotation summary: `reports/weekly-rotation-summary.md`
   - Includes: rotated count, failed count, upcoming expirations, risk assessment

### Workflow 4: `monthly-compliance-audit` (monthly — scheduled)

1. **full-scan** (command phase)
   - Deep secret scan across all configured repositories
   - Collects complete rotation history from `data/rotations/history.json`
   - Gathers GitHub secret metadata via `gh secret list`
   - Outputs to `data/audit/monthly-scan.json`

2. **compliance-report** (agent: compliance-reporter)
   - Produces comprehensive audit: `reports/monthly-compliance-audit.md`
   - Includes: secret inventory summary, rotation compliance rates, policy violations, age analysis
   - Writes compliance metrics to `data/metrics/compliance-trends.json`
   - Cross-references against rotation policy (max age per secret type)

3. **risk-assessment** (agent: rotation-planner)
   - Reviews audit findings, identifies systemic risks
   - Recommends policy changes (e.g., shorter rotation windows for high-risk secrets)
   - Updates `config/rotation-policy.yaml` with recommended changes
   - Writes `reports/risk-assessment.md`

## MCP Servers

| Server | Purpose |
|---|---|
| `filesystem` | Read/write config, data, inventory, reports |
| `github` | Scan repos, manage GitHub secrets, create issues for exposed secrets |
| `sequential-thinking` | Complex rotation planning and risk analysis |

## Directory Structure

```
examples/secret-rotation/
├── .ao/workflows/
│   ├── agents.yaml
│   ├── phases.yaml
│   ├── workflows.yaml
│   ├── mcp-servers.yaml
│   └── schedules.yaml
├── config/
│   ├── repos.yaml               # Repositories to scan
│   ├── rotation-policy.yaml     # Max age, rotation windows per secret type
│   ├── secret-patterns.yaml     # Regex patterns for secret detection
│   └── health-checks.yaml       # Service endpoints for post-rotation verification
├── scripts/
│   ├── scan-secrets.sh          # Regex-based secret scanner
│   ├── generate-credential.sh   # Credential generation dispatcher
│   ├── check-health.sh          # Service health verification
│   └── revoke-credential.sh     # Old credential revocation
├── data/
│   ├── inventory/               # Current secret inventory
│   ├── scan-results/            # Raw scan output
│   ├── rotations/               # Rotation plans, logs, history
│   ├── audit/                   # Monthly audit data
│   └── metrics/                 # Compliance trend data
├── reports/                     # Generated reports and dashboards
├── templates/
│   ├── daily-alert.md           # Alert template
│   ├── weekly-summary.md        # Weekly rotation summary template
│   ├── monthly-audit.md         # Compliance audit template
│   └── risk-assessment.md       # Risk assessment template
├── CLAUDE.md
└── README.md
```

## Supporting Files

### config/repos.yaml (sample)
```yaml
repositories:
  - repo: myorg/api-service
    github_org: myorg
    scan_branches: [main, develop]
    secret_types: [api-key, database-url, jwt-secret]
    owner: backend-team
  - repo: myorg/web-frontend
    github_org: myorg
    scan_branches: [main]
    secret_types: [api-key, oauth-client-secret]
    owner: frontend-team
  - repo: myorg/infrastructure
    github_org: myorg
    scan_branches: [main]
    secret_types: [ssh-key, tls-cert, aws-access-key]
    owner: devops-team
```

### config/rotation-policy.yaml
```yaml
rotation_policy:
  api-key:
    max_age_days: 90
    warning_threshold_days: 14
    auto_rotate: true
  database-url:
    max_age_days: 180
    warning_threshold_days: 30
    auto_rotate: false      # requires manual verification
  jwt-secret:
    max_age_days: 30
    warning_threshold_days: 7
    auto_rotate: true
  ssh-key:
    max_age_days: 365
    warning_threshold_days: 30
    auto_rotate: true
  tls-cert:
    max_age_days: 365
    warning_threshold_days: 30
    auto_rotate: false      # handled by cert-manager
  aws-access-key:
    max_age_days: 90
    warning_threshold_days: 14
    auto_rotate: true
  oauth-client-secret:
    max_age_days: 180
    warning_threshold_days: 30
    auto_rotate: false
```

### config/secret-patterns.yaml
```yaml
patterns:
  - name: aws-access-key
    regex: "AKIA[0-9A-Z]{16}"
    severity: critical
  - name: aws-secret-key
    regex: "[0-9a-zA-Z/+]{40}"
    context_regex: "aws_secret|AWS_SECRET"
    severity: critical
  - name: github-token
    regex: "ghp_[0-9a-zA-Z]{36}"
    severity: high
  - name: generic-api-key
    regex: "['\"]?[a-zA-Z_]*(?:api[_-]?key|apikey|api[_-]?secret)['\"]?\\s*[:=]\\s*['\"]([^'\"\\s]{16,})['\"]"
    severity: medium
  - name: private-key
    regex: "-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"
    severity: critical
  - name: jwt-secret
    regex: "['\"]?(?:jwt[_-]?secret|JWT_SECRET)['\"]?\\s*[:=]\\s*['\"]([^'\"\\s]{16,})['\"]"
    severity: high
  - name: database-url
    regex: "(?:postgres|mysql|mongodb)://[^\\s'\"]{10,}"
    severity: critical
```

### config/health-checks.yaml
```yaml
health_checks:
  api-service:
    url: "https://api.example.com/health"
    expected_status: 200
    timeout_seconds: 10
  web-frontend:
    url: "https://www.example.com"
    expected_status: 200
    timeout_seconds: 10
  github-actions:
    method: gh-workflow
    repos: [myorg/api-service, myorg/web-frontend]
    check_last_n_runs: 3
```

### scripts/scan-secrets.sh
Scans configured repositories using `grep -rn` with patterns from `config/secret-patterns.yaml`,
`git log --all --diff-filter=A` to detect secrets in git history,
and `gh secret list -R <repo>` to enumerate GitHub Actions secrets.

### scripts/generate-credential.sh
Dispatches credential generation based on type:
- `openssl rand -hex 32` for API keys and JWT secrets
- `openssl req -x509 -newkey rsa:4096 -nodes` for self-signed TLS certs
- `ssh-keygen -t ed25519 -N "" -f <keyfile>` for SSH keys
- `gh secret set <NAME> -R <repo>` for setting GitHub secrets

### scripts/check-health.sh
Iterates over health check targets from config, runs `curl -sf` against each endpoint,
and checks `gh run list --status completed -L 3` for GitHub Actions health.

### scripts/revoke-credential.sh
Marks credentials as revoked in inventory, optionally removes old GitHub secrets
via `gh secret delete`, and logs the revocation event.

## Key AO Features Demonstrated

- **Scheduled workflows**: Daily secret audit, weekly rotation batch, monthly compliance audit
- **Multi-agent pipeline**: 5 agents with distinct security-focused roles
- **Command phases**: Real CLI tools (openssl, gh, git, grep, curl, ssh-keygen, jq)
- **Decision contracts**: Rotation urgency classification, health status routing
- **Rework loops**: Failed health verification triggers config re-update (max 2 attempts)
- **GitHub integration**: Secret management, issue creation for exposed secrets, workflow health checks
- **Compliance audit trail**: Full rotation history, policy enforcement, trend tracking
