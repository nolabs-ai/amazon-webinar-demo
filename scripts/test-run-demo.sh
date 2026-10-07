#!/usr/bin/env bash
# Exercises bin/run-demo and bin/pi-agent end to end with fake nono, Pi and
# GitHub (curl), so the launcher's logic can be tested without a cluster, a
# token or Linux. What this cannot show is real sandbox enforcement and real Pi
# behavior; scripts/test-profiles.sh and the cluster run cover those.
# shellcheck disable=SC2015  # A && pass || fail is the test idiom here; pass never fails
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for command in git jq ssh-agent ssh-keygen ssh-add; do
  command -v "$command" >/dev/null || {
    echo "missing required command: $command" >&2
    exit 1
  }
done

# A short path: ssh-agent's socket path must fit a sockaddr_un.
work=$(mktemp -d /tmp/run-demo-test.XXXXXX)
trap '[[ -n ${KEEP_WORK:-} ]] || rm -rf "$work"' EXIT
fakes=$work/fakes
state=$work/state
mkdir -p "$fakes" "$state" "$work/home" "$work/workspace" "$work/secrets"

# ---- fakes --------------------------------------------------------------------

# nono: records the invocation, then runs the command like nono would, with the
# environment the real profiles and proxy would give it.
cat >"$fakes/nono" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && pass || fail is the test idiom here; pass never fails
set -euo pipefail
case $1 in
  --version) echo "nono 0.79.0" ;;
  profile) exit 0 ;;
  audit)
    case $2 in
      list)
        shopt -s nullglob
        ids=("$FAKE_STATE"/session-*)
        jq -n '$ARGS.positional | map({session_id: (. | sub(".*/session-"; ""))})' --args "${ids[@]}"
        ;;
      show)
        if [[ ${4:-} == --json ]]; then
          jq -n --arg id agent '{command_policy_events: [
            {decision: "invocation_denied", command: "gh", caller: "session",
             reason: "the \($id) may not merge pull requests"},
            {decision: "allowed", command: "git", caller: "session"}],
            network_events: [{decision: "deny", target: "example.com", port: 443}]}'
        else
          echo "Session: $3" >&2
          echo "  Command Policy Events: 2" >&2
        fi
        ;;
    esac
    ;;
  run)
    shift
    profile=
    while [[ $1 != -- ]]; do
      [[ $1 == --profile ]] && { profile=$2; shift; }
      shift
    done
    shift
    role=$(basename "$profile" .json)
    echo "$role $(pwd) ssh_auth_sock=${SSH_AUTH_SOCK:+set}" >>"$FAKE_STATE/nono-runs"
    printf '%s\n' "$profile" >>"$FAKE_STATE/profiles"
    cp "$profile" "$FAKE_STATE/profile-$role.json"
    touch "$FAKE_STATE/session-$role-$(date +%s%N)"
    FAKE_ROLE=$role LLM_BASE_URL=http://127.0.0.1:1/llm LLM_API_KEY=placeholder \
      PI_CODING_AGENT_DIR="$HOME/.pi/$role" \
      env -u GITHUB_TOKEN "$@"
    ;;
esac
EOF

# pi: prints a JSONL stream and does what the agent of that role would do.
cat >"$fakes/pi" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && pass || fail is the test idiom here; pass never fails
set -euo pipefail
role=$(basename "$PI_CODING_AGENT_DIR")
printf '%s\n' "$*" >"$FAKE_STATE/pi-args-$role"
cp "$PI_CODING_AGENT_DIR/models.json" "$FAKE_STATE/models-$role.json"
echo '{"type":"session","version":3,"id":"x","cwd":"/workspace"}'
echo '{"type":"tool_execution_start","toolName":"bash","args":{"command":"gh pr merge 12"}}'
echo '{"type":"tool_execution_end","toolName":"bash","isError":true,"result":{"content":[{"type":"text","text":"nono: command policy denied gh"}]}}'
echo 'a stray stderr line' >&2
case $role in
  developer) [[ -n ${FAKE_NO_PR:-} ]] || touch "$FAKE_STATE/pr" ;;
  reviewer) [[ -n ${FAKE_NO_COMMENT:-} ]] || echo x >>"$FAKE_STATE/comments" ;;
