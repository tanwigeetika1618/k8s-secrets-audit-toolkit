#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="secrets-audit-demo"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}═══ Applying CSI Pattern Fix ═══${NC}"
echo ""

echo -e "${BLUE}Step 1: Installing Secrets Store CSI Driver...${NC}"
helm repo add secrets-store-csi-driver \
    https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts 2>/dev/null || true
helm repo update

helm upgrade --install csi-secrets-store \
    secrets-store-csi-driver/secrets-store-csi-driver \
    --namespace kube-system \
    --set syncSecret.enabled=false \
    --set enableSecretRotation=true \
    --set rotationPollInterval=30s \
    --wait --timeout 120s

echo -e "${GREEN}✅ CSI Driver installed${NC}"
echo ""

echo -e "${BLUE}Step 2: Installing Vault CSI Provider...${NC}"
helm upgrade --install vault hashicorp/vault \
    --namespace "$NAMESPACE" \
    --set "server.enabled=false" \
    --set "injector.enabled=false" \
    --set "csi.enabled=true" \
    --wait --timeout 120s

echo -e "${GREEN}✅ Vault CSI Provider installed${NC}"
echo ""

echo -e "${BLUE}Step 3: Applying SecretProviderClass...${NC}"
kubectl apply -f "$SCRIPT_DIR/secret-provider-class.yaml" -n "$NAMESPACE"
echo -e "${GREEN}✅ SecretProviderClass created${NC}"
echo ""

echo -e "${BLUE}Step 4: Deleting old K8s Secret (removing from etcd)...${NC}"
kubectl delete secret db-creds -n "$NAMESPACE" 2>/dev/null || true
kubectl delete secret app-creds -n "$NAMESPACE" 2>/dev/null || true
echo -e "${GREEN}✅ Old K8s Secrets removed from etcd${NC}"
echo ""

echo -e "${BLUE}Step 5: Removing VSO sync (no more syncing to etcd)...${NC}"
kubectl delete vaultstaticsecret db-creds-sync -n "$NAMESPACE" 2>/dev/null || true
kubectl delete vaultstaticsecret app-creds-sync -n "$NAMESPACE" 2>/dev/null || true
echo -e "${GREEN}✅ VSO sync resources removed${NC}"
echo ""

echo -e "${BLUE}Step 6: Deploying CSI-based webapp...${NC}"
kubectl apply -f "$SCRIPT_DIR/webapp-csi.yaml" -n "$NAMESPACE"

echo -e "${BLUE}Waiting for new pods to be ready...${NC}"
kubectl rollout status deployment/webapp -n "$NAMESPACE" --timeout=120s
echo -e "${GREEN}✅ CSI-based webapp deployed${NC}"
echo ""

echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           CSI PATTERN FIX APPLIED                        ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║  What changed:                                           ║${NC}"
echo -e "${GREEN}║  ✅ Secrets no longer stored in etcd                     ║${NC}"
echo -e "${GREEN}║  ✅ No environment variables with credentials            ║${NC}"
echo -e "${GREEN}║  ✅ App reads from tmpfs files on demand                 ║${NC}"
echo -e "${GREEN}║  ✅ Logs sanitized (no credential strings)               ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║  Run the audit again to see the difference:              ║${NC}"
echo -e "${GREEN}║    ./audit/audit.sh                                      ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
