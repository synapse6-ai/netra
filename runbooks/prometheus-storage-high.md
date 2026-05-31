# PrometheusStorageHigh

Alert: `PrometheusStorageHigh`
Severity: `warning`
Owner: platform

## What it means

Prometheus TSDB is using more than 80% of its PVC capacity for 30+
minutes. Without action, Prometheus will stop accepting new samples.

## Where to look

- Grafana: `Netra / Platform / Prometheus health` — TSDB block bytes,
  active series, samples appended/s.
- Prometheus UI (port-forward): Status → TSDB Status.
- PVC:
  ```sh
  kubectl -n observability get pvc -l app.kubernetes.io/name=prometheus
  ```

## Immediate actions

1. Confirm growth rate — sudden spike vs gradual drift.
2. Check for cardinality explosion:
   - `topk(20, count by (__name__)({__name__=~".+"}))` in Prometheus.
   - Look for new high-cardinality labels on app metrics.
3. Check retention settings in `values/kube-prometheus-stack/values.yaml`
   (`retention: 15d`).

## Mitigation

- Short term: increase PVC size (requires storageClass that supports
  expansion) or lower `retention` / `retentionSize`.
- Medium term: drop unused scrape targets, fix mis-instrumented apps
  emitting unbounded label values.
- Long term: Thanos/Mimir is out of scope for this repo — file an RFC if
  15d on a single PVC is insufficient.

## Escalation

Page platform on-call if usage is above 90% or Prometheus enters
read-only mode.
