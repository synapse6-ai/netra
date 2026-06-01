#!/usr/bin/env bash
# Netra observability uninstall.
#
# Removes Helm releases and dashboard ConfigMaps. PVCs and object-storage
# buckets are kept by default so we do not silently lose data.
#
# Usage:
#   ./scripts/uninstall.sh                     # keep PVCs, namespace, secret
#   PURGE_PVCS=1 ./scripts/uninstall.sh        # also delete observability PVCs
#   ./scripts/uninstall.sh --purge-all         # PVCs + namespace + Grafana secret
#
# Object-storage buckets are NEVER deleted by this script.

set -euo pipefail

NS=observability
PURGE_PVCS="${PURGE_PVCS:-0}"
PURGE_ALL=0

for arg in "$@"; do
  case "$arg" in
    --purge-all) PURGE_ALL=1; PURGE_PVCS=1 ;;
    -h|--help)
      echo "Usage: $0 [--purge-all]"
      echo "  PURGE_PVCS=1  also delete PVCs in $NS"
      echo "  --purge-all   PVCs + namespace + netra-grafana-admin secret"
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 1
  }
}

require kubectl
require helm

releases=(
  netra-blackbox
  netra-otel-collector
  netra-tempo
  netra-alloy
  netra-loki
  netra-kps
)

for r in "${releases[@]}"; do
  if helm status "$r" -n "$NS" >/dev/null 2>&1; then
    say "Uninstalling $r"
    helm uninstall "$r" -n "$NS"
  else
    echo "skip: $r is not installed"
  fi
done

say "Removing dashboard ConfigMaps"
kubectl delete configmap -n "$NS" -l grafana_dashboard=1,app.kubernetes.io/part-of=netra --ignore-not-found

say "Removing Netra-owned manifests"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
kubectl delete -n "$NS" -f "$REPO_ROOT/manifests/networkpolicies/" --ignore-not-found
kubectl delete -n "$NS" -f "$REPO_ROOT/manifests/grafana/datasources-configmap.yaml" --ignore-not-found
kubectl delete -n "$NS" -f "$REPO_ROOT/manifests/prometheus/prometheusrules/" --ignore-not-found
kubectl delete -n "$NS" -f "$REPO_ROOT/manifests/prometheus/servicemonitors/" --ignore-not-found
kubectl delete -n "$NS" -f "$REPO_ROOT/manifests/blackbox/probes-configmap.yaml" --ignore-not-found
kubectl delete -n "$NS" -f "$REPO_ROOT/manifests/node-scheduling.yaml" --ignore-not-found

if [[ "$PURGE_PVCS" == "1" ]]; then
  say "Deleting observability PVCs"
  kubectl delete pvc -n "$NS" --all --ignore-not-found
else
  echo
  echo "PVCs preserved. To remove them later:"
  echo "  PURGE_PVCS=1 ./scripts/uninstall.sh"
fi

if [[ "$PURGE_ALL" == "1" ]]; then
  say "Deleting Grafana admin Secret"
  kubectl delete secret -n "$NS" netra-grafana-admin --ignore-not-found
  say "Deleting namespace $NS"
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
fi

echo
echo "Object-storage buckets are NEVER deleted by this script."
echo "If you really want to drop bucket data, do it through your cloud console."
echo
echo "Orphan resources (removed manually if needed):"
echo "  - Namespace '$NS' (kept unless --purge-all)"
echo "  - Prometheus Operator CRDs (cluster-scoped, installed by netra-kps)"
echo "  - GCS buckets and Workload Identity bindings (cloud console)"
echo
echo "Full teardown:"
echo "  ./scripts/uninstall.sh --purge-all"
