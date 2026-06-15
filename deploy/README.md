# Deployment bundles

Optional customer- or environment-specific overlays that sit **outside** the
generic Netra core. Each bundle wraps `scripts/install.sh` with env vars and
extra manifests — Netra itself is not edited for a specific deployment.

| Bundle | Description |
| ------ | ----------- |
| [guardrailstudio/](guardrailstudio/) | Per-cluster Netra on GuardrailStudio app GKE (dev/stg/prod) |
| [synapse6/](synapse6/) | Central observability GKE + agents on dev/stg/prod app clusters *(gitignored — private)* |

To add a new bundle, copy the pattern in `deploy/synapse6/`:

```
deploy/<name>/
├── README.md
├── docs/           ← runbooks for this deployment only
├── central/        ← Helm overlays + manifests (if hub topology)
├── agents/         ← per-cluster agents (if remote ingest)
├── dashboards/     ← multi-cluster dashboards (optional)
└── scripts/        ← thin wrappers that export NETRA_* env vars
```

Generic extension hooks (see `scripts/install.sh` header):

- `NETRA_VALUES_OVERLAY` — Helm value overlays per chart
- `NETRA_SKIP_CLUSTER_LABEL=1` — skip Prometheus/OTel cluster label overrides
- `NETRA_ALLOY_CONFIG` — alternate Alloy config file
- `NETRA_EXTRA_MANIFESTS` — extra kubectl manifests applied after stock NPs
- `NETRA_EXTRA_DASHBOARDS_DIR` — additional Grafana dashboard JSON files
- `NETRA_NETWORKPOLICIES_DIR` — replace stock ingest NetworkPolicies (hub topology)

Application integration contract (topology-neutral): [docs/app-integration.md](../docs/app-integration.md).
