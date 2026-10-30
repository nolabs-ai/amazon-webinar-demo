#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2012  # test idioms: A && pass || fail; literal ${ patterns; ls on fixtures
# Tests setup-secrets.sh, deploy.sh and teardown.sh against a fake kubectl (the
# cluster guard, what is sent to the API server, and that no secret ever reaches
# argv) and create-issue.sh against a fake gh. Real cluster and GitHub behavior is
# covered by running the scripts.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for command in jq envsubst python3 ssh-keygen; do
  command -v "$command" >/dev/null || {
    echo "missing required command: $command" >&2
    exit 1
  }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"

cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_STATE/argv"
case $1 in
  config)
    case $2 in
      current-context) [[ -z ${FAKE_NO_CONTEXT:-} ]] || exit 1; echo "${FAKE_CONTEXT:-fake-context}" ;;
      view) echo https://fake.example.invalid ;;
    esac ;;
  cluster-info) [[ -z ${FAKE_NO_CLUSTER:-} ]] || exit 1 ;;
  apply)
    if [[ ${*: -1} == - ]]; then
      n=$(ls "$FAKE_STATE" | grep -c '^applied-' || true)
      cat >"$FAKE_STATE/applied-$n"
    fi ;;
  get)
    case $2 in
      secret)
        [[ -z ${FAKE_NO_SECRET:-} ]] || exit 1
        [[ ${*: -1} != json ]] || echo '{"data":{"model-api-key":"x","ssh-private-key":"x","token":"x"}}' ;;
      runtimeclass) ;;
      pods) echo Running ;;
      job)
        if [[ ${*: -1} == *failed* ]]; then [[ -z ${FAKE_JOB_FAILED:-} ]] || echo 1
        else [[ -n ${FAKE_JOB_FAILED:-} ]] || echo 1; fi ;;
    esac ;;
  logs) echo "fake log line"; echo "@@ tagged event"; echo "@# machine event" ;;
