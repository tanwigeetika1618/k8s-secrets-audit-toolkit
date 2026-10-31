#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

pause() {
    echo ""
    echo -e "${YELLOW}▶ Press ENTER to continue...${NC}"
    read -r
    echo ""
}

narrate() {
    echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  The Secret Lifecycle You're Ignoring:                         ║"
echo "║  How Secrets Leak Inside Kubernetes Operators                  ║"
echo "║                                                                ║"
echo "║  DevConf.IN 2027 — Live Demo                                   ║"
echo "║  Tanwi Geetika                                                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
pause

# ─── ACT 1: THE SETUP ───────────────────────────────────────────────

narrate "ACT 1: Let's look at what we have"

echo "We have a typical setup:"
echo "  • HashiCorp Vault storing our database credentials"
echo "  • Vault Secrets Operator (VSO) syncing secrets to Kubernetes"
echo "  • A web app connected to PostgreSQL"
echo "  • Everything looks secure... right?"
pause

echo -e "${BLUE}Let's verify our app is running:${NC}"
kubectl get pods -n secrets-audit-demo -l app=webapp
echo ""
kubectl get pods -n secrets-audit-demo -l app=postgres
pause

echo -e "${BLUE}And our secret is synced from Vault:${NC}"
kubectl get vaultstaticsecret -n secrets-audit-demo
echo ""
kubectl get secrets -n secrets-audit-demo -l synced-from=vault
pause

# ─── ACT 2: THE AUDIT ───────────────────────────────────────────────

narrate "ACT 2: The Audit — Where is our password right now?"

echo "Let's trace our database password through every stage of its lifecycle."
echo "We'll check 6 stages — from Vault to container logs."
pause

echo -e "${BOLD}Stage 1: Vault (should be encrypted)${NC}"
vault kv get -format=table secret/demo/db 2>/dev/null || echo "  (Vault stores this encrypted with AES-256-GCM)"
echo -e "${GREEN}✅ Encrypted at rest in Vault — this is fine${NC}"
pause

echo -e "${BOLD}Stage 2: Kubernetes Secret (etcd)${NC}"
echo "Let's decode the K8s Secret that VSO created:"
echo ""
echo "  kubectl get secret db-creds -n secrets-audit-demo -o jsonpath='{.data.password}' | base64 -d"
echo ""
PASSWORD=$(kubectl get secret db-creds -n secrets-audit-demo -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "N/A")
echo -e "${RED}  Decoded password: $PASSWORD${NC}"
echo -e "${RED}❌ Plain text in etcd! Anyone with RBAC 'get secrets' can see this.${NC}"
pause

echo -e "${BOLD}Stage 3: Environment Variables${NC}"
POD=$(kubectl get pods -n secrets-audit-demo -l app=webapp -o jsonpath='{.items[0].metadata.name}')
echo "  kubectl exec $POD -- env | grep DB_PASSWORD"
echo ""
kubectl exec "$POD" -n secrets-audit-demo -- env | grep -E "DB_PASSWORD|API_KEY|JWT_SECRET" || true
echo ""
echo -e "${RED}❌ Plain text in environment variables!${NC}"
echo -e "${RED}   Any process in the container can read /proc/self/environ${NC}"
pause

echo -e "${BOLD}Stage 4: Mounted Files${NC}"
echo "  kubectl exec $POD -- cat /etc/secrets/db/password"
echo ""
kubectl exec "$POD" -n secrets-audit-demo -- cat /etc/secrets/db/password 2>/dev/null || echo "  (not mounted)"
echo ""
echo -e "${RED}❌ Plain text file on the container filesystem!${NC}"
pause

echo -e "${BOLD}Stage 5: Application Memory${NC}"
echo "  The app caches the password in a Python dict at startup."
echo "  Even if we rotate the secret, the old password stays in memory."
echo ""
kubectl exec "$POD" -n secrets-audit-demo -- python3 -c "
import os
pw = os.environ.get('DB_PASSWORD', '')
print(f'  Password in memory: {pw[:4]}****')
print(f'  Memory address: {hex(id(pw))}')
print(f'  Length: {len(pw)} chars — fully accessible to any code in this process')
" 2>/dev/null || echo "  (could not inspect)"
echo -e "${RED}❌ Cached in process memory — survives secret rotation!${NC}"
pause

echo -e "${BOLD}Stage 6: Logs${NC}"
echo "  kubectl logs $POD --tail=20 | grep -i password"
echo ""
kubectl logs "$POD" -n secrets-audit-demo --tail=50 2>/dev/null | grep -i "password\|secret\|credential" | head -5 || echo "  (no matches)"
echo ""
echo -e "${YELLOW}⚠️  Credential-related strings in logs — sent to your log aggregator!${NC}"
pause

# ─── ACT 3: THE REPORT ──────────────────────────────────────────────

narrate "ACT 3: The Audit Report"

"$ROOT_DIR/audit/audit.sh"
pause

# ─── ACT 4: THE FIX ─────────────────────────────────────────────────

narrate "ACT 4: The Fix — CSI Secret Store Pattern"

echo "Now let's fix this. We'll switch from VSO-sync-to-etcd to CSI volume mounts."
echo ""
echo "What changes:"
echo "  1. Secrets are fetched directly from Vault by the CSI driver"
echo "  2. Mounted as tmpfs files — NEVER stored in etcd"
echo "  3. App reads from files on demand — no env vars, no caching"
echo "  4. Logs are sanitized — no credential strings"
pause

echo -e "${BLUE}Applying the CSI fix...${NC}"
"$ROOT_DIR/fix/csi-pattern/apply-fix.sh"
pause

# ─── ACT 5: RE-AUDIT ────────────────────────────────────────────────

narrate "ACT 5: Re-Audit — Did we actually fix it?"

"$ROOT_DIR/audit/audit.sh"
pause

# ─── CONCLUSION ──────────────────────────────────────────────────────

narrate "Conclusion"

echo -e "${BOLD}Key Takeaways:${NC}"
echo ""
echo "  1. Using Vault doesn't automatically make you secure"
echo "     → Audit WHERE your secret exists, not just where it starts"
echo ""
echo "  2. The default VSO pattern (sync to K8s Secret) puts credentials in etcd"
echo "     → Use CSI mounts for high-sensitivity secrets"
echo ""
echo "  3. Environment variables are the most common leak point"
echo "     → Read from files instead"
echo ""
echo "  4. Application caching defeats secret rotation"
echo "     → Read on demand, never cache credentials"
echo ""
echo "  5. The Bootstrap Paradox is real"
echo "     → Use K8s ServiceAccount JWT auth to avoid storing auth creds"
echo ""
echo -e "${GREEN}${BOLD}Repo: github.com/tanwigeetika1618/k8s-secrets-audit-toolkit${NC}"
echo -e "${GREEN}${BOLD}Try the audit on YOUR operator — you'll be surprised!${NC}"
echo ""
