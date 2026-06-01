#!/usr/bin/env bash
# Install Synapse6 observability agents on an app GKE cluster.
#
# Required environment:
#   K8S_CLUSTER              guardrailstudio-stg | -dev | -prod
#   ENVIRONMENT              stage | dev | prod
#   CENTRAL_OTEL_ENDPOINT     otel.obs.internal.synapse6.ai:4317
#   CENTRAL_LOKI_URL         http://loki.obs.internal.synapse6.ai:3100/loki/api/v1/push
#   CENTRAL_PROM_REMOTE_WRITE http://prom.obs.internal.synapse6.ai:9090/api/v1/write
#   INGEST_TOKEN             same as netra-ingest-auth on central cluster
#
# Usage (stg example):
#   export K8S_CLUSTER=guardrailstudio-stg
#   export ENVIRONMENT=stage
#   export CENTRAL_OTEL_ENDPOINT=10.x.x.x:4317
#   export CENTRAL_LOKI_URL=http://10.x.x.x:3100/loki/api/v1/push
#   export CENTRAL_PROM_REMOTE_WRITE=http://10.x.x.x:9090/api/v1/write
#   export INGEST_TOKEN='...'
#   ./deploy/synapse6/scripts/install-agents.sh

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
AGENTS="$REPO_ROOT/deploy/synapse6/agents"
NS=observability
TMPFILES=()

cleanup() {
  for f in "${TMPFILES[@]:-}"; do [[ -f "$f" ]] && rm -f "$f"; done
}
trap cleanup EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }
}
require kubectl
require helm
require envsubst

die() { echo "error: $*" >&2; exit 1; }

[[ -n "${K8S_CLUSTER:-}" ]]       || die "set K8S_CLUSTER"
[[ -n "${ENVIRONMENT:-}" ]]       || die "set ENVIRONMENT"
[[ -n "${CENTRAL_OTEL_ENDPOINT:-}" ]] || die "set CENTRAL_OTEL_ENDPOINT"
[[ -n "${CENTRAL_LOKI_URL:-}" ]]  || die "set CENTRAL_LOKI_URL"
[[ -n "${CENTRAL_PROM_REMOTE_WRITE:-}" ]] || die "set CENTRAL_PROM_REMOTE_WRITE"
[[ -n "${INGEST_TOKEN:-}" ]]      || die "set INGEST_TOKEN"

export K8S_CLUSTER ENVIRONMENT CENTRAL_OTEL_ENDPOINT CENTRAL_LOKI_URL CENTRAL_PROM_REMOTE_WRITE

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "Synapse6 agents on $(kubectl config current-context)"
echo "  cluster:      $K8S_CLUSTER"
echo "  environment:  $ENVIRONMENT"

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

INGEST_SECRET_FILE="$(mktemp)"
TMPFILES+=("$INGEST_SECRET_FILE")
printf 'token=%s\n' "$INGEST_TOKEN" > "$INGEST_SECRET_FILE"
kubectl create secret generic synapse6-ingest-auth \
  --namespace="$NS" \
  --from-env-file="$INGEST_SECRET_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

ALLOY_CONFIG="$(mktemp)"
OTEL_VALUES="$(mktemp)"
TMPFILES+=("$ALLOY_CONFIG" "$OTEL_VALUES")

envsubst '${K8S_CLUSTER} ${ENVIRONMENT} ${CENTRAL_LOKI_URL} ${CENTRAL_PROM_REMOTE_WRITE}' \
  < "$AGENTS/alloy/config.alloy" > "$ALLOY_CONFIG"

envsubst '${K8S_CLUSTER} ${ENVIRONMENT} ${CENTRAL_OTEL_ENDPOINT}' \
  < "$AGENTS/otel-collector/values.yaml" > "$OTEL_VALUES"

say "Installing Alloy agent (logs + metrics)"
helm upgrade --install synapse6-agent-alloy grafana/alloy \
  --namespace "$NS" \
  --version 1.8.2 \
  --values "$AGENTS/alloy/values.yaml" \
  --set-file alloy.configMap.content="$ALLOY_CONFIG" \
  --wait

say "Installing OTel agent (traces)"
helm upgrade --install synapse6-agent-otel open-telemetry/opentelemetry-collector \
  --namespace "$NS" \
  --version 0.158.0 \
  --values "$OTEL_VALUES" \
  --wait

say "Agents installed."
echo "  Apps should send OTLP to: synapse6-agent-otel.$NS.svc.cluster.local:4317"
echo "  Pod labels: environment=$ENVIRONMENT, team, app.kubernetes.io/name"
echo
"$REPO_ROOT/deploy/synapse6/scripts/verify-synapse6-agents.sh"
