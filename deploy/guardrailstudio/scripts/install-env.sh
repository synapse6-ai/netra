#!/usr/bin/env bash
# Install Netra on GuardrailStudio dev|stg|prod.
#
# Usage:
#   ./deploy/guardrailstudio/scripts/install-env.sh dev
#   HELM_TIMEOUT=45m ./deploy/guardrailstudio/scripts/install-env.sh stg
#
# Run from GKE Cloud Shell or GitHub Actions — not a laptop IDE terminal.
# bootstrap-gcp.sh is one-time per GCP project.
# ensure-observability-node-pool.sh: pool create (skippable) + unlabel/wait (always).

set -euo pipefail

ENV="${1:-}"
case "$ENV" in
  dev)
    NETRA_CLUSTER=guardrailstudio-dev
    OVERLAY=deploy/guardrailstudio/dev
    ;;
  stg)
    NETRA_CLUSTER=guardrailstudio-stg
    OVERLAY=deploy/guardrailstudio/stg
    ;;
  prod)
    NETRA_CLUSTER=guardrailstudio-prod
    OVERLAY=deploy/guardrailstudio/prod
    ;;
  *)
    echo "usage: $0 dev|stg|prod" >&2
    exit 1
    ;;
esac

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

export SKIP_OBSERVABILITY_POOL_CREATE="${SKIP_OBSERVABILITY_POOL_CREATE:-${SKIP_OBSERVABILITY_POOL:-false}}"
./deploy/guardrailstudio/scripts/ensure-observability-node-pool.sh "$ENV"

NETRA_CLUSTER="$NETRA_CLUSTER" \
NETRA_VALUES_OVERLAY="$OVERLAY" \
./scripts/install.sh

./scripts/verify.sh --deep

if [[ "${SKIP_GRAFANA_EDGE:-false}" == "true" ]]; then
  echo ""
  echo "Skipped Grafana edge (SKIP_GRAFANA_EDGE=true)."
else
  ./deploy/guardrailstudio/scripts/apply-grafana-edge.sh "$ENV"
  ./scripts/verify.sh --edge
fi
