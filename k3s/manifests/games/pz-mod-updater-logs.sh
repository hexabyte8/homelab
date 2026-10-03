#!/usr/bin/env bash
# Prints logs from the most recent pz-mod-updater CronJob run.
#
# Usage:
#   ./pz-mod-updater-logs.sh          # latest completed run
#   ./pz-mod-updater-logs.sh -f       # follow the next run live (waits for it to start)
set -euo pipefail

NAMESPACE="games"
FOLLOW=false

if [[ "${1:-}" == "-f" ]]; then
  FOLLOW=true
fi

if [[ "$FOLLOW" == true ]]; then
  echo "Waiting for the next pz-mod-updater run to start (runs every 15m)..." >&2
  latest_before=$(kubectl -n "$NAMESPACE" get pods -l job-name --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)

  while :; do
    latest_now=$(kubectl -n "$NAMESPACE" get pods -l job-name --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)
    if [[ -n "$latest_now" && "$latest_now" != "$latest_before" ]]; then
      break
    fi
    sleep 5
  done

  echo "New run detected: $latest_now" >&2
  exec kubectl -n "$NAMESPACE" logs -f "$latest_now"
fi

pod=$(kubectl -n "$NAMESPACE" get pods -l job-name --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1:].metadata.name}')

if [[ -z "$pod" ]]; then
  echo "No pz-mod-updater job pods found in namespace '$NAMESPACE'." >&2
  exit 1
fi

echo "Showing logs for: $pod" >&2
kubectl -n "$NAMESPACE" logs "$pod"
