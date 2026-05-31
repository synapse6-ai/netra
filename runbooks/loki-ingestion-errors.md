# LokiIngestionErrors / AlloyDown / PrometheusStorageHigh

Alerts: `LokiIngestionErrors`, `AlloyDown`, `PrometheusStorageHigh`
Severity: `critical` / `warning`
Owner: platform

## What it means

Loki is returning 5xx on the push path for 10+ minutes
(`LokiIngestionErrors`), Alloy is target-down for 5+ minutes
(`AlloyDown`), or Prometheus PVC is more than 80% full for 30+ minutes
(`PrometheusStorageHigh`).

Any of these mean Netra is going partly blind. We are still safe because
Datadog stays during the migration, but treat this as a self-monitoring
emergency.

## Where to look

- Grafana: `Netra / Platform / Loki health`, `Netra / Platform / Alloy health`,
  `Netra / Platform / Prometheus health`.
- Loki pod logs:
  ```sh
  kubectl logs -n observability statefulset/netra-loki -c loki --tail=200
  ```
- Object storage health (GCS bucket: `netra-loki-data` in default values).

## Immediate actions

1. Confirm the GCS backend is reachable and Workload Identity is bound:
   ```sh
   # From a pod on the Loki KSA, the metadata server should return the GSA:
   kubectl exec -n observability statefulset/netra-loki -c loki -- \
     wget -qO- -H "Metadata-Flavor: Google" \
     "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email"
   # Bucket access (from a workstation with gcloud):
   gsutil ls "gs://netra-loki-data/" | head
   ```
2. Check Loki ingester memory / CPU — is it OOMing? See
   `pod-crashlooping.md`.
3. For Alloy: confirm DaemonSet pods are running on every node:
   ```sh
   kubectl get pods -n observability -l app.kubernetes.io/name=alloy -o wide
   ```
4. For Prometheus storage: check the PVC usage trend and consider
   reducing retention temporarily.

## Mitigation

- Roll Loki pods if they look stuck:
  ```sh
  kubectl rollout restart -n observability statefulset/netra-loki
  ```
- Restart Alloy DaemonSet:
  ```sh
  kubectl rollout restart -n observability daemonset/netra-alloy
  ```
- For Prometheus storage: expand the PVC (preferred) or drop retention
  from 15d to 7d temporarily via Helm values.

## Escalation

Page the platform on-call. Note: if Loki is hard down, the Datadog
pipeline is still authoritative; do not gate incident response on Netra.
