#!/usr/bin/env bash
# Start or pause the Kata worker node (the only compute that costs money while
# the demo sits idle).
#
#   scripts/kata-node.sh start    scale to one node and wait until it is Ready
#   scripts/kata-node.sh pause    scale to zero
#   scripts/kata-node.sh status   show the node group and node state
#
# A new node takes several minutes: it downloads the custom guest kernel while
# booting. Start it well before the session; scripts/check-ready.sh confirms it.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# shellcheck disable=SC1091  # path is resolved at run time
source "$repo_root/config/webinar.env"
action=${1:-}
case $action in
  start | pause | status) ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) ||
  die "no valid AWS session (aws sso login / AWS_PROFILE?)"
[[ $account == "$WEBINAR_AWS_ACCOUNT" ]] ||
  die "AWS account is $account, expected $WEBINAR_AWS_ACCOUNT"

scale() {
  aws eks update-nodegroup-config --region "$WEBINAR_REGION" --cluster-name "$WEBINAR_CLUSTER" \
    --nodegroup-name "$WEBINAR_NODEGROUP" --scaling-config "minSize=0,maxSize=2,desiredSize=$1" >/dev/null
}

case $action in
  start)
    scale 1
    echo "Scaling $WEBINAR_NODEGROUP to 1 node; waiting for the node group (several minutes)..."
    aws eks wait nodegroup-active --region "$WEBINAR_REGION" --cluster-name "$WEBINAR_CLUSTER" \
      --nodegroup-name "$WEBINAR_NODEGROUP"
    context=$(kubectl config current-context 2>/dev/null || true)
    [[ $context == *"$WEBINAR_CLUSTER"* ]] ||
      die "kube context '${context:-none}' does not name $WEBINAR_CLUSTER (aws eks update-kubeconfig --name $WEBINAR_CLUSTER)"
    kubectl wait --for=condition=Ready node -l katacontainers.io/kata-runtime=true --timeout=15m
    kubectl get runtimeclass kata-clh >/dev/null
    echo "Kata node is Ready."
    ;;
  pause)
    scale 0
    echo "Scaled $WEBINAR_NODEGROUP to 0; compute charges for the node stop shortly."
    ;;
  status)
    aws eks describe-nodegroup --region "$WEBINAR_REGION" --cluster-name "$WEBINAR_CLUSTER" \
      --nodegroup-name "$WEBINAR_NODEGROUP" \
      --query 'nodegroup.[status, scalingConfig.desiredSize]' --output text |
      awk '{print "node group: " $1 ", desired nodes: " $2}'
    kubectl get nodes -L katacontainers.io/kata-runtime 2>/dev/null || echo "(kubectl cannot reach the cluster)"
    ;;
esac
