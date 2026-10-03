#!/bin/bash
# Pushes N unique job IDs onto the 'jobs' list. Usage: scripts/produce.sh 20
# Resets the counters first so the check afterwards is simply done == N.

# Stop on errors, unset variables and failures inside pipes.
set -euo pipefail

# N = first argument; stop with a usage message if it's missing.
N=${1:?usage: produce.sh N}

# Current time in seconds; makes job IDs unique per run (job-<run>-1, job-<run>-2, ...).
run=$(date +%s)

# Print one Redis command per line and send them all through ONE redis-cli connection:
#   DEL ...    -> start from a clean slate (empty lists, done counter removed)
#   RPUSH ...  -> append each job ID to the end (right) of the 'jobs' list
# seq 1 N prints the numbers 1..N. Redis' replies are thrown away (>/dev/null).
{
  echo "DEL jobs processing done"
  for i in $(seq 1 "$N"); do echo "RPUSH jobs job-$run-$i"; done
} | "$(dirname "$0")/redis.sh" >/dev/null

# Confirm what landed in the queue.
echo "pushed $N jobs (run $run); jobs=$("$(dirname "$0")/redis.sh" LLEN jobs)"
