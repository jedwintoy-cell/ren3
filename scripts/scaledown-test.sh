#!/bin/bash
# Forces KEDA to scale down in the middle of a run, then runs the check.
#
#   1. reset Redis state and wait until no old worker pods are left
#      (terminating pods could otherwise steal jobs from this run)
#   2. push N jobs and wait until SCALE_AT worker replicas are ready
#   3. lower the ScaledObject's maxReplicaCount to 2
#      -> the HPA removes the extra pods while they are busy
#   4. wait until the queue is empty and 'done' stops changing, then check
#   5. restore maxReplicaCount to 10
#
# Usage: scripts/scaledown-test.sh [N] [SCALE_AT] [CSV_OUT]

# Stop on unset variables and pipe failures (not -e: a FAIL must not abort the test early).
set -uo pipefail
# Go to the project root.
cd "$(dirname "$0")/.."
# Arguments with defaults: 100 jobs, scale down once 5 workers are ready, CSV file path.
N=${1:-100}; SCALE_AT=${2:-5}; out=${3:-results/scaledown.csv}
# Short name for the Redis helper.
r=scripts/redis.sh
# Make sure the folder for the CSV file exists.
mkdir -p "$(dirname "$out")"

# Function: change the ScaledObject's maxReplicaCount to the number given ($1).
# "patch --type merge" edits just that one field of the live object.
set_max() {
  kubectl -n ingest patch scaledobject worker --type merge \
    -p "{\"spec\":{\"maxReplicaCount\":$1}}" >/dev/null
}
# Function run on exit: put max back to 10 and stop the background CSV logger.
restore() { set_max 10; kill "$watcher" 2>/dev/null; }

# Function: number of worker pods that exist (including ones still terminating).
pods() { kubectl -n ingest get pods -l app=worker --no-headers 2>/dev/null | wc -l; }
# Function: number of worker pods that are Ready.
ready() { kubectl -n ingest get deploy worker -o jsonpath='{.status.readyReplicas}'; }

# Clear leftovers of a previous (failed) run first, so old pods can scale away.
$r DEL jobs processing done >/dev/null
echo "waiting for old worker pods to go away..."
# Poll every 2 s until there are no worker pods at all.
until [ "$(pods)" = 0 ]; do sleep 2; done

# Start the CSV logger in the background ("&") and remember its process ID ($!).
scripts/watch-replicas.sh "$out" 5 &
watcher=$!
# Whatever happens from here on (success, failure, Ctrl-C), run "restore" on exit.
trap restore EXIT

# Push the jobs; KEDA will start scaling the workers up.
scripts/produce.sh "$N"

# Wait until at least SCALE_AT workers are Ready (errors hidden while the value is still empty).
until [ "$(ready)" -ge "$SCALE_AT" ] 2>/dev/null; do sleep 1; done
# Log the moment of scale-down; "grep . || echo 0" prints 0 if 'done' doesn't exist yet.
echo "$(ready) replicas ready, done=$($r GET done | grep . || echo 0): scaling max 10 -> 2"
# Force the scale-down: the HPA must now remove pods that are busy with jobs.
set_max 2
# Measure how long the removed pods take to disappear (graceful vs. killed after 30 s).
t0=$(date +%s)
until [ "$(pods)" -le 2 ]; do sleep 1; done
echo "removed pods took $(( $(date +%s) - t0 ))s to terminate"

# Idle = queue empty and 'done' unchanged for 30s (stuck jobs never finish).
# "last" = previous 'done' value, "stable" = seconds it has stayed unchanged.
last=-1; stable=0
while [ "$stable" -lt 30 ]; do
  sleep 5
  cur=$($r GET done)
  # Queue empty and no progress since the last sample? Count 5 more stable seconds.
  if [ "$($r LLEN jobs)" = 0 ] && [ "$cur" = "$last" ]; then
    stable=$((stable + 5))
  # Otherwise work is still happening: reset the stable timer.
  else
    stable=0
  fi
  last=$cur
done

# Show any job IDs stranded in 'processing' (the jobs that would be lost).
# tr turns the one-per-line output into one line separated by spaces.
echo "stuck in processing: $($r LRANGE processing 0 -1 | tr '\n' ' ')"
# Final verdict: PASS or FAIL (and the exit code of this script).
scripts/check.sh "$N"
