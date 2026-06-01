#!/usr/bin/env bash
# Smoke-test Synapse6 central ingest after install-central.sh.
#
# Usage:
#   INGEST_TOKEN='...' ./deploy/synapse6/scripts/verify-synapse6-central.sh
#
# Requires kubectl context on the central observability cluster.

set -euo pipefail

NS=observability
EXIT=0

ok()   { printf '  \033[1;32m[ ok ]\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m[fail]\033[0m %s\n' "$*"; EXIT=1; }

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl required"
[[ -n "${INGEST_TOKEN:-}" ]] || die "set INGEST_TOKEN (same value as netra-ingest-auth)"

section() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

curl_pod() {
  local args=("$@")
  kubectl run "netra-verify-$$-${RANDOM}" \
    --namespace="$NS" \
    --restart=Never \
    --rm \
    --image=curlimages/curl:8.5.0 \
    --command -- \
    curl "${args[@]}"
}

http_code() {
  local url="$1"
  shift
  curl_pod -sS -o /dev/null -w '%{http_code}' "$@" "$url" 2>/dev/null || echo "000"
}

section "Gateway auth (in-cluster netra-ingest-gateway)"

code="$(http_code "http://netra-ingest-gateway.${NS}.svc.cluster.local:9090/api/v1/write" -X POST -d '')"
if [[ "$code" == "401" ]]; then
  ok "Prom remote_write rejects missing token (401)"
else
  fail "expected 401 without token on remote_write, got ${code}"
fi

code="$(http_code "http://netra-ingest-gateway.${NS}.svc.cluster.local:9090/api/v1/write" \
  -X POST -H "Authorization: Bearer ${INGEST_TOKEN}" -d '')"
if [[ "$code" == "200" || "$code" == "204" || "$code" == "400" ]]; then
  ok "Prom remote_write accepts bearer token (${code})"
else
  fail "expected 200/204/400 with token on remote_write, got ${code}"
fi

code="$(http_code "http://netra-ingest-gateway.${NS}.svc.cluster.local:3100/loki/api/v1/push" -X POST -d '{}')"
if [[ "$code" == "401" ]]; then
  ok "Loki push rejects missing token (401)"
else
  fail "expected 401 without token on Loki push, got ${code}"
fi

code="$(http_code "http://netra-ingest-gateway.${NS}.svc.cluster.local:3100/loki/api/v1/push" \
  -X POST -H "Authorization: Bearer ${INGEST_TOKEN}" -H 'Content-Type: application/json' -d '{"streams":[]}')"
if [[ "$code" != "401" ]]; then
  ok "Loki push accepts bearer token (${code})"
else
  fail "Loki push still 401 with token"
fi

section "Central workloads"

for dep in netra-ingest-gateway netra-otel-collector; do
  if kubectl get deploy -n "$NS" "$dep" >/dev/null 2>&1; then
    ready="$(kubectl get deploy -n "$NS" "$dep" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    if [[ "${ready:-0}" -ge 1 ]]; then
      ok "deployment/$dep ready (${ready} replicas)"
    else
      fail "deployment/$dep not ready"
    fi
  else
    fail "missing deployment/$dep"
  fi
done

for svc in netra-ingest-otel netra-ingest-loki netra-ingest-prometheus netra-ingest-faro; do
  if kubectl get svc -n "$NS" "$svc" >/dev/null 2>&1; then
    ok "service/$svc"
  else
    fail "missing service/$svc"
  fi
done

section "OTel bearer auth (in-cluster)"

code="$(http_code "http://netra-otel-collector.${NS}.svc.cluster.local:4318/v1/traces" -X POST -d '{}')"
if [[ "$code" == "401" || "$code" == "405" ]]; then
  ok "OTel rejects unauthenticated OTLP HTTP (${code})"
else
  fail "expected 401/405 without token on OTel HTTP, got ${code}"
fi

echo
if [[ "$EXIT" -eq 0 ]]; then
  echo "verify-synapse6-central.sh: all checks passed."
else
  echo "verify-synapse6-central.sh: one or more checks failed."
fi
exit "$EXIT"
