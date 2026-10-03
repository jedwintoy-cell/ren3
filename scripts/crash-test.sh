#!/bin/bash
# Reaper test: hard-kill a busy worker (SIGKILL, like the OOM killer) so its
# job is stranded in 'processing', then wait for the reaper to recover it.
# Usage: scripts/crash-test.sh [N]

# Stop on unset variables and pipe failures (not -e: keep going to report results).
set -uo pipefail
# Go to the project root.
cd "$(dirname "$0")/.."
# Number of jobs (default 20) and short name for the Redis helper.
N=${1:-20}
r=scripts/redis.sh

# Reset the reaper's counter and memory so this test starts clean.
$r DEL requeued reaper:seen >/dev/null
# Push the jobs.
scripts/produce.sh "$N"
# Wait until at least one job is being worked on, plus 1 s so the worker is mid-job.
until [ "$($r LLEN processing)" -ge 1 ] 2>/dev/null; do sleep 1; done
sleep 1

# Find the node of one worker pod; kind nodes are podman containers.
node=$(kubectl -n ingest get pods -l app=worker \
  -o jsonpath='{.items[0].spec.nodeName}')
echo "$(date +%T) SIGKILL one worker process on $node"
# Inside that node container, send signal 9 (SIGKILL, cannot be trapped) to the
# oldest (-o) process whose command line (-f) contains /scripts/worker.sh.
# From the node, the worker is NOT PID 1 of our namespace, so SIGKILL works.
podman exec "$node" pkill -9 -o -f "/scripts/worker.sh"

# Every 10 s print the queue state, until everything is done or 300 s have passed.
start=$(date +%s)
while true; do
  sleep 10
  jobs=$($r LLEN jobs); processing=$($r LLEN processing); d=$($r GET done)
  echo "t=$(( $(date +%s) - start ))s jobs=$jobs processing=$processing done=$d in_processing=[$($r LRANGE processing 0 -1 | tr '\n' ' ')]"
  # All jobs done and nothing left anywhere: the reaper recovered the stranded job.
  if [ "$d" = "$N" ] && [ "$processing" = 0 ] && [ "$jobs" = 0 ]; then break; fi
  # Safety timeout so the test can't run forever.
  [ $(( $(date +%s) - start )) -gt 300 ] && break
done

# Evidence: how many jobs the reaper re-queued (its counter in Redis)...
echo "jobs re-queued by the reaper: $($r GET requeued)"
# ...and the restart count of the worker pods (a killed container is restarted).
echo "--- worker restarts: $(kubectl -n ingest get pods -l app=worker \
  -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].restartCount} {end}')"
# Final verdict: PASS or FAIL.
scripts/check.sh "$N"
