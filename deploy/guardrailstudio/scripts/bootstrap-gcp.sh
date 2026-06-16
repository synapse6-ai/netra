#!/usr/bin/env bash
# GuardrailStudio — bootstrap GCS + GSAs + Workload Identity for per-cluster Netra.
#
# Idempotent where gcloud/gsutil allow. Run once per GCP project before install.sh.
#
# Usage:
#   PROJECT=synapse6ai-dev ./deploy/guardrailstudio/scripts/bootstrap-gcp.sh
#   PROJECT=synapse6ai-stg REGION=us-central1 ./deploy/guardrailstudio/scripts/bootstrap-gcp.sh
#
# Requires: gcloud, gsutil, permission to create buckets + service accounts + IAM.

set -euo pipefail

PROJECT="${PROJECT:?set PROJECT (e.g. synapse6ai-dev)}"
REGION="${REGION:-us-central1}"
LOKI_BUCKET="${LOKI_BUCKET:-${PROJECT}-netra-loki}"
TEMPO_BUCKET="${TEMPO_BUCKET:-${PROJECT}-netra-tempo}"
LOKI_GSA="netra-loki"
TEMPO_GSA="netra-tempo"
NS="${NETRA_NAMESPACE:-observability}"
K8S_LOKI_SA="${K8S_LOKI_SA:-netra-loki}"
K8S_TEMPO_SA="${K8S_TEMPO_SA:-netra-tempo}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 1
  }
}

require gcloud
require gsutil

say "Project: ${PROJECT}  region: ${REGION}"
gcloud config set project "$PROJECT" >/dev/null

say "Enable APIs (no-op if already enabled)"
gcloud services enable storage.googleapis.com iam.googleapis.com --project="$PROJECT" >/dev/null 2>&1 || true

create_bucket() {
  local bucket="$1"
  local lifecycle_days="$2"
  if gsutil ls -p "$PROJECT" "gs://${bucket}" >/dev/null 2>&1; then
    echo "  bucket exists: gs://${bucket}"
  else
    gsutil mb -p "$PROJECT" -l "$REGION" "gs://${bucket}"
    echo "  created: gs://${bucket}"
  fi
  local lifecycle_file
  lifecycle_file="$(mktemp)"
  printf '{"rule": [{"action": {"type": "Delete"}, "condition": {"age": %s}}]}' \
    "$lifecycle_days" >"$lifecycle_file"
  gsutil lifecycle set "$lifecycle_file" "gs://${bucket}"
  rm -f "$lifecycle_file"
  echo "  lifecycle: delete after ${lifecycle_days}d"
}

say "GCS buckets"
create_bucket "$LOKI_BUCKET" 15
create_bucket "$TEMPO_BUCKET" 7

create_gsa() {
  local name="$1"
  if gcloud iam service-accounts describe "${name}@${PROJECT}.iam.gserviceaccount.com" \
    --project="$PROJECT" >/dev/null 2>&1; then
    echo "  GSA exists: ${name}@${PROJECT}.iam.gserviceaccount.com"
  else
    gcloud iam service-accounts create "$name" \
      --project="$PROJECT" \
      --display-name="Netra ${name} (${PROJECT})"
    echo "  created GSA: ${name}@${PROJECT}.iam.gserviceaccount.com"
  fi
}

say "Service accounts"
create_gsa "$LOKI_GSA"
create_gsa "$TEMPO_GSA"

say "Bucket IAM (objectAdmin + legacyBucketReader for bucket metadata)"
gsutil iam ch \
  "serviceAccount:${LOKI_GSA}@${PROJECT}.iam.gserviceaccount.com:objectAdmin,legacyBucketReader" \
  "gs://${LOKI_BUCKET}"
gsutil iam ch \
  "serviceAccount:${TEMPO_GSA}@${PROJECT}.iam.gserviceaccount.com:objectAdmin,legacyBucketReader" \
  "gs://${TEMPO_BUCKET}"

say "Workload Identity bindings (namespace ${NS})"
bind_wi() {
  local gsa="$1"
  local k8s_sa="$2"
  gcloud iam service-accounts add-iam-policy-binding \
    "${gsa}@${PROJECT}.iam.gserviceaccount.com" \
    --project="$PROJECT" \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT}.svc.id.goog[${NS}/${k8s_sa}]" \
    --quiet >/dev/null
  echo "  bound ${gsa} ← ${NS}/${k8s_sa}"
}

bind_wi "$LOKI_GSA" "$K8S_LOKI_SA"
bind_wi "$TEMPO_GSA" "$K8S_TEMPO_SA"

say "Done."
cat <<EOF

Next steps:
  1. Dedicated observability node pool (label + taint):
       ./deploy/guardrailstudio/scripts/ensure-observability-node-pool.sh dev

  2. Create Grafana edge secrets (see deploy/guardrailstudio/examples/).

  3. Install Netra (example dev):
       NETRA_CLUSTER=guardrailstudio-dev \\
       NETRA_VALUES_OVERLAY=deploy/guardrailstudio/dev \\
       ./scripts/install.sh

  4. Apply Grafana ingress:
       kubectl apply -f deploy/guardrailstudio/dev/grafana-ingress.yaml

Buckets:
  loki: gs://${LOKI_BUCKET}
  tempo: gs://${TEMPO_BUCKET}
GSAs:
  ${LOKI_GSA}@${PROJECT}.iam.gserviceaccount.com
  ${TEMPO_GSA}@${PROJECT}.iam.gserviceaccount.com
EOF
