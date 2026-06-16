#!/usr/bin/env bash
# Grant deploy SA access to read netra-grafana-edge-{env} from Secret Manager.
#
# Usage:
#   ./deploy/guardrailstudio/scripts/grant-grafana-edge-gsm-access.sh dev

set -euo pipefail

ENV="${1:-}"
case "$ENV" in
  dev)
    PROJECT="${GCP_PROJECT:-synapse6ai-dev}"
    GSM_SECRET="${NETRA_GRAFANA_EDGE_GSM:-netra-grafana-edge-dev}"
    DEPLOY_SA="${NETRA_DEPLOY_SA:-github-netra-deploy@${PROJECT}.iam.gserviceaccount.com}"
    ;;
  stg)
    PROJECT="${GCP_PROJECT:-synapse6ai-stg}"
    GSM_SECRET="${NETRA_GRAFANA_EDGE_GSM:-netra-grafana-edge-stg}"
    DEPLOY_SA="${NETRA_DEPLOY_SA:-github-netra-deploy@${PROJECT}.iam.gserviceaccount.com}"
    ;;
  prod)
    PROJECT="${GCP_PROJECT:-synapse6-prod}"
    GSM_SECRET="${NETRA_GRAFANA_EDGE_GSM:-netra-grafana-edge-prod}"
    DEPLOY_SA="${NETRA_DEPLOY_SA:-github-netra-deploy@${PROJECT}.iam.gserviceaccount.com}"
    ;;
  *)
    echo "usage: $0 dev|stg|prod" >&2
    exit 1
    ;;
esac

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 1
  }
}
require gcloud

echo "Granting secretAccessor on ${GSM_SECRET} to ${DEPLOY_SA} (project ${PROJECT})"
gcloud secrets add-iam-policy-binding "$GSM_SECRET" \
  --project="$PROJECT" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/secretmanager.secretAccessor" \
  --quiet

echo "Done."
