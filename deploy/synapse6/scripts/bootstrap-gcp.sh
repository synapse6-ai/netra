#!/usr/bin/env bash
# Synapse6 GCP bootstrap reference commands (run manually with org admin).
#
# This script prints the gcloud commands — it does NOT execute them.
# Review, adapt, then run line by line.

set -euo pipefail

PROJECT=synapse6-observability
REGION=us-central1
CLUSTER=netra-platform

cat <<EOF
# === Synapse6 observability GCP bootstrap ===

# 1. Project
gcloud projects create ${PROJECT} --organization=YOUR_ORG_ID
gcloud billing projects link ${PROJECT} --billing-account=YOUR_BILLING_ID

# 2. APIs
gcloud services enable container.googleapis.com storage.googleapis.com \\
  iam.googleapis.com compute.googleapis.com dns.googleapis.com \\
  --project=${PROJECT}

# 3. GCS buckets + lifecycle (15d logs, 7d traces)
gsutil mb -p ${PROJECT} -l ${REGION} gs://synapse6-obs-netra-loki
gsutil mb -p ${PROJECT} -l ${REGION} gs://synapse6-obs-netra-tempo
gsutil lifecycle set - gs://synapse6-obs-netra-loki <<'LIFECYCLE'
{"rule": [{"action": {"type": "Delete"}, "condition": {"age": 15}}]}
LIFECYCLE
gsutil lifecycle set - gs://synapse6-obs-netra-tempo <<'LIFECYCLE'
{"rule": [{"action": {"type": "Delete"}, "condition": {"age": 7}}]}
LIFECYCLE

# 4. GSAs + bucket IAM
gcloud iam service-accounts create netra-loki --project=${PROJECT}
gcloud iam service-accounts create netra-tempo --project=${PROJECT}
gsutil iam ch serviceAccount:netra-loki@${PROJECT}.iam.gserviceaccount.com:objectAdmin \\
  gs://synapse6-obs-netra-loki
gsutil iam ch serviceAccount:netra-tempo@${PROJECT}.iam.gserviceaccount.com:objectAdmin \\
  gs://synapse6-obs-netra-tempo

# 5. GKE (regional control plane, observability node pool)
gcloud container clusters create ${CLUSTER} \\
  --project=${PROJECT} \\
  --region=${REGION} \\
  --workload-pool=${PROJECT}.svc.id.goog \\
  --release-channel=regular \\
  --enable-ip-alias \\
  --num-nodes=0 \\
  --autoscaling-profile=optimize-utilization

gcloud container node-pools create observability \\
  --project=${PROJECT} \\
  --cluster=${CLUSTER} \\
  --region=${REGION} \\
  --machine-type=e2-standard-4 \\
  --num-nodes=2 \\
  --node-labels=workload=observability \\
  --node-taints=workload=observability:NoSchedule \\
  --disk-type=pd-balanced \\
  --disk-size=100

# 6. Workload Identity bindings (after install-central creates K8s SAs)
gcloud iam service-accounts add-iam-policy-binding netra-loki@${PROJECT}.iam.gserviceaccount.com \\
  --role=roles/iam.workloadIdentityUser \\
  --member="serviceAccount:${PROJECT}.svc.id.goog[observability/netra-loki]"
gcloud iam service-accounts add-iam-policy-binding netra-tempo@${PROJECT}.iam.gserviceaccount.com \\
  --role=roles/iam.workloadIdentityUser \\
  --member="serviceAccount:${PROJECT}.svc.id.goog[observability/netra-tempo]"

# 7. VPC peering to synapse6ai-dev, synapse6ai-stg, synapse6-prod (org network team)

# 8. Install Netra
# gcloud container clusters get-credentials ${CLUSTER} --region=${REGION} --project=${PROJECT}
# kubectl create secret generic netra-ingest-auth --namespace=observability \\
#   --from-literal=token="\$(openssl rand -base64 32)"
# ./deploy/synapse6/scripts/install-central.sh

EOF
