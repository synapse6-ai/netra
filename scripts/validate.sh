#!/usr/bin/env bash
# Local lint for Netra. Runs without a cluster.
#
# Usage:
#   ./scripts/validate.sh
#
# Checks:
#   - dashboards/*.json parses with jq and has uid + title
#   - every required values/manifests file is present
#   - no committed placeholder secret/password-looking value carries a
#     real-looking secret (sniff test, not a substitute for code review)

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EXIT=0

ok()   { printf '  \033[1;32m[ ok ]\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m[fail]\033[0m %s\n' "$*"; EXIT=1; }
section() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 2
  }
}
require jq

# --- Required values --------------------------------------------------
section "values/"
for f in \
  values/kube-prometheus-stack/values.yaml \
  values/loki/values.yaml \
  values/alloy/values.yaml \
  values/tempo/values.yaml \
  values/otel-collector/values.yaml \
  values/blackbox-exporter/values.yaml
do
  if [[ -s "$REPO_ROOT/$f" ]]; then ok "$f"; else fail "missing $f"; fi
done

# --- Required manifests -----------------------------------------------
section "manifests/"
for f in \
  manifests/namespace.yaml \
  manifests/node-scheduling.yaml \
  manifests/grafana/datasources-configmap.yaml \
  manifests/prometheus/servicemonitors/python-api-servicemonitor.yaml \
  manifests/prometheus/servicemonitors/python-worker-servicemonitor.yaml \
  manifests/prometheus/servicemonitors/opa-servicemonitor.yaml \
  manifests/prometheus/servicemonitors/blackbox-probes.yaml \
  manifests/prometheus/prometheusrules/node-alerts.yaml \
  manifests/prometheus/prometheusrules/python-api-alerts.yaml \
  manifests/prometheus/prometheusrules/python-worker-alerts.yaml \
  manifests/prometheus/prometheusrules/opa-alerts.yaml \
  manifests/prometheus/prometheusrules/blackbox-alerts.yaml \
  manifests/prometheus/prometheusrules/observability-stack-alerts.yaml \
  manifests/blackbox/probes-configmap.yaml \
  manifests/networkpolicies/ingest.yaml
do
  if [[ -s "$REPO_ROOT/$f" ]]; then ok "$f"; else fail "missing $f"; fi
done

# --- Dashboards: JSON parses, has uid + title -------------------------
section "dashboards/*.json"
shopt -s nullglob
seen_uids=()
for f in "$REPO_ROOT/dashboards"/*.json; do
  rel="${f#$REPO_ROOT/}"
  if ! jq empty "$f" >/dev/null 2>&1; then
    fail "$rel: invalid JSON"
    continue
  fi
  uid=$(jq -r '.uid // ""'   "$f")
  title=$(jq -r '.title // ""' "$f")
  if [[ -z "$uid"   ]]; then fail "$rel: missing uid";   continue; fi
  if [[ -z "$title" ]]; then fail "$rel: missing title"; continue; fi
  for s in "${seen_uids[@]:-}"; do
    if [[ "$s" == "$uid" ]]; then fail "$rel: duplicate uid $uid"; fi
  done
  seen_uids+=("$uid")
  ok "$rel ($uid)"
done
shopt -u nullglob

required_dashboards=(
  kubernetes.json python-api.json python-workers.json opa.json
  nextjs-rum.json prometheus-health.json loki-health.json
  tempo-health.json alloy-health.json blackbox-health.json
)
for d in "${required_dashboards[@]}"; do
  if [[ -s "$REPO_ROOT/dashboards/$d" ]]; then
    ok "required dashboard present: $d"
  else
    fail "missing required dashboard: $d"
  fi
done

# --- Runbooks ---------------------------------------------------------
section "runbooks/"
required_runbooks=(
  node-not-ready.md node-disk-pressure.md pod-crashlooping.md
  python-api-high-5xx.md python-api-high-latency.md
  worker-queue-age-high.md worker-failures-high.md
  opa-latency-high.md opa-decision-errors.md
  blackbox-endpoint-down.md loki-ingestion-errors.md
  tempo-ingestion-errors.md alloy-down.md prometheus-storage-high.md
)
for r in "${required_runbooks[@]}"; do
  if [[ -s "$REPO_ROOT/runbooks/$r" ]]; then ok "$r"; else fail "missing $r"; fi
done

# --- Docs -------------------------------------------------------------
section "docs/"
for d in architecture.md datadog-migration.md app-integration.md \
         dashboards-alerts-in-git.md production-checklist.md; do
  if [[ -s "$REPO_ROOT/docs/$d" ]]; then ok "$d"; else fail "missing $d"; fi
done

# --- Placeholder secret sniff test ------------------------------------
section "secret/placeholder sniff test"

# Anything that looks like an AWS-style live key or a hardcoded password
# in a prod-critical field is treated as a failure.
suspicious=$(grep -RInE \
  -e 'AKIA[0-9A-Z]{16}' \
  -e 'aws_secret_access_key:\s*[A-Za-z0-9/+]{20,}' \
  -e 'password:\s*"[^"]*"\s*$' \
  --exclude-dir=.git \
  --exclude='*.md' \
  --exclude='validate.sh' \
  "$REPO_ROOT" 2>/dev/null || true)
if [[ -z "$suspicious" ]]; then
  ok "no committed secrets / real-looking creds found"
else
  fail "possible committed secrets:"
  echo "$suspicious" | sed 's/^/      /'
fi

echo
if [[ "$EXIT" -eq 0 ]]; then
  echo "validate.sh: all local checks passed."
else
  echo "validate.sh: one or more checks failed."
fi
exit "$EXIT"
