#!/usr/bin/env bash
# Label a node for Netra observability scheduling.
#
# install.sh preflight requires at least one Ready node with label workload=observability.
#
# Single-node clusters (dev): LABEL ONLY — do not taint the only node or app pods
# will have nowhere to schedule.
#
# Multi-node / dedicated pool: also apply the taint so app workloads stay off the
# observability node.
#
# Usage:
#   ./deploy/guardrailstudio/scripts/label-observability-node.sh
#   NODE=gke-... TAINT=true ./deploy/guardrailstudio/scripts/label-observability-node.sh

set -euo pipefail

TAINT="${TAINT:-false}"

if [[ -z "${NODE:-}" ]]; then
  # Portable node list (macOS ships bash 3.2 — no mapfile).
  nodes=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && nodes+=("$line")
  done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if [[ "${#nodes[@]}" -eq 0 ]]; then
    echo "error: no nodes found" >&2
    exit 1
  fi
  if [[ "${#nodes[@]}" -eq 1 ]]; then
    NODE="${nodes[0]}"
    if [[ "$TAINT" == "true" ]]; then
      echo "warning: single-node cluster — forcing TAINT=false (app pods need the node)" >&2
      TAINT=false
    fi
    echo "single-node cluster: using ${NODE} (label only)"
  else
    echo "Multiple nodes — set NODE= explicitly. Candidates:"
    printf '  %s\n' "${nodes[@]}"
    exit 1
  fi
fi

kubectl label node "$NODE" workload=observability --overwrite
echo "labeled ${NODE} workload=observability"

if [[ "$TAINT" == "true" ]]; then
  kubectl taint node "$NODE" workload=observability:NoSchedule --overwrite
  echo "tainted ${NODE} workload=observability:NoSchedule"
else
  echo "no taint applied (TAINT=true to add NoSchedule on multi-node pools)"
fi
