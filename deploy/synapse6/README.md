# Synapse6 deployment bundle

Commercial-grade **central observability platform** for Synapse6. Implements
one Netra stack on `synapse6-observability` with agents forwarding telemetry
from dev/stg/prod app clusters.

> Single-cluster deployments use stock [README.md](../../README.md) — this bundle
> is only for the three app-cluster + one hub topology.

```
deploy/synapse6/
├── README.md
├── docs/
│   └── central-observability.md   ← full runbook
├── dashboards/
│   └── python-api-multi-cluster.json
├── central/
│   ├── values/               ← Helm overlays (edit WI + buckets before install)
│   ├── alloy/                ← central stack Alloy config
│   ├── extras/               ← ILBs, auth gateway (applied via NETRA_EXTRA_MANIFESTS)
│   ├── manifests/
│   │   └── networkpolicies/  ← hub NPs (applied via NETRA_NETWORKPOLICIES_DIR)
│   └── examples/             ← ingest-auth Secret template
├── agents/
│   ├── alloy/                ← logs + metrics remote_write
│   └── otel-collector/       ← trace forwarding
└── scripts/
    ├── bootstrap-gcp.sh
    ├── install-central.sh
    ├── install-agents.sh
    ├── verify-synapse6-central.sh
    └── verify-synapse6-agents.sh
```

## Quick start

See [docs/central-observability.md](docs/central-observability.md).

## App integration (Synapse6)

Apps in each app cluster send OTLP to the **local agent** DaemonSet:

```
synapse6-agent-otel.observability.svc.cluster.local:4317   # gRPC
synapse6-agent-otel.observability.svc.cluster.local:4318   # HTTP
```

The agent forwards traces to the central platform with `k8s.cluster.name`,
`cluster`, and `deployment.environment` stamped on every span. Metrics and logs
use the `cluster` label (see agents/alloy/config.alloy).

**Ingest auth:** All ILB surfaces validate the shared Bearer token except Faro
(browser SDK — CORS + NetworkPolicy CIDRs; add HTTPS edge ingress for public RUM).

Use **`http://`** URLs for central ILB endpoints unless your org terminates TLS
at an edge proxy.

Generic Netra contract: [docs/app-integration.md](../../docs/app-integration.md).

## Edit before first install

| File | What to set |
| ---- | ----------- |
| `central/values/loki.yaml` | GCS bucket + `iam.gke.io/gcp-service-account` |
| `central/values/tempo.yaml` | GCS bucket + WI annotation |
| `central/manifests/networkpolicies/ingest-cross-cluster.yaml` | App cluster Pod CIDR `/24` blocks |
| `central/examples/ingest-auth-secret.example.yaml` | Copy to cluster Secret, never commit token |

## Environment matrix

| App cluster | `K8S_CLUSTER` | `ENVIRONMENT` | GCP project |
| ----------- | ------------- | ------------- | ----------- |
| guardrailstudio-dev | `guardrailstudio-dev` | `dev` | `synapse6ai-dev` |
| guardrailstudio-stg | `guardrailstudio-stg` | `stage` | `synapse6ai-stg` |
| guardrailstudio-prod | `guardrailstudio-prod` | `prod` | `synapse6-prod` |

Central: `NETRA_CLUSTER=netra-platform` (set by `install-central.sh`).

## Verify

```bash
INGEST_TOKEN='...' ./deploy/synapse6/scripts/verify-synapse6-central.sh   # hub cluster
./deploy/synapse6/scripts/verify-synapse6-agents.sh                      # app cluster
```