esac
EOF
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_STATE/gh-argv"
case "$1 $2" in
  "issue list")
    if [[ -n ${FAKE_EXISTING_ISSUE:-} ]]; then
      jq -n --argjson n "$FAKE_EXISTING_ISSUE" '[{number: $n, title: "Orders at the free-shipping threshold are charged shipping"}]'
    else echo '[]'; fi ;;
  "issue create")
    while (($#)); do
      [[ $1 != --body-file ]] || cp "$2" "$FAKE_STATE/issue-body"
      shift
    done
    echo "https://github.com/acme/widgets/issues/42" ;;
esac
EOF
chmod +x "$work/bin/kubectl" "$work/bin/gh"
export PATH=$work/bin:$PATH FAKE_STATE=$work/state

failures=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}
reset() { rm -rf "$work/state" && mkdir -p "$work/state"; }

digest=sha256:$(printf 'b%.0s' {1..64})
image=registry.example.invalid/demo@$digest

# ---- deploy.sh -------------------------------------------------------------------
reset
"$repo_root/scripts/deploy.sh" --repo acme/widgets --issue 7 --image "$image" --yes >"$work/out" 2>&1 &&
  pass "deploy succeeds when the Job succeeds" || {
  fail "deploy"
  cat "$work/out" >&2
}
job=$(cat "$work"/state/applied-* 2>/dev/null || true)
grep -q "image: $image\$" <<<"$job" && grep -q 'value: "7"' <<<"$job" &&
  ! grep -q '\${' <<<"$job" && pass "Job manifest has the digest and issue substituted" ||
  fail "Job manifest substitution"
grep -q 'delete job github-agents-demo' "$work/state/argv" &&
  pass "an earlier Job is replaced" || fail "old Job not deleted"
grep -q 'fake log line' "$work/out" && pass "logs are streamed" || fail "no logs"

reset
log_file="$work/saved/demo.log"
"$repo_root/scripts/deploy.sh" --repo acme/widgets --issue 7 --image "$image" \
  --yes --log-file "$log_file" >/dev/null 2>&1 &&
  grep -q 'fake log line' "$log_file" && pass "deploy saves the streamed log" ||
  fail "deploy did not save the log"

reset
log_file="$work/saved/presenter.log"
"$repo_root/scripts/deploy.sh" --repo acme/widgets --issue 7 --image "$image" \
  --yes --view presenter --log-file "$log_file" >"$work/out" 2>&1
grep -qx 'tagged event' "$work/out" && ! grep -q 'fake log line\|machine event' "$work/out" &&
  pass "presenter view shows only the tagged events" || fail "presenter view filtering"
grep -q 'fake log line' "$log_file" && grep -q '^@@ tagged event' "$log_file" &&
  grep -q '^@# machine event' "$log_file" && pass "the saved log keeps the full stream" ||
  fail "saved log is incomplete in presenter view"
grep -q 'value: "presenter"' "$work"/state/applied-* && pass "presenter view turns on the Job's tagged output" ||
  fail "DEMO_OUTPUT not set for presenter view"

reset
if "$repo_root/scripts/deploy.sh" --repo acme/widgets --issue 7 --image registry.example.invalid/demo:latest --yes >/dev/null 2>"$work/err"; then
  fail "deploy accepted a tag"
else
  grep -q 'pinned by digest' "$work/err" && pass "deploy refuses an image tag" || fail "tag message"
fi
reset
# CI sets GITHUB_REPOSITORY itself, so make sure it is unset for this check.
if env -u GITHUB_REPOSITORY "$repo_root/scripts/deploy.sh" --issue 7 --image "$image" --yes >/dev/null 2>"$work/err"; then
  fail "deploy ran without a repository"
else
  grep -q -- '--repo' "$work/err" && pass "deploy requires --repo" || fail "repo message"
fi

if "$repo_root/scripts/deploy.sh" --repo acme/widgets --issue x --image "$image" --yes >/dev/null 2>&1; then
  fail "deploy accepted a bad issue"
else pass "deploy refuses a non-numeric issue"; fi
reset
if FAKE_NO_SECRET=1 "$repo_root/scripts/deploy.sh" --repo acme/widgets --issue 7 --image "$image" --yes >/dev/null 2>"$work/err"; then
  fail "deploy ran without the Secret"
else
  grep -q 'setup-secrets' "$work/err" && pass "deploy needs the Secret" || fail "secret message"
fi
reset
if FAKE_JOB_FAILED=1 "$repo_root/scripts/deploy.sh" --repo acme/widgets --issue 7 --image "$image" --yes >/dev/null 2>"$work/err"; then
  fail "deploy reported success for a failed Job"
else pass "deploy exits non-zero when the Job fails"; fi
reset
if FAKE_NO_CLUSTER=1 "$repo_root/scripts/deploy.sh" --repo acme/widgets --issue 7 --image "$image" --yes >/dev/null 2>"$work/err"; then
  fail "deploy ran without a cluster"
else
  grep -q 'cannot reach the cluster' "$work/err" && pass "deploy refuses an unreachable cluster" || fail "cluster message"
fi

# ---- the cluster guard masks the AWS account ID --------------------------------------
reset
out=$(FAKE_CONTEXT=arn:aws:eks:eu-west-1:123456789012:cluster/demo "$repo_root/scripts/teardown.sh" --yes 2>&1)
if grep -q 'kubectl context: arn:aws:eks:eu-west-1:\*\{12\}:cluster/demo' <<<"$out" && ! grep -q 123456789012 <<<"$out"; then
  pass "the cluster guard masks the account ID"
else fail "the cluster guard prints the account ID"; fi

# ---- deploy.sh masks the account ID in the registry host it prints --------------------
reset
acct_image=123456789012.dkr.ecr.eu-west-1.amazonaws.com/demo@$digest
"$repo_root/scripts/deploy.sh" --repo acme/widgets --issue 7 --image "$acct_image" --yes >"$work/out" 2>&1
job=$(cat "$work"/state/applied-* 2>/dev/null || true)
if grep -q 'image \*\{12\}\.dkr\.ecr' "$work/out" && ! grep -q 123456789012 "$work/out" &&
  grep -q "image: $acct_image\$" <<<"$job"; then
  pass "deploy masks the account ID on screen but deploys the real image"
else fail "deploy prints the account ID or changed the image"; fi

# ---- teardown.sh -----------------------------------------------------------------
reset
"$repo_root/scripts/teardown.sh" --yes >/dev/null 2>&1 &&
  ! grep -q 'delete namespace' "$work/state/argv" && pass "teardown deletes only the Job by default" ||
  fail "teardown default"
reset
"$repo_root/scripts/teardown.sh" --purge --yes >/dev/null 2>&1 &&
  grep -q 'delete namespace github-agents-demo' "$work/state/argv" && pass "teardown --purge deletes the namespace" ||
  fail "teardown --purge"

# ---- setup-secrets.sh ------------------------------------------------------------
reset
if FAKE_NO_CONTEXT=1 "$repo_root/scripts/setup-secrets.sh" --yes </dev/null >/dev/null 2>"$work/err"; then
  fail "setup-secrets ran without a kubectl context"
else pass "setup-secrets refuses without a terminal or context"; fi

ssh-keygen -q -t ed25519 -N '' -f "$work/key" -C fixture
# Drive the prompts through a pty: the script refuses to read secrets from a pipe.
reset
python3 - "$repo_root/scripts/setup-secrets.sh" "$work/key" "$work/transcript" <<'PY'
import os, pty, sys, select
script, key, transcript = sys.argv[1:4]
answers = [("Use this cluster?", "y"),
           ("GitHub token", "ghp_FIXTURETOKEN"),
           ("Path to the SSH private key", key),
           ("Model API key", "sk-FIXTUREMODELKEY")]
pid, fd = pty.fork()
if pid == 0:
    os.execv(script, [script])
buf = b""
with open(transcript, "wb") as log:
    for prompt, reply in answers:
        while prompt.encode() not in buf:
            r, _, _ = select.select([fd], [], [], 20)
            if not r:
                sys.exit("timed out waiting for: " + prompt)
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            buf += chunk
            log.write(chunk)
        buf = b""
        os.write(fd, (reply + "\n").encode())
    while True:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        log.write(chunk)
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
PY
status=$?
((status == 0)) && pass "setup-secrets completes through the prompts" || {
  fail "setup-secrets (status $status)"
  cat "$work/transcript" >&2
}
secret_json=$(ls "$work"/state/applied-* 2>/dev/null | tail -n 1 | xargs cat 2>/dev/null || true)
[[ $(jq -r '.data.token | @base64d' <<<"$secret_json") == ghp_FIXTURETOKEN ]] &&
  [[ $(jq -r '.data["model-api-key"] | @base64d' <<<"$secret_json") == sk-FIXTUREMODELKEY ]] &&
  [[ $(jq -r '.data["ssh-private-key"] | @base64d' <<<"$secret_json") == "$(cat "$work/key")" ]] &&
  [[ $(jq -r '.data["ssh-private-key"] | @base64d' <<<"$secret_json" | tail -c1 | od -An -c | tr -d ' ') == '\n' ]] &&
  pass "Secret carries all three values, key with its trailing newline" || fail "Secret contents"
[[ $(jq -r '.metadata | "\(.namespace)/\(.name)"' <<<"$secret_json") == github-agents-demo/github-agents ]] &&
  pass "Secret is github-agents in github-agents-demo" || fail "Secret identity"
! grep -q 'FIXTURETOKEN\|FIXTUREMODELKEY\|BEGIN OPENSSH' "$work/state/argv" &&
  pass "no secret in kubectl's argv" || fail "secret in argv"
! grep -q 'FIXTURETOKEN\|FIXTUREMODELKEY' "$work/transcript" &&
  pass "secrets are not echoed" || fail "secret echoed"

# ---- create-issue.sh -------------------------------------------------------------
reset
out=$("$repo_root/scripts/create-issue.sh" -R acme/widgets 2>/dev/null)
[[ $out == 42 ]] && pass "create-issue prints only the new issue number" || fail "create-issue output '$out'"
grep -q -- '--title Orders at the free-shipping threshold are charged shipping' "$work/state/gh-argv" &&
  [[ $(head -n 1 "$work/state/issue-body") == 'Orders qualify for free shipping when their total is at least `50.00`.' ]] &&
  pass "title and body are taken from scenario/issue.md" || fail "issue title/body"
reset
out=$(FAKE_EXISTING_ISSUE=9 "$repo_root/scripts/create-issue.sh" -R acme/widgets 2>/dev/null)
[[ $out == 9 ]] && ! grep -q 'issue create' "$work/state/gh-argv" &&
  pass "create-issue reuses an open issue with the same title" || fail "create-issue reuse"
reset
out=$(FAKE_EXISTING_ISSUE=9 "$repo_root/scripts/create-issue.sh" -R acme/widgets --new 2>/dev/null)
[[ $out == 42 ]] && pass "create-issue --new files another" || fail "create-issue --new"

echo
if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all cluster and issue script checks passed"
