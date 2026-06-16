# GuardrailStudio per-cluster Netra overlays

One full Netra stack **per app GKE cluster** (dev / stg / prod). Grafana is
exposed at `obs-{env}.instantevidence.ai` behind **oauth2-proxy** (Google OAuth
+ email allowlist). Do **not** use `deploy/synapse6/` central hub for this
topology.

GuardrailStudio runbook: sibling repo `GuardrailStudio/docs/observability-deployment.md`.

## Layout

```
deploy/guardrailstudio/
├── README.md
├── scripts/
│   ├── bootstrap-gcp.sh          # GCS + GSAs + Workload Identity (per project)
│   ├── ensure-observability-node-pool.sh  # dedicated tainted pool (dev/stg/prod)
│   ├── apply-grafana-edge.sh     # GSM → secrets → oauth2-proxy → ingress
│   └── install-env.sh            # ensure pool + install.sh + verify + edge
├── examples/                     # Secret templates — never commit real values
├── manifests/
│   └── grafana-oauth2-proxy.yaml
├── dev/
│   ├── cluster.yaml
│   ├── loki.yaml                 # GCS bucket + WI (required for install preflight)
│   ├── tempo.yaml
│   ├── kube-prometheus-stack.yaml
│   └── grafana-ingress.yaml
├── stg/
│   └── …
└── prod/
    └── …
```

## Dev install order (`synapse6ai-dev` / `guardrailstudio-dev`)

Run from **Cloud Shell** (or any host with `gcloud`, `kubectl`, `helm`, `jq`,
`envsubst`) — workloads land in GKE, not on your laptop.

```bash
gcloud config set project synapse6ai-dev
gcloud container clusters get-credentials guardrailstudio-dev --zone=us-central1-a

git clone https://github.com/synapse6-ai/netra.git && cd netra

# 1. GCS + Workload Identity
PROJECT=synapse6ai-dev ./deploy/guardrailstudio/scripts/bootstrap-gcp.sh

# 2. Dedicated observability node pool (label + taint; apps stay on app pool)
./deploy/guardrailstudio/scripts/ensure-observability-node-pool.sh dev

# 3. Core stack + Grafana edge (install-env runs both; edge needs GSM secret)
HELM_TIMEOUT=45m ./deploy/guardrailstudio/scripts/install-env.sh dev
```

Or core stack only:

```bash
SKIP_GRAFANA_EDGE=true HELM_TIMEOUT=45m ./deploy/guardrailstudio/scripts/install-env.sh dev
```

Manual edge only (existing K8s secrets):

```bash
SKIP_GRAFANA_EDGE_SECRETS=true ./deploy/guardrailstudio/scripts/apply-grafana-edge.sh dev
```

| Cluster | GCP project | `NETRA_VALUES_OVERLAY` | Grafana host |
|---------|-------------|------------------------|--------------|
| guardrailstudio-dev | synapse6ai-dev | `deploy/guardrailstudio/dev` | `obs-dev.instantevidence.ai` |
| guardrailstudio-stg | synapse6ai-stg | `deploy/guardrailstudio/stg` | `obs-stg.instantevidence.ai` |
| guardrailstudio-prod | synapse6-prod | `deploy/guardrailstudio/prod` | `obs.instantevidence.ai` |

## GCS buckets (created by bootstrap-gcp.sh)

| Project | Loki bucket | Tempo bucket |
|---------|-------------|--------------|
| synapse6ai-dev | `synapse6ai-dev-netra-loki` | `synapse6ai-dev-netra-tempo` |
| synapse6ai-stg | `synapse6ai-stg-netra-loki` | `synapse6ai-stg-netra-tempo` |
| synapse6-prod | `synapse6-prod-netra-loki` | `synapse6-prod-netra-tempo` |

## Secrets (Grafana edge)

Create **Secret Manager** secret `netra-grafana-edge-{env}` before CI or `install-env.sh`
(without `SKIP_GRAFANA_EDGE`). Template:
`deploy/guardrailstudio/examples/netra-grafana-edge-secret.example.json`

| GSM secret | GCP project | K8s secrets created |
|------------|-------------|---------------------|
| `netra-grafana-edge-dev` | synapse6ai-dev | `grafana-google-oauth`, `grafana-superadmin-emails`, `grafana-oauth2-env` |
| `netra-grafana-edge-stg` | synapse6ai-stg | same |
| `netra-grafana-edge-prod` | synapse6-prod | same |

Redirect URL is derived from the obs host (`obs-dev.instantevidence.ai`, etc.).
**Deploy SA** (`github-netra-deploy@…`) needs `roles/secretmanager.secretAccessor` on
the GSM secret (edge step reads GSM at apply time — nothing stored on the GHA runner).
Mirror `superadmin_emails` to API `PLATFORM_ADMIN_EMAILS`.

Generate `cookie_secret` once: `openssl rand -hex 16`

`install.sh` creates `netra-grafana-admin` for break-glass local admin.

## Auth flow

```
Browser → Ingress (obs-*) → oauth2-proxy → Grafana (auth.proxy / X-Forwarded-Email)
```

