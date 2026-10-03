#!/bin/bash
# Runs a redis-cli command inside the Redis pod, e.g.: scripts/redis.sh LLEN jobs
# With no arguments, reads commands from stdin (one per line).
#
# How it works:
#   kubectl -n ingest exec -i deploy/redis -c redis --
#       run a command inside the Redis pod's "redis" container; -i passes our
#       input (stdin) through, so piped commands reach redis-cli.
#   sh -c '...' _ "$@"
#       run a small shell INSIDE the pod. The single quotes stop our own machine
#       from expanding $REDIS_PASSWORD; it's expanded inside the pod, where the
#       variable exists (from the Secret). So we never handle the password here.
#       "_" fills the shell's $0 slot, so "$@" inside = the arguments given to this script.
#   exec
#       replace this script with kubectl (no extra process; exit code passes through).
exec kubectl -n ingest exec -i deploy/redis -c redis -- \
  sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@"' _ "$@"