esac
echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done, merge was denied"}]}}'
EOF

# curl: a tiny GitHub. The token arrives as a curl config on stdin, as in run-demo.
cat >"$fakes/curl" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && pass || fail is the test idiom here; pass never fails
set -euo pipefail
out=; url=
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    -o) out=${args[++i]} ;;
    http*) url=${args[i]} ;;
  esac
done
printf '%s\n' "$*" >>"$FAKE_STATE/curl-argv"
cat >>"$FAKE_STATE/curl-stdin"
path=${url#http://fake/}
status=200
case $path in
  repos/acme/widgets/issues/7) body='{"number":7,"title":"Orders at the threshold"}'
    [[ -z ${FAKE_NO_ISSUE:-} ]] || { status=404; body='{}'; } ;;
  repos/acme/widgets/branches/demo/webinar-fix)
    if [[ -e $FAKE_STATE/pr || -n ${FAKE_BRANCH_EXISTS:-} ]]; then body='{}'; else status=404; body='{}'; fi ;;
  repos/acme/widgets/pulls\?*)
    if [[ -e $FAKE_STATE/pr ]]; then body='[{"number":12}]'; else body='[]'; fi ;;
  repos/acme/widgets/pulls/12)
    body='{"merged":'"${FAKE_MERGED:-false}"',"html_url":"https://github.com/acme/widgets/pull/12"}' ;;
  repos/acme/widgets/issues/12/comments\?*)
    n=0; [[ ! -e $FAKE_STATE/comments ]] || n=$(wc -l <"$FAKE_STATE/comments")
    body=$(jq -n --argjson n "$n" '[range($n) | {id: .}]') ;;
  *) status=404; body='{"message":"fake: unknown path"}' ;;
esac
printf '%s' "$body" >"$out"
printf '%s' "$status"
EOF

