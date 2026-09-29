#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
kind delete cluster --name "$CLUSTER"
rm -f "$KUBECONFIG"
