#!/bin/bash
# Deploys Redis + worker into namespace "ingest".
# Creates the Redis password Secret once (random value, not stored in git).
set -euo pipefail
cd "$(dirname "$0")/.."

kubectl apply -f k8s/00-namespace.yaml
if ! kubectl -n ingest get secret redis-auth >/dev/null 2>&1; then
  kubectl -n ingest create secret generic redis-auth \
    --from-literal=password="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
fi
kubectl apply -f k8s/redis.yaml -f k8s/worker.yaml
kubectl -n ingest rollout status deploy/redis --timeout=120s
