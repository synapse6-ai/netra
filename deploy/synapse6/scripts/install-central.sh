#!/usr/bin/env bash
# Install full Netra on the Synapse6 central observability cluster.
#
# Prerequisites:
#   - kubectl context → synapse6-observability / netra-platform
#   - Observability node pool (2× e2-standard-4 recommended)
#   - GCS buckets + WI annotations in central/values/loki.yaml and tempo.yaml
#   - Edit central/manifests/networkpolicies/ Pod CIDRs (no REPLACE left)
#   - netra-ingest-auth Secret in observability namespace
#
# Usage:
#   ./deploy/synapse6/scripts/install-central.sh
#
# Dev-only escape hatches:
#   SYNAPSE6_SKIP_INGEST_SECRET_CHECK=1  — install without netra-ingest-auth
#   SYNAPSE6_SKIP_CIDR_CHECK=1           — allow placeholder CIDRs (not for prod)

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
CENTRAL="$REPO_ROOT/deploy/synapse6/central"
NP_DIR="$CENTRAL/manifests/networkpolicies"

export NETRA_SKIP_CLUSTER_LABEL=1
export NETRA_CLUSTER=netra-platform
export NETRA_VALUES_OVERLAY="$CENTRAL/values"
export NETRA_ALLOY_CONFIG="$CENTRAL/alloy/config.alloy"
export NETRA_NETWORKPOLICIES_DIR="$NP_DIR"
export NETRA_EXTRA_MANIFESTS="$CENTRAL/extras"
export NETRA_EXTRA_DASHBOARDS_DIR="$REPO_ROOT/deploy/synapse6/dashboards"

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

echo "==> Synapse6 central Netra install"
echo "    cluster: $NETRA_CLUSTER"
echo "    overlay: $NETRA_VALUES_OVERLAY"
echo

kubectl get namespace observability >/dev/null 2>&1 || kubectl create namespace observability

if [[ "${SYNAPSE6_SKIP_CIDR_CHECK:-0}" != "1" ]]; then
  if grep -qr 'REPLACE' "$NP_DIR"; then
    die "placeholder Pod CIDRs remain under $NP_DIR

  Replace each REPLACE comment with real clusterIpv4Cidr values, or set
  SYNAPSE6_SKIP_CIDR_CHECK=1 for local smoke tests only."
  fi
fi

if [[ "${SYNAPSE6_SKIP_INGEST_SECRET_CHECK:-0}" != "1" ]]; then
  if ! kubectl get secret -n observability netra-ingest-auth >/dev/null 2>&1; then
    die "missing Secret observability/netra-ingest-auth

  Central OTel validates Bearer tokens from this Secret.
  Create it from $CENTRAL/examples/ingest-auth-secret.example.yaml
  or set SYNAPSE6_SKIP_INGEST_SECRET_CHECK=1 for dev-only installs."
  fi
fi

"$REPO_ROOT/scripts/install.sh"

echo
echo "==> Central install complete."
echo "    Next:"
echo "      1. Map internal LB IPs to obs.internal DNS (central/extras/ingest-internal-services.yaml)"
echo "      2. INGEST_TOKEN=... ./deploy/synapse6/scripts/verify-synapse6-central.sh"
echo "      3. ./deploy/synapse6/scripts/install-agents.sh on each app cluster"
