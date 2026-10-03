#!/bin/bash
# The case's check: once idle, done == N and 'processing' is empty.
# Usage: scripts/check.sh N

# N = expected number of finished jobs (required).
N=${1:?usage: check.sh N}

# Path of the helper that runs redis-cli inside the Redis pod.
r="$(dirname "$0")/redis.sh"

# Read the three numbers: waiting jobs, jobs in progress, finished counter.
# (The variable is "done_" because "done" is a bash keyword.)
jobs=$($r LLEN jobs); processing=$($r LLEN processing); done_=$($r GET done)

# Print them; ${done_:-0} shows 0 if the counter doesn't exist yet.
echo "jobs=$jobs processing=$processing done=${done_:-0} (expected $N)"

# PASS only if all N are done AND nothing is left waiting or stuck in progress.
# On FAIL, exit with code 1 so other scripts can detect the failure.
if [ "${done_:-0}" = "$N" ] && [ "$processing" = 0 ] && [ "$jobs" = 0 ]; then
  echo PASS
else
  echo FAIL; exit 1
fi
