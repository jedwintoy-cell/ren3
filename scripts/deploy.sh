#!/bin/bash
# Deploys Redis + worker into namespace "ingest".
# Creates the Redis password Secret once (random value, not stored in git).
# Safe to run again at any time ("apply" only changes what differs).

# Stop on errors, unset variables and failures inside pipes.
set -euo pipefail
# Go to the project root.
cd "$(dirname "$0")/.."

# Create the namespace first; everything else goes inside it.
kubectl apply -f k8s/00-namespace.yaml

# Create the password Secret only if it doesn't exist yet ("!" = NOT; output hidden).
# The password is 24 random bytes from /dev/urandom, turned into text with base64,
# then reduced to letters and digits only (tr -dc keeps just those characters).
# Never overwritten afterwards, so Redis, the workers and KEDA keep agreeing on it.
if ! kubectl -n ingest get secret redis-auth >/dev/null 2>&1; then
  kubectl -n ingest create secret generic redis-auth \
    --from-literal=password="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
fi

# Create or update every object: Redis, worker, KEDA scaling, reaper.
kubectl apply -f k8s/redis.yaml -f k8s/worker.yaml -f k8s/keda.yaml -f k8s/reaper.yaml

# Wait until the Redis pod is running and Ready (its readiness probe passes).
kubectl -n ingest rollout status deploy/redis --timeout=120s

# The worker script lives in a ConfigMap; pods only read it at start, so
# restart them to pick up changes (no-op cost when scaled to 0).
kubectl -n ingest rollout restart deploy/worker
