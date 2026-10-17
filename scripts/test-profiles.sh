#!/usr/bin/env bash
# shellcheck disable=SC2016  # the sandboxed `sh -c` programs are single-quoted on purpose

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
developer_profile="$repo_root/profiles/developer.json"
reviewer_profile="$repo_root/profiles/reviewer.json"
known_hosts="$repo_root/config/github_known_hosts"
secret_dir=/run/secrets/github
secret_path=$secret_dir/token
model_key_path=$secret_dir/model-api-key
ssh_key_path=$secret_dir/ssh-private-key
model_key=ci-placeholder-model-key-not-a-real-credential
secrets_created=0
ssh_agent_started=0
test_dir=

cleanup() {
  if [[ -n "$test_dir" && "$test_dir" == /srv/nono-webinar-test.* ]]; then
    sudo rm -r -- "$test_dir"
  fi
  if ((secrets_created)); then
    sudo rm -f -- "$secret_path" "$model_key_path" "$ssh_key_path"
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

# Both agents reach the model API only through one brokered route: the real key
# stays in a file the supervisor reads, the sandbox sees a placeholder, and the
# proxy refuses everything but the model calls. An empty allow_domain would make
# the proxy forward to any host, hence the sentinel entry that matches nothing.
for profile in "$developer_profile" "$reviewer_profile"; do
  jq -e '
    .network.credentials == ["llm"]
    and .network.allow_domain == ["nono-deny-all.invalid"]
    and (.network.block // false) == false
    and (.network.custom_credentials | keys) == ["llm"]
    and (.network.custom_credentials.llm
         | (.credential_key | startswith("file:///run/secrets/github/"))
           and .env_var == "LLM_API_KEY"
           and (.upstream | startswith("https://"))
           and (.endpoint_rules | length > 0 and all(.method == "POST")))
  ' "$profile" >/dev/null || {
    echo "FAIL: $profile does not broker the model key as expected" >&2
    exit 1
  }
done

# The reviewer is comment-only: both agents share one GitHub identity, which
# cannot approve its own pull request, and a review verdict is not part of the
# role. No reviews endpoint and no `gh pr review` may be reachable.
jq -e '
  .command_policies.commands.gh.from.session.invocation_policy.allow
  | map(.argv.prefix) == [["api"]]
' "$reviewer_profile" >/dev/null
jq -e '
  .command_policies.commands.gh.from.session.sandbox.credentials[0]
    .endpoint_policy.allow
  | any(.method == "POST" and
        .path == "/repos/nolabs-ai/amazon-webinar-demo/issues/*/comments")
    and all(.path | contains("/reviews") | not)
' "$reviewer_profile" >/dev/null

# The session proxy (model route) intercepts TLS and sets SSL_CERT_FILE to its own
# CA. gh has its own proxy with its own CA, so it must not inherit that variable
# or every gh call fails with "certificate signed by unknown authority".
for profile in "$developer_profile" "$reviewer_profile"; do
  jq -e '
    .command_policies.commands.gh.from.session.sandbox.environment.allow_vars
    | index("SSL_CERT_FILE") == null' "$profile" >/dev/null || {
    echo "FAIL: $profile lets gh inherit the session's SSL_CERT_FILE" >&2
    exit 1
  }
done

# gh may only use REST: the only subcommand is `api`, /graphql is never allowed
# and is denied explicitly for any method.
for profile in "$developer_profile" "$reviewer_profile"; do
  jq -e '
    .command_policies.commands.gh.from.session as $gh
    | ($gh.invocation_policy.allow | map(.argv.prefix) == [["api"]])
      and ($gh.invocation_policy.deny | any(.argv.contains? == ["graphql"]))
      and ($gh.sandbox.credentials[0].endpoint_policy
           | (.allow | all(.path != "/graphql"))
             and (.deny | any(.method == "*" and .path == "/graphql")))
  ' "$profile" >/dev/null || {
    echo "FAIL: $profile allows more than REST for gh" >&2
    exit 1
  }
done

eval "$(ssh-agent -s)" >/dev/null
ssh_agent_started=1

for path in "$secret_path" "$model_key_path" "$ssh_key_path"; do
  [[ ! -e "$path" ]] || {
    echo "refusing to replace existing $path" >&2
    exit 1
  }
done

