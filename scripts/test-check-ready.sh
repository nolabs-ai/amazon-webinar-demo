#!/usr/bin/env bash
# Tests scripts/check-ready.sh against fake aws, kubectl and gh.
# shellcheck disable=SC2015  # A && pass || fail is the test idiom here; pass never fails
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
mkdir -p "$work/bin"

cat >"$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
case $2 in
  get-caller-identity) [[ -z ${FAKE_NO_AWS:-} ]] || exit 1; echo "${FAKE_ACCOUNT:-816301968846}" ;;
  update-nodegroup-config | wait) echo "aws $*" >>"${FAKE_CALLS:-/dev/null}" ;;
  describe-nodegroup) printf 'ACTIVE\t1\n' ;;
  describe-images) [[ -z ${FAKE_NO_IMAGE:-} ]] || exit 1; echo "${FAKE_TAGS-frozen-20261018 9c0b538-dirty}" ;;
esac
FAKE
cat >"$work/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
case $1 in
  config) echo "arn:aws:eks:eu-west-1:816301968846:cluster/webinar-kata" ;;
  cluster-info) ;;
  wait) echo "kubectl $*" >>"${FAKE_CALLS:-/dev/null}" ;;
  get)
    case $2 in
      nodes) [[ -n ${FAKE_NO_NODE:-} ]] || echo True ;;
      runtimeclass) ;;
    esac ;;
  -n)
    case $4 in
      secret) echo "${FAKE_KEYS:-model-api-key
ssh-private-key
token}" ;;
      job) exit 1 ;;
    esac ;;
esac
FAKE
cat >"$work/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case $2 in
  */issues/*) echo "${FAKE_ISSUE:-open false}" ;;
  */git/ref/heads/main) echo "${FAKE_MAIN:-aaa1111}" ;;
  */git/ref/tags/demo-baseline) [[ -z ${FAKE_NO_BASE:-} ]] || exit 1; echo "${FAKE_BASE:-aaa1111}" ;;
  */git/ref/*) [[ -n ${FAKE_BRANCH:-} ]] || exit 1 ;;
  *pulls*) echo "${FAKE_OPEN_PRS:-0}" ;;
esac
FAKE
chmod +x "$work/bin"/*
export PATH=$work/bin:$PATH

# The script reads config/image and artifacts/image.txt; keep the real ones safe.
mkdir -p "$repo_root/artifacts"
for f in config/image artifacts/image.txt; do
  [[ ! -f $repo_root/$f ]] || cp "$repo_root/$f" "$work/backup-$(basename "$f")"
done
restore() {
  for f in config/image artifacts/image.txt; do
    if [[ -f $work/backup-$(basename "$f") ]]; then
      cp "$work/backup-$(basename "$f")" "$repo_root/$f"
    else
      rm -f "$repo_root/$f"
    fi
  done
  rm -rf "$work"
}
trap restore EXIT
fixture_image="registry.example.invalid/demo@sha256:$(printf 'c%.0s' {1..64})"
printf '%s\n' "$fixture_image" >"$repo_root/config/image"
printf '%s\n' "$fixture_image" >"$repo_root/artifacts/image.txt"

failures=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}
run() { set +e; env "$@" "$repo_root/scripts/check-ready.sh" >"$work/out" 2>&1; status=$?; set -e; }
expect() { # label env... -- pattern
  local label=$1 pattern=${*: -1}
  set -- "${@:2:$#-2}"
  run "$@"
  if ((status != 0)) && grep -q -- "$pattern" "$work/out" && grep -q '^NOT READY' "$work/out"; then
    pass "$label"
  else
    fail "$label (status $status, wanted /$pattern/)"
    cat "$work/out" >&2
  fi
}

run FAKE_OK=1
if ((status == 0)) && grep -qx READY "$work/out" && ! grep -q '^FAIL' "$work/out"; then
  pass "everything ready reports READY"
else
  fail "READY case (status $status)"
  cat "$work/out" >&2
fi
expect "no AWS session" FAKE_NO_AWS=1 'FAIL  AWS identity'
expect "wrong AWS account" FAKE_ACCOUNT=111111111111 'expected 816301968846'
expect "no Kata node" FAKE_NO_NODE=1 'FAIL  Kata node'
expect "stale OAuth key in the Secret" "FAKE_KEYS=model-api-key
model-auth-json
ssh-private-key
token" "FAIL  Secret keys"
expect "closed issue" "FAKE_ISSUE=closed false" 'FAIL  GitHub issue'
expect "leftover branch" FAKE_BRANCH=1 'FAIL  branch state'
expect "image missing from ECR" FAKE_NO_IMAGE=1 'FAIL  image digest'
expect "main moved by a merge" FAKE_MAIN=bbb2222 'FAIL  main state'

# WARN cases still count as ready.
run FAKE_TAGS=9c0b538-dirty
if ((status == 0)) && grep -q 'WARN  image digest.*not tagged frozen' "$work/out" && grep -qx READY "$work/out"; then
  pass "an unprotected image is a warning, not a failure"
else
  fail "unfrozen image warning (status $status)"
  cat "$work/out" >&2
fi
run FAKE_NO_BASE=1
if ((status == 0)) && grep -q 'WARN  main state.*no demo-baseline' "$work/out"; then
  pass "a missing baseline tag is a warning"
else
  fail "missing baseline warning (status $status)"
fi
rm -f "$repo_root/config/image"
expect "nothing frozen" FAKE_OK=1 'FAIL  image digest.*nothing frozen'
run_latest() { set +e; env "$@" "$repo_root/scripts/check-ready.sh" --latest >"$work/out" 2>&1; status=$?; set -e; }
run_latest FAKE_OK=1
((status == 0)) && grep -q 'newest build' "$work/out" && pass "--latest checks the newest build" ||
  fail "--latest (status $status)"

# --- scripts/kata-node.sh ---
export FAKE_CALLS=$work/calls
: >"$FAKE_CALLS"
"$repo_root/scripts/kata-node.sh" start >"$work/out" 2>&1 &&
  grep -q 'desiredSize=1' "$FAKE_CALLS" && grep -q 'wait nodegroup-active' "$FAKE_CALLS" &&
  grep -q 'kubectl wait --for=condition=Ready node' "$FAKE_CALLS" && grep -q 'Kata node is Ready' "$work/out" &&
  pass "kata-node start scales to 1 and waits for Ready" || { fail "kata-node start"; cat "$work/out" >&2; }
: >"$FAKE_CALLS"
"$repo_root/scripts/kata-node.sh" pause >"$work/out" 2>&1 && grep -q 'desiredSize=0' "$FAKE_CALLS" &&
  pass "kata-node pause scales to 0" || { fail "kata-node pause"; cat "$work/out" >&2; }
"$repo_root/scripts/kata-node.sh" status >"$work/out" 2>&1 && grep -q 'node group: ACTIVE, desired nodes: 1' "$work/out" &&
  pass "kata-node status reports the node group" || { fail "kata-node status"; cat "$work/out" >&2; }
: >"$FAKE_CALLS"
FAKE_ACCOUNT=111111111111 "$repo_root/scripts/kata-node.sh" start >"$work/out" 2>&1 && fail "kata-node ran in the wrong account" ||
  { grep -q 'expected 816301968846' "$work/out" && [[ ! -s $FAKE_CALLS ]] && pass "kata-node refuses the wrong AWS account"; }

((failures == 0)) && echo "all readiness checks passed" || {
  echo "$failures check(s) failed" >&2
  exit 1
}
