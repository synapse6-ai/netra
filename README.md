# Netra

### The open-source observability boilerplate for Kubernetes teams who want to own their stack — without owning the yak shave.

Netra gives you a **production-shaped observability platform in an afternoon**, not a quarter. Metrics, logs, traces, optional browser RUM, dashboards, alerts, and on-call runbooks — all wired together, pinned, and **versioned in Git** so your platform story stays reviewable, reproducible, and yours.

One install. Every namespace. Every app environment. **No duplicate stacks for dev, stage, and prod.**

---

## The story behind Netra

Most teams eventually face the same fork in the road:

- **Keep renting** observability from a SaaS vendor — fast to start, expensive at scale, hard to exit.
- **Build it yourself** from Helm charts — powerful, but weeks of glue, drift, and "who owns the Grafana dashboard someone edited at 2am?"
- **Do nothing** — until the outage where nobody can answer *which environment* or *which service* broke.

Netra is the third path: **an opinionated, extensible open-source boilerplate** that ships the glue code, conventions, and GitOps discipline so you can focus on what your applications need to expose — not on re-inventing the observability plane every time you spin up a cluster.

We built Netra because platform work should **multiply** product teams, not block them. App repos adopt a [published contract](docs/app-integration.md). This repo stays generic. Your services show up in Grafana automatically when they label their pods correctly. That's the multiplier.

---

## Who Netra is for


