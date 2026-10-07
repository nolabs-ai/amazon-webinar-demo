#!/usr/bin/env bash
# Remove the demo from the current cluster.
#
#   scripts/teardown.sh [--purge] [--yes]
#
# Deletes the Job (and its pod, logs and emptyDirs). With --purge it also
# deletes the namespace, which removes the Secret `github-agents` and the
# service account. The Kata node group and everything under infra/ are not
# touched. GitHub is not touched either: close the demo PR and delete the
# `demo/webinar-fix` branch yourself before the next rehearsal.
set -euo pipefail

# shellcheck source=scripts/kube-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kube-common.sh"
assume_yes=0
purge=0

while (($#)); do
  case $1 in
    --purge) purge=1 ;;
    -y | --yes) assume_yes=1 ;;
    -h | --help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

require_cluster

kubectl delete job "$job_name" -n "$namespace" --ignore-not-found --wait=true
if ((purge)); then
  kubectl delete namespace "$namespace" --ignore-not-found --wait=true
  echo "Namespace $namespace deleted (Secret and service account included)."
else
  echo "Job deleted. The Secret and namespace remain; use --purge to remove them."
fi
