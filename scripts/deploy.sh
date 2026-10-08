#!/usr/bin/env bash
# Apply the namespace, service account and Job to the current cluster and stream
# the demo's logs.
#
#   scripts/deploy.sh --repo <owner/name> --issue <number> \
#       --image <repo>@sha256:<digest> [--yes] [--no-logs]
#
# --repo is the disposable GitHub repository the agents work in (also
# GITHUB_REPOSITORY); there is deliberately no default, so a run can never
# silently open pull requests in the wrong repository. --image is the immutable
# reference printed by scripts/build-image.sh (also IMAGE in the environment);
# --issue is the issue to fix in that repository (also ISSUE_NUMBER;
# scripts/create-issue.sh prints one). The Secret must already exist
# (scripts/setup-secrets.sh). An earlier Job of the same name is replaced.
# Exits 0 only if the Job succeeded.
set -euo pipefail

# shellcheck source=scripts/kube-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kube-common.sh"
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
assume_yes=0
follow=1
IMAGE=${IMAGE:-}
ISSUE_NUMBER=${ISSUE_NUMBER:-}
GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-}

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case $1 in
    --repo) GITHUB_REPOSITORY=${2:?missing value for $1}; shift ;;
    --issue) ISSUE_NUMBER=${2:?missing value for $1}; shift ;;
    --image) IMAGE=${2:?missing value for $1}; shift ;;
    -y | --yes) assume_yes=1 ;;
    --no-logs) follow=0 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

[[ $GITHUB_REPOSITORY =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  die "--repo <owner/name> is required: the disposable repository the agents work in"
[[ $ISSUE_NUMBER =~ ^[1-9][0-9]*$ ]] || die "--issue must be a positive integer"
[[ $IMAGE =~ @sha256:[0-9a-f]{64}$ ]] ||
  die "--image must be pinned by digest (repo@sha256:...), as printed by scripts/build-image.sh"
command -v envsubst >/dev/null || die "envsubst not found (gettext)"

require_cluster
export IMAGE ISSUE_NUMBER GITHUB_REPOSITORY

kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1 ||
  die "Secret $namespace/$secret_name not found; run scripts/setup-secrets.sh first"
kubectl get runtimeclass kata-clh >/dev/null 2>&1 ||
  die "RuntimeClass kata-clh not found; the Kata runtime is not installed on this cluster"

kubectl apply -f "$repo_root/k8s/namespace.yaml" -f "$repo_root/k8s/service-account.yaml"
# Jobs are immutable: a rerun replaces the old one (and with it its logs).
kubectl delete job "$job_name" -n "$namespace" --ignore-not-found --wait=true
# shellcheck disable=SC2016  # envsubst takes the variable names literally
envsubst '${IMAGE} ${ISSUE_NUMBER} ${GITHUB_REPOSITORY}' <"$repo_root/k8s/job.yaml" | kubectl apply -f -
echo "Job $namespace/$job_name started: $GITHUB_REPOSITORY issue #$ISSUE_NUMBER, image $IMAGE"

((follow)) || exit 0

# A Kata pod takes a while to schedule, pull and boot; logs only work once the
# container has started.
echo "Waiting for the pod to start..."
deadline=$((SECONDS + 600))
while :; do
  phase=$(kubectl get pods -n "$namespace" -l "job-name=$job_name" \
    -o 'jsonpath={.items[0].status.phase}' 2>/dev/null || true)
  case $phase in
    Running | Succeeded | Failed) break ;;
  esac
  ((SECONDS < deadline)) || {
    kubectl describe pods -n "$namespace" -l "job-name=$job_name" | tail -n 25 >&2
    die "the pod did not start within 10 minutes (phase: ${phase:-none})"
  }
  sleep 3
done

kubectl logs -f -n "$namespace" "job/$job_name" || true

# The log stream ends when the container does; report how the Job ended.
for _ in $(seq 1 30); do
  succeeded=$(kubectl get job "$job_name" -n "$namespace" -o 'jsonpath={.status.succeeded}' 2>/dev/null || true)
  failed=$(kubectl get job "$job_name" -n "$namespace" -o 'jsonpath={.status.failed}' 2>/dev/null || true)
  [[ $succeeded == 1 ]] && { echo "Job succeeded."; exit 0; }
  [[ -n $failed && $failed != 0 ]] && die "Job failed (kubectl logs -n $namespace job/$job_name)"
  sleep 2
done
die "Job did not reach a final state"
