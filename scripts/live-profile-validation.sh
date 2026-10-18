#!/usr/bin/env bash
# Run inside k8s/profile-validation-pod.yaml via kubectl exec.
set -euo pipefail

repo=MateSaary/webinar-demo-sandbox
issue=1
pr=2
work=/workspace/profile-validation
profiles=/tmp/profile-validation-profiles
results=/tmp/profile-validation-results
failures=0

rm -rf "$work" "$profiles" "$results"
mkdir -p "$work" "$profiles" "$results" "$HOME/.pi/developer" "$HOME/.pi/reviewer"
printf 'developer-owned\n' >"$HOME/.pi/developer/boundary-sentinel"
printf 'reviewer-owned\n' >"$HOME/.pi/reviewer/boundary-sentinel"

for role in developer reviewer; do
  jq --arg repo "$repo" '
    walk(if type == "string" then split("nolabs-ai/amazon-webinar-demo") | join($repo) else . end)
    | .network.allow_domain = ["chatgpt.com", "auth.openai.com"]
    | .network.credentials = []
    | .network.custom_credentials = {}
  ' "/demo/profiles/$role.json" >"$profiles/$role.json"
  nono profile validate "$profiles/$role.json"
done

cd "$work"
git init -q
git config user.name "Boundary Validator"
git config user.email "boundary-validator@example.invalid"
printf 'fixture\n' >fixture.txt
git add fixture.txt
git commit -qm initial

pass() { printf 'PASS %-9s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %-9s %s\n' "$1" "$2" >&2; failures=$((failures + 1)); }

run_role() {
  local role=$1
  shift
  nono run -s --allow-cwd --profile "$profiles/$role.json" -- "$@"
}

expect_ok() {
  local role=$1 label=$2
  shift 2
  if run_role "$role" "$@" >"$results/out" 2>"$results/err"; then pass "$role" "$label"; else
    fail "$role" "$label"
    sed -n '1,3p' "$results/err" >&2
  fi
}

expect_deny() {
  local role=$1 label=$2
  shift 2
  if run_role "$role" "$@" >"$results/out" 2>"$results/err"; then
    fail "$role" "$label (unexpectedly allowed)"
  else
    pass "$role" "$label"
  fi
}

expect_l7_deny() {
  local role=$1 label=$2
  shift 2
  if run_role "$role" "$@" >"$results/out" 2>"$results/err"; then
    fail "$role" "$label (unexpectedly allowed)"
  elif grep -q '"error":"Forbidden"' "$results/out"; then
    pass "$role" "$label"
  else
    fail "$role" "$label (not denied by endpoint policy)"
    sed -n '1,3p' "$results/out" >&2
    sed -n '1,3p' "$results/err" >&2
  fi
}

expect_why() {
  local expected=$1 role=$2 label=$3 command=$4
  shift 4
  local actual
  actual=$(nono why --json --profile "$profiles/$role.json" --command "$command" -- "$@" | jq -r .status)
  if [[ $actual == "$expected" ]]; then pass "$role" "$label ($expected)"; else
    fail "$role" "$label (expected $expected, got $actual)"
  fi
}

expect_why_caller() {
  local expected=$1 role=$2 label=$3 command=$4 caller=$5
  shift 5
  local actual
  actual=$(nono why --json --profile "$profiles/$role.json" --command "$command" --caller "$caller" -- "$@" | jq -r .status)
  if [[ $actual == "$expected" ]]; then pass "$role" "$label ($expected)"; else
    fail "$role" "$label (expected $expected, got $actual)"
  fi
}

# Filesystem and local command boundaries.
expect_ok developer "read/write working tree" sh -c 'printf x > developer-write && test -f developer-write'
expect_ok developer "read own Pi directory" cat "$HOME/.pi/developer/boundary-sentinel"
expect_deny developer "read reviewer Pi directory denied" cat "$HOME/.pi/reviewer/boundary-sentinel"
expect_ok developer "create designated branch" git switch -c demo/webinar-fix
expect_deny developer "create arbitrary branch denied" git switch -c demo/other
expect_deny developer "unknown git operation denied" git tag boundary-test
expect_deny developer "direct SSH denied" ssh -T git@ssh.github.com

expect_ok reviewer "read working tree" git status --short
expect_deny reviewer "working-tree write denied" sh -c 'printf x > reviewer-write'
expect_ok reviewer "read own Pi directory" cat "$HOME/.pi/reviewer/boundary-sentinel"
expect_deny reviewer "read developer Pi directory denied" cat "$HOME/.pi/developer/boundary-sentinel"
expect_deny reviewer "branch creation denied" git switch -c reviewer/webinar-suggestion
expect_deny reviewer "commit denied" git commit --allow-empty -m blocked
expect_deny reviewer "push denied" git push origin HEAD
expect_deny reviewer "direct SSH denied" ssh -T git@ssh.github.com

# Raw mounted credentials must be invisible to both roles.
for role in developer reviewer; do
  for secret in token ssh-private-key model-api-key model-auth-json; do
    expect_deny "$role" "raw secret $secret denied" cat "/run/secrets/github/$secret"
  done
done

# Network boundaries: only the selected model hosts are direct session routes.
for role in developer reviewer; do
  expect_deny "$role" "arbitrary Internet denied" curl -sS --max-time 5 https://example.com
  expect_ok "$role" "Codex model host reachable" curl -sS --max-time 10 -o /dev/null https://chatgpt.com/
done

# GitHub token is usable only through the gh command proxy and REST allow-list.
for role in developer reviewer; do
  expect_ok "$role" "allowed issue read" gh api "repos/$repo/issues/$issue" --jq .number
  expect_ok "$role" "allowed PR read" gh api "repos/$repo/pulls/$pr" --jq .number
  expect_deny "$role" "GraphQL command denied" gh api --hostname api.github.com graphql -f query='{ viewer { login } }'
  expect_deny "$role" "gh merge command denied" gh pr merge "$pr" --repo "$repo" --merge
done
expect_l7_deny reviewer "REST approval endpoint denied" gh api --method POST \
  "repos/$repo/pulls/$pr/reviews" -f event=APPROVE
expect_l7_deny reviewer "low-level merge endpoint denied" gh api --method PUT \
  "repos/$repo/pulls/$pr/merge"
expect_l7_deny developer "low-level merge endpoint denied" gh api --method PUT \
  "repos/$repo/pulls/$pr/merge"

# Static command-policy decisions for actions we deliberately do not execute.
expect_why allowed developer "designated push policy" git push demo-secure HEAD:refs/heads/demo/webinar-fix
expect_why denied developer "default-branch push policy" git push demo-secure HEAD:refs/heads/main
expect_why_caller allowed developer "mediated GitHub SSH policy" ssh git -p 443 git@ssh.github.com \
  "git-receive-pack '/$repo.git'"
expect_why_caller denied developer "alternate SSH host policy" ssh git -p 443 git@example.com \
  "git-receive-pack '/$repo.git'"

sessions=$(nono audit list --json | jq 'length')
printf '\nAudit sessions recorded: %s\n' "$sessions"
if ((failures)); then
  printf 'BOUNDARY VALIDATION FAILED: %s check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'BOUNDARY VALIDATION PASSED\n'
