# Netra architecture

Netra is one shared observability stack that watches every environment
(dev, stage, prod) through labels, namespaces, and dashboard variables.

## Signals at a glance

```
+----------------+        +-------+        +-------+        +---------+
|  pods (any ns) | stdout |       |        |       |        |         |
| dev/stage/prod | -----> | Alloy | -----> | Loki  | -----> |         |
+----------------+        |  ds   |        |  GCS  |        |         |
                          +-------+        +-------+        |         |
                                                            |         |
+----------------+        +-----------------------+         |         |
|   pods + nodes |        | Prometheus (kps)      |         |         |
| /metrics + ksm | -----> | scrape across all ns  | ------> |         |
+----------------+        | + Alertmanager        |         | Grafana |
                          +-----------------------+         |   OSS   |
                                  |                         |         |
                                  v                         |         |
                          +-----------------------+         |         |
                          |   PrometheusRules     |         |         |
                          +-----------------------+         |         |
                                                            |         |
+----------------+        +-------+        +-------+        |         |
|  app services  | OTLP   | OTel  |        | Tempo |        |         |
|                | -----> | Coll. | -----> |  GCS  | -----> |         |
+----------------+        +-------+        +-------+        |         |
                              ^                             |         |
                              |                             |         |
+----------------+            |                             |         |
| Next.js Faro   |   HTTPS    |   logs   +-------+          |         |
| SDK (optional) | -----> Alloy ------> Loki     |          |         |
+----------------+         (Faro recv)  +-------+           |         |
                              |                             |         |
                              +---- traces -----------------+         |
                                                            +---------+
```

## Per-signal pipelines

- **Logs:** pod stdout → Alloy DaemonSet → Loki (single-binary) → GCS
  object storage → Grafana (Loki datasource).
- **Metrics:** kubelet/cAdvisor + kube-state-metrics + node-exporter +
  ServiceMonitors → Prometheus (kube-prometheus-stack) → Grafana
  (Prometheus datasource). Alertmanager fires PrometheusRule alerts.
- **Traces:** apps → OpenTelemetry Collector → Tempo → GCS → Grafana
  (Tempo datasource).
- **RUM:** Next.js Faro SDK (optional) → Alloy Faro receiver → Loki for
  events, Tempo for traces → Grafana.

## Cross-environment tracking

**One Netra stack, env-neutral.** Netra itself has no dev/stage/prod — it is a
single observability plane (`cluster: netra` on stack metrics only).

**Apps carry their own environment.** Every workload (e.g. guardrailstudio)
labels pods with `environment: dev | stage | prod`. Netra copies that label
onto metrics and logs automatically. Traces use OTLP
`deployment.environment`.

```
┌─────────────────────────────────────────┐
│  Netra (one stack, no app environment)  │
│  cluster=netra, namespace=observability │
└─────────────────────────────────────────┘
          ▲ scrapes / collects
          │
   guardrailstudio-api pods
   ├── environment=dev
   ├── environment=stage
   └── environment=prod
```

Dashboards for services filter on the **app** `environment` variable.
Platform dashboards (Loki health, Prometheus health, …) filter on
`namespace=observability` — not on environment.

Every **app** signal should carry:

- `environment` (dev | stage | prod) — from pod labels or OTLP
- `namespace`
- `service` / `service_name`
- `pod`
- `team`

Prometheus `external_labels` set `cluster` only. Alloy copies `environment`
and `cluster` from pod labels onto log streams. Apps set
`deployment.environment` on OTLP spans.

Service dashboards expose `environment` and `service` as template variables
(e.g. pick `guardrailstudio-api` + `prod` on the Python API dashboard).

App blackbox probes use `layer: app` and `environment: dev|stage|prod` per
target. Stack self-checks use `layer: platform` with no environment.

## Node isolation, not HA

Observability workloads run on a dedicated `workload=observability` node
pool. **Default GKE machine type: `e2-standard-4`** (4 vCPU, 16 GiB RAM,
one node). Helm `resources` in `values/` are request/limit-tuned for that
footprint; memory **limits** sum to ~6.3 GiB so an 8 GiB node is not
overcommitted. Use `e2-standard-4` or additional nodes if Prometheus
memory pressure or high scrape cardinality appears.

Components scheduled on that pool:

- Grafana, Prometheus, Alertmanager, Prometheus Operator,
  kube-state-metrics
- Loki, Tempo, OpenTelemetry Collector
- blackbox_exporter

Alloy and node-exporter run on every node (DaemonSet with
`tolerations: Exists`) so they can collect from app pools.

**Isolation, not HA.** A dedicated observability node protects app pools
from observability load and vice-versa, but a single-node setup is still
a single point of failure for Netra itself. True HA requires:

- 3+ observability nodes spread across AZs
- replicated/stateless Loki/Tempo deployment modes (read/write/backend
  split) — out of scope for this scaffold
- Prometheus Operator HA (replicas: 2 with shard-aware Alertmanager
  clustering)

We will not pretend HA exists until we make those changes.

## Storage

- **Prometheus:** SSD PVC, 15d retention.
- **Loki:** GCS object storage, 15d retention. Local PVC is WAL/cache only.
  GCS auth via GKE Workload Identity (no static keys).
- **Tempo:** GCS object storage, 7d retention (configurable up to 15d via
  `tempo.retention`). Local PVC is WAL only. GCS auth via GKE Workload
  Identity.
- **Grafana:** small PVC for plugins and session data; dashboards and
  datasources are reloaded from ConfigMaps every restart.
- **Dashboards / alerts / datasources / runbooks:** Git is the source of
  truth, forever.
