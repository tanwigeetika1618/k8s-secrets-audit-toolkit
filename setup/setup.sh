#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="secrets-audit-demo"
VAULT_PORT=8200

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step() { echo -e "\n${BLUE}▶ $1${NC}"; }
print_ok()   { echo -e "${GREEN}✅ $1${NC}"; }
print_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_err()  { echo -e "${RED}❌ $1${NC}"; }

check_prerequisites() {
    print_step "Checking prerequisites..."
    local missing=0

    for cmd in docker kind kubectl helm vault jq; do
        if command -v "$cmd" &>/dev/null; then
            print_ok "$cmd found: $(command -v "$cmd")"
        else
            print_err "$cmd not found. Install with: brew install $cmd"
            missing=1
        fi
    done

    if ! docker info &>/dev/null; then
        print_err "Docker is not running. Please start Docker Desktop."
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        echo -e "\n${RED}Missing prerequisites. Install them and re-run.${NC}"
        exit 1
    fi

    print_ok "All prerequisites met!"
}

create_kind_cluster() {
    print_step "Creating Kind cluster..."

    if kind get clusters 2>/dev/null | grep -q "secrets-audit-demo"; then
        print_warn "Cluster 'secrets-audit-demo' already exists. Deleting..."
        kind delete cluster --name secrets-audit-demo
    fi

    kind create cluster --config "$SCRIPT_DIR/kind-cluster.yaml" --wait 60s
    kubectl cluster-info --context kind-secrets-audit-demo
    print_ok "Kind cluster created!"
}

install_vault() {
    print_step "Starting Vault in dev mode..."

    pkill -f "vault server -dev" 2>/dev/null || true
    sleep 1

    export VAULT_ADDR="http://127.0.0.1:${VAULT_PORT}"
    export VAULT_TOKEN="root"

    vault server -dev \
        -dev-root-token-id="root" \
        -dev-listen-address="0.0.0.0:${VAULT_PORT}" \
        &>/tmp/vault-dev.log &

    VAULT_PID=$!
    echo "$VAULT_PID" > /tmp/vault-dev.pid
    sleep 3

    if ! vault status &>/dev/null; then
        print_err "Vault failed to start. Check /tmp/vault-dev.log"
        exit 1
    fi

    print_ok "Vault dev server running (PID: $VAULT_PID)"
    echo -e "  VAULT_ADDR=$VAULT_ADDR"
    echo -e "  VAULT_TOKEN=$VAULT_TOKEN"
}

configure_vault() {
    print_step "Configuring Vault secrets and auth..."
    source "$SCRIPT_DIR/vault-config.sh"
    print_ok "Vault configured with secrets, policies, and K8s auth!"
}

install_vso() {
    print_step "Installing Vault Secrets Operator via Helm..."

    helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
    helm repo update

    kubectl create namespace vault-secrets-operator-system 2>/dev/null || true

    helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
        --namespace vault-secrets-operator-system \
        --set "defaultVaultConnection.enabled=true" \
        --set "defaultVaultConnection.address=http://host.docker.internal:${VAULT_PORT}" \
        --wait --timeout 120s

    kubectl wait --for=condition=available deployment/vault-secrets-operator-controller-manager \
        -n vault-secrets-operator-system --timeout=120s

    print_ok "VSO installed and running!"
}

deploy_sample_app() {
    print_step "Deploying sample application..."

    kubectl create namespace "$NAMESPACE" 2>/dev/null || true

    kubectl apply -f "$SCRIPT_DIR/sample-app/postgres.yaml" -n "$NAMESPACE"

    print_step "Waiting for PostgreSQL to be ready..."
    kubectl wait --for=condition=available deployment/postgres \
        -n "$NAMESPACE" --timeout=120s

    kubectl apply -f "$SCRIPT_DIR/sample-app/vault-connection.yaml" -n "$NAMESPACE"
    kubectl apply -f "$SCRIPT_DIR/sample-app/vault-auth.yaml" -n "$NAMESPACE"
    kubectl apply -f "$SCRIPT_DIR/sample-app/vault-static-secret.yaml" -n "$NAMESPACE"

    print_step "Waiting for VSO to sync the secret..."
    sleep 10

    if kubectl get secret db-creds -n "$NAMESPACE" &>/dev/null; then
        print_ok "VSO synced secret 'db-creds' from Vault!"
    else
        print_warn "Secret not synced yet. VSO may need more time."
    fi

    kubectl apply -f "$SCRIPT_DIR/sample-app/webapp.yaml" -n "$NAMESPACE"

    print_step "Waiting for web app to be ready..."
    kubectl wait --for=condition=available deployment/webapp \
        -n "$NAMESPACE" --timeout=120s

    print_ok "Sample application deployed!"
}

print_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           SETUP COMPLETE — READY FOR AUDIT              ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║                                                          ║${NC}"
    echo -e "${GREEN}║  Kind Cluster:  secrets-audit-demo                       ║${NC}"
    echo -e "${GREEN}║  Vault:         http://127.0.0.1:${VAULT_PORT} (token: root)        ║${NC}"
    echo -e "${GREEN}║  Namespace:     ${NAMESPACE}                     ║${NC}"
    echo -e "${GREEN}║  VSO:           vault-secrets-operator-system            ║${NC}"
    echo -e "${GREEN}║                                                          ║${NC}"
    echo -e "${GREEN}║  Next: Run the audit                                     ║${NC}"
    echo -e "${GREEN}║    ./audit/audit.sh                                      ║${NC}"
    echo -e "${GREEN}║                                                          ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
}

main() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║       K8s Secrets Audit Toolkit — Setup                 ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_prerequisites
    create_kind_cluster
    install_vault
    configure_vault
    install_vso
    deploy_sample_app
    print_summary
}

main "$@"
