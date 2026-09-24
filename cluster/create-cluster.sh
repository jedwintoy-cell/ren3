#!/bin/bash
# Builds the patched kind node image and creates the "ren3" cluster.
set -euo pipefail
cd "$(dirname "$0")/.."

podman build -t localhost/kind-node-cgv1:v1.31.12 -f cluster/Containerfile cluster
kind create cluster --name ren3 --config kind-config.yaml
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes
