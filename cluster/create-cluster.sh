#!/bin/bash
# Builds the patched kind node image and creates the "ren3" cluster.
# Usage: ./cluster/create-cluster.sh

# Safety switches: stop on any error (-e), on use of an unset variable (-u),
# and when any command inside a pipe fails (pipefail).
set -euo pipefail

# Go to the project root (the folder above this script), wherever we're run from.
cd "$(dirname "$0")/.."

# Build the patched node image from cluster/Containerfile and name it
# localhost/kind-node-cgv1:v1.31.12 (the name kind-config.yaml refers to).
podman build -t localhost/kind-node-cgv1:v1.31.12 -f cluster/Containerfile cluster

# Create the cluster: kind starts 3 node containers and runs kubeadm in them.
# It also writes the kubectl connection settings (context "kind-ren3").
kind create cluster --name ren3 --config kind-config.yaml

# Block until all 3 nodes report Ready (or fail after 3 minutes).
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# Show the nodes so you can see the result.
kubectl get nodes
