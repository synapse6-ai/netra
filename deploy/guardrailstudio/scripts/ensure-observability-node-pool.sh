#!/usr/bin/env bash
# Ensure a dedicated observability node pool exists (GuardrailStudio dev/stg/prod).
#
# Creates a tainted pool labelled workload=observability so Netra and key-stack
# app pods do not share a node. Always removes the label from app pool nodes
# (single-node bootstrap leftover) and waits for Ready observability nodes.
#
# Usage:
#   ./deploy/guardrailstudio/scripts/ensure-observability-node-pool.sh dev
#   SKIP_OBSERVABILITY_POOL_CREATE=true ./deploy/guardrailstudio/scripts/ensure-observability-node-pool.sh dev
#
# Env overrides:
#   PROJECT, CLUSTER, ZONE, POOL, MACHINE_TYPE, DISK_SIZE_GB, NUM_NODES
#   SKIP_OBSERVABILITY_POOL_CREATE — skip gcloud create only (unlabel/wait always run)
#   SKIP_OBSERVABILITY_POOL — legacy alias for SKIP_OBSERVABILITY_POOL_CREATE

set -euo pipefail

ENV="${1:-dev}"
case "$ENV" in
  dev)
    PROJECT="${PROJECT:-synapse6ai-dev}"
    CLUSTER="${CLUSTER:-guardrailstudio-dev}"
    ZONE="${ZONE:-us-central1-a}"
    POOL="${POOL:-guardrailstudio-dev-observability-pool}"
    ;;
  stg)
    PROJECT="${PROJECT:-synapse6ai-stg}"
    CLUSTER="${CLUSTER:-guardrailstudio-stg}"
    ZONE="${ZONE:-us-central1-a}"
    POOL="${POOL:-guardrailstudio-stg-observability-pool}"
    ;;
  prod)
    PROJECT="${PROJECT:-synapse6-prod}"
    CLUSTER="${CLUSTER:-guardrailstudio-prod}"
    ZONE="${ZONE:-us-central1-a}"
    POOL="${POOL:-guardrailstudio-prod-observability-pool}"
    NUM_NODES="${NUM_NODES:-2}"
    ;;
  *)
    echo "usage: $0 dev|stg|prod" >&2
    exit 1
    ;;
esac

MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"
DISK_SIZE_GB="${DISK_SIZE_GB:-100}"
NUM_NODES="${NUM_NODES:-1}"
TAINT="${TAINT:-workload=observability:NoSchedule}"
SKIP_OBSERVABILITY_POOL_CREATE="${SKIP_OBSERVABILITY_POOL_CREATE:-false}"
if [[ "${SKIP_OBSERVABILITY_POOL:-false}" == "true" ]]; then
  SKIP_OBSERVABILITY_POOL_CREATE=true
fi

configure_kubectl() {
  gcloud container clusters get-credentials "$CLUSTER" \
    --zone="$ZONE" \
    --project="$PROJECT"
  local ctx
  ctx="$(kubectl config current-context)"
  if [[ "$ctx" != *"$CLUSTER"* ]]; then
    echo "error: kubectl context '${ctx}' does not match cluster '${CLUSTER}'" >&2
    exit 1
  fi
}

preflight_iam() {
  if ! gcloud container node-pools list \
    --cluster="$CLUSTER" --zone="$ZONE" --project="$PROJECT" --limit=1 &>/dev/null; then
    echo "error: cannot list node pools on ${CLUSTER} — deploy SA needs roles/container.admin" >&2
    exit 1
  fi
}

pool_exists() {
  gcloud container node-pools describe "$POOL" \
    --cluster="$CLUSTER" --zone="$ZONE" --project="$PROJECT" &>/dev/null
}

create_pool_if_needed() {
  if [[ "$SKIP_OBSERVABILITY_POOL_CREATE" == "true" ]]; then
    echo "Skipping observability pool create (SKIP_OBSERVABILITY_POOL_CREATE=true)."
    return 0
  fi
  if pool_exists; then
    echo "Observability node pool ${POOL} already exists."
    return 0
  fi
  echo "Creating observability node pool ${POOL} (${MACHINE_TYPE}, ${NUM_NODES} node(s))..."
  local err
  err="$(mktemp)"
  if ! gcloud container node-pools create "$POOL" \
    --cluster="$CLUSTER" \
    --zone="$ZONE" \
    --project="$PROJECT" \
    --machine-type="$MACHINE_TYPE" \
    --disk-type=pd-balanced \
    --disk-size="$DISK_SIZE_GB" \
    --num-nodes="$NUM_NODES" \
    --node-labels="workload=observability,env=${ENV}" \
    --node-taints="$TAINT" \
    --tags="guardrailstudio,${ENV},observability" 2>"$err"; then
    if grep -qiE 'already exists|Already exists' "$err"; then
      echo "Observability node pool ${POOL} already exists (concurrent create)."
    else
      cat "$err" >&2
      rm -f "$err"
      exit 1
    fi
  fi
  rm -f "$err"
}

wait_observability_nodes() {
  echo "Waiting for observability node(s) to become Ready..."
  kubectl wait --for=condition=Ready node -l workload=observability --timeout=600s
}

unlabel_app_nodes() {
  while IFS= read -r node; do
    [[ -z "$node" ]] && continue
    if kubectl get node "$node" -o jsonpath='{.metadata.labels.workload}' 2>/dev/null | grep -q observability; then
      pool=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.cloud\.google\.com/gke-nodepool}' 2>/dev/null || true)
      if [[ "$pool" != "$POOL" ]]; then
        echo "Removing workload=observability from app node ${node} (pool=${pool})"
        kubectl label node "$node" workload- --overwrite
      fi
    fi
  done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
}

verify_observability_scheduling() {
  local ready tainted
  ready=$(kubectl get nodes -l workload=observability --no-headers 2>/dev/null \
    | awk '$2 == "Ready" { c++ } END { print c + 0 }')
  if [[ "${ready:-0}" -lt "${NUM_NODES:-1}" ]]; then
    echo "error: expected >= ${NUM_NODES} Ready observability node(s), got ${ready:-0}" >&2
    kubectl get nodes -L workload,cloud.google.com/gke-nodepool
    exit 1
  fi
  tainted=$(kubectl get nodes -l workload=observability \
    -o jsonpath='{range .items[*]}{range .spec.taints[*]}{.key}:{.value}{"\n"}{end}{end}' 2>/dev/null \
    | grep -c '^workload:observability$' || true)
  if [[ "${tainted:-0}" -lt 1 ]]; then
    echo "warning: observability node(s) missing workload=observability:NoSchedule taint — verify pool ${POOL}" >&2
  fi
  echo "Observability scheduling ready: ${ready} node(s) with workload=observability + taint ${TAINT}"
  kubectl get nodes -L workload,cloud.google.com/gke-nodepool -l workload=observability
}

configure_kubectl
preflight_iam
create_pool_if_needed
wait_observability_nodes
unlabel_app_nodes
verify_observability_scheduling
