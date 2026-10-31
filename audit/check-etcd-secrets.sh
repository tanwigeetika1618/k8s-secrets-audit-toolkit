#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-secrets-audit-demo}"
SECRET_NAME="${2:-db-creds}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}═══ Checking K8s Secrets in etcd ═══${NC}"
echo ""

echo "All secrets in namespace '$NAMESPACE':"
kubectl get secrets -n "$NAMESPACE" -o custom-columns=\
'NAME:.metadata.name,TYPE:.type,KEYS:.data' --no-headers 2>/dev/null || echo "  No secrets found"
echo ""

echo "Detailed check for secret '$SECRET_NAME':"
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo -e "${RED}  Secret exists in etcd as a Kubernetes Secret object${NC}"
    echo ""
    echo "  Keys stored:"
    kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o json | \
        jq -r '.data | keys[]' 2>/dev/null | while read -r key; do
        value=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" \
            -o jsonpath="{.data.$key}" | base64 -d)
        masked="${value:0:3}$(printf '%*s' $((${#value} - 3)) | tr ' ' '*')"
        echo -e "  ${RED}  $key = $masked${NC}"
    done

    echo ""
    echo "  Labels:"
    kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o json | \
        jq -r '.metadata.labels // {} | to_entries[] | "    \(.key) = \(.value)"' 2>/dev/null

    echo ""
    echo -e "${RED}  ⚠ Base64 encoding is NOT encryption.${NC}"
    echo -e "${RED}  ⚠ Anyone with 'get secrets' RBAC permission can read this.${NC}"
    echo -e "${RED}  ⚠ This secret is stored unencrypted in etcd by default.${NC}"
else
    echo -e "${GREEN}  ✅ Secret '$SECRET_NAME' does not exist as a K8s Secret${NC}"
    echo -e "${GREEN}     (Good — may be using CSI volume mount instead)${NC}"
fi
