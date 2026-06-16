#!/usr/bin/env bash
# Apply Grafana public edge: GSM → K8s secrets → oauth2-proxy → Ingress.
#
# Usage:
#   ./deploy/guardrailstudio/scripts/apply-grafana-edge.sh dev
#
# Secret source (first match):
#   1. GRAFANA_EDGE_JSON_FILE — pre-fetched JSON (CI bootstrap SA)
#   2. gcloud Secret Manager — netra-grafana-edge-{env} in the env GCP project
#   3. SKIP_GRAFANA_EDGE_SECRETS=true — reuse existing K8s secrets in observability
#
# JSON keys (see deploy/guardrailstudio/examples/netra-grafana-edge-secret.example.json):
#   google_client_id, google_client_secret, superadmin_emails (newline-separated or JSON array)

set -euo pipefail

ENV="${1:-}"
case "$ENV" in
  dev)
    PROJECT="${GCP_PROJECT:-synapse6ai-dev}"
    OVERLAY=deploy/guardrailstudio/dev
    GRAFANA_HOST=obs-dev.instantevidence.ai
    TLS_CERT_NAME=netra-grafana-tls-dev
    GSM_SECRET="${NETRA_GRAFANA_EDGE_GSM:-netra-grafana-edge-dev}"
    ;;
  stg)
    PROJECT="${GCP_PROJECT:-synapse6ai-stg}"
    OVERLAY=deploy/guardrailstudio/stg
    GRAFANA_HOST=obs-stg.instantevidence.ai
    TLS_CERT_NAME=netra-grafana-tls-stg
    GSM_SECRET="${NETRA_GRAFANA_EDGE_GSM:-netra-grafana-edge-stg}"
    ;;
  prod)
    PROJECT="${GCP_PROJECT:-synapse6-prod}"
    OVERLAY=deploy/guardrailstudio/prod
    GRAFANA_HOST=obs.instantevidence.ai
    TLS_CERT_NAME=netra-grafana-tls-prod
    GSM_SECRET="${NETRA_GRAFANA_EDGE_GSM:-netra-grafana-edge-prod}"
    ;;
  *)
    echo "usage: $0 dev|stg|prod" >&2
    exit 1
    ;;
esac

NS="${NETRA_NAMESPACE:-observability}"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
REDIRECT_URL="https://${GRAFANA_HOST}/oauth2/callback"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

require kubectl
require jq

load_edge_json() {
  if [[ -n "${GRAFANA_EDGE_JSON_FILE:-}" && -f "${GRAFANA_EDGE_JSON_FILE}" ]]; then
    cat "${GRAFANA_EDGE_JSON_FILE}"
    return 0
  fi
  if [[ "${SKIP_GRAFANA_EDGE_SECRETS:-false}" == "true" ]]; then
    return 1
  fi
  require gcloud
  gcloud secrets versions access latest \
    --secret="$GSM_SECRET" \
    --project="$PROJECT"
}

ensure_namespace() {
  kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
}

sync_secrets_from_json() {
  local json="$1"
  local client_id client_secret emails

  client_id="$(echo "$json" | jq -r '.google_client_id // .client_id // .["client-id"] // empty')"
  client_secret="$(echo "$json" | jq -r '.google_client_secret // .client_secret // .["client-secret"] // empty')"
  if [[ -z "$client_id" || -z "$client_secret" ]]; then
    die "Grafana edge JSON must include google_client_id and google_client_secret"
  fi

  if echo "$json" | jq -e '.superadmin_emails | type == "array"' >/dev/null 2>&1; then
    emails="$(echo "$json" | jq -r '.superadmin_emails[]')"
  else
    emails="$(echo "$json" | jq -r '.superadmin_emails // .emails_txt // .["emails.txt"] // empty')"
  fi
  if [[ -z "$emails" ]]; then
    die "Grafana edge JSON must include superadmin_emails (string or array)"
  fi

  say "Syncing Kubernetes secrets in ${NS}"
  kubectl create secret generic grafana-google-oauth \
    --namespace="$NS" \
    --from-literal=client-id="$client_id" \
    --from-literal=client-secret="$client_secret" \
    --dry-run=client -o yaml | kubectl apply -f -

  printf '%s\n' "$emails" | kubectl create secret generic grafana-superadmin-emails \
    --namespace="$NS" \
    --from-file=emails.txt=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic grafana-oauth2-env \
    --namespace="$NS" \
    --from-literal=redirect-url="$REDIRECT_URL" \
    --dry-run=client -o yaml | kubectl apply -f -
}

