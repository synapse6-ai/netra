# AlloyDown

Alert: `AlloyDown`
Severity: `critical`
Owner: platform

## What it means

An Alloy DaemonSet pod has not been scraped successfully for 5+ minutes.
Log collection and the Faro RUM receiver on that node are offline.

## Where to look

- Grafana: `Netra / Platform / Alloy health`
- Kubernetes:
  ```sh
  kubectl -n observability get pods -l app.kubernetes.io/instance=netra-alloy -o wide
  kubectl -n observability describe daemonset netra-alloy
  ```
- Node coverage: Alloy should run on every node. Compare DaemonSet
  `status.numberReady` to cluster node count.

## Immediate actions

1. Identify which node(s) lost Alloy (`kubectl get pods -o wide`).
2. Check pod events and logs:
   ```sh
   kubectl -n observability logs -l app.kubernetes.io/instance=netra-alloy --tail=100
   ```
3. Check Loki push errors — if Loki is rejecting writes, Alloy may be
   crash-looping. See `loki-ingestion-errors.md`.

## Mitigation

- Delete the stuck pod to force reschedule on the same node.
- If the node is NotReady, cordon/drain per `node-not-ready.md`.
- If Alloy OOMs, raise memory limits in `values/alloy/values.yaml`.

## Escalation

Page platform on-call. Missing Alloy on an app node means logs from that
node are not reaching Loki until the pod recovers.
