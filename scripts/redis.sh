#!/bin/bash
# Runs a redis-cli command inside the Redis pod, e.g.: scripts/redis.sh LLEN jobs
# With no arguments, reads commands from stdin (one per line).
exec kubectl -n ingest exec -i deploy/redis -c redis -- \
  sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@"' _ "$@"