## Troubleshooting

### Helm `pending-install` / `failed` with no pods

Usually an interrupted install (laptop terminal closed, `context canceled`, flaky
API watch). `install.sh` auto-removes stuck releases before retry.

```bash
helm list -n observability
helm history netra-kps -n observability
kubectl get pods,pvc,events -n observability
kubectl get nodes -L workload,cloud.google.com/gke-nodepool

# Manual recovery (if needed):
helm uninstall netra-kps -n observability
./deploy/guardrailstudio/scripts/ensure-observability-node-pool.sh dev
HELM_TIMEOUT=45m ./deploy/guardrailstudio/scripts/install-env.sh dev
```

### PVC attach errors on c3 nodes

If events show `pd-standard disk type cannot be used by c3-standard-4`, PVCs
were provisioned with legacy `standard` instead of `standard-rwo`. Delete the
stuck release + PVCs and reinstall (values now use `standard-rwo`).

### Observability node pool

Each cluster needs a **dedicated** node pool (label `workload=observability`,
taint `workload=observability:NoSchedule`). App pods (`key-stack-*`) stay on the
primary pool. Run once per cluster (idempotent):

```bash
./deploy/guardrailstudio/scripts/ensure-observability-node-pool.sh dev
```

Or apply via Terraform: `infra/terraform/gke.tf` (`observability_nodes` pool).

**Do not** run long installs from a laptop IDE terminal. Use **GKE Cloud Shell**
or the GitHub Actions workflow `.github/workflows/deploy-guardrailstudio-dev.yml`.

### CI deploy (dev)

1. **Secret Manager** (`synapse6ai-dev`):
   - `github-netra-deploy-json` — `github-netra-deploy@…` SA key (`container.admin` + `storage.admin`)
   - `synapse-secret-manager-json` — bootstrap reader (same as GuardrailStudio CI)
   - `netra-grafana-edge-dev` — Google OAuth + superadmin emails JSON (see `examples/`)
2. **GitHub** (`synapse6-ai/netra`): secret `REGISTRY_PASSWORD` = bootstrap SA JSON.
3. **Deploy SA** (`github-netra-deploy@…`): `roles/container.admin` plus, for first node pool create,
   `roles/iam.serviceAccountUser` on `{PROJECT_NUMBER}-compute@developer.gserviceaccount.com`
   (see error output from `ensure-observability-node-pool.sh` for exact `gcloud` command).
4. **Deploy SA IAM** on `netra-grafana-edge-dev`:
   ```bash
   ./deploy/guardrailstudio/scripts/grant-grafana-edge-gsm-access.sh dev
   ```
5. **DNS (GoDaddy)**: A record `obs-dev.instantevidence.ai` → ingress LB IP (printed in Phase 3).
6. Actions → **Deploy GuardrailStudio Dev (Netra)** → Run workflow.

The workflow runs **four explicit phases** (after auth/bootstrap):
1. Core stack (`install-env.sh` with `SKIP_GRAFANA_EDGE=true`)
2. GSM preflight (readable + valid JSON)
3. Grafana edge (`apply-grafana-edge.sh`)
4. Edge verify (`verify.sh --edge-only`)

Use `skip_grafana_edge=true` if the GSM secret is not ready yet. Use `skip_observability_pool=true`
when the pool was created via Terraform — still unlabels stray labels on app nodes.

### Grafana edge DNS / TLS (two-phase)

First deploy: Phase 3 prints ingress IP → add GoDaddy A record → re-run workflow
(or `./deploy/guardrailstudio/scripts/apply-grafana-edge.sh dev`) until
`verify.sh --edge` reports TLS Ready.

### Migrating dev from single-node (shared app + observability)

If the app node still has `workload=observability` or PVCs used legacy `standard`:

```bash
# 1. Pool + unlabel (install-env runs this; or run alone)
./deploy/guardrailstudio/scripts/ensure-observability-node-pool.sh dev

# 2. Drop stuck pd-standard PVCs / failed Helm release
helm uninstall netra-kps -n observability 2>/dev/null || true
kubectl delete pvc -n observability --all 2>/dev/null || true

# 3. Reinstall
HELM_TIMEOUT=45m ./deploy/guardrailstudio/scripts/install-env.sh dev

# 4. Verify isolation
kubectl get nodes -L workload,cloud.google.com/gke-nodepool
kubectl get pods -n observability -o wide
kubectl get pods -n synapse6ai-dev -o wide
```

**Infra owners:** app pool via GuardrailStudio Terraform (`primary_nodes`); observability
pool via Terraform `observability_nodes` or Netra `ensure-observability-node-pool.sh`.
If Terraform created the pool, Netra deploys with `SKIP_OBSERVABILITY_POOL_CREATE=true`.

## App integration

GuardrailStudio `key-stack` Helm values:

```yaml
observability:
  otlpEndpoint: "netra-otel-collector.observability.svc.cluster.local:4317"
  environment: "dev"
  obsUrl: "https://obs-dev.instantevidence.ai"
```
