#!/bin/bash
# The case's check: once idle, done == N and 'processing' is empty.
# Usage: scripts/check.sh N
N=${1:?usage: check.sh N}
r="$(dirname "$0")/redis.sh"
jobs=$($r LLEN jobs); processing=$($r LLEN processing); done_=$($r GET done)
echo "jobs=$jobs processing=$processing done=${done_:-0} (expected $N)"
if [ "${done_:-0}" = "$N" ] && [ "$processing" = 0 ] && [ "$jobs" = 0 ]; then
  echo PASS
else
  echo FAIL; exit 1
fi
