# Application integration contract

Netra is a **plug-and-play** observability platform. It publishes the
stable contract below; any service in any repository adopts it to get
logs, metrics, traces, and RUM **without changing anything in this repo**.

Netra deliberately knows nothing about specific applications. This is the
separation of concerns that keeps it reusable:

- **Netra owns** the platform: collectors, Prometheus/Grafana/Alertmanager,
  Loki, Tempo, Alloy, the scrape conventions, and the generic platform
  dashboards/alerts.
- **Each service owns** its own instrumentation, its app-specific
  dashboards/alerts, and conforming to the contract here.

If a future repo wants observability, it implements this contract — Netra
is not edited to "know about" it.

## Metrics (Prometheus)

Expose `/metrics` on a Service port named **`http-metrics`**.

### Labels — Service metadata vs pod labels

ServiceMonitors match **Service metadata**, not pod labels. Prometheus relabeling
copies **pod** labels into metric series (`service`, `team`, `environment`) and
copies **Service metadata** into `scrape_class`:

| Label | Where it lives | Purpose |
|-------|----------------|---------|
| `app.kubernetes.io/component: api \| worker` | **Service metadata** | Selects `netra-python-api` or `netra-python-worker` ServiceMonitor; copied to `scrape_class` on scraped series |
| `app.kubernetes.io/name: <service>` | **Pod** labels | Becomes the Prometheus `service` label |
| `team`, `environment` | **Pod** labels | Relabeled onto every scraped series |
| `app.kubernetes.io/component: <routing-id>` | **Pod** labels (optional) | Immutable deployment identity (e.g. `decision-engine`, `mcp-gateway`); **not** used for scrape selection |

When a workload's routing component differs from its scrape class (common for
sidecar-style services), set `component: api` on the **Service** metadata only
and keep the pod/Deployment selector on the routing value.

Example Service metadata for an HTTP API scrape target:

```
app.kubernetes.io/component:  api          # scrape class → scrape_class="api"
```

Example pod labels (become `service`, `team`, `environment` on series):

```
app.kubernetes.io/name:       guardrailstudio-api
app.kubernetes.io/component:  api
team:                         guardrailstudio
environment:                  dev          # or stage | prod — one value per Deployment
```

Run **three Deployments** (or namespaces) with the same `app.kubernetes.io/name`
but different `environment` pod labels to track guardrailstudio across dev,
stage, and prod on one Netra stack. The Python API dashboard will list
`guardrailstudio-api` under service and let you pick the environment.

Blackbox synthetic checks for apps use `layer: app` and per-target
`environment` labels — see the commented example in
`manifests/prometheus/servicemonitors/blackbox-probes.yaml`.

- ServiceMonitors are namespace-agnostic (`namespaceSelector: any`), so a
  conforming workload in **any** namespace is scraped automatically.
- Platform alerts and dashboards filter on `scrape_class="api"` or
  `scrape_class="worker"`, not on pod routing labels.
- **OPA**: expose a Service labelled `app.kubernetes.io/name: opa` with an
  `http-metrics` port (the `netra-opa` ServiceMonitor matches it).
- Need a component beyond `api`/`worker`? Add a generic ServiceMonitor here
  keyed on a convention — never one named after a single app.

## Traces (OpenTelemetry)

Send OTLP to the in-cluster collector:

```
netra-otel-collector.observability.svc.cluster.local:4317   # gRPC
netra-otel-collector.observability.svc.cluster.local:4318   # HTTP
```

Do **not** send traces directly to Tempo — the collector is the blessed
path. NetworkPolicy blocks direct Tempo OTLP from other pods.

Set `deployment.environment` and `service.name` on every span via OTLP
resource attributes. The collector upserts `cluster` only.

## Logs (Alloy → Loki)

- Write structured logs to **stdout**. Alloy's per-node DaemonSet collects
  them automatically; no sidecar, no Promtail.
- **Low-cardinality labels only**: `environment`, `namespace`,
  `service_name`, `pod`, `container`, `level`, `cluster`, `team`. Keep
  `request_id` / `trace_id` / `span_id` / `user_id` / `tenant_id` in the
  log body or structured metadata — **never** as Loki labels.
- Emit `trace_id` / `span_id` in logs to light up Loki↔Tempo correlation.

## RUM (browser, optional)

Point a Grafana Faro Web SDK at the Alloy Faro receiver. In-cluster URL
(no ingress required for smoke tests):

```
http://netra-alloy.observability.svc.cluster.local:12347/collect
```

For browsers outside the cluster, expose port **12347** on the Alloy
Service via ingress (add ingress separately — not in this scaffold).

Set `app.name` in the Faro SDK to match the `service_name` label used in
dashboards (pick **service** on the RUM dashboard). CORS origins are
configured in `values/alloy/values.yaml` (default: localhost:3000).

## Alerting expectations

The bundled platform PrometheusRules assume conventional metric families.
A service either emits these names, or ships its own PrometheusRule with
its own repo/overlay — it does not edit Netra's rules.

| Domain | Expected series |
|--------|-----------------|
| HTTP API | `http_requests_total`, `http_request_duration_seconds_bucket` |
| Workers | `worker_jobs_total`, `worker_jobs_retried_total`, `worker_jobs_processed_total`, `worker_queue_oldest_job_age_seconds` |
| OPA | `http_request_duration_seconds_{bucket,count,sum}`, `bundle_failed_load_counter`, `up` |

OPA exposes HTTP metrics on `/metrics` by default. Enable the bundle
plugin's status reporting so `bundle_failed_load_counter` is populated.
Do not rely on `opa_decisions_total` — it is not part of OPA's built-in
Prometheus surface.

## Out of scope for this repo

- Application instrumentation code.
- App-specific dashboards/alerts beyond the generic platform set.

Adopting the contract is the only integration step. Netra stays reusable
because consumers conform to it — the dependency points at Netra, never the
other way around.
