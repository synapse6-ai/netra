#!/usr/bin/env bash
# Port-forward Netra UI services to localhost.
#
# Usage:
#   ./scripts/port-forward.sh                    # forward grafana only
#   ./scripts/port-forward.sh all                # forward all UIs
#   ./scripts/port-forward.sh grafana prom       # subset by name
#
# Targets:
#   grafana       -> http://localhost:3000
#   prom(etheus)  -> http://localhost:9090
#   am|alert      -> http://localhost:9093
#   loki          -> http://localhost:3100
#   tempo         -> http://localhost:3200

set -euo pipefail

NS=observability

declare -A TARGETS=(
  [grafana]="svc/netra-kps-grafana 3000:80"
  [prometheus]="svc/netra-kps-prometheus 9090:9090"
  [alertmanager]="svc/netra-kps-alertmanager 9093:9093"
  [loki]="svc/netra-loki 3100:3100"
  [tempo]="svc/netra-tempo 3200:3200"
)

declare -A ALIASES=(
  [prom]=prometheus
  [am]=alertmanager
  [alert]=alertmanager
)

resolve() {
  local key="$1"
  echo "${ALIASES[$key]:-$key}"
}

pids=()
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM

selection=()
if [[ $# -eq 0 ]]; then
  selection=(grafana)
elif [[ "$1" == "all" ]]; then
  selection=("${!TARGETS[@]}")
else
  for arg in "$@"; do
    selection+=("$(resolve "$arg")")
  done
fi

for s in "${selection[@]}"; do
  spec="${TARGETS[$s]:-}"
  if [[ -z "$spec" ]]; then
    echo "unknown target: $s" >&2
    exit 1
  fi
  # shellcheck disable=SC2086
  kubectl -n "$NS" port-forward $spec >/dev/null 2>&1 &
  pids+=("$!")
  printf '  %-12s -> %s\n' "$s" "${spec##* }"
done

echo
echo "Port-forwards running. Ctrl+C to stop."
wait
