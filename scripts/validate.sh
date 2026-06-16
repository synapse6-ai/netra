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
warn() { printf '  \033[1;33m[warn]\033[0m %s\n' "$*"; }
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
  values/cluster.yaml \
  values/kube-prometheus-stack/values.yaml \
  values/loki/values.yaml \
  values/alloy/values.yaml \
  values/alloy/config.alloy \
  values/tempo/values.yaml \
  values/otel-collector/values.yaml \
  values/blackbox-exporter/values.yaml
do
  if [[ -s "$REPO_ROOT/$f" ]]; then ok "$f"; else fail "missing $f"; fi
done

# --- Brand assets -----------------------------------------------------
section "brand/"
for f in \
  brand/README.md \
  brand/netra-symbol.svg \
  brand/netra-symbol-white.svg \
  brand/netra-logo-horizontal.svg \
  brand/netra-logo-stacked.svg \
  brand/netra-icon.svg \
  brand/favicon.svg \
  brand/social-preview.svg \
  brand/netra-logo-horizontal.png \
  brand/netra-logo-stacked.png \
  brand/netra-symbol.png \
  brand/netra-icon.png \
  brand/favicon.png \
  brand/social-preview.png
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
  manifests/networkpolicies/ingest.yaml \
  manifests/alertmanager/receivers-secret.example.yaml
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

# --- install.sh stock path (no customer coupling) ---------------------
section "install.sh stock path"
if grep -q 'synapse6' "$REPO_ROOT/scripts/install.sh" 2>/dev/null; then
  fail "install.sh contains synapse6-specific strings"
else
  ok "install.sh has no synapse6-specific strings"
fi
for hook in NETRA_VALUES_OVERLAY NETRA_SKIP_CLUSTER_LABEL NETRA_NETWORKPOLICIES_DIR; do
  if grep -q "$hook" "$REPO_ROOT/scripts/install.sh"; then ok "hook documented: $hook"; else fail "missing hook: $hook"; fi
done

# --- deploy/synapse6 bundle (optional) --------------------------------
section "deploy/synapse6/"
SYNAPSE6="$REPO_ROOT/deploy/synapse6"
if [[ -d "$SYNAPSE6" ]]; then
  for s in scripts/install-central.sh scripts/install-agents.sh scripts/bootstrap-gcp.sh \
           scripts/verify-synapse6-central.sh scripts/verify-synapse6-agents.sh; do
    if bash -n "$SYNAPSE6/$s" 2>/dev/null; then ok "$s (bash -n)"; else fail "$s (bash -n)"; fi
  done
  if [[ -d "$SYNAPSE6/central/extras" ]]; then ok "central/extras/"; else fail "missing central/extras/"; fi
  if [[ -d "$SYNAPSE6/central/manifests/networkpolicies" ]]; then ok "central/manifests/networkpolicies/"; else fail "missing networkpolicies/"; fi
  if [[ -s "$SYNAPSE6/docs/central-observability.md" ]]; then
    ok "docs/central-observability.md"
  else
    fail "missing deploy/synapse6/docs/central-observability.md"
  fi
  if grep -qr 'REPLACE' "$SYNAPSE6/central/manifests/networkpolicies/" 2>/dev/null; then
    warn "networkpolicies/ has REPLACE placeholders (expected until prod CIDRs set)"
  else
    ok "networkpolicies/ CIDRs configured"
  fi
  if grep -q 'INGEST_AUTH_TOKEN' "$SYNAPSE6/central/alloy/config.alloy" 2>/dev/null; then
    ok "central Alloy Faro → OTel bearer auth wired"
  else
    fail "central Alloy missing INGEST_AUTH_TOKEN on OTel exporter"
  fi
  shopt -s nullglob
  for f in "$SYNAPSE6"/dashboards/*.json; do
    base="$(basename "$f")"
    if jq empty "$f" 2>/dev/null; then ok "dashboards/$base"; else fail "dashboards/$base (invalid JSON)"; fi
  done
  shopt -u nullglob
  if ! ls "$SYNAPSE6"/dashboards/*.json >/dev/null 2>&1; then
    fail "no dashboards in deploy/synapse6/dashboards/"
  fi
else
  ok "skipped (no deploy/synapse6 bundle)"
fi

# --- deploy/guardrailstudio bundle ------------------------------------
section "deploy/guardrailstudio/"
GS="$REPO_ROOT/deploy/guardrailstudio"
if [[ -d "$GS" ]]; then
  for env in dev stg prod; do
    for f in cluster.yaml loki.yaml tempo.yaml kube-prometheus-stack.yaml grafana-ingress.yaml; do
      if [[ -s "$GS/$env/$f" ]]; then
        ok "$env/$f"
      else
        fail "missing or empty $env/$f"
      fi
    done
    if grep -q 'iam.gke.io/gcp-service-account' "$GS/$env/loki.yaml" 2>/dev/null; then
      ok "$env/loki.yaml WI annotation"
    else
      fail "$env/loki.yaml missing WI annotation"
    fi
    if grep -q 'iam.gke.io/gcp-service-account' "$GS/$env/tempo.yaml" 2>/dev/null; then
      ok "$env/tempo.yaml WI annotation"
    else
      fail "$env/tempo.yaml missing WI annotation"
    fi
  done
  for s in scripts/bootstrap-gcp.sh \
    scripts/ensure-observability-node-pool.sh \
    scripts/install-env.sh; do
    if [[ -x "$GS/$s" ]]; then ok "$s (executable)"; else fail "$s (missing or not executable)"; fi
  done
  if [[ -s "$REPO_ROOT/.github/workflows/deploy-guardrailstudio-dev.yml" ]]; then
    ok ".github/workflows/deploy-guardrailstudio-dev.yml"
  else
    fail "missing .github/workflows/deploy-guardrailstudio-dev.yml"
  fi
  if [[ -s "$GS/manifests/grafana-oauth2-proxy.yaml" ]]; then
    ok "manifests/grafana-oauth2-proxy.yaml"
  else
    fail "missing manifests/grafana-oauth2-proxy.yaml"
  fi
else
  fail "missing deploy/guardrailstudio/"
fi

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

# --- PromQL rules (optional promtool) ---------------------------------
section "promtool (optional)"
if command -v promtool >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  for f in "$REPO_ROOT"/manifests/prometheus/prometheusrules/*.yaml; do
    rel="${f#$REPO_ROOT/}"
    tmp="$(mktemp)"
    if python3 - "$f" "$tmp" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh:
    doc = yaml.safe_load(fh)
with open(dst, "w") as out:
    yaml.dump(doc.get("spec", {}), out)
PY
    then
      if promtool check rules "$tmp" >/dev/null 2>&1; then
        ok "$rel"
      else
        fail "$rel (promtool check rules)"
      fi
    else
      fail "$rel (could not extract spec for promtool)"
    fi
    rm -f "$tmp"
  done
else
  ok "skipped (install promtool + python3-yaml for rule lint)"
fi

echo
if [[ "$EXIT" -eq 0 ]]; then
  echo "validate.sh: all local checks passed."
else
  echo "validate.sh: one or more checks failed."
fi
exit "$EXIT"
