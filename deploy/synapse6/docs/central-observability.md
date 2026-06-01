# Synapse6 central observability — greenfield commercial deployment.
# One Grafana workspace for dev + stage + prod. No Datadog. No single-cluster shortcut.

> **Not using multi-cluster?** Stock single-cluster Netra is the default path —
> see [README.md](../../../README.md) and `./scripts/install.sh` with no `NETRA_*`
> overrides.

## Architecture (fixed)

Synapse6 runs **three app GKE clusters** and **one central observability cluster**.

```
synapse6-observability / netra-platform     ← full Netra (install-central.sh)
synapse6ai-dev     / guardrailstudio-dev     ← agents only (install-agents.sh)
synapse6ai-stg     / guardrailstudio-stg     ← agents only
synapse6-prod      / guardrailstudio-prod    ← agents only
```

Every signal carries:

| Label / attribute | Example |
| ----------------- | ------- |
| `environment` | `dev`, `stage`, `prod` |
| `cluster` (metrics/logs) | `guardrailstudio-dev`, `guardrailstudio-stg`, `guardrailstudio-prod` |
| `k8s.cluster.name` (traces) | same as `cluster` above |
| `cluster` (central stack self-metrics) | `netra-platform` |

## Prerequisites

### GCP (once)

1. Create project **`synapse6-observability`**
2. Enable APIs: GKE, GCS, IAM, Compute, DNS, Secret Manager
3. **Shared VPC or VPC peering** between obs project and dev/stg/prod projects
4. GKE **`netra-platform`**: regional `us-central1`, Workload Identity, node pool
   **`observability`**: 2× `e2-standard-4`, label `workload=observability`, taint
   `workload=observability:NoSchedule`
5. GCS buckets (lifecycle delete 15d logs / 7d traces):
   - `synapse6-obs-netra-loki`
   - `synapse6-obs-netra-tempo`
6. GSAs + WI bindings for Loki/Tempo (see `central/values/loki.yaml`, `tempo.yaml`)
7. Private DNS (e.g. `obs.internal.synapse6.ai`) pointing at **internal ILB IPs**

Internal ILBs are **plain HTTP/TCP** (GKE passthrough). Use `http://` in agent
env vars unless you terminate TLS at an org edge proxy.

### Before install-central.sh

Create the observability namespace and ingest auth secret **before** install:

```bash
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic netra-ingest-auth \
  --namespace=observability \
  --from-literal=token="$(openssl rand -base64 32)"
```

See `deploy/synapse6/central/examples/ingest-auth-secret.example.yaml`.

Edit **`deploy/synapse6/central/values/loki.yaml`** and **`tempo.yaml`** — set real
`iam.gke.io/gcp-service-account` annotations.

Edit **`deploy/synapse6/central/manifests/networkpolicies/ingest-cross-cluster.yaml`** —
replace placeholder Pod CIDRs with values from each app cluster:

```bash
gcloud container clusters describe guardrailstudio-stg \
  --zone=us-central1-a --project=synapse6ai-stg \
  --format='value(clusterIpv4Cidr)'
```

`install-central.sh` exits if `REPLACE` remains in the CIDR manifest or if
`netra-ingest-auth` is missing (use `SYNAPSE6_SKIP_*` env vars for dev only).

## Install order

### 1. Central platform

```bash
kubectl config use-context gke_synapse6-observability_us-central1_netra-platform
./deploy/synapse6/scripts/install-central.sh
./scripts/verify.sh --deep
INGEST_TOKEN='...' ./deploy/synapse6/scripts/verify-synapse6-central.sh
```

### 2. Networking

Map internal LB IPs to private DNS:

| DNS | Service | Port |
| --- | ------- | ---- |
| `otel.obs.internal...` | `netra-ingest-otel` | 4317 gRPC / 4318 HTTP |
| `loki.obs.internal...` | `netra-ingest-loki` | 3100 |
| `prom.obs.internal...` | `netra-ingest-prometheus` | 9090 |
| `faro.obs.internal...` | `netra-ingest-faro` | 12347 |

