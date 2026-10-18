#!/usr/bin/env bash
# One-command, read-only readiness check before a rehearsal or the webinar.
#
#   scripts/check-ready.sh [--latest]
#
# Checks the AWS account, kube context, Kata node, RuntimeClass, Secret key
# names, the GitHub issue, branch and main state, and that the frozen image
# (config/image) exists in ECR and is protected from expiry. --latest checks the
# newest build (artifacts/image.txt) instead, for rehearsals before freezing. It changes nothing and never reads a credential's value. Prints PASS,
# WARN or FAIL per check and ends with READY or NOT READY (exit 0 or 1).
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
latest=0
case ${1:-} in
  -h | --help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --latest) latest=1 ;;
  "") ;;
  *) echo "error: unknown argument: $1" >&2; exit 2 ;;
esac

# shellcheck disable=SC1091  # path is resolved at run time
source "$repo_root/config/webinar.env"
namespace=github-agents-demo
secret=github-agents
branch=demo/webinar-fix
failures=0

result() { printf '%-5s %-34s %s\n' "$1" "$2" "${3:-}"; [[ $1 != FAIL ]] || failures=$((failures + 1)); }

# --- AWS ------------------------------------------------------------------------
account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || account=
if [[ -z $account ]]; then
  result FAIL "AWS identity" "no valid session (aws sso login / AWS_PROFILE?)"
elif [[ $account != "$WEBINAR_AWS_ACCOUNT" ]]; then
  result FAIL "AWS identity" "account $account, expected $WEBINAR_AWS_ACCOUNT"
else
  result PASS "AWS identity" "account $account"
fi

# --- Kubernetes -----------------------------------------------------------------
context=$(kubectl config current-context 2>/dev/null) || context=
if [[ $context != *"$WEBINAR_CLUSTER"* ]]; then
  result FAIL "kube context" "'${context:-none}' does not name $WEBINAR_CLUSTER"
elif ! kubectl cluster-info --request-timeout=15s >/dev/null 2>&1; then
  result FAIL "kube context" "$context is not reachable"
else
  result PASS "kube context" "$context"
  ready=$(kubectl get nodes -l katacontainers.io/kata-runtime=true \
    -o 'jsonpath={range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null |
    grep -c '^True$')
  if ((ready > 0)); then
    result PASS "Kata node" "$ready Ready"
  else
    result FAIL "Kata node" "none Ready (RUNBOOK.md section 2 starts it)"
  fi
  if kubectl get runtimeclass kata-clh >/dev/null 2>&1; then
    result PASS "RuntimeClass" "kata-clh"
  else
    result FAIL "RuntimeClass" "kata-clh not found"
  fi
  # shellcheck disable=SC2016  # the go-template is for kubectl, not the shell
  keys=$(kubectl -n "$namespace" get secret "$secret" \
    -o 'go-template={{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null | sort | tr '\n' ' ')
  if [[ -z $keys ]]; then
    result FAIL "Secret" "$namespace/$secret not found (scripts/setup-secrets.sh)"
  elif [[ ${keys% } == "model-api-key ssh-private-key token" ]]; then
    result PASS "Secret keys" "${keys% }"
  else
    result FAIL "Secret keys" "found '${keys% }', expected 'model-api-key ssh-private-key token'"
  fi
  if kubectl -n "$namespace" get job github-agents-demo >/dev/null 2>&1; then
    result WARN "previous Job" "still present; the next run replaces it"
  fi
fi

# --- GitHub ---------------------------------------------------------------------
owner=${WEBINAR_REPO%%/*}
issue=$(gh api "repos/$WEBINAR_REPO/issues/$WEBINAR_ISSUE" --jq '"\(.state) \(.pull_request != null)"' 2>/dev/null) || issue=
if [[ $issue == "open false" ]]; then
  result PASS "GitHub issue" "$WEBINAR_REPO#$WEBINAR_ISSUE is open"
else
  result FAIL "GitHub issue" "$WEBINAR_REPO#$WEBINAR_ISSUE: ${issue:-not readable (gh auth status?)}"
fi
if gh api "repos/$WEBINAR_REPO/git/ref/heads/$branch" >/dev/null 2>&1; then
  result FAIL "branch state" "$branch exists (scripts/reset-demo.sh)"
else
  open_prs=$(gh api "repos/$WEBINAR_REPO/pulls?state=open&head=$owner:$branch" --jq length 2>/dev/null) || open_prs='?'
  if [[ $open_prs == 0 ]]; then
    result PASS "branch state" "no $branch branch, no open demo PR"
  else
    result FAIL "branch state" "$open_prs open PR(s) from $branch (scripts/reset-demo.sh)"
  fi
fi

main_sha=$(gh api "repos/$WEBINAR_REPO/git/ref/heads/main" --jq .object.sha 2>/dev/null) || main_sha=
base_sha=$(gh api "repos/$WEBINAR_REPO/git/ref/tags/demo-baseline" --jq .object.sha 2>/dev/null) || base_sha=
if [[ -z $main_sha ]]; then
  result FAIL "main state" "cannot read main in $WEBINAR_REPO"
elif [[ -z $base_sha ]]; then
  result WARN "main state" "no demo-baseline tag, so a merge on main would go unnoticed (reset-demo.sh --set-baseline)"
elif [[ $main_sha == "$base_sha" ]]; then
  result PASS "main state" "at the demo baseline ${base_sha:0:7}"
else
  result FAIL "main state" "main (${main_sha:0:7}) is not at the baseline (${base_sha:0:7}); scripts/reset-demo.sh restores it"
fi

# --- Image ----------------------------------------------------------------------
if ((latest)); then
  image=$(cat "$repo_root/artifacts/image.txt" 2>/dev/null || true)
  image_hint="artifacts/image.txt missing (scripts/build-image.sh)"
else
  image=$(cat "$repo_root/config/image" 2>/dev/null || true)
  image_hint="nothing frozen in config/image (scripts/freeze-image.sh)"
fi
if [[ ! $image =~ @sha256:[0-9a-f]{64}$ ]]; then
  result FAIL "image digest" "$image_hint"
elif tags=$(aws ecr describe-images --region "$WEBINAR_REGION" --repository-name "$WEBINAR_ECR_REPOSITORY" \
  --image-ids "imageDigest=${image##*@}" --query 'imageDetails[0].imageTags' --output text 2>/dev/null); then
  short=${image##*@sha256:}
  if ((latest)); then
    result PASS "image digest" "sha256:${short:0:12} in ECR (newest build)"
  elif [[ $tags == *frozen-* ]]; then
    result PASS "image digest" "sha256:${short:0:12} in ECR, frozen"
  else
    result WARN "image digest" "sha256:${short:0:12} is in ECR but not tagged frozen-*; newer builds may expire it (scripts/freeze-image.sh)"
  fi
else
  result FAIL "image digest" "${image##*@} not found in ECR $WEBINAR_ECR_REPOSITORY"
fi

# --- Not checkable from here ----------------------------------------------------
result INFO "model key and balance" "not read by design; a rehearsal is the test"
result INFO "token and deploy key expiry" "check on the GitHub settings pages the day before"

echo
if ((failures == 0)); then
  echo "READY"
else
  echo "NOT READY: $failures check(s) failed"
  exit 1
fi
