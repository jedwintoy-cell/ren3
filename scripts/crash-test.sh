#!/bin/bash
# Reaper test: hard-kill a busy worker (SIGKILL, like the OOM killer) so its
# job is stranded in 'processing', then wait for the reaper to recover it.
# Usage: scripts/crash-test.sh [N]
set -uo pipefail
cd "$(dirname "$0")/.."
N=${1:-20}
r=scripts/redis.sh

$r DEL requeued reaper:seen >/dev/null
scripts/produce.sh "$N"
until [ "$($r LLEN processing)" -ge 1 ] 2>/dev/null; do sleep 1; done
sleep 1

# Find the node of one worker pod; kind nodes are podman containers.
node=$(kubectl -n ingest get pods -l app=worker \
  -o jsonpath='{.items[0].spec.nodeName}')
echo "$(date +%T) SIGKILL one worker process on $node"
podman exec "$node" pkill -9 -o -f "/scripts/worker.sh"

start=$(date +%s)
while true; do
  sleep 10
  jobs=$($r LLEN jobs); processing=$($r LLEN processing); d=$($r GET done)
  echo "t=$(( $(date +%s) - start ))s jobs=$jobs processing=$processing done=$d in_processing=[$($r LRANGE processing 0 -1 | tr '\n' ' ')]"
  if [ "$d" = "$N" ] && [ "$processing" = 0 ] && [ "$jobs" = 0 ]; then break; fi
  [ $(( $(date +%s) - start )) -gt 300 ] && break
done

echo "jobs re-queued by the reaper: $($r GET requeued)"
echo "--- worker restarts: $(kubectl -n ingest get pods -l app=worker \
  -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].restartCount} {end}')"
scripts/check.sh "$N"
