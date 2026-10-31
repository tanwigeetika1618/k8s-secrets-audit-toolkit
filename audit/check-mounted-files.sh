#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-secrets-audit-demo}"
APP_LABEL="${2:-app=webapp}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

SECRET_MOUNT_PATHS=(
    "/etc/secrets"
    "/var/run/secrets"
    "/mnt/secrets"
    "/opt/secrets"
)

echo -e "${BLUE}═══ Checking Mounted Secret Files in Pods ═══${NC}"
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

    for mount_path in "${SECRET_MOUNT_PATHS[@]}"; do
        files=$(kubectl exec "$pod" -n "$NAMESPACE" -- \
            find "$mount_path" -type f 2>/dev/null || echo "")

        if [[ -n "$files" ]]; then
            echo -e "  ${RED}❌ Secret files found at $mount_path:${NC}"
            echo "$files" | while read -r filepath; do
                content=$(kubectl exec "$pod" -n "$NAMESPACE" -- \
                    cat "$filepath" 2>/dev/null || echo "")
                if [[ -n "$content" ]]; then
                    masked="${content:0:4}$(printf '%*s' $((${#content} - 4)) | tr ' ' '*')"
                    echo -e "  ${RED}  $filepath = $masked${NC}"
                    exposed_count=$((exposed_count + 1))
                fi
            done
        fi
    done

    volume_mounts=$(kubectl get pod "$pod" -n "$NAMESPACE" -o json | \
        jq -r '.spec.containers[].volumeMounts[]? | select(.name | test("secret|cred|key"; "i")) | "\(.name) → \(.mountPath)"' 2>/dev/null || echo "")

    if [[ -n "$volume_mounts" ]]; then
        echo -e "  ${RED}  Volume mounts with secret-like names:${NC}"
        echo "$volume_mounts" | while read -r mount; do
            echo -e "  ${RED}    $mount${NC}"
        done
    fi
    echo ""
done

echo "═══ Summary ═══"
if [[ $exposed_count -gt 0 ]]; then
    echo -e "${RED}Secret files found mounted in containers${NC}"
    echo -e "${RED}Risk: Any process can read these files from the container filesystem${NC}"
    echo -e "${RED}Fix: Use CSI volumes with ephemeral tmpfs (no etcd, no persistent files)${NC}"
else
    echo -e "${GREEN}No secret files found in standard mount paths${NC}"
fi
