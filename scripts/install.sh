#!/usr/bin/env bash
# Netra observability install.
#
# Idempotent. Reapply at any time.
# Requirements: kubectl, helm, jq, envsubst (gettext).
#
# Usage:
#   ./scripts/install.sh
#   NETRA_CLUSTER=my-gke ./scripts/install.sh
#   SKIP_GCS_PREFLIGHT=1 ./scripts/install.sh   # non-GKE smoke tests only
#
# Pinned to current stable chart releases (2026-05-31):
#   kube-prometheus-stack 86.1.0 | loki 17.1.5 | alloy 1.8.2 | tempo 2.2.0
#   opentelemetry-collector 0.158.0 | prometheus-blackbox-exporter 11.9.1
#
# Loki + Tempo charts: grafana-community (grafana/helm-charts is GEL-only after Mar 2026).

set -euo pipefail

NS=observability
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES_DIR="$REPO_ROOT/values"
MANIFESTS_DIR="$REPO_ROOT/manifests"
DASHBOARDS_DIR="$REPO_ROOT/dashboards"
HELM_TIMEOUT="${HELM_TIMEOUT:-15m}"
TMPFILES=()

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup_tmp() {
  for f in "${TMPFILES[@]:-}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup_tmp EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 1
  }
}

require kubectl
require helm
require jq
require envsubst

resolve_cluster() {
  if [[ -n "${NETRA_CLUSTER:-}" ]]; then
    echo "$NETRA_CLUSTER"
    return
  fi
  if [[ -f "$VALUES_DIR/cluster.yaml" ]]; then
    awk '/^cluster:/ { print $2; exit }' "$VALUES_DIR/cluster.yaml" | tr -d '"'"'"
    return
  fi
  echo netra
}

preflight() {
  say "Preflight checks"

  local ready_nodes
  ready_nodes=$(kubectl get nodes -l workload=observability --no-headers 2>/dev/null \
    | awk '$2 == "Ready" { c++ } END { print c + 0 }')
  if [[ "${ready_nodes:-0}" -lt 1 ]]; then
    die "no Ready node with label workload=observability.

  Prepare a dedicated observability node pool first:
    kubectl label node <NODE> workload=observability --overwrite
    kubectl taint  node <NODE> workload=observability:NoSchedule --overwrite

  See manifests/node-scheduling.yaml"
  fi
  echo "  observability node pool: ${ready_nodes} Ready node(s)"

  if [[ "${SKIP_GCS_PREFLIGHT:-0}" != "1" ]]; then
    local wi_ok=0
    if grep -q 'iam.gke.io/gcp-service-account' "$VALUES_DIR/loki/values.yaml" 2>/dev/null; then
      wi_ok=1
    fi
    if grep -q 'iam.gke.io/gcp-service-account' "$VALUES_DIR/tempo/values.yaml" 2>/dev/null; then
      wi_ok=1
    fi
    if [[ "$wi_ok" -eq 0 ]]; then
      die "Loki/Tempo require GCS + GKE Workload Identity before install.

  1. Create GCS buckets (see docs/production-checklist.md)
  2. Set iam.gke.io/gcp-service-account on Loki/Tempo serviceAccount.annotations
     in values/loki/values.yaml and values/tempo/values.yaml

  For local/non-GCS smoke tests only: SKIP_GCS_PREFLIGHT=1 ./scripts/install.sh"
    fi
    echo "  GCS Workload Identity annotation present in values/"
  else
    warn "SKIP_GCS_PREFLIGHT=1 — Loki/Tempo may not persist data without GCS/WI"
  fi
}

