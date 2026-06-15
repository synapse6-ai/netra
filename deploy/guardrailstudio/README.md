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
│   ├── label-observability-node.sh
│   └── install-env.sh            # dev|stg|prod → install.sh + verify --deep
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

git clone https://github.com/kuldeep-key/netra.git && cd netra

# 1. GCS + Workload Identity
PROJECT=synapse6ai-dev ./deploy/guardrailstudio/scripts/bootstrap-gcp.sh

# 2. Observability node label (single-node dev: no taint)
./deploy/guardrailstudio/scripts/label-observability-node.sh

# 3. Core stack
HELM_TIMEOUT=45m ./deploy/guardrailstudio/scripts/install-env.sh dev

# 4. Grafana edge (after creating secrets from examples/)
kubectl apply -f deploy/guardrailstudio/manifests/grafana-oauth2-proxy.yaml
kubectl apply -f deploy/guardrailstudio/dev/grafana-ingress.yaml
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

## Secrets (create before Grafana ingress)

| Secret | Purpose |
|--------|---------|
| `grafana-google-oauth` | GCP OAuth `client-id`, `client-secret` |
| `grafana-superadmin-emails` | `emails.txt` — one address per line (mirror `PLATFORM_ADMIN_EMAILS`) |
| `grafana-oauth2-env` | `redirect-url` — e.g. `https://obs-dev.instantevidence.ai/oauth2/callback` |

`install.sh` creates `netra-grafana-admin` for break-glass local admin.

## Auth flow

```
Browser → Ingress (obs-*) → oauth2-proxy → Grafana (auth.proxy / X-Forwarded-Email)
```

## Troubleshooting

### Helm `pending-install` / `failed` with no pods

Usually an interrupted install (laptop terminal closed, `context canceled`, flaky
API watch). `install.sh` now auto-removes stuck releases before retry and
auto-labels the observability node after GKE node replacement.

```bash
helm list -n observability
helm history netra-kps -n observability
kubectl get pods,pvc,events -n observability
kubectl get nodes -l workload=observability

# Manual recovery (if needed):
helm uninstall netra-kps -n observability
./deploy/guardrailstudio/scripts/label-observability-node.sh
HELM_TIMEOUT=45m ./deploy/guardrailstudio/scripts/install-env.sh dev
```

**Do not** run long installs from a laptop IDE terminal. Use **GKE Cloud Shell**
or the GitHub Actions workflow `.github/workflows/deploy-guardrailstudio-dev.yml`.

### CI deploy (dev)

1. Add repo secret `GCP_SA_KEY` (SA with `container.admin` + `storage.admin` on `synapse6ai-dev`).
2. Actions → **Deploy GuardrailStudio Dev (Netra)** → Run workflow.
3. After core stack is healthy, apply Grafana edge secrets + ingress manually.

## App integration

GuardrailStudio `key-stack` Helm values:

```yaml
observability:
  otlpEndpoint: "netra-otel-collector.observability.svc.cluster.local:4317"
  environment: "dev"
  obsUrl: "https://obs-dev.instantevidence.ai"
```
