#!/usr/bin/env bash
set -euo pipefail

export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:-root}"
NAMESPACE="secrets-audit-demo"

vault secrets enable -path=secret kv-v2 2>/dev/null || true

vault kv put secret/demo/db \
    username="appuser" \
    password="S3cretP@ssw0rd-2027!" \
    host="postgres.${NAMESPACE}.svc.cluster.local" \
    port="5432" \
    dbname="appdb"

vault kv put secret/demo/app \
    api_key="ak_live_7f3d2e1a9b8c4d5e6f7a8b9c0d1e2f3a" \
    jwt_secret="jwt-hmac-secret-key-do-not-share" \
    session_secret="sess_k3y_r4nd0m_v4lu3"

vault policy write demo-app - <<EOF
path "secret/data/demo/db" {
  capabilities = ["read"]
}
path "secret/data/demo/app" {
  capabilities = ["read"]
}
path "secret/metadata/demo/*" {
  capabilities = ["read", "list"]
}
EOF

vault auth enable kubernetes 2>/dev/null || true

K8S_HOST=$(kubectl config view --raw --minify --output='jsonpath={.clusters[0].cluster.server}')
K8S_CA_CERT=$(kubectl config view --raw --minify --output='jsonpath={.clusters[0].cluster.certificate-authority-data}' | base64 -d)

SA_SECRET=$(kubectl get sa -n "$NAMESPACE" default -o jsonpath='{.secrets[0].name}' 2>/dev/null || echo "")
if [[ -z "$SA_SECRET" ]]; then
    kubectl create serviceaccount vault-auth -n "$NAMESPACE" 2>/dev/null || true

    cat <<TOKENEOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-token
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
TOKENEOF

    sleep 3
    SA_JWT=$(kubectl get secret vault-auth-token -n "$NAMESPACE" -o jsonpath='{.data.token}' | base64 -d)
else
    SA_JWT=$(kubectl get secret "$SA_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.token}' | base64 -d)
fi

vault write auth/kubernetes/config \
    kubernetes_host="$K8S_HOST" \
    kubernetes_ca_cert="$K8S_CA_CERT" \
    token_reviewer_jwt="$SA_JWT" \
    disable_local_ca_jwt="true"

vault write auth/kubernetes/role/demo-app \
    bound_service_account_names="default,vault-auth,webapp-sa" \
    bound_service_account_namespaces="$NAMESPACE" \
    policies="demo-app" \
    ttl="1h"

echo "Vault configured:"
echo "  - KV secrets at secret/demo/db and secret/demo/app"
echo "  - Policy: demo-app (read access to demo secrets)"
echo "  - K8s auth: role 'demo-app' bound to namespace '$NAMESPACE'"