write_cluster_overrides() {
  local cluster="$1"
  export NETRA_CLUSTER="$cluster"

  KPS_CLUSTER_OVERRIDE="$(mktemp)"
  OTEL_CLUSTER_OVERRIDE="$(mktemp)"
  ALLOY_CONFIG="$(mktemp)"
  TMPFILES+=("$KPS_CLUSTER_OVERRIDE" "$OTEL_CLUSTER_OVERRIDE" "$ALLOY_CONFIG")

  cat > "$KPS_CLUSTER_OVERRIDE" <<EOF
prometheus:
  prometheusSpec:
    externalLabels:
      cluster: ${cluster}
EOF

  cat > "$OTEL_CLUSTER_OVERRIDE" <<EOF
config:
  processors:
    resource/env:
      attributes:
        - key: cluster
          value: ${cluster}
          action: upsert
EOF

  envsubst '${NETRA_CLUSTER}' < "$VALUES_DIR/alloy/config.alloy" > "$ALLOY_CONFIG"
}

NETRA_CLUSTER="$(resolve_cluster)"
say "Cluster identity: ${NETRA_CLUSTER}"
write_cluster_overrides "$NETRA_CLUSTER"

preflight

# -------------------------------------------------------------------------
# 1. Helm repos
# -------------------------------------------------------------------------
say "Adding Helm repos"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add grafana              https://grafana.github.io/helm-charts             >/dev/null
helm repo add grafana-community    https://grafana-community.github.io/helm-charts   >/dev/null
helm repo add open-telemetry       https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null
helm repo update >/dev/null

# -------------------------------------------------------------------------
# 2. Namespace + base manifests
# -------------------------------------------------------------------------
say "Applying namespace"
kubectl apply -f "$MANIFESTS_DIR/namespace.yaml"
kubectl apply -f "$MANIFESTS_DIR/node-scheduling.yaml"

say "Ensuring Grafana admin Secret"
if ! kubectl get secret -n "$NS" netra-grafana-admin >/dev/null 2>&1; then
  require openssl
  kubectl create secret generic netra-grafana-admin \
    --namespace "$NS" \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 24)"
  echo "  created secret netra-grafana-admin (password is random — retrieve from the cluster)"
fi

# -------------------------------------------------------------------------
# 3. Helm releases
# -------------------------------------------------------------------------
say "Installing kube-prometheus-stack (netra-kps)"
helm upgrade --install netra-kps prometheus-community/kube-prometheus-stack \
  --namespace "$NS" \
  --version 86.1.0 \
  --values "$VALUES_DIR/kube-prometheus-stack/values.yaml" \
  --values "$KPS_CLUSTER_OVERRIDE" \
  --timeout "$HELM_TIMEOUT" \
  --wait

say "Installing Loki (netra-loki)"
helm upgrade --install netra-loki grafana-community/loki \
  --namespace "$NS" \
  --version 17.1.5 \
  --values "$VALUES_DIR/loki/values.yaml" \
  --timeout "$HELM_TIMEOUT" \
  --wait

say "Installing Alloy (netra-alloy)"
helm upgrade --install netra-alloy grafana/alloy \
  --namespace "$NS" \
  --version 1.8.2 \
  --values "$VALUES_DIR/alloy/values.yaml" \
  --set-file alloy.configMap.content="$ALLOY_CONFIG" \
  --timeout "$HELM_TIMEOUT" \
  --wait

say "Installing Tempo (netra-tempo)"
helm upgrade --install netra-tempo grafana-community/tempo \
  --namespace "$NS" \
  --version 2.2.0 \
  --values "$VALUES_DIR/tempo/values.yaml" \
  --timeout "$HELM_TIMEOUT" \
  --wait

say "Installing OpenTelemetry Collector (netra-otel-collector)"
helm upgrade --install netra-otel-collector open-telemetry/opentelemetry-collector \
  --namespace "$NS" \
  --version 0.158.0 \
  --values "$VALUES_DIR/otel-collector/values.yaml" \
  --values "$OTEL_CLUSTER_OVERRIDE" \
  --timeout "$HELM_TIMEOUT" \
  --wait

