#!/usr/bin/env bash
# Smoke-test Synapse6 app-cluster agents after install-agents.sh.
#
# Usage:
#   ./deploy/synapse6/scripts/verify-synapse6-agents.sh

set -euo pipefail

NS=observability
EXIT=0

ok()   { printf '  \033[1;32m[ ok ]\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m[fail]\033[0m %s\n' "$*"; EXIT=1; }

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl required"

section() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

section "Agent DaemonSets"

for ds in synapse6-agent-alloy synapse6-agent-otel; do
  if kubectl get ds -n "$NS" "$ds" >/dev/null 2>&1; then
    desired="$(kubectl get ds -n "$NS" "$ds" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
    ready="$(kubectl get ds -n "$NS" "$ds" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
    if [[ "${desired:-0}" -gt 0 && "$ready" == "$desired" ]]; then
      ok "daemonset/$ds $ready/$desired ready"
    else
      fail "daemonset/$ds $ready/$desired ready"
    fi
  else
    fail "missing daemonset/$ds"
  fi
done

section "Local OTLP endpoint"

if kubectl get svc -n "$NS" synapse6-agent-otel >/dev/null 2>&1; then
  ok "service/synapse6-agent-otel"
  code=$(kubectl run "netra-agent-verify-$$-${RANDOM}" \
    --namespace="$NS" --restart=Never --rm \
    --image=curlimages/curl:8.5.0 --command -- \
    curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "http://synapse6-agent-otel.${NS}.svc.cluster.local:4318/v1/traces" \
    -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo "000")
  if [[ "$code" == "200" || "$code" == "405" || "$code" == "400" ]]; then
    ok "local OTel HTTP accepts POST (${code})"
  else
    fail "local OTel HTTP unexpected status ${code}"
  fi
else
  fail "missing service/synapse6-agent-otel"
fi

echo
if [[ "$EXIT" -eq 0 ]]; then
  echo "verify-synapse6-agents.sh: all checks passed."
else
  echo "verify-synapse6-agents.sh: one or more checks failed."
fi
exit "$EXIT"