verify_k8s_secrets_exist() {
  local name
  for name in grafana-google-oauth grafana-superadmin-emails grafana-oauth2-env; do
    kubectl get secret "$name" -n "$NS" >/dev/null 2>&1 \
      || die "missing secret ${name} in ${NS} (create GSM ${GSM_SECRET} or set SKIP_GRAFANA_EDGE_SECRETS=false)"
  done
}

wait_ingress_ip() {
  local ip="" elapsed=0 max=180
  say "Waiting for Ingress ${GRAFANA_HOST} load balancer IP"
  while (( elapsed < max )); do
    ip="$(kubectl get ingress netra-grafana -n "$NS" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$ip" ]] && { echo "  ${ip}"; echo "$ip"; return 0; }
    sleep 5
    elapsed=$((elapsed + 5))
  done
  die "Ingress netra-grafana has no loadBalancer IP after ${max}s"
}

check_dns() {
  local ip="$1"
  local resolved=""
  if command -v dig >/dev/null 2>&1; then
    resolved="$(dig +short "$GRAFANA_HOST" A 2>/dev/null | tail -1 || true)"
  elif command -v getent >/dev/null 2>&1; then
    resolved="$(getent ahostsv4 "$GRAFANA_HOST" 2>/dev/null | awk '{print $1; exit}' || true)"
  fi
  if [[ -z "$resolved" ]]; then
    warn "Could not resolve ${GRAFANA_HOST} — create DNS A record → ${ip} for TLS"
    return 0
  fi
  if [[ "$resolved" == "$ip" ]]; then
    echo "  DNS OK: ${GRAFANA_HOST} → ${ip}"
  else
    warn "DNS mismatch: ${GRAFANA_HOST} resolves to ${resolved}, ingress IP is ${ip}"
  fi
}

wait_tls_certificate() {
  if ! kubectl get certificate "$TLS_CERT_NAME" -n "$NS" >/dev/null 2>&1; then
    warn "Certificate ${TLS_CERT_NAME} not created yet (cert-manager may still be reconciling)"
    return 0
  fi
  if kubectl wait --for=condition=Ready "certificate/${TLS_CERT_NAME}" \
    -n "$NS" --timeout=120s >/dev/null 2>&1; then
    echo "  TLS certificate ${TLS_CERT_NAME} Ready"
  else
    warn "Certificate ${TLS_CERT_NAME} not Ready — ensure DNS points to ingress IP for Let's Encrypt"
  fi
}

cd "$REPO_ROOT"
ensure_namespace

edge_json=""
if edge_json="$(load_edge_json 2>/dev/null)"; then
  sync_secrets_from_json "$edge_json"
else
  say "Using existing Kubernetes Grafana edge secrets"
  verify_k8s_secrets_exist
  kubectl create secret generic grafana-oauth2-env \
    --namespace="$NS" \
    --from-literal=redirect-url="$REDIRECT_URL" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

say "Applying oauth2-proxy"
kubectl apply -f deploy/guardrailstudio/manifests/grafana-oauth2-proxy.yaml

say "Applying Grafana ingress (${GRAFANA_HOST})"
kubectl apply -f "${OVERLAY}/grafana-ingress.yaml"

say "Waiting for oauth2-proxy rollout"
kubectl rollout status deployment/grafana-oauth2-proxy -n "$NS" --timeout=5m

ingress_ip="$(wait_ingress_ip)"
check_dns "$ingress_ip"
wait_tls_certificate

say "Grafana edge applied"
cat <<EOF

  URL:      https://${GRAFANA_HOST}/
  OAuth:    ${REDIRECT_URL}
  Ingress:  ${ingress_ip}  (A record for ${GRAFANA_HOST})

EOF
