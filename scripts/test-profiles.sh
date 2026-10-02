#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
developer_profile="$repo_root/profiles/developer.json"
reviewer_profile="$repo_root/profiles/reviewer.json"
secret_path=/run/secrets/github/token
secret_created=0
test_dir=

cleanup() {
  if [[ -n "$test_dir" && "$test_dir" == /srv/nono-webinar-test.* ]]; then
    sudo rm -r -- "$test_dir"
  fi
  if ((secret_created)); then
    sudo rm -f -- "$secret_path"
  fi
}
trap cleanup EXIT

[[ $(uname -s) == Linux ]] || {
  echo "profile behavior tests require Linux" >&2
  exit 1
}

for command in nono git gh; do
  command -v "$command" >/dev/null || {
    echo "missing required command: $command" >&2
    exit 1
  }
done

expected_version="nono $(tr -d '\n' < "$repo_root/NONO_VERSION")"
[[ $(nono --version) == "$expected_version" ]] || {
  echo "expected $expected_version, found $(nono --version)" >&2
  exit 1
}

nono profile validate "$developer_profile"
nono profile validate "$reviewer_profile"

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
cd "$test_dir"

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

run_developer() {
  nono run -s --no-audit --allow-cwd --profile "$developer_profile" -- "$@"
}

run_reviewer() {
  nono run -s --no-audit --allow-cwd --profile "$reviewer_profile" -- "$@"
}

expect_ok "developer git status" run_developer git status --short
expect_ok "developer designated branch" \
  run_developer git switch -c demo/webinar-fix
expect_deny "developer arbitrary branch" \
  run_developer git switch -c demo/other

expect_ok "reviewer git status" run_reviewer git status --short
expect_deny "reviewer branch creation" \
  run_reviewer git switch -c reviewer/webinar-suggestion
expect_deny "reviewer filesystem write" \
  run_reviewer sh -c 'printf blocked > reviewer-write.txt'
expect_deny "reviewer raw credential read" \
  run_reviewer cat "$secret_path"

expect_deny "developer PR merge" \
  run_developer gh pr merge 1 --repo nolabs-ai/amazon-webinar-demo
expect_deny "reviewer PR merge" \
  run_reviewer gh pr merge 1 --repo nolabs-ai/amazon-webinar-demo
expect_deny "reviewer approval" \
  run_reviewer gh pr review 1 --repo nolabs-ai/amazon-webinar-demo --approve
expect_l7_deny "reviewer low-level merge endpoint" \
  run_reviewer gh api --method PUT \
    repos/nolabs-ai/amazon-webinar-demo/pulls/1/merge
