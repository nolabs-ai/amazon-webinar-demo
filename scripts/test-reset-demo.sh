#!/usr/bin/env bash
# Tests scripts/reset-demo.sh against a small stateful fake of the GitHub API.
# shellcheck disable=SC2015  # A && pass || fail is the test idiom here; pass never fails
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"

# State: files under $FAKE_STATE (prs, branch, main, baseline, calls).
cat >"$work/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
s=$FAKE_STATE
shift # "api"
method=GET path= args=()
while (($#)); do
  case $1 in
    --method) method=$2; shift ;;
    --jq) shift ;;
    -f | -F) args+=("$2"); shift ;;
    *) [[ -n $path ]] || path=$1 ;;
  esac
  shift
done
echo "$method $path ${args[*]:-}" >>"$s/calls"
case "$method $path" in
  "GET repos/o/r/git/ref/heads/main") cat "$s/main" ;;
  "GET repos/o/r/git/ref/tags/demo-baseline")
    if [[ -f $s/baseline ]]; then cat "$s/baseline"; else echo '{"message":"Not Found","status":"404"}'; exit 1; fi ;;
  "GET repos/o/r/git/ref/heads/demo/webinar-fix") [[ -f $s/branch ]] || exit 1 ;;
  "GET repos/o/r/pulls?state=open&head=o:demo/webinar-fix") [[ ! -f $s/prs ]] || cat "$s/prs" ;;
  "PATCH repos/o/r/pulls/"*) rm -f "$s/prs" ;;
  "DELETE repos/o/r/git/refs/heads/demo/webinar-fix") rm -f "$s/branch" ;;
  "PATCH repos/o/r/git/refs/heads/main") sed 's/^sha=//' <<<"${args[0]}" >"$s/main" ;;
  "POST repos/o/r/git/refs") sed 's/^sha=//' <<<"${args[1]}" >"$s/baseline" ;;
  *) echo "fake gh: unhandled $method $path" >&2; exit 1 ;;
esac
FAKE
chmod +x "$work/bin/gh"
export PATH=$work/bin:$PATH FAKE_STATE=$work/state

A=$(printf "a%.0s" {1..40}) B=$(printf "b%.0s" {1..40}) C=$(printf "c%.0s" {1..40})
failures=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}
setup() { # main baseline(or empty) prs branch(0/1)
  rm -rf "$work/state" && mkdir -p "$work/state"
  echo "$1" >"$work/state/main"
  [[ -z $2 ]] || echo "$2" >"$work/state/baseline"
  [[ -z $3 ]] || echo "$3" >"$work/state/prs"
  [[ $4 != 1 ]] || touch "$work/state/branch"
}
reset() { "$repo_root/scripts/reset-demo.sh" --repo o/r --yes "$@" >"$work/out" 2>&1; }

setup "$A" "$A" "" 0
reset && grep -q 'Already reset' "$work/out" && ! grep -q 'PATCH\|DELETE' "$work/state/calls" &&
  pass "clean repo: nothing to do and nothing changed" || fail "clean repo"

setup "$A" "$A" "7" 1
reset && grep -q 'Open PRs:   #7' "$work/out" && grep -q 'Closed PR #7' "$work/out" &&
  grep -q 'Deleted demo/webinar-fix' "$work/out" && ! grep -q 'Restored main' "$work/out" &&
  [[ $(cat "$work/state/main") == "$A" ]] && pass "PR closed and branch deleted; main untouched" ||
  { fail "PR and branch reset"; cat "$work/out" >&2; }

setup "$B" "$A" "" 0
reset && grep -q 'Restored main to aaaaaaa' "$work/out" && [[ $(cat "$work/state/main") == "$A" ]] &&
  pass "a merged main is restored to the baseline" || { fail "main restore"; cat "$work/out" >&2; }
grep -q "PATCH repos/o/r/git/refs/heads/main sha=$A force=true" "$work/state/calls" &&
  pass "main is force-updated to the baseline commit" || fail "force update call"

setup "$B" "" "" 0
reset && grep -q 'no demo-baseline tag' "$work/out" && [[ $(cat "$work/state/main") == "$B" ]] &&
  ! grep -q 'PATCH repos/o/r/git/refs/heads/main' "$work/state/calls" && ! grep -q 'will be restored' "$work/out" &&
  pass "without a baseline tag main is left alone and the user is told" || fail "no baseline"

setup "$C" "" "" 0
reset --set-baseline && [[ $(cat "$work/state/baseline") == "$C" ]] &&
  pass "--set-baseline tags the current main" || fail "set-baseline"
reset --set-baseline && fail "set-baseline overwrote an existing tag" ||
  { grep -q 'already exists' "$work/out" && pass "--set-baseline refuses to move an existing tag"; }

# Without --yes and without a terminal the reset must not run.
setup "$B" "$A" "" 0
if "$repo_root/scripts/reset-demo.sh" --repo o/r </dev/null >"$work/out" 2>&1; then
  fail "reset ran without confirmation"
else
  grep -q 'not a terminal' "$work/out" && [[ $(cat "$work/state/main") == "$B" ]] &&
    pass "no confirmation, no change" || fail "unconfirmed reset message"
fi

((failures == 0)) && echo "all reset checks passed" || {
  echo "$failures check(s) failed" >&2
  exit 1
}