# World-readable like the Secret volume is to uid 1000 (mode 0440, fsGroup
# 1000): only the sandbox, not file permissions, keeps the agents out.
sudo install -d -m 0755 "$secret_dir"
secrets_created=1
printf 'ci-placeholder-not-a-real-credential\n' | sudo tee "$secret_path" >/dev/null
printf '%s\n' "$model_key" | sudo tee "$model_key_path" >/dev/null
printf 'ci-placeholder-not-a-real-ssh-key\n' | sudo tee "$ssh_key_path" >/dev/null
sudo chmod 0444 "$secret_path" "$model_key_path" "$ssh_key_path"

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
# `gh pr review` is not allowed at all, so no spelling of a flag can sneak an
# approval through (argv rules match whole arguments, e.g. not `--approve=true`).
for flag in --approve -a --approve=true --request-changes -r --comment; do
  expect_deny "reviewer gh pr review $flag" \
    run_reviewer gh pr review 1 --repo nolabs-ai/amazon-webinar-demo "$flag"
done
expect_l7_deny "reviewer REST approval" \
  run_reviewer gh api --method POST \
    repos/nolabs-ai/amazon-webinar-demo/pulls/1/reviews -f event=APPROVE
expect_deny "developer direct GraphQL" \
  run_developer gh api --hostname api.github.com graphql
expect_deny "reviewer direct GraphQL" \
  run_reviewer gh api --hostname api.github.com graphql
expect_l7_deny "reviewer low-level merge endpoint" \
  run_reviewer gh api --method PUT \
    repos/nolabs-ai/amazon-webinar-demo/pulls/1/merge

# GraphQL gap: nono matches endpoints by method and path only, so a GraphQL
# mutation (mergePullRequest, addPullRequestReview) cannot be told from a
# query. gh pr create/view/comment/checks and gh issue view all use GraphQL, so
# none of them is allowed; gh is limited to `gh api` on REST paths, and /graphql
# is refused at both the argv and the endpoint layer.
expect_deny "developer gh pr create (GraphQL)" \
  run_developer gh pr create --repo nolabs-ai/amazon-webinar-demo --fill
expect_deny "developer gh pr view (GraphQL)" \
  run_developer gh pr view 1 --repo nolabs-ai/amazon-webinar-demo
expect_deny "developer gh issue view (GraphQL)" \
  run_developer gh issue view 1 --repo nolabs-ai/amazon-webinar-demo
expect_deny "reviewer gh pr comment (GraphQL)" \
  run_reviewer gh pr comment 1 --repo nolabs-ai/amazon-webinar-demo --body x
expect_deny "reviewer gh pr view (GraphQL)" \
  run_reviewer gh pr view 1 --repo nolabs-ai/amazon-webinar-demo
for role in developer reviewer; do
  expect_l7_deny "$role GraphQL mutation over the /graphql path" \
    "run_$role" gh api --method POST /graphql \
    -f query='mutation { mergePullRequest(input: {pullRequestId: "x"}) { clientMutationId } }'
done

# Raw credential files stay unreadable from both roles, whatever their mode.
for role in developer reviewer; do
  for file in "$secret_path" "$model_key_path" "$ssh_key_path"; do
    expect_deny "$role raw read of ${file##*/}" "run_$role" cat "$file"
  done
done

# The model key: placeholder inside the sandbox, real value only in the proxy.
for role in developer reviewer; do
  expect_ok "$role sees a placeholder, not the model key" "run_$role" sh -c '
    [ -n "$LLM_API_KEY" ] && [ "$LLM_API_KEY" != "$1" ] &&
      case $LLM_BASE_URL in http://127.0.0.1:*/llm) ;; *) exit 1 ;; esac &&
      ! env | grep -qF -- "$1"
  ' sh "$model_key"
  expect_deny "$role arbitrary host through the proxy" \
    "run_$role" curl -sS --max-time 10 https://example.com
  expect_deny "$role direct connection around the proxy" \
    "run_$role" curl -sS --max-time 10 --noproxy '*' https://example.com
  expect_l7_deny "$role model route outside the endpoint rules" \
    "run_$role" sh -c \
    'curl -sS --max-time 15 --fail-with-body "$LLM_BASE_URL/v1/models" -H "x-api-key: $LLM_API_KEY"'
done

# An allowed model call is forwarded with the real key. The test key is wrong,
# so the provider's own authentication error proves it left the sandbox through
# the proxy; a proxy refusal would look different.
expect_proxied() {
  local label=$1
  shift
  "$@" >command.out 2>command.err || true
  if grep -q '"error":"Forbidden"' command.out; then
    echo "FAIL proxied: $label (refused by the proxy)" >&2
    return 1
  fi
  if ! grep -q 'authentication_error' command.out; then
    echo "FAIL proxied: $label (no provider response)" >&2
    sed -n '1,12p' command.out >&2
    sed -n '1,12p' command.err >&2
    return 1
  fi
  echo "PASS proxied: $label"
}

for role in developer reviewer; do
  expect_proxied "$role model call reaches the provider through the proxy" \
    "run_$role" sh -c '
      curl -sS --max-time 30 -X POST "$LLM_BASE_URL/v1/messages" \
        -H "x-api-key: $LLM_API_KEY" -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" -d "{}"'
done
