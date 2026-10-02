#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
developer_profile="$repo_root/profiles/developer.json"
reviewer_profile="$repo_root/profiles/reviewer.json"
known_hosts="$repo_root/config/github_known_hosts"
secret_path=/run/secrets/github/token
secret_created=0
ssh_agent_started=0
test_dir=

cleanup() {
  if [[ -n "$test_dir" && "$test_dir" == /srv/nono-webinar-test.* ]]; then
    sudo rm -r -- "$test_dir"
  fi
  if ((secret_created)); then
    sudo rm -f -- "$secret_path"
  fi
  if ((ssh_agent_started)); then
    ssh-agent -k >/dev/null
  fi
}
trap cleanup EXIT

[[ $(uname -s) == Linux ]] || {
  echo "profile behavior tests require Linux" >&2
  exit 1
}

for command in nono git gh curl jq ssh-agent ssh-keygen; do
  command -v "$command" >/dev/null || {
    echo "missing required command: $command" >&2
    exit 1
  }
done

expected_fingerprint=SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
[[ $(ssh-keygen -lf "$known_hosts" | awk '{print $2}') == "$expected_fingerprint" ]] || {
  echo "GitHub known-host fingerprint does not match the pinned value" >&2
  exit 1
}

expected_version="nono $(tr -d '\n' < "$repo_root/NONO_VERSION")"
[[ $(nono --version) == "$expected_version" ]] || {
  echo "expected $expected_version, found $(nono --version)" >&2
  exit 1
}

nono profile validate "$developer_profile"
nono profile validate "$reviewer_profile"

jq -e '
  .command_policies.commands.gh.from.session.invocation_policy.allow
  | any(.argv.prefix? == ["pr", "review"])
' "$reviewer_profile" >/dev/null
jq -e '
  .command_policies.commands.gh.from.session.sandbox.credentials[0]
    .endpoint_policy.allow
  | any(.method == "POST" and
        .path == "/repos/nolabs-ai/amazon-webinar-demo/pulls/*/reviews")
' "$reviewer_profile" >/dev/null

eval "$(ssh-agent -s)" >/dev/null
ssh_agent_started=1

[[ ! -e "$secret_path" ]] || {
  echo "refusing to replace existing $secret_path" >&2
  exit 1
}

sudo install -d -m 0755 "$(dirname "$secret_path")"
printf 'ci-placeholder-not-a-real-credential\n' | sudo tee "$secret_path" >/dev/null
secret_created=1
sudo chmod 0444 "$secret_path"

test_dir=$(sudo mktemp -d /srv/nono-webinar-test.XXXXXX)
sudo chown "$(id -u):$(id -g)" "$test_dir"
mkdir "$test_dir/repo"
cd "$test_dir/repo"

git init -q
git config user.name "Webinar Test"
git config user.email "webinar@example.invalid"
printf 'fixture\n' > fixture.txt
git add fixture.txt
git commit -qm initial

expect_ok() {
  local label=$1
  shift
  if "$@" >command.out 2>command.err; then
    echo "PASS allow: $label"
  else
    echo "FAIL allow: $label" >&2
    sed -n '1,12p' command.err >&2
    return 1
  fi
}

expect_deny() {
  local label=$1
  shift
  if "$@" >command.out 2>command.err; then
    echo "FAIL deny: $label" >&2
    return 1
  fi
  echo "PASS deny: $label"
}

expect_l7_deny() {
  local label=$1
  shift
  if "$@" >command.out 2>command.err; then
    echo "FAIL deny: $label" >&2
    return 1
  fi
  if ! grep -q '"error":"Forbidden"' command.out; then
    echo "FAIL L7 deny: $label" >&2
    sed -n '1,12p' command.out >&2
    sed -n '1,12p' command.err >&2
    return 1
  fi
  echo "PASS L7 deny: $label"
}

expect_policy() {
  local expected=$1
  local label=$2
  shift 2
  local actual
  actual=$("$@" | jq -r .status)
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL policy: $label (expected $expected, got $actual)" >&2
    return 1
  fi
  echo "PASS policy $expected: $label"
}

run_developer() {
  nono run -s --no-audit --allow-cwd --profile "$developer_profile" -- "$@"
}

run_reviewer() {
  nono run -s --no-audit --allow-cwd --profile "$reviewer_profile" -- "$@"
}

expect_ok "developer git status" run_developer git status --short
expect_ok "developer designated branch" \
  run_developer git switch -c demo/webinar-fix
expect_policy allowed "developer designated push" \
  nono why --json --profile "$developer_profile" --command git -- \
    push demo-secure HEAD:refs/heads/demo/webinar-fix
expect_policy denied "developer default-branch push" \
  nono why --json --profile "$developer_profile" --command git -- \
    push demo-secure HEAD:refs/heads/main
expect_policy allowed "git GitHub SSH transport" \
  nono why --json --profile "$developer_profile" --command ssh --caller git -- \
    -p 443 git@ssh.github.com \
    "git-receive-pack '/nolabs-ai/amazon-webinar-demo.git'"
expect_policy denied "git alternate SSH host" \
  nono why --json --profile "$developer_profile" --command ssh --caller git -- \
    -p 443 git@example.com \
    "git-receive-pack '/nolabs-ai/amazon-webinar-demo.git'"
expect_deny "developer arbitrary branch" \
  run_developer git switch -c demo/other
expect_deny "developer unknown git operation" run_developer git tag demo-tag
expect_deny "developer direct SSH" \
  run_developer ssh -T git@ssh.github.com

expect_ok "reviewer git status" run_reviewer git status --short
expect_deny "reviewer branch creation" \
  run_reviewer git switch -c reviewer/webinar-suggestion
expect_deny "reviewer direct SSH" \
  run_reviewer ssh -T git@ssh.github.com
expect_deny "reviewer filesystem write" \
  run_reviewer sh -c 'printf blocked > reviewer-write.txt'
expect_deny "reviewer raw credential read" \
  run_reviewer cat "$secret_path"
expect_deny "reviewer arbitrary network" \
  run_reviewer curl --max-time 2 https://example.com

expect_deny "developer PR merge" \
  run_developer gh pr merge 1 --repo nolabs-ai/amazon-webinar-demo
expect_deny "reviewer PR merge" \
  run_reviewer gh pr merge 1 --repo nolabs-ai/amazon-webinar-demo
expect_deny "reviewer request changes" \
  run_reviewer gh pr review 1 --repo nolabs-ai/amazon-webinar-demo \
    --request-changes
expect_deny "reviewer request changes short flag" \
  run_reviewer gh pr review 1 --repo nolabs-ai/amazon-webinar-demo -r
expect_deny "developer direct GraphQL" \
  run_developer gh api --hostname api.github.com graphql
expect_deny "reviewer direct GraphQL" \
  run_reviewer gh api --hostname api.github.com graphql
expect_l7_deny "reviewer low-level merge endpoint" \
  run_reviewer gh api --method PUT \
    repos/nolabs-ai/amazon-webinar-demo/pulls/1/merge
