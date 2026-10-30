# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables are used by the scripts that source this
# Shared by setup-secrets.sh, deploy.sh and teardown.sh. Sourced, not executed.

namespace=github-agents-demo
job_name=github-agents-demo
secret_name=github-agents

die() {
  echo "error: $*" >&2
  exit 1
}

# Refuse to continue unless kubectl points at a reachable cluster, show which
# one, and (unless --yes was given) ask before touching it.
require_cluster() {
  command -v kubectl >/dev/null || die "kubectl not found"
  local context server
  context=$(kubectl config current-context 2>/dev/null) ||
    die "kubectl has no current context; point it at the demo cluster first (aws eks update-kubeconfig)"
  kubectl cluster-info --request-timeout=15s >/dev/null 2>&1 ||
    die "cannot reach the cluster for context '$context'"
  server=$(kubectl config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null || true)
  # The context ARN carries the AWS account ID; mask it so the guard can be shown on screen.
  echo "kubectl context: $(sed -E 's/[0-9]{12}/************/g' <<<"$context")"
  echo "API server:      ${server:-unknown}"
  if [[ ${assume_yes:-0} != 1 ]]; then
    [[ -t 0 ]] || die "not a terminal; pass --yes to confirm the cluster above"
    local answer
    read -r -p "Use this cluster? [y/N] " answer
    [[ $answer == y || $answer == Y ]] || die "aborted"
  fi
}
