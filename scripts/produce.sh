#!/bin/bash
# Pushes N unique job IDs onto the 'jobs' list. Usage: scripts/produce.sh 20
# Resets the counters first so the check afterwards is simply done == N.
set -euo pipefail
N=${1:?usage: produce.sh N}
run=$(date +%s)
{
  echo "DEL jobs processing done"
  for i in $(seq 1 "$N"); do echo "RPUSH jobs job-$run-$i"; done
} | "$(dirname "$0")/redis.sh" >/dev/null
echo "pushed $N jobs (run $run); jobs=$("$(dirname "$0")/redis.sh" LLEN jobs)"
