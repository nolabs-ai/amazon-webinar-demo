#!/usr/bin/env bash
# Install kata-deploy on the Kata nodes and confirm the kata-clh RuntimeClass.
# Requires helm and kubectl pointed at the cluster.
set -euo pipefail

KATA_CHART_VERSION="${KATA_CHART_VERSION:-3.27.0}"
KATA_NAMESPACE="${KATA_NAMESPACE:-kata-system}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-600s}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for cmd in helm kubectl; do
  command -v "$cmd" >/dev/null || { echo "missing required command: $cmd" >&2; exit 1; }
done

echo "Installing kata-deploy ${KATA_CHART_VERSION} into namespace ${KATA_NAMESPACE}"
helm upgrade --install kata-deploy \
  oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
  --version "${KATA_CHART_VERSION}" \
  --namespace "${KATA_NAMESPACE}" \
  --create-namespace \
  --values "${HERE}/kata-values.yaml"

echo "Waiting for kata-deploy rollout"
daemonsets="$(kubectl -n "${KATA_NAMESPACE}" get daemonset -o name)"
[[ -n "${daemonsets}" ]] || { echo "no DaemonSet found in ${KATA_NAMESPACE}" >&2; exit 1; }
for ds in ${daemonsets}; do
  kubectl -n "${KATA_NAMESPACE}" rollout status "${ds}" --timeout="${ROLLOUT_TIMEOUT}"
done

# kata-deploy creates the RuntimeClass after configuring the node.
echo "Waiting for RuntimeClass kata-clh"
for _ in $(seq 1 60); do
  if kubectl get runtimeclass kata-clh >/dev/null 2>&1; then
    kubectl get runtimeclass kata-clh
    echo "OK: kata-clh is installed"
    exit 0
  fi
  sleep 5
done
echo "RuntimeClass kata-clh did not appear within 5 minutes" >&2
kubectl get runtimeclass >&2 || true
exit 1
