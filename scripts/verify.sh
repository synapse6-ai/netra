#!/usr/bin/env bash
# Netra in-cluster sanity check.
#
# Usage:
#   ./scripts/verify.sh
#
# Exits non-zero if any required object is missing or unhealthy.

set -uo pipefail   # not -e: we want to keep checking after a failure.

NS=observability
EXIT=0

ok()   { printf '  \033[1;32m[ ok ]\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m[fail]\033[0m %s\n' "$*"; EXIT=1; }

section() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

# --- Pods ---------------------------------------------------------------
section "Pods in $NS"
non_ready=$(kubectl get pods -n "$NS" \
  --no-headers 2>/dev/null \
  | awk '$3 != "Running" && $3 != "Completed" {print}')
if [[ -z "$non_ready" ]]; then
  ok "all pods Running/Completed"
else
  fail "non-ready pods:"
  echo "$non_ready" | sed 's/^/      /'
fi

# --- Services -----------------------------------------------------------
section "Services in $NS"
required_svcs=(
  netra-kps-grafana
  netra-kps-prometheus
  netra-kps-alertmanager
  netra-loki
  netra-tempo
  netra-otel-collector
  netra-blackbox
)
for svc in "${required_svcs[@]}"; do
  if kubectl get svc -n "$NS" "$svc" >/dev/null 2>&1; then
    ok "service $svc"
  else
    fail "missing service: $svc"
  fi
done

# --- Alloy DaemonSet ----------------------------------------------------
section "Alloy DaemonSet"
if kubectl get daemonset -n "$NS" netra-alloy >/dev/null 2>&1; then
  desired="$(kubectl get daemonset -n "$NS" netra-alloy -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
  ready="$(kubectl get daemonset -n "$NS" netra-alloy -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
  if [[ "$desired" -gt 0 && "$ready" == "$desired" ]]; then
    ok "Alloy DaemonSet $ready/$desired ready"
  else
    fail "Alloy DaemonSet $ready/$desired ready"
  fi
else
  fail "missing DaemonSet: netra-alloy"
fi

# --- ServiceMonitors ----------------------------------------------------
section "ServiceMonitors"
required_sm=(
  netra-python-api
  netra-python-worker
  netra-opa
)
for sm in "${required_sm[@]}"; do
  if kubectl get servicemonitor -n "$NS" "$sm" >/dev/null 2>&1; then
    ok "ServiceMonitor $sm"
  else
    fail "missing ServiceMonitor: $sm"
  fi
done

# --- Probes (blackbox) --------------------------------------------------
section "Probes (blackbox)"
required_probes=(
  netra-blackbox-grafana
  netra-blackbox-prometheus
  netra-blackbox-loki
  netra-blackbox-alertmanager
)
for p in "${required_probes[@]}"; do
  if kubectl get probe -n "$NS" "$p" >/dev/null 2>&1; then
    ok "Probe $p"
  else
    fail "missing Probe: $p"
  fi
done

# --- NetworkPolicies ----------------------------------------------------
section "NetworkPolicies"
for np in netra-loki-ingress netra-tempo-ingress netra-otel-collector-ingress; do
  if kubectl get networkpolicy -n "$NS" "$np" >/dev/null 2>&1; then
    ok "NetworkPolicy $np"
  else
    fail "missing NetworkPolicy: $np"
  fi
done

# --- PrometheusRules ----------------------------------------------------
section "PrometheusRules"
required_rules=(
  netra-node-alerts
  netra-python-api-alerts
  netra-python-worker-alerts
  netra-opa-alerts
  netra-blackbox-alerts
  netra-observability-stack-alerts
)
for r in "${required_rules[@]}"; do
  if kubectl get prometheusrule -n "$NS" "$r" >/dev/null 2>&1; then
    ok "PrometheusRule $r"
  else
    fail "missing PrometheusRule: $r"
  fi
done

# --- Dashboard ConfigMaps ----------------------------------------------
section "Dashboard ConfigMaps"
n=$(kubectl get configmap -n "$NS" \
  -l grafana_dashboard=1,app.kubernetes.io/part-of=netra \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$n" -ge 10 ]]; then
  ok "$n dashboard ConfigMaps (expected >= 10)"
else
  fail "only $n dashboard ConfigMaps (expected 10)"
fi

# --- Datasources -------------------------------------------------------
section "Grafana datasources ConfigMap"
if kubectl get configmap -n "$NS" netra-grafana-datasources >/dev/null 2>&1; then
  ok "netra-grafana-datasources present"
else
  fail "missing ConfigMap: netra-grafana-datasources"
fi

echo
if [[ "$EXIT" -eq 0 ]]; then
  echo "verify.sh: all checks passed."
else
  echo "verify.sh: one or more checks failed."
fi
exit "$EXIT"
