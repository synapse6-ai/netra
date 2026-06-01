# Production checklist

Use this before installing Netra into a real cluster, especially prod.
Anything not checked here is a known gap.

## Before install

- [ ] GCS buckets exist and Loki/Tempo `serviceAccount.annotations` include
      `iam.gke.io/gcp-service-account` (install.sh preflight checks this;
      use `SKIP_GCS_PREFLIGHT=1` only for non-GCS smoke tests).
- [ ] Cluster identity set via `values/cluster.yaml` or
      `NETRA_CLUSTER=my-cluster ./scripts/install.sh`.
- [ ] Storage class in `values/` matches your cluster (`standard` by default).
- [ ] Grafana admin Secret exists or will be created by `install.sh`
      (`netra-grafana-admin`).
- [ ] Loki and Tempo GCS buckets exist with matching retention lifecycle rules.
- [ ] GKE Workload Identity bound for Loki/Tempo if using GCS.
- [ ] Observability node pool exists: **`e2-standard-2`** (or larger), label
      `workload=observability`, taint `workload=observability:NoSchedule`.

## After install

- [ ] `scripts/verify.sh` returns 0 (`scripts/verify.sh --deep` after prod cutover).
- [ ] `scripts/validate.sh` returns 0 in CI.
- [ ] Grafana datasources `Prometheus`, `Loki`, `Tempo`, `Alertmanager`
      all show green health.
- [ ] All 10 dashboards are visible under `Netra / Platform`,
      `Netra / Services`, `Netra / OPA`, `Netra / RUM`.
- [ ] Every PrometheusRule shows `health: ok` in
      `https://<grafana>/alerting/list` filtered by `netra` label.
- [ ] No alert is firing on the Netra stack itself.
- [ ] In-cluster blackbox probes return `probe_success == 1`.

## Security posture

- [ ] No public ingress for Grafana, Prometheus, Loki, Tempo, or
      Alertmanager. Access is via cluster-internal Service + port-forward,
      a private LB with mTLS, or an authenticated ingress (e.g.
      OAuth2 Proxy).
- [ ] Alertmanager receiver tokens (PagerDuty, Slack, Opsgenie, SMTP)
      are mounted from a Secret, **not** committed to this repo. Start from
      `manifests/alertmanager/receivers-secret.example.yaml`. The default
      Alertmanager config routes to `null`; `verify.sh` warns until real
      receivers are wired.
- [ ] Network policies in `manifests/networkpolicies/` are applied
      (`install.sh` does this). They restrict Loki/Tempo ingest to
      Alloy and the OTel Collector respectively; OTLP is open to all
      namespaces via the collector Service.
- [ ] No `request_id`, `trace_id`, `span_id`, `user_id`, `email`,
      `session_id`, or `tenant_id` is being used as a Loki label.
      Cross-check with `logcli labels` after first 24h of ingest.

## Health expectations

- [ ] Prometheus PVC usage < 50% after first 24h.
- [ ] Loki ingest 5xx rate is zero outside of brief restart windows.
- [ ] Tempo block_retention matches policy (**7d default**, 15d if you
      raised `tempo.retention` in values — traces are shorter-lived than
      metrics/logs by default).
- [ ] Alloy DaemonSet is running on every node in the cluster, including
      app pools.

## During the Datadog overlap window

- [ ] Datadog still installed, still collecting, still paging.
- [ ] No on-call route is moved off Datadog until the relevant service
      has dashboards + alerts + runbooks + at least one validated
      incident on Netra. See `datadog-migration.md`.

## Out of scope (do not silently add)

- Thanos / Mimir / Cortex
- OpenSearch / Elasticsearch / Logstash
- Pyroscope, Backstage, OpenCost, Trivy, Falco
- Any data warehouse or long-term analytics archival
- A Netra CLI

Any of these become real proposals through a follow-up RFC, not a quiet
commit to this repo.
