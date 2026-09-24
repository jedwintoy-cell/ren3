#!/bin/bash
# Installs KEDA from its official Helm chart (version pinned for reproducibility).
set -euo pipefail
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update kedacore
helm upgrade --install keda kedacore/keda --version 2.21.0 \
  --namespace keda --create-namespace --wait --timeout 5m
