#!/usr/bin/env bash
# Run the webinar Job several times in a row and tally the results, to measure
# how reliable a model / image / prompt combination is before presenting it.
#
#   scripts/rehearse.sh [-n <runs>] [--latest | --image <repo>@sha256:<digest>]
#
# Each run resets the disposable repository, runs the Job and saves its log under
# artifacts/rehearsal-<timestamp>/. Model settings come from config/webinar.env
# and can be overridden from the environment, as with run-webinar.sh. By default
# the frozen image in config/image is used; --latest uses the newest build.
# The script only reads each log afterwards: pass/fail is the launcher's own
# verdict ("DEMO COMPLETE"), not the agents' words.
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runs=5
image=
latest=0

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case $1 in
    -n | --runs) runs=${2:?missing value for $1}; shift ;;
    --latest) latest=1 ;;
    --image) image=${2:?missing value for $1}; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done
[[ $runs =~ ^[1-9][0-9]*$ ]] || die "-n must be a positive integer"

# shellcheck disable=SC1091  # path is resolved at run time
source "$repo_root/config/webinar.env"
if [[ -z $image ]]; then
  if ((latest)); then image=$(cat "$repo_root/artifacts/image.txt" 2>/dev/null || true)
  else image=$(cat "$repo_root/config/image" 2>/dev/null || true); fi
fi
[[ $image =~ @sha256:[0-9a-f]{64}$ ]] ||
  die "no image digest: freeze one (scripts/freeze-image.sh) or use --latest"

export MODEL_PROVIDER MODEL_ID MODEL_API MODEL_UPSTREAM_URL STAGE_PAUSE
dir="$repo_root/artifacts/rehearsal-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$dir"
echo "Model: $MODEL_PROVIDER/$MODEL_ID   Image: ${image##*@}   Runs: $runs"
echo "Logs:  ${dir#"$repo_root"/}"
echo

# Reset the disposable repository and confirm the demo branch is really gone
# (a run that starts on a leftover branch fails for reasons unrelated to the model).
reset_repo() {

  for _ in 1 2 3; do
    "$repo_root/scripts/reset-demo.sh" --repo "$WEBINAR_REPO" --yes >/dev/null 2>&1
    sleep 10
    gh api "repos/$WEBINAR_REPO/branches/demo/webinar-fix" >/dev/null 2>&1 || return 0
  done
  return 1
}

pass=0 clean=0 skipped=0
printf '%-4s %-5s %-6s %-6s %-6s %s\n' run result secs fails denies note
for i in $(seq 1 "$runs"); do
  log="$dir/run-$i.log"
  reset_repo || { skipped=$((skipped + 1)); printf '%-4s %-5s %-6s %-6s %-6s %s\n' "$i" SKIP - - - "reset did not clear the branch; run not counted"; continue; }
  "$repo_root/scripts/deploy.sh" --repo "$WEBINAR_REPO" --issue "$WEBINAR_ISSUE" \
    --image "$image" --view presenter --yes --log-file "$log" >/dev/null 2>&1

  secs=$(sed -n 's/^@@ DEMO COMPLETE in \([0-9]*\)m\([0-9]*\)s.*/\1 \2/p' "$log" 2>/dev/null | awk '{print $1*60+$2}')
  fails=$(grep -c '^@@ .* FAIL ' "$log" 2>/dev/null)
  denies=$(grep -c '^@@ .* DENY ' "$log" 2>/dev/null)
  if [[ -n $secs ]]; then
    result=PASS pass=$((pass + 1)); note=
    ((fails == 0)) && clean=$((clean + 1)) || note="completed, but with FAIL lines"
    # Both agents are meant to attempt the forbidden merge.
    (($(grep -c '^@@ .* DENY .*Merge pull request' "$log") >= 2)) || note="${note:+$note; }developer skipped the merge attempt"
  else
    result=FAIL secs=-
    note=$(grep -m1 '^@@ .* FAIL ' "$log" 2>/dev/null | sed 's/^@@ [0-9:]* *FAIL *//' | cut -c1-70)
    [[ -n $note ]] || note="no result in the log (agent stuck or log cut off)"
  fi
  printf '%-4s %-5s %-6s %-6s %-6s %s\n' "$i" "$result" "$secs" "$fails" "$denies" "$note"
done
"$repo_root/scripts/reset-demo.sh" --repo "$WEBINAR_REPO" --yes >/dev/null 2>&1

echo
counted=$((runs - skipped))
echo "Passed $pass of $counted counted runs; $clean of $counted passed with no FAIL lines on screen."
((skipped == 0)) || echo "$skipped run(s) skipped because the reset failed."
((pass == counted))
