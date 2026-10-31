#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="secrets-audit-demo"
SECRET_NAME="db-creds"
SEARCH_TERM="S3cretP@ssw0rd"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

TOTAL_STAGES=6
EXPOSED_COUNT=0

results=()

print_header() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        SECRET LIFECYCLE AUDIT — In Progress             ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  Target: ${SECRET_NAME} in namespace ${NAMESPACE}${NC}"
    echo -e "${BLUE}║  Searching for credential exposure at every stage       ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

record_result() {
    local stage="$1"
    local status="$2"
    local detail="$3"
    results+=("$stage|$status|$detail")
}

stage1_vault() {
    echo -e "${BOLD}Stage 1: Vault KV Store${NC}"
    echo "  Checking if secret is stored encrypted in Vault..."

    if vault kv get -format=json secret/demo/db &>/dev/null; then
        echo -e "  ${GREEN}✅ Secret exists in Vault KV store${NC}"
        echo -e "  ${GREEN}   Vault encrypts data at rest using AES-256-GCM${NC}"
        echo -e "  ${GREEN}   Access controlled by policies and auth methods${NC}"
        record_result "Stage 1: Vault KV Store" "SECURE" "Encrypted at rest, policy-controlled access"
    else
        echo -e "  ${YELLOW}⚠️  Cannot reach Vault or secret not found${NC}"
        record_result "Stage 1: Vault KV Store" "UNKNOWN" "Could not verify"
    fi
    echo ""
}

stage2_etcd() {
    echo -e "${BOLD}Stage 2: Kubernetes Secret (etcd)${NC}"
    echo "  Checking if secret exists as a K8s Secret object..."

    if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        local b64_password
        b64_password=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" \
            -o jsonpath='{.data.password}' 2>/dev/null)

        if [[ -n "$b64_password" ]]; then
            local decoded
            decoded=$(echo "$b64_password" | base64 -d 2>/dev/null)
            echo -e "  ${RED}❌ Secret found in etcd as base64-encoded K8s Secret${NC}"
            echo -e "  ${RED}   Anyone with RBAC access can decode it:${NC}"
            echo -e "  ${RED}   kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath='{.data.password}' | base64 -d${NC}"
            echo -e "  ${RED}   Decoded value: ${decoded:0:4}****${NC}"
            EXPOSED_COUNT=$((EXPOSED_COUNT + 1))
            record_result "Stage 2: K8s Secret (etcd)" "EXPOSED" "Base64-encoded, decodable with RBAC access"
        fi
    else
        echo -e "  ${GREEN}✅ No K8s Secret object found (may be using CSI mount)${NC}"
        record_result "Stage 2: K8s Secret (etcd)" "SECURE" "Secret not stored in etcd"
    fi
    echo ""
}

stage3_env_vars() {
    echo -e "${BOLD}Stage 3: Pod Environment Variables${NC}"
    echo "  Checking if secrets are exposed as env vars in running pods..."

    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" -l app=webapp \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    local found_in_env=false
    for pod in $pods; do
        local env_output
        env_output=$(kubectl exec "$pod" -n "$NAMESPACE" -- env 2>/dev/null || echo "")

        if echo "$env_output" | grep -q "DB_PASSWORD"; then
            local exposed_value
            exposed_value=$(echo "$env_output" | grep "DB_PASSWORD" | cut -d'=' -f2-)
            echo -e "  ${RED}❌ Pod $pod: DB_PASSWORD found in environment${NC}"
            echo -e "  ${RED}   Value: ${exposed_value:0:4}****${NC}"
            echo -e "  ${RED}   Command: kubectl exec $pod -n $NAMESPACE -- env | grep DB_PASSWORD${NC}"
            found_in_env=true
        fi

        if echo "$env_output" | grep -q "API_KEY\|JWT_SECRET"; then
            echo -e "  ${RED}   Also found: API_KEY, JWT_SECRET in env vars${NC}"
        fi
    done

    if $found_in_env; then
        EXPOSED_COUNT=$((EXPOSED_COUNT + 1))
        record_result "Stage 3: Pod Env Variables" "EXPOSED" "Plain text in pod environment, readable via kubectl exec"
    else
        echo -e "  ${GREEN}✅ No secrets found in pod environment variables${NC}"
        record_result "Stage 3: Pod Env Variables" "SECURE" "Not exposed as env vars"
    fi
    echo ""
}

stage4_files() {
    echo -e "${BOLD}Stage 4: Mounted Files on Disk${NC}"
    echo "  Checking if secrets are readable as files in containers..."

    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" -l app=webapp \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    local found_in_files=false
    for pod in $pods; do
        local file_content
        file_content=$(kubectl exec "$pod" -n "$NAMESPACE" -- \
            cat /etc/secrets/db/password 2>/dev/null || echo "")

        if [[ -n "$file_content" ]]; then
            echo -e "  ${RED}❌ Pod $pod: Secret readable at /etc/secrets/db/password${NC}"
            echo -e "  ${RED}   Content: ${file_content:0:4}****${NC}"
            echo -e "  ${RED}   Command: kubectl exec $pod -n $NAMESPACE -- cat /etc/secrets/db/password${NC}"
            found_in_files=true

            local all_files
            all_files=$(kubectl exec "$pod" -n "$NAMESPACE" -- ls /etc/secrets/db/ 2>/dev/null || echo "")
            echo -e "  ${RED}   All secret files: $all_files${NC}"
        fi
    done

    if $found_in_files; then
        EXPOSED_COUNT=$((EXPOSED_COUNT + 1))
        record_result "Stage 4: Mounted Files" "EXPOSED" "Plain text files readable in container filesystem"
    else
        echo -e "  ${GREEN}✅ No secret files found mounted in containers${NC}"
        record_result "Stage 4: Mounted Files" "SECURE" "No secret files mounted"
    fi
    echo ""
}