| You are…                                                              | Netra helps you…                                                                                                                                                   |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **A platform / DevOps engineer** standing up GKE (or any serious K8s) | Skip the "which chart goes with which sidecar?" spreadsheet and install a coherent stack with one script                                                           |
| **A startup with GCP credits**                                        | Run a real metrics/logs/traces plane without a five-figure SaaS line item — and keep your data in *your* buckets                                                   |
| **A team validating self-hosted observability**                       | Run Netra **alongside** your existing vendor, prove parity on dashboards and alerts, then cut over on your timeline ([migration guide](docs/datadog-migration.md)) |
| **An OSS contributor**                                                | Extend a boilerplate designed for **more tools, not more forks** — see [Roadmap & extension model](#roadmap--extension-model) below                                |


If you want a turn-key SaaS with zero cluster ops, Netra is not that — and we're honest about it. If you want **control, composability, and a repo you can fork without shame**, you're in the right place.

---

## What you get on day one

Netra is not a empty Helm umbrella chart. It's a **curated platform** with opinions baked in:

### Unified signals — one Grafana, one mental model


| Signal                   | Powered by                                                  | What Netra adds beyond "just install the chart"                                        |
| ------------------------ | ----------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| **Metrics**              | Prometheus, Alertmanager, kube-state-metrics, node-exporter | Git-owned `PrometheusRule`s, ServiceMonitor conventions, platform + service dashboards |
| **Logs**                 | Loki on object storage (GCS)                                | Alloy DaemonSet on every node, cardinality guardrails, structured log pipeline         |
| **Traces**               | Tempo on object storage (GCS)                               | OpenTelemetry Collector as the blessed ingest path, network policies                   |
| **Synthetic monitoring** | blackbox_exporter                                           | In-cluster stack health probes + pattern for per-app, per-env external checks          |
| **Real user monitoring** | Grafana Faro via Alloy                                      | Optional browser SDK path with CORS hooks ready to configure                           |
| **Operations**           | Markdown runbooks                                           | Every critical alert links to a runbook — onboarding-friendly for on-call              |


### GitOps observability — review it like code

- **10+ Grafana dashboards** under `dashboards/` — platform health, Kubernetes, HTTP APIs, workers, OPA, RUM
- **PrometheusRules** under `manifests/prometheus/prometheusrules/` — scoped alerts with ratio guards and runbook URLs
- **Datasources** as ConfigMaps — Grafana sidecar reloads on every deploy
- **Network policies** for ingest paths — Loki and Tempo aren't wide open to the cluster by default

Dashboard edits in the UI are **drafts** until you export and commit. That's intentional. See [dashboards-alerts-in-git.md](docs/dashboards-alerts-in-git.md).

### One stack, many app environments

Netra is **env-neutral**. The observability plane doesn't pretend to be "dev" or "prod" — your **applications** do.

Label pods with `environment: dev | stage | prod`. Netra copies that onto metrics and logs. Set `deployment.environment` on OTLP spans. Open a single dashboard, pick your service, filter by environment — compare dev against prod without running three monitoring stacks.

```
┌─────────────────────────────────────────┐
│  Netra — one stack, cluster=netra       │
│  namespace: observability               │
└─────────────────────────────────────────┘
                    ▲
        ┌───────────┼───────────┐
        │           │           │
   my-api (dev)  my-api (stage)  my-api (prod)
   same ServiceMonitor, same dashboards, different series
```

This is how you keep platform cost flat while product surface area grows.

---

## Architecture at a glance

```
  YOUR APPS (any namespace)              NETRA (observability namespace)
  ─────────────────────────              ─────────────────────────────────

  stdout ─────────────────────────────►  Alloy ──► Loki ──► GCS
  /metrics ────────────────────────────►  Prometheus ──► Grafana OSS
  OTLP traces ─────────────────────────►  OTel Collector ──► Tempo ──► GCS
  Faro RUM (optional) ─────────────────►  Alloy ──► Loki / Tempo

  blackbox probes ◄── stack health + your app URLs (optional)
  Alertmanager ◄── PrometheusRules (Git-owned)
```

**Logs:** pod stdout → Alloy (DaemonSet) → Loki → durable object storage  
**Metrics:** ServiceMonitors scrape `/metrics` across all namespaces → Prometheus  
**Traces:** apps → OTel Collector → Tempo (direct Tempo ingest is blocked by policy — use the collector)  
**RUM:** browser SDK → Alloy Faro receiver → Loki + Tempo  

Deep dive: [docs/architecture.md](docs/architecture.md)

---

## Why teams choose Netra over rolling their own

**Time to first useful dashboard.** `./scripts/install.sh` and you're looking at platform health panels — not reading three charts' READMEs to figure out why the sidecar didn't pick up your JSON.

**Conventions that scale.** App teams don't open PRs against the platform repo. They label pods and expose `/metrics`. Netra's ServiceMonitors discover them. New service on Monday, visible in Grafana on Monday.

**Exit ramps included.** Run parallel with a commercial vendor during validation. No rip-and-replace theater. [datadog-migration.md](docs/datadog-migration.md) documents the overlap window explicitly.

**Fork-friendly, not fork-required.** Values, manifests, dashboards, and runbooks are plain YAML and JSON. No proprietary DSL. No Netra CLI you can't grep.

**Built for extension.** Today's stack is the **core bundle**. Tomorrow's Pyroscope, Mimir, or Falco layer slots in through the same GitOps patterns — see the roadmap below. You're not buying a dead-end scaffold; you're cloning a **living boilerplate**.

---

## Get started in three steps

### 1. Clone and install

**Prerequisites:** Kubernetes (GKE recommended for GCS + Workload Identity), `kubectl`, `helm`, `jq`, and a node pool labeled `workload=observability` ([scheduling reference](manifests/node-scheduling.yaml)).

```sh
git clone https://github.com/kuldeep-key/netra.git
cd netra
./scripts/install.sh
```

Pinned chart releases (May 2026): kube-prometheus-stack **86.1.0**, Loki **17.1.5**, Tempo **2.2.0**, Alloy **1.8.2**, OpenTelemetry Collector **0.158.0**, blackbox_exporter **11.9.1**.

`install.sh` is idempotent — safe to re-run. It creates the Grafana admin Secret, applies network policies, and packages dashboards into ConfigMaps.

### 2. Verify

```sh
./scripts/verify.sh      # in-cluster sanity check
./scripts/validate.sh    # local JSON/YAML lint — no cluster needed
```

### 3. Open Grafana

```sh
./scripts/port-forward.sh grafana
# → http://localhost:3000

kubectl get secret -n observability netra-grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Browse **Netra / Platform** for stack health, then wire your first app (below).

**Tear down** (PVCs and GCS buckets preserved by default): `./scripts/uninstall.sh`

Production hardening checklist: [docs/production-checklist.md](docs/production-checklist.md)

---

## Connect your first service

Netra deliberately contains **zero application code**. Your service repo does the wiring; Netra does the collecting. That's the contract — and it's what keeps this boilerplate reusable.

Full spec: [docs/app-integration.md](docs/app-integration.md)

**The four moves:**

1. **Metrics** — expose Prometheus metrics on a Service port named `http-metrics`
2. **Labels** — set on pods: `environment`, `team`, `app.kubernetes.io/name`
3. **Scrape class** — set on Service metadata: `app.kubernetes.io/component: api` (or `worker`)
4. **Traces** — send OTLP to `netra-otel-collector.observability.svc.cluster.local:4317`
5. **Logs** — write JSON to stdout; Alloy handles the rest

**Minimal example** — one API, production:

```yaml
# Deployment pod template
labels:
  app.kubernetes.io/name: payments-api
  app.kubernetes.io/component: payments-api
  team: payments
  environment: prod

# Service metadata (for ServiceMonitor discovery)
labels:
  app.kubernetes.io/component: api
```

Run three Deployments with `environment: dev`, `stage`, and `prod` — same name, different labels — and watch all three appear in **Netra / Services / Python API** without touching this repo.

**Synthetic checks** for public endpoints: add a Probe in [blackbox-probes.yaml](manifests/prometheus/servicemonitors/blackbox-probes.yaml) with `layer: app` and `environment: dev|stage|prod`. Stack self-checks already use `layer: platform`.

---

## Configuration reference

Defaults target a small dev cluster. Override for production:


| Setting                       | Location                                                              | Default                               |
| ----------------------------- | --------------------------------------------------------------------- | ------------------------------------- |
| Cluster identity (stack only) | `values/kube-prometheus-stack/values.yaml` → `externalLabels.cluster` | `netra`                               |
| PVC storage class             | kps, loki, tempo values                                               | `standard`                            |
| Log / trace buckets           | `values/loki/values.yaml`, `values/tempo/values.yaml`                 | `netra-loki-data`, `netra-tempo-data` |
| GKE Workload Identity         | `serviceAccount.annotations` in loki/tempo                            | unset — add your GSA                  |
| Grafana admin                 | auto-created by install                                               | Secret `netra-grafana-admin`          |
| RUM CORS                      | `values/alloy/values.yaml`                                            | `http://localhost:3000`               |


### Retention defaults


| Signal                       | Retention                   | Backend        |
| ---------------------------- | --------------------------- | -------------- |
| Metrics                      | 15 days                     | Prometheus PVC |
| Logs                         | 15 days                     | Loki → GCS     |
| Traces                       | 7 days (configurable to 15) | Tempo → GCS    |
| Dashboards, alerts, runbooks | indefinite                  | Git            |


---

## Roadmap & extension model

Netra is a **boilerplate, not a cage**. The core repo ships a battle-tested **minimum viable observability platform**. Extended capabilities arrive as **optional integration layers** — same GitOps patterns (`values/`, `manifests/`, `dashboards/`), same install story, no silent scope creep in the core.

We follow a simple rule from [production-checklist.md](docs/production-checklist.md): **new tools land through an RFC and a focused PR**, not as drive-by commits. That keeps the boilerplate trustworthy while the ecosystem grows.

### Core bundle (shipped today)

Grafana OSS · Prometheus · Alertmanager · Loki · Alloy · Tempo · OpenTelemetry Collector · blackbox_exporter · Git-owned dashboards, alerts, runbooks

### Integration layers (on the roadmap)

These are **not** in the core install today. They represent the direction of the boilerplate — community contributions and RFCs welcome:


| Layer                   | Example OSS tools               | Typical value add                                           |
| ----------------------- | ------------------------------- | ----------------------------------------------------------- |
| **Long-term metrics**   | Thanos, Mimir, Cortex           | Beyond 15d Prometheus retention without SaaS                |
| **Profiling**           | Pyroscope, Parca                | Continuous profiling linked to traces                       |
| **Security signals**    | Falco, Trivy                    | Runtime and image risk alongside app metrics                |
| **Cost visibility**     | OpenCost, Kubecost OSS patterns | Show back to platform what observability and workloads cost |
| **Search & analytics**  | OpenSearch (where justified)    | Heavy log analytics beyond Loki's sweet spot                |
| **Developer portal**    | Backstage plugins               | Observability links from service catalog to Grafana         |
| **Chaos & reliability** | Litmus, probe extensions        | Game days wired into the same alert/runbook loop            |


If you're evaluating Netra as a **foundation to extend**, star the repo and watch for integration PRs — or open an RFC for the tool you need. The architecture doc's extension points (`values/` per component, namespace-scoped manifests, sidecar-loaded dashboards) are deliberately boring so **new tools feel native, not bolted on**.

---

## Repository layout

```
netra/
├── values/           Helm values — one directory per component
├── manifests/        Namespace, network policies, ServiceMonitors, PrometheusRules
├── dashboards/       Grafana JSON — loaded via sidecar ConfigMaps
├── runbooks/         On-call playbooks linked from alerts
├── scripts/          install · uninstall · verify · validate · port-forward
└── docs/             Architecture, integration contract, checklists, migration
```

---

## Documentation


| Document                                                        | Read this when…                                                      |
| --------------------------------------------------------------- | -------------------------------------------------------------------- |
| [architecture.md](docs/architecture.md)                         | You need pipelines, node scheduling, storage, or the multi-env model |
| [app-integration.md](docs/app-integration.md)                   | You're wiring a new service into Netra                               |
| [production-checklist.md](docs/production-checklist.md)         | You're going beyond a dev cluster                                    |
| [dashboards-alerts-in-git.md](docs/dashboards-alerts-in-git.md) | Your team needs the GitOps workflow for Grafana                      |
| [datadog-migration.md](docs/datadog-migration.md)               | You're validating Netra against an existing vendor                   |


---

## Design principles we won't compromise on

- **One observability stack per cluster** — app environments are labels, not duplicate platforms
- **Apps own instrumentation; Netra owns the plane** — no per-app forks of this repo
- **Git is the source of truth** for dashboards, alerts, and datasources
- **No secrets in Git** — credentials live in Secrets, Workload Identity, or your secret manager
- **Cluster-internal by default** — Grafana, Prometheus, Loki, and Tempo stay off the public internet unless you explicitly expose them with auth
- **Low-cardinality Loki labels** — high-cardinality IDs belong in log bodies, not label sets
- **Durable object storage for logs and traces in production** — node disks are for WAL/cache, not your compliance story

---

## Project status & honesty clause

Netra is a **scaffold you can run today**, not a hosted product with a SLA. The install path works, the conventions are documented, and the review-hardened defaults reflect real production lessons — but **you** own buckets, node pools, alert receivers, and on-call routing.

Before you point a pager at Netra in production, walk [production-checklist.md](docs/production-checklist.md). Before you ask app teams to adopt it, share [app-integration.md](docs/app-integration.md).

We're building Netra in the open because observability infrastructure belongs in the commons — composable, forkable, and extensible. **Star the repo** if that's a future you want to help build. **Open an issue or PR** if you've integrated the next OSS layer and want others to benefit.

---

**Netra** — see your whole cluster. Know which environment broke. Own the stack.