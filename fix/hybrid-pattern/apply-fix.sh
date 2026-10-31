#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
NAMESPACE="secrets-audit-demo"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}═══ Applying Hybrid Pattern Fix ═══${NC}"
echo ""
echo "Strategy: CSI for high-sensitivity secrets, VSO sync for low-sensitivity config"
echo ""

echo -e "${BLUE}Step 1: Installing CSI Driver + Vault CSI Provider...${NC}"
helm repo add secrets-store-csi-driver \
    https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts 2>/dev/null || true
helm repo update

helm upgrade --install csi-secrets-store \
    secrets-store-csi-driver/secrets-store-csi-driver \
    --namespace kube-system \
    --set syncSecret.enabled=false \
    --set enableSecretRotation=true \
    --wait --timeout 120s

helm upgrade --install vault hashicorp/vault \
    --namespace "$NAMESPACE" \
    --set "server.enabled=false" \
    --set "injector.enabled=false" \
    --set "csi.enabled=true" \
    --wait --timeout 120s

echo -e "${GREEN}✅ CSI infrastructure installed${NC}"
echo ""

echo -e "${BLUE}Step 2: Applying SecretProviderClass...${NC}"
kubectl apply -f "$ROOT_DIR/fix/csi-pattern/secret-provider-class.yaml" -n "$NAMESPACE"
echo -e "${GREEN}✅ SecretProviderClass created${NC}"
echo ""

echo -e "${BLUE}Step 3: Creating low-sensitivity K8s Secret (ok for etcd)...${NC}"
kubectl create secret generic db-connection-info \
    -n "$NAMESPACE" \
    --from-literal=host="postgres.secrets-audit-demo.svc.cluster.local" \
    --from-literal=port="5432" \
    --from-literal=dbname="appdb" \
    --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✅ Non-sensitive connection info stored in K8s Secret${NC}"
echo ""

echo -e "${BLUE}Step 4: Removing high-sensitivity K8s Secrets from etcd...${NC}"
kubectl delete secret db-creds -n "$NAMESPACE" 2>/dev/null || true
echo -e "${GREEN}✅ Credentials removed from etcd${NC}"
echo ""

echo -e "${BLUE}Step 5: Deploying hybrid webapp...${NC}"
kubectl apply -f "$SCRIPT_DIR/webapp-hybrid.yaml" -n "$NAMESPACE"
kubectl rollout status deployment/webapp -n "$NAMESPACE" --timeout=120s
echo -e "${GREEN}✅ Hybrid webapp deployed${NC}"
echo ""

echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         HYBRID PATTERN APPLIED                           ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║  CSI Mount (never in etcd):                              ║${NC}"
echo -e "${GREEN}║    ✅ db-username                                        ║${NC}"
echo -e "${GREEN}║    ✅ db-password                                        ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║  VSO Sync (in etcd, acceptable risk):                    ║${NC}"
echo -e "${GREEN}║    ⚠️  db-host (non-sensitive)                            ║${NC}"
echo -e "${GREEN}║    ⚠️  db-port (non-sensitive)                            ║${NC}"
echo -e "${GREEN}║    ⚠️  db-name (non-sensitive)                            ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