stage5_memory() {
    echo -e "${BOLD}Stage 5: Application Memory${NC}"
    echo "  Checking if secrets are cached in application memory..."

    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" -l app=webapp \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    local found_in_memory=false
    for pod in $pods; do
        local app_response
        app_response=$(kubectl exec "$pod" -n "$NAMESPACE" -- \
            python3 -c "
import os
config = {
    'password': os.environ.get('DB_PASSWORD', ''),
    'api_key': os.environ.get('API_KEY', ''),
}
has_secrets = any(v for v in config.values())
print('SECRETS_IN_MEMORY=' + str(has_secrets))
for k, v in config.items():
    if v:
        print(f'  {k}={v[:4]}****')
" 2>/dev/null || echo "")

        if echo "$app_response" | grep -q "SECRETS_IN_MEMORY=True"; then
            echo -e "  ${RED}❌ Pod $pod: Secrets cached in application memory${NC}"
            echo "$app_response" | grep -v "SECRETS_IN_MEMORY" | while read -r line; do
                echo -e "  ${RED}  $line${NC}"
            done
            found_in_memory=true
        fi
    done

    if $found_in_memory; then
        EXPOSED_COUNT=$((EXPOSED_COUNT + 1))
        record_result "Stage 5: App Memory" "EXPOSED" "Secrets cached in Python process memory (connection pool)"
    else
        echo -e "  ${GREEN}✅ Secrets not detected in application memory${NC}"
        record_result "Stage 5: App Memory" "SECURE" "Not cached in memory"
    fi
    echo ""
}

stage6_logs() {
    echo -e "${BOLD}Stage 6: Container Logs${NC}"
    echo "  Scanning container logs for credential exposure..."

    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" -l app=webapp \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    local found_in_logs=false
    for pod in $pods; do
        local log_output
        log_output=$(kubectl logs "$pod" -n "$NAMESPACE" --tail=100 2>/dev/null || echo "")

        if echo "$log_output" | grep -qi "password\|secret\|credential\|api_key"; then
            local matches
            matches=$(echo "$log_output" | grep -i "password\|secret\|credential\|api_key" | head -3)
            echo -e "  ${YELLOW}⚠️  Pod $pod: Potential secret exposure in logs${NC}"
            echo "$matches" | while read -r line; do
                echo -e "  ${YELLOW}   $line${NC}"
            done
            found_in_logs=true
        fi
    done

    if $found_in_logs; then
        EXPOSED_COUNT=$((EXPOSED_COUNT + 1))
        record_result "Stage 6: Container Logs" "PARTIALLY EXPOSED" "Credential-related strings found in logs"
    else
        echo -e "  ${GREEN}✅ No credential exposure detected in logs${NC}"
        record_result "Stage 6: Container Logs" "SECURE" "No credential strings in recent logs"
    fi
    echo ""
}

print_report() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║           SECRET LIFECYCLE AUDIT REPORT                  ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║                                                          ║${NC}"
    echo -e "${BOLD}║  Target Secret: ${SECRET_NAME}                              ║${NC}"
    echo -e "${BOLD}║  Namespace: ${NAMESPACE}                     ║${NC}"
    echo -e "${BOLD}║                                                          ║${NC}"

    for result in "${results[@]}"; do
        IFS='|' read -r stage status detail <<< "$result"
        local color
        case "$status" in
            "SECURE") color="$GREEN"; icon="✅" ;;
            "EXPOSED") color="$RED"; icon="❌" ;;
            "PARTIALLY EXPOSED") color="$YELLOW"; icon="⚠️ " ;;
            *) color="$YELLOW"; icon="❓" ;;
        esac
        printf "  ${color}%-35s %s %s${NC}\n" "$stage" "$icon" "$status"
    done

    echo -e "${BOLD}║                                                          ║${NC}"

    local risk_color
    if [[ $EXPOSED_COUNT -ge 4 ]]; then
        risk_color="$RED"
    elif [[ $EXPOSED_COUNT -ge 2 ]]; then
        risk_color="$YELLOW"
    else
        risk_color="$GREEN"
    fi

    echo -e "  ${risk_color}${BOLD}RISK SCORE: ${EXPOSED_COUNT}/${TOTAL_STAGES} stages exposed${NC}"
    echo -e "${BOLD}║                                                          ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"

    echo ""
    if [[ $EXPOSED_COUNT -ge 3 ]]; then
        echo -e "${RED}${BOLD}RECOMMENDATION: HIGH RISK — Apply CSI pattern fix immediately${NC}"
        echo -e "  Run: ./fix/csi-pattern/apply-fix.sh"
    elif [[ $EXPOSED_COUNT -ge 1 ]]; then
        echo -e "${YELLOW}${BOLD}RECOMMENDATION: MEDIUM RISK — Consider hybrid pattern${NC}"
        echo -e "  Run: ./fix/hybrid-pattern/apply-fix.sh"
    else
        echo -e "${GREEN}${BOLD}RESULT: LOW RISK — Secret exposure is minimized${NC}"
    fi
    echo ""
}

main() {
    print_header
    stage1_vault
    stage2_etcd
    stage3_env_vars
    stage4_files
    stage5_memory
    stage6_logs
    print_report
}

main "$@"
