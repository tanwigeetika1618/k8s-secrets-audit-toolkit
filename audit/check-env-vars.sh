#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-secrets-audit-demo}"
APP_LABEL="${2:-app=webapp}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

SENSITIVE_PATTERNS="PASSWORD|SECRET|KEY|TOKEN|CREDENTIAL|API_KEY|JWT|PRIVATE"

echo -e "${BLUE}═══ Checking Environment Variables in Pods ═══${NC}"
echo ""

pods=$(kubectl get pods -n "$NAMESPACE" -l "$APP_LABEL" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

if [[ -z "$pods" ]]; then
    echo "  No pods found with label '$APP_LABEL' in namespace '$NAMESPACE'"
    exit 0
fi

exposed_count=0

for pod in $pods; do
    echo -e "Pod: ${BLUE}$pod${NC}"

    env_output=$(kubectl exec "$pod" -n "$NAMESPACE" -- env 2>/dev/null || echo "EXEC_FAILED")

    if [[ "$env_output" == "EXEC_FAILED" ]]; then
        echo "  Could not exec into pod (may not be running)"
        continue
    fi

    sensitive_vars=$(echo "$env_output" | grep -iE "$SENSITIVE_PATTERNS" || echo "")

    if [[ -n "$sensitive_vars" ]]; then
        echo -e "  ${RED}❌ Sensitive environment variables found:${NC}"
        echo "$sensitive_vars" | while read -r line; do
            var_name=$(echo "$line" | cut -d'=' -f1)
            var_value=$(echo "$line" | cut -d'=' -f2-)
            masked="${var_value:0:4}$(printf '%*s' $((${#var_value} - 4)) | tr ' ' '*')"
            echo -e "  ${RED}  $var_name = $masked${NC}"
        done
        exposed_count=$((exposed_count + 1))
    else
        echo -e "  ${GREEN}✅ No sensitive environment variables detected${NC}"
    fi
    echo ""
done

echo "═══ Summary ═══"
if [[ $exposed_count -gt 0 ]]; then
    echo -e "${RED}$exposed_count pod(s) have secrets exposed as environment variables${NC}"
    echo -e "${RED}Risk: Any process in the container can read these via /proc/self/environ${NC}"
    echo -e "${RED}Fix: Use CSI volume mounts instead of env vars (see fix/csi-pattern/)${NC}"
else
    echo -e "${GREEN}No secrets exposed as environment variables${NC}"
fi
