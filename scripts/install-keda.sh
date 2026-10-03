#!/bin/bash
# Installs KEDA from its official Helm chart (version pinned for reproducibility).
# (For an offline install, airgap/install-airgap.sh uses a local chart file instead.)

# Stop on errors, unset variables and failures inside pipes.
set -euo pipefail

# Register KEDA's chart repository under the name "kedacore".
# "|| true": don't fail if it's already registered.
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true

# Download the repository's latest list of chart versions.
helm repo update kedacore

# Install KEDA 2.21.0 as a "release" called keda in namespace keda
# ("upgrade --install" = install if missing, upgrade if present).
# --wait blocks until all KEDA pods are Ready, giving up after 5 minutes.
helm upgrade --install keda kedacore/keda --version 2.21.0 \
  --namespace keda --create-namespace --wait --timeout 5m
