#!/usr/bin/env bash
# Netra in-cluster sanity check.
#
# Usage:
#   ./scripts/verify.sh           # existence + pod health
#   ./scripts/verify.sh --deep    # also query Prometheus + resource budget
#   ./scripts/verify.sh --edge    # oauth2-proxy, ingress, Grafana edge secrets
#
# Exits non-zero if any required object is missing or unhealthy.

set -uo pipefail

NS=observability
DEEP=0
EDGE=0
EXIT=0

for arg in "$@"; do
  case "$arg" in
    --deep) DEEP=1 ;;
    --edge) EDGE=1 ;;
    -h|--help)
      echo "Usage: $0 [--deep] [--edge]"
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[1;32m[ ok ]\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m[fail]\033[0m %s\n' "$*"; EXIT=1; }
warn() { printf '  \033[1;33m[warn]\033[0m %s\n' "$*"; }

section() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

# --- Pods ---------------------------------------------------------------
section "Pods in $NS"
non_ready=$(kubectl get pods -n "$NS" \
  --no-headers 2>/dev/null \
  | awk '$3 != "Running" && $3 != "Completed" && $3 != "Terminating" {print}')
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
  netra-alloy
)
for svc in "${required_svcs[@]}"; do
  if kubectl get svc -n "$NS" "$svc" >/dev/null 2>&1; then
    ok "service $svc"
  else
    fail "missing service: $svc"
  fi
done

# --- Alloy Faro port ----------------------------------------------------
section "Alloy Faro Service port"
if kubectl get svc -n "$NS" netra-alloy -o jsonpath='{.spec.ports[*].port}' 2>/dev/null \
  | tr ' ' '\n' | grep -qx '12347'; then
  ok "netra-alloy exposes port 12347 (Faro RUM)"
else
  fail "netra-alloy missing Service port 12347 — browser RUM will not work"
fi

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
  netra-blackbox-tempo
  netra-blackbox-otel-collector
  netra-blackbox-alloy
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

# --- Alertmanager routing ----------------------------------------------
section "Alertmanager routing"
am_cfg=$(kubectl get secret -n "$NS" -l app.kubernetes.io/name=alertmanager \
  -o jsonpath='{.items[0].data.alertmanager\.yaml}' 2>/dev/null | base64 -d 2>/dev/null || true)
if [[ -z "$am_cfg" ]]; then
  warn "could not read Alertmanager config (release may still be starting)"
elif echo "$am_cfg" | grep -q 'receiver: "null"\|receiver: null'; then
  warn "Alertmanager still routes to null receiver — wire real receivers before paging (see manifests/alertmanager/receivers-secret.example.yaml)"
else
  ok "Alertmanager has non-null receiver configured"
fi

if [[ "$DEEP" -eq 1 ]]; then
  section "Deep checks (Prometheus)"

  prom_pod=$(kubectl get pods -n "$NS" -l app.kubernetes.io/name=prometheus \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$prom_pod" ]]; then
    fail "no Prometheus pod found for deep checks"
  else
    prom_query() {
      kubectl exec -n "$NS" "$prom_pod" -c prometheus -- \
        wget -qO- "http://127.0.0.1:9090/api/v1/query?query=$(printf '%s' "$1" | jq -sRr @uri)" 2>/dev/null \
        | jq -r '.data.result | length' 2>/dev/null || echo 0
    }

    down_count=$(prom_query 'count(up{namespace="observability"} == 0) or vector(0)')
    if [[ "${down_count:-0}" == "0" ]]; then
      ok "all observability scrape targets up"
    else
      fail "$down_count observability target(s) down (up==0)"
    fi

    probe_fail=$(prom_query 'count(probe_success{layer="platform"} == 0) or vector(0)')
    if [[ "${probe_fail:-0}" == "0" ]]; then
      ok "all platform blackbox probes succeeding"
    else
      fail "$probe_fail platform blackbox probe(s) failing"
    fi
  fi

  section "Deep checks (observability node memory budget)"
  # Sum of memory limits on the observability node should stay below
  # allocatable on e2-standard-2 (~6 GiB after kube/system reserve).
  obs_node=$(kubectl get nodes -l workload=observability -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$obs_node" ]]; then
    alloc_bytes=$(kubectl get node "$obs_node" -o jsonpath='{.status.allocatable.memory}' 2>/dev/null || true)
    # allocatable is Ki — convert to Mi for comparison
    alloc_mi=$(echo "$alloc_bytes" | sed 's/Ki$//' | awk '{printf "%.0f", $1/1024}')
    # Static budget: tuned limits sum ~6.3 GiB on observability node
    budget_mi=6500
    if [[ -n "$alloc_mi" && "$alloc_mi" -gt 0 && "$budget_mi" -le "$alloc_mi" ]]; then
      ok "node $obs_node allocatable ${alloc_mi}Mi >= budget ${budget_mi}Mi"
    elif [[ -n "$alloc_mi" && "$alloc_mi" -gt 0 ]]; then
      fail "node $obs_node allocatable ${alloc_mi}Mi < budget ${budget_mi}Mi — raise machine type or lower limits"
    else
      warn "could not read allocatable memory for $obs_node"
    fi
  else
    warn "no observability node found for memory budget check"
  fi
fi

if [[ "$EDGE" -eq 1 ]]; then
  section "Grafana edge (oauth2-proxy + ingress)"
  for secret in grafana-google-oauth grafana-superadmin-emails grafana-oauth2-env; do
    if kubectl get secret -n "$NS" "$secret" >/dev/null 2>&1; then
      ok "secret $secret"
    else
      fail "missing secret: $secret"
    fi
  done

  if kubectl get deployment -n "$NS" grafana-oauth2-proxy >/dev/null 2>&1; then
    desired="$(kubectl get deployment -n "$NS" grafana-oauth2-proxy -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"
    ready="$(kubectl get deployment -n "$NS" grafana-oauth2-proxy -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    if [[ "${desired:-0}" -gt 0 && "${ready:-0}" == "${desired:-0}" ]]; then
      ok "oauth2-proxy ${ready}/${desired} ready"
    else
      fail "oauth2-proxy ${ready:-0}/${desired:-0} ready"
    fi
  else
    fail "missing deployment: grafana-oauth2-proxy"
  fi

  host=""
  ip=""
  if kubectl get ingress -n "$NS" netra-grafana >/dev/null 2>&1; then
    host="$(kubectl get ingress -n "$NS" netra-grafana -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
    ip="$(kubectl get ingress -n "$NS" netra-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      ok "ingress ${host} → ${ip}"
    else
      fail "ingress ${host} has no loadBalancer IP yet"
    fi
  else
    fail "missing ingress: netra-grafana"
  fi

  if kubectl get networkpolicy -n "$NS" netra-grafana-ingress >/dev/null 2>&1; then
    ok "NetworkPolicy netra-grafana-ingress"
  else
    fail "missing NetworkPolicy netra-grafana-ingress"
  fi

  cookie_len=$(kubectl get secret grafana-oauth2-env -n "$NS" \
    -o jsonpath='{.data.cookie-secret}' 2>/dev/null | base64 -d 2>/dev/null | wc -c | tr -d ' ')
  if [[ "${cookie_len:-0}" -ge 16 ]]; then
    ok "oauth2-proxy cookie-secret configured"
  else
    fail "grafana-oauth2-env missing cookie-secret (>=16 chars)"
  fi

  if [[ -n "${ip:-}" ]]; then
    resolved=""
    if command -v dig >/dev/null 2>&1; then
      resolved="$(dig +short "$host" A 2>/dev/null | tail -1 || true)"
    fi
    if [[ -z "$resolved" ]]; then
      warn "DNS: ${host} not resolving — add GoDaddy A record → ${ip}, then re-run Phase 2"
    elif [[ "$resolved" == "$ip" ]]; then
      ok "DNS ${host} → ${ip}"
    else
      warn "DNS mismatch: ${host} → ${resolved}, ingress IP ${ip}"
    fi
  fi

  tls_name=$(kubectl get ingress netra-grafana -n "$NS" \
    -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null || true)
  if [[ -n "$tls_name" ]] && kubectl get certificate "$tls_name" -n "$NS" >/dev/null 2>&1; then
    if kubectl wait --for=condition=Ready "certificate/${tls_name}" \
      -n "$NS" --timeout=30s >/dev/null 2>&1; then
      ok "TLS certificate ${tls_name} Ready"
    else
      warn "TLS certificate ${tls_name} not Ready — set DNS then re-run Phase 2"
    fi
  else
    warn "cert-manager Certificate not found for ingress TLS yet"
  fi
fi

echo
if [[ "$EXIT" -eq 0 ]]; then
  echo "verify.sh: all checks passed."
else
  echo "verify.sh: one or more checks failed."
fi
exit "$EXIT"