say "Installing blackbox_exporter (netra-blackbox)"
helm upgrade --install netra-blackbox prometheus-community/prometheus-blackbox-exporter \
  --namespace "$NS" \
  --version 11.9.1 \
  --values "$VALUES_DIR/blackbox-exporter/values.yaml" \
  --timeout "$HELM_TIMEOUT" \
  --wait

# -------------------------------------------------------------------------
# 4. Manifests: datasources, ServiceMonitors, Probes, PrometheusRules
# -------------------------------------------------------------------------
say "Applying datasources ConfigMap"
kubectl apply -f "$MANIFESTS_DIR/grafana/datasources-configmap.yaml"

say "Applying ServiceMonitors and blackbox Probes"
kubectl apply -f "$MANIFESTS_DIR/prometheus/servicemonitors/"

# Remove deprecated probe CRDs from earlier scaffold versions.
deprecated_probes=(
  netra-blackbox-frontend netra-blackbox-api-health netra-blackbox-api-ready
  netra-blackbox-opa-health netra-blackbox-frontend-dev netra-blackbox-frontend-stage
  netra-blackbox-frontend-prod netra-blackbox-api-health-dev netra-blackbox-api-health-stage
  netra-blackbox-api-health-prod netra-blackbox-api-ready-dev netra-blackbox-api-ready-stage
  netra-blackbox-api-ready-prod netra-blackbox-opa-health-dev netra-blackbox-opa-health-stage
  netra-blackbox-opa-health-prod
)
for p in "${deprecated_probes[@]}"; do
  kubectl delete probe -n "$NS" "$p" --ignore-not-found
done

say "Applying PrometheusRules"
kubectl apply -f "$MANIFESTS_DIR/prometheus/prometheusrules/"

say "Applying blackbox probe catalog (informational)"
kubectl apply -f "$MANIFESTS_DIR/blackbox/probes-configmap.yaml"

say "Applying NetworkPolicies"
kubectl apply -f "$MANIFESTS_DIR/networkpolicies/"

# -------------------------------------------------------------------------
# 5. Dashboards -> ConfigMaps (grafana_dashboard=1)
# -------------------------------------------------------------------------
say "Packaging dashboards/*.json into ConfigMaps"

expected_cms=()
shopt -s nullglob
for f in "$DASHBOARDS_DIR"/*.json; do
  base="$(basename "$f" .json)"
  cm_name="netra-dashboard-$base"
  expected_cms+=("$cm_name")

  jq empty "$f"

  title="$(jq -r '.title // ""' "$f")"
  if [[ "$title" == *" / "* ]]; then
    folder="$(echo "$title" | awk -F' / ' '{print $1" / "$2}')"
  else
    folder="Netra"
  fi

  kubectl create configmap "$cm_name" \
    --namespace "$NS" \
    --from-file="$base.json=$f" \
    --dry-run=client -o yaml | \
    kubectl label --local -f - \
      grafana_dashboard=1 \
      app.kubernetes.io/part-of=netra \
      --dry-run=client -o yaml | \
    kubectl annotate --local -f - \
      grafana_folder="$folder" \
      --dry-run=client -o yaml | \
    kubectl apply -f -
done
shopt -u nullglob

say "Removing stale dashboard ConfigMaps"
while IFS= read -r cm; do
  [[ -z "$cm" ]] && continue
  name="${cm#configmap/}"
  keep=0
  for e in "${expected_cms[@]}"; do
    if [[ "$name" == "$e" ]]; then keep=1; break; fi
  done
  if [[ "$keep" -eq 0 ]]; then
    kubectl delete configmap -n "$NS" "$name" --ignore-not-found
  fi
done < <(kubectl get configmap -n "$NS" \
  -l grafana_dashboard=1,app.kubernetes.io/part-of=netra \
  -o name 2>/dev/null || true)

say "Done. Run scripts/verify.sh (or scripts/verify.sh --deep) to check cluster state."
