#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-secrets-audit-demo}"
APP_LABEL="${2:-app=webapp}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SENSITIVE_PATTERNS="password|secret|credential|api.key|token|private.key|jwt|auth"
LOG_LINES=200

echo -e "${BLUE}═══ Checking Container Logs for Secret Exposure ═══${NC}"
echo ""

pods=$(kubectl get pods -n "$NAMESPACE" -l "$APP_LABEL" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

if [[ -z "$pods" ]]; then
    echo "  No pods found with label '$APP_LABEL' in namespace '$NAMESPACE'"
    exit 0
fi

total_matches=0

for pod in $pods; do
    echo -e "Pod: ${BLUE}$pod${NC}"

    logs=$(kubectl logs "$pod" -n "$NAMESPACE" --tail="$LOG_LINES" 2>/dev/null || echo "")

    if [[ -z "$logs" ]]; then
        echo "  No logs available"
        continue
    fi

    matches=$(echo "$logs" | grep -inE "$SENSITIVE_PATTERNS" || echo "")

    if [[ -n "$matches" ]]; then
        match_count=$(echo "$matches" | wc -l | tr -d ' ')
        total_matches=$((total_matches + match_count))
        echo -e "  ${YELLOW}⚠️  $match_count lines contain credential-related strings:${NC}"
        echo "$matches" | head -5 | while read -r line; do
            sanitized=$(echo "$line" | sed -E "s/(password|secret|key|token)([=: ]+)([^ \"',]+)/\1\2****REDACTED****/gi")
            echo -e "  ${YELLOW}  $sanitized${NC}"
        done
        if [[ $match_count -gt 5 ]]; then
            echo -e "  ${YELLOW}  ... and $((match_count - 5)) more matches${NC}"
        fi
    else
        echo -e "  ${GREEN}✅ No credential-related strings found in recent logs${NC}"
    fi
    echo ""
done

echo "═══ Summary ═══"
if [[ $total_matches -gt 0 ]]; then
    echo -e "${YELLOW}$total_matches total log lines contain credential-related strings${NC}"
    echo -e "${YELLOW}Risk: Secrets may be exposed in log aggregation systems (ELK, Splunk, etc.)${NC}"
    echo -e "${YELLOW}Fix: Sanitize logging, use structured logging with secret redaction${NC}"
else
    echo -e "${GREEN}No credential exposure detected in container logs${NC}"
fi
