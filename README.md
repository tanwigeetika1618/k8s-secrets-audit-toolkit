# K8s Secrets Audit Toolkit

**The Secret Lifecycle You're Ignoring: How Secrets Leak Inside Kubernetes Operators**

A hands-on toolkit to audit, visualize, and fix secret leaks in Kubernetes operator-managed platforms. Demonstrates the complete lifecycle of a secret — from HashiCorp Vault through etcd, environment variables, config files, and application memory — and shows where it exists in plain text at each stage.

> 🎤 Presented at DevConf.IN 2027 — Software Supply Chain Security & Agentic AppSec Track

## The Problem

Most teams think "we use Vault, so we're secure." But even with Vault in the picture, a single database password can exist in **plain text at 4+ points simultaneously** inside a Kubernetes operator:

```
┌─────────┐    ┌───────────┐    ┌──────────────┐    ┌──────────────┐    ┌─────────────┐    ┌──────┐
│  Vault   │───▶│  K8s      │───▶│ Environment  │───▶│ Config Files │───▶│ Application │───▶│ Logs │
│(encrypted)│   │  Secret   │    │ Variables    │    │ on Disk      │    │ Memory      │    │      │
│          │    │ (etcd,    │    │ (plain text) │    │ (plain text) │    │ (plain text)│    │(leak)│
│          │    │  base64)  │    │              │    │              │    │             │    │      │
└─────────┘    └───────────┘    └──────────────┘    └──────────────┘    └─────────────┘    └──────┘
     ✅              ⚠️               ❌                  ❌                  ❌              ❌
```

This toolkit helps you **audit** these leak points and **fix** them using proper Vault Secrets Operator patterns.

## Quick Start

### Prerequisites

- Docker Desktop (for Kind)
- `kind` — `brew install kind`
- `kubectl` — `brew install kubectl`
- `helm` — `brew install helm`
- `vault` CLI — `brew install vault`
- `jq` — `brew install jq`

### One-Command Setup

```bash
# Set up everything: Kind cluster + Vault + VSO + Sample App
./setup/setup.sh
```

### Run the Audit

```bash
# Run the full secret lifecycle audit
./audit/audit.sh
```

### See the Fix

```bash
# Apply CSI-based fix and re-audit
./fix/csi-pattern/apply-fix.sh
./audit/audit.sh  # Run again to see the difference
```

### Full Demo (Conference Talk)

```bash
# End-to-end demo with narration pauses
./demo/run-full-demo.sh
```

## Architecture

### Before (Insecure Default)

```
Vault ──▶ VSO syncs to K8s Secret (etcd) ──▶ Operator reads Secret
                                                    │
                                              ┌─────┴──────┐
                                              ▼            ▼
                                         env vars    config files
                                        (plain text)  (plain text)
                                              │            │
                                              ▼            ▼
                                         app memory     logs
                                        (cached)     (on error)
```

### After (CSI Pattern Fix)

```
Vault ──▶ CSI Secret Store Driver ──▶ tmpfs volume mount (never in etcd)
                                              │
                                              ▼
                                      file on ephemeral volume
                                     (app reads directly, no env var)
                                              │
                                              ▼
                                       app reads on demand
                                      (no caching in memory)
```

## What's Inside

```
k8s-secrets-audit-toolkit/
├── setup/
│   ├── setup.sh                    # Master setup (Kind + Vault + VSO + app)
│   ├── kind-cluster.yaml           # Kind cluster configuration
│   ├── vault-config.sh             # Vault secrets engine + policies + auth
│   └── sample-app/
│       ├── namespace.yaml          # Demo namespace
│       ├── postgres.yaml           # PostgreSQL with secret-based auth
│       ├── webapp.yaml             # Web app consuming DB credentials
│       ├── vault-connection.yaml   # VaultConnection CR
│       ├── vault-auth.yaml         # VaultAuth CR (K8s auth method)
│       └── vault-static-secret.yaml # VaultStaticSecret CR
├── app/
│   ├── app.py                      # Sample Flask app (DB consumer)
│   ├── Dockerfile                  # Container image for the web app
│   └── requirements.txt            # Python dependencies
├── audit/
│   ├── audit.sh                    # Main audit: runs all checks, generates report
│   ├── check-etcd-secrets.sh       # Verify if secret exists in etcd
│   ├── check-env-vars.sh           # Check env vars in running pods
│   ├── check-mounted-files.sh      # Check secret files in containers
│   └── check-logs.sh              # Scan logs for credential exposure
├── fix/
│   ├── csi-pattern/
│   │   ├── apply-fix.sh           # Apply the CSI-based fix
│   │   ├── secret-provider-class.yaml
│   │   └── webapp-csi.yaml        # Web app using CSI volume mounts
│   └── hybrid-pattern/
│       ├── apply-fix.sh           # Apply hybrid pattern
│       └── webapp-hybrid.yaml     # CSI for DB creds, VSO sync for others
├── demo/
│   └── run-full-demo.sh           # Conference demo script with pauses
└── README.md
```

## The Three Integration Patterns

| Pattern | Secret in etcd? | Operator changes? | Complexity | Best for |
|---------|----------------|-------------------|------------|----------|
| **A: VSO Sync** | Yes (base64) | Minimal | Low | Quick wins, low-compliance |
| **B: CSI Mount** | Never | Significant | Medium | High-compliance, zero-trust |
| **C: Hybrid** | Some secrets | Moderate | Medium | Pragmatic middle ground |

## The Bootstrap Paradox

Your secret manager needs authentication to start. But the authentication credential is itself a secret. This toolkit demonstrates three bootstrap patterns:

1. **Static Initial Secret** — One-time manual secret for initial Vault auth
2. **Kubernetes ServiceAccount JWT** — Auto-auth using K8s service account tokens
3. **Cert-based Auto-Auth** — mTLS authentication (most secure, most complex)

## Audit Output Example

```
╔══════════════════════════════════════════════════════════╗
║           SECRET LIFECYCLE AUDIT REPORT                  ║
╠══════════════════════════════════════════════════════════╣
║                                                          ║
║  Target Secret: db-password                              ║
║  Namespace: secrets-audit-demo                           ║
║                                                          ║
║  Stage 1: Vault KV Store          ✅ ENCRYPTED           ║
║  Stage 2: K8s Secret (etcd)       ⚠️  BASE64 (readable)  ║
║  Stage 3: Pod Env Variables       ❌ PLAIN TEXT           ║
║  Stage 4: Config Files on Disk    ❌ PLAIN TEXT           ║
║  Stage 5: Application Memory      ❌ CACHED              ║
║  Stage 6: Container Logs          ⚠️  PARTIALLY EXPOSED   ║
║                                                          ║
║  RISK SCORE: 4/6 stages exposed                          ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
```

## Requirements

| Tool | Version | Install |
|------|---------|---------|
| Docker | 20.10+ | [docker.com](https://docker.com) |
| Kind | 0.20+ | `brew install kind` |
| kubectl | 1.27+ | `brew install kubectl` |
| Helm | 3.12+ | `brew install helm` |
| Vault CLI | 1.15+ | `brew install vault` |
| jq | 1.6+ | `brew install jq` |

## License

Apache License 2.0

## Author

Tanwi Geetika — [DevConf.IN 2027](https://devconf.in)
