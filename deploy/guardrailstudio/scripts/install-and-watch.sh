#!/usr/bin/env bash
# Start Netra install in the background and watch progress in this terminal.
#
# Usage:
#   ./deploy/guardrailstudio/scripts/install-and-watch.sh dev
#   HELM_TIMEOUT=45m ./deploy/guardrailstudio/scripts/install-and-watch.sh dev
#
# Ctrl+C stops the watcher only — install keeps running in the background.

set -euo pipefail

ENV="${1:-dev}"
LOG="${INSTALL_LOG:-/tmp/netra-install.log}"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

: > "$LOG"
echo "Starting install ($ENV) — log: $LOG"
echo "HELM_TIMEOUT=${HELM_TIMEOUT:-30m}"
echo "Ctrl+C stops this watcher only; install continues (tail -f $LOG)"
echo ""

HELM_TIMEOUT="${HELM_TIMEOUT:-30m}" \
  ./deploy/guardrailstudio/scripts/install-env.sh "$ENV" >>"$LOG" 2>&1 &
INSTALL_PID=$!

stop_watch() {
  kill "$WATCH_PID" 2>/dev/null || true
  echo ""
  echo "Watcher stopped. Install still running (PID $INSTALL_PID)."
  echo "  tail -f $LOG"
  echo "  ./deploy/guardrailstudio/scripts/watch-install.sh"
  exit 130
}
trap stop_watch INT TERM

./deploy/guardrailstudio/scripts/watch-install.sh "$LOG" &
WATCH_PID=$!

wait "$INSTALL_PID"
INSTALL_EXIT=$?

kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true

echo ""
echo "Install exited with code $INSTALL_EXIT"
exit "$INSTALL_EXIT"
