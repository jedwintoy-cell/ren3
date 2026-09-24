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
set -uo pipefail
cd "$(dirname "$0")/.."
N=${1:-100}; SCALE_AT=${2:-5}; out=${3:-results/scaledown.csv}
r=scripts/redis.sh
mkdir -p "$(dirname "$out")"

set_max() {
  kubectl -n ingest patch scaledobject worker --type merge \
    -p "{\"spec\":{\"maxReplicaCount\":$1}}" >/dev/null
}
restore() { set_max 10; kill "$watcher" 2>/dev/null; }

pods() { kubectl -n ingest get pods -l app=worker --no-headers 2>/dev/null | wc -l; }
ready() { kubectl -n ingest get deploy worker -o jsonpath='{.status.readyReplicas}'; }

# Clear leftovers of a previous (failed) run first, so old pods can scale away.
$r DEL jobs processing done >/dev/null
echo "waiting for old worker pods to go away..."
until [ "$(pods)" = 0 ]; do sleep 2; done

scripts/watch-replicas.sh "$out" 5 &
watcher=$!
trap restore EXIT

scripts/produce.sh "$N"

until [ "$(ready)" -ge "$SCALE_AT" ] 2>/dev/null; do sleep 1; done
echo "$(ready) replicas ready, done=$($r GET done | grep . || echo 0): scaling max 10 -> 2"
set_max 2
t0=$(date +%s)
until [ "$(pods)" -le 2 ]; do sleep 1; done
echo "removed pods took $(( $(date +%s) - t0 ))s to terminate"

# Idle = queue empty and 'done' unchanged for 30s (stuck jobs never finish).
last=-1; stable=0
while [ "$stable" -lt 30 ]; do
  sleep 5
  cur=$($r GET done)
  if [ "$($r LLEN jobs)" = 0 ] && [ "$cur" = "$last" ]; then
    stable=$((stable + 5))
  else
    stable=0
  fi
  last=$cur
done

echo "stuck in processing: $($r LRANGE processing 0 -1 | tr '\n' ' ')"
scripts/check.sh "$N"
