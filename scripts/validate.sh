#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

kubectl kustomize "${repo_root}/k8s" > /dev/null

printf 'Kustomize rendered all Kubernetes manifests successfully.\n'