Confirm from an app cluster (HTTP — ILB is TCP passthrough):

```bash
curl -H "Authorization: Bearer $INGEST_TOKEN" \
  http://otel.obs.internal.synapse6.ai:4318/v1/traces -X POST -d '{}'
```

**Browser RUM (Faro):** the bundle exposes an internal ILB on port 12347 with CORS
for Guardrail Studio domains. Public browser traffic requires HTTPS ingress at your
edge (Cloud LB / CDN) pointing at `netra-ingest-faro` — not included in this bundle.

### 3. App cluster agents (stg → dev → prod)

```bash
export K8S_CLUSTER=guardrailstudio-stg
export ENVIRONMENT=stage
export CENTRAL_OTEL_ENDPOINT=otel.obs.internal.synapse6.ai:4317
export CENTRAL_LOKI_URL=http://loki.obs.internal.synapse6.ai:3100/loki/api/v1/push
export CENTRAL_PROM_REMOTE_WRITE=http://prom.obs.internal.synapse6.ai:9090/api/v1/write
export INGEST_TOKEN='...'

kubectl config use-context gke_synapse6ai-stg_us-central1-a_guardrailstudio-stg
./deploy/synapse6/scripts/install-agents.sh
```

Repeat with dev/prod values.

### 4. Wire Guardrail Studio

Apps in each cluster send OTLP to the local agent (see
[deploy/synapse6/README.md](../README.md#app-integration-synapse6)).
Pod labels: `environment`, `team`, `app.kubernetes.io/name`.

### 5. Production hardening

- [ ] Grafana Google SSO (replace port-forward-only access)
- [ ] Alertmanager receivers (`manifests/alertmanager/receivers-secret.example.yaml`)
- [ ] HTTPS ingress for Faro if browsers call RUM directly
- [ ] Scale obs pool to 3× `e2-standard-4` when Prometheus memory > 70%
- [ ] Enable GCS bucket monitoring + billing alerts
- [ ] On-call runbooks validated with a game-day drill

## Ingest token rotation

All clusters share one token in v1 (`netra-ingest-auth`). To rotate:

```bash
NEW="$(openssl rand -base64 32)"
kubectl create secret generic netra-ingest-auth \
  --namespace=observability --from-literal=token="$NEW" --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/netra-ingest-gateway -n observability
kubectl rollout restart deployment/netra-otel-collector -n observability
kubectl rollout restart daemonset/netra-alloy -n observability

# Each app cluster — re-run with updated INGEST_TOKEN:
export INGEST_TOKEN="$NEW"
./deploy/synapse6/scripts/install-agents.sh
```

Restart gateway pods so nginx re-renders the auth map from the updated Secret.

## Commercial-grade defaults in this bundle

| Area | Choice |
| ---- | ------ |
| Central sizing | 2× `e2-standard-4` obs nodes, OTel 2 replicas, Prometheus 500Gi PVC |
| Ingest auth | Bearer on OTel + nginx gateway (Loki/Prom); Faro via CORS + NP CIDRs |
| Multi-cluster labels | Central OTel skips cluster upsert; agents stamp `cluster` + `k8s.cluster.name` |
| Dashboards | `python-api-multi-cluster.json` via `NETRA_EXTRA_DASHBOARDS_DIR` |
| Remote write | Prometheus `remote-write-receiver` enabled |
| Agents | Alloy DS (logs + metrics) + OTel DS (traces) per app cluster |
| HA path | Add 3rd obs node + OTel HPA when SLO requires it |

## Related docs

- [deploy/synapse6/README.md](../README.md) — file layout + app OTLP endpoints
- [docs/app-integration.md](../../../docs/app-integration.md) — generic app contract
- [docs/production-checklist.md](../../../docs/production-checklist.md)
- [README.md](../../../README.md) — stock single-cluster Netra
