#!/usr/bin/env bash
# Watch Netra install progress. Run in a separate terminal while install runs.
#
# Usage:
#   ./deploy/guardrailstudio/scripts/watch-install.sh
#   ./deploy/guardrailstudio/scripts/watch-install.sh /path/to/install.log

set -euo pipefail

LOG="${1:-/tmp/netra-install.log}"
INTERVAL="${WATCH_INTERVAL:-10}"

while true; do
  printf '\033[2J\033[H'   # clear screen
  date
  echo ""

  if pgrep -f 'install-env\.sh|scripts/install\.sh' >/dev/null 2>&1; then
    echo "● install process: running"
    HELM_PID="$(pgrep -f 'helm upgrade --install netra-' 2>/dev/null | head -1 || true)"
    if [[ -n "$HELM_PID" ]] && ps -p "$HELM_PID" -o etime= 2>/dev/null | grep -q .; then
      echo "  helm child: PID $HELM_PID elapsed $(ps -p "$HELM_PID" -o etime= 2>/dev/null | xargs)"
      ps -p "$HELM_PID" -o args= 2>/dev/null | sed 's/^/  /' | cut -c1-100
    fi
  else
    echo "○ install process: not running"
  fi

  echo ""
  echo "── log (last 20 lines) ──"
  tail -20 "$LOG" 2>/dev/null || echo "(no log yet — start install first)"

  echo ""
  echo "── applied resources (observability ns) ──"
  NS_COUNT="$(kubectl get all,cm,secret,role,sa,pvc,job -n observability --no-headers 2>/dev/null | wc -l | xargs)"
  echo "  namespaced objects: ${NS_COUNT:-0}"
  if helm list -n observability -f 'netra-kps' -q 2>/dev/null | grep -q .; then
    KPS_STATUS="$(helm list -n observability -f 'netra-kps' -o json 2>/dev/null | sed -n 's/.*"status":"\([^"]*\)".*/\1/p' | head -1)"
    echo "  netra-kps: ${KPS_STATUS:-unknown} (log stays quiet during Helm --wait; 10–30m is normal)"
  fi

  echo ""
  echo "── helm releases (observability) ──"
  helm list -n observability 2>/dev/null || true

  echo ""
  echo "── pods ──"
  kubectl get pods -n observability -o wide 2>/dev/null || echo "(none yet)"

  echo ""
  echo "── PVCs ──"
  kubectl get pvc -n observability 2>/dev/null || true

  if ! pgrep -f 'install-env\.sh|scripts/install\.sh' >/dev/null 2>&1; then
    echo ""
    echo "Install finished or stopped. Last log lines above."
    if helm list -n observability -f 'netra-blackbox' -q 2>/dev/null | grep -q .; then
      echo "✓ netra-blackbox present — core stack likely complete. Run: ./scripts/verify.sh --deep"
    fi
    break
  fi

  sleep "$INTERVAL"
done