cat >"$fakes/timeout" <<'EOF'
#!/usr/bin/env bash
shift 3
exec "$@"
EOF
chmod +x "$fakes"/*

# ---- fixtures -------------------------------------------------------------------

export GIT_CONFIG_GLOBAL=$work/gitconfig GIT_CONFIG_SYSTEM=/dev/null
git config --global init.defaultBranch main
git config --global user.name Fixture
git config --global user.email fixture@example.invalid
mkdir -p "$work/remote/acme" "$work/seed"
git init -q --bare "$work/remote/acme/widgets.git"
git -C "$work/seed" init -q
echo fixture >"$work/seed/README"
git -C "$work/seed" add README
git -C "$work/seed" commit -qm initial
git -C "$work/seed" push -q "$work/remote/acme/widgets.git" HEAD:refs/heads/main

ssh-keygen -q -t ed25519 -N '' -f "$work/key" -C fixture
printf 'ghp_FIXTURETOKENNOTREAL0123456789\n' >"$work/secrets/token"
cp "$work/key" "$work/secrets/ssh-private-key"
printf 'sk-FIXTUREMODELKEYNOTREAL\n' >"$work/secrets/model-api-key"
# Like the Secret volume: group-readable, which plain `ssh-add <file>` rejects.
chmod 0440 "$work/secrets"/*

export HOME=$work/home
# run-demo must start its own agent; make sure a real one is never touched.
export SSH_AUTH_SOCK=/nonexistent SSH_AGENT_PID=1
export PATH=$fakes:$PATH
export FAKE_STATE=$state
export DEMO_DIR=$repo_root SECRETS_DIR=$work/secrets WORKSPACE=$work/workspace
export GITHUB_API_URL=http://fake GITHUB_GIT_URL=file://$work/remote

base_env=(
  GITHUB_REPOSITORY=acme/widgets ISSUE_NUMBER=7 GIT_REMOTE=demo-secure
  GIT_BRANCH=demo/webinar-fix AGENT_COMMAND=pi MODEL_PROVIDER=testprov
  MODEL_ID=test-model MODEL_UPSTREAM_URL=https://models.example.invalid
)

failures=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

reset() {
  rm -rf "$state" "$work/workspace" "$work/home/.pi" "$work/home/.local"
  mkdir -p "$state" "$work/workspace"
}

# run_demo <extra env...>; output in $work/out, status in $status.
status=0
run_demo() {
  reset
  set +e
  env "${base_env[@]}" "$@" "$repo_root/bin/run-demo" >"$work/out" 2>&1
  status=$?
  set -e
}

expect_fail() {
  local label=$1 pattern=$2
  if ((status != 0)) && grep -q -- "$pattern" "$work/out"; then
    pass "$label"
  else
    fail "$label (status $status, wanted /$pattern/)"
    sed -n '1,25p' "$work/out" >&2
  fi
}

# ---- scenarios ------------------------------------------------------------------

run_demo
[[ -z ${SHOW_OUTPUT:-} ]] || cat "$work/out"
if ((status == 0)); then pass "happy path exits 0"; else
  fail "happy path (status $status)"
  cat "$work/out" >&2
fi
for pattern in 'STAGE: developer agent' 'STAGE: reviewer agent' 'NONO AUDIT: developer' \
  'NONO AUDIT: reviewer' 'DENIED command  gh' 'DENIED network' 'DEMO COMPLETE' \
  'Issue #7: Orders at the threshold' '> bash: gh pr merge 12' 'assistant: done'; do
  grep -q -- "$pattern" "$work/out" && pass "output shows: $pattern" ||
    fail "output lacks: $pattern"
done
grep -q 'a stray stderr line' "$work/out" && pass "non-JSON lines pass through" ||
  fail "non-JSON lines were dropped"

[[ $(awk '{print $1}' "$state/nono-runs" | tr '\n' ' ') == 'developer reviewer ' ]] &&
  pass "developer ran before reviewer" || fail "stage order"
grep -q '^developer .*ssh_auth_sock=set' "$state/nono-runs" &&
  pass "developer stage had the agent socket (for the mediated ssh)" ||
  fail "developer stage lacks SSH_AUTH_SOCK"
grep -q '^reviewer .*ssh_auth_sock=$' "$state/nono-runs" &&
  pass "reviewer stage has no ssh-agent environment" || fail "reviewer stage sees SSH_AUTH_SOCK"
grep -q "^developer $work/workspace" "$state/nono-runs" &&
  pass "stages run in the workspace" || fail "stage working directory"

git -C "$work/workspace" remote get-url demo-secure |
  grep -qx 'ssh://git@ssh.github.com:443/acme/widgets.git' &&
  pass "demo-secure remote added" || fail "demo-secure remote"
[[ $(git -C "$work/workspace" config user.name) == 'Webinar Developer Agent' ]] &&
  pass "git identity set" || fail "git identity"
! grep -rq 'FIXTURETOKEN' "$work/workspace/.git" &&
  pass "token is not in the clone" || fail "token leaked into .git"
! grep -q 'FIXTURETOKEN' "$state/curl-argv" &&
  pass "token never appears in curl's argv" || fail "token in curl argv"
grep -q 'FIXTURETOKEN' "$state/curl-stdin" &&
  pass "token reaches curl through stdin" || fail "token not sent"
! grep -rq 'FIXTUREMODELKEY\|FIXTURETOKEN' "$work/out" &&
  pass "no secret in the log" || fail "secret in the log"

# The ssh-agent was started with the key loaded through a pipe from a 0440 file.
grep -q 'ssh-agent:.*loaded' "$work/out" &&
  pass "key loaded into ssh-agent from a group-readable file" || fail "ssh-add"

# Rendering: repository, upstream, prompts.
jq -e '.network.custom_credentials.llm.upstream == "https://models.example.invalid"' \
  "$state/profile-developer.json" >/dev/null && pass "upstream rendered from MODEL_UPSTREAM_URL" ||
  fail "upstream not rendered"
! grep -q 'nolabs-ai' "$state/profile-developer.json" "$state/profile-reviewer.json" &&
  grep -q 'acme/widgets' "$state/profile-reviewer.json" &&
  pass "repository rendered into both profiles" || fail "repository not rendered"
grep -q 'issues/7 ' "$state/pi-args-developer" && ! grep -q '{{' "$state/pi-args-developer" &&
  pass "developer prompt rendered" || fail "developer prompt"
grep -q 'pulls/12' "$state/pi-args-reviewer" && grep -q 'issues/7' "$state/pi-args-reviewer" &&
  ! grep -q '{{' "$state/pi-args-reviewer" && pass "reviewer prompt rendered with the PR number" ||
  fail "reviewer prompt"

# pi-agent: models.json from the proxy environment, Pi flags.
jq -e '.providers.testprov
       | .baseUrl == "http://127.0.0.1:1/llm" and .api == "anthropic-messages"
         and .apiKey == "${LLM_API_KEY}" and .models == [{id: "test-model"}]' \
  "$state/models-developer.json" >/dev/null && pass "pi-agent writes models.json" ||
  fail "models.json"
! grep -q 'FIXTUREMODELKEY\|placeholder' "$state/models-developer.json" &&
  pass "models.json holds no key" || fail "key in models.json"
for flag in --mode --no-session --no-context-files --offline --provider; do
  grep -q -- "$flag" "$state/pi-args-developer" && pass "pi flag $flag" || fail "pi flag $flag"
done

# Real nono: the rendered profiles must validate.
if nono_real=$(PATH=${PATH#"$fakes":} command -v nono) && [[ -n $nono_real ]]; then
  for role in developer reviewer; do
    "$nono_real" profile validate "$state/profile-$role.json" >/dev/null 2>&1 &&
      pass "rendered $role profile validates with $("$nono_real" --version)" ||
      fail "rendered $role profile does not validate"
  done
fi

# Model route per MODEL_API.
jq -e '.network.custom_credentials.llm
       | .inject_header == "x-api-key" and .credential_format == "{}"
         and (.endpoint_rules | map(.path) == ["/v1/messages", "/v1/messages/count_tokens"])' \
  "$state/profile-developer.json" >/dev/null && pass "anthropic-messages route" ||
  fail "anthropic-messages route"
run_demo MODEL_API=openai-completions MODEL_UPSTREAM_URL=https://models.example.invalid/v1
jq -e '.network.custom_credentials.llm
       | .inject_header == "Authorization" and .credential_format == "Bearer {}"
         and .upstream == "https://models.example.invalid/v1"
         and (.endpoint_rules | map(.method + " " + .path) == ["POST /chat/completions"])' \
  "$state/profile-reviewer.json" >/dev/null && pass "openai-completions route" ||
  fail "openai-completions route"
jq -e '.providers.testprov.api == "openai-completions"' "$state/models-reviewer.json" >/dev/null &&
  pass "pi-agent passes MODEL_API to Pi" || fail "MODEL_API in models.json"
run_demo MODEL_API=openai-responses
jq -e '.network.custom_credentials.llm.endpoint_rules | map(.path) == ["/responses"]' \
  "$state/profile-developer.json" >/dev/null && pass "openai-responses route" ||
  fail "openai-responses route"
run_demo MODEL_API=bogus
expect_fail "unknown MODEL_API is refused" 'unsupported MODEL_API'

# Failure paths.
run_demo ISSUE_NUMBER=
expect_fail "missing ISSUE_NUMBER fails fast" 'missing environment variable.*ISSUE_NUMBER'
run_demo GIT_REMOTE=origin
expect_fail "wrong remote is refused" 'GIT_REMOTE must be demo-secure'
run_demo MODEL_UPSTREAM_URL=http://insecure.example.invalid
expect_fail "non-https model URL is refused" 'must be an https'
mv "$work/secrets/model-api-key" "$work/model-key.bak"
run_demo
expect_fail "missing model key file fails fast" 'model-api-key is missing'
mv "$work/model-key.bak" "$work/secrets/model-api-key"
run_demo FAKE_NO_ISSUE=1
expect_fail "unreadable issue fails before any agent runs" 'issue #7 not found'
[[ ! -e $state/nono-runs ]] && pass "no agent ran" || fail "an agent ran without an issue"
run_demo FAKE_BRANCH_EXISTS=1
expect_fail "leftover branch is reported" 'already exists'
run_demo FAKE_NO_PR=1
expect_fail "no PR is a failure" 'opened no pull request'
run_demo FAKE_NO_COMMENT=1
expect_fail "no review comment is a failure" 'left no comment'
run_demo FAKE_MERGED=true
expect_fail "a merged PR is a failure" 'MERGED'

echo
if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all run-demo checks passed"
