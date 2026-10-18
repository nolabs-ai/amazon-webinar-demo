#!/usr/bin/env bash
# Return a disposable GitHub repository to the state the demo starts from: close
# open PRs from demo/webinar-fix, delete that branch, and, if the repository has a
# demo-baseline tag, move main back to it (a human merging the PR changes main,
# and the next run would find the bug already fixed). The issue is never changed.
#
#   scripts/reset-demo.sh --repo <owner/name> [--yes]
#   scripts/reset-demo.sh --repo <owner/name> --set-baseline
#
# --set-baseline tags the current main as demo-baseline. Do it once, while main
# still has the bug the issue describes.
set -euo pipefail

repo=${GITHUB_REPOSITORY:-}
assume_yes=0
set_baseline=0
branch=demo/webinar-fix
baseline_tag=demo-baseline

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 1; }

while (($#)); do
  case $1 in
    -R | --repo) repo=${2:?missing value for $1}; shift ;;
    -y | --yes) assume_yes=1 ;;
    --set-baseline) set_baseline=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  die "--repo <owner/name> is required and must name the disposable demo repository"
for tool in gh jq; do command -v "$tool" >/dev/null || die "$tool not found"; done

confirm() {
  ((assume_yes == 0)) || return 0
  [[ -t 0 ]] || die "not a terminal; pass --yes to confirm"
  local answer
  read -r -p "$1 [y/N] " answer
  [[ $answer == y || $answer == Y ]] || die "aborted"
}

main_sha=$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha) ||
  die "cannot read main in $repo (gh auth status? repository name?)"

if ((set_baseline)); then
  if gh api "repos/$repo/git/ref/tags/$baseline_tag" >/dev/null 2>&1; then
    die "$baseline_tag already exists in $repo; delete that tag first if you really mean to move it"
  fi
  echo "Repository: $repo"
  echo "main is at: ${main_sha:0:7}"
  confirm "Tag this as the demo's starting point ($baseline_tag)? main must still contain the bug."
  gh api --method POST "repos/$repo/git/refs" -f "ref=refs/tags/$baseline_tag" -f "sha=$main_sha" >/dev/null
  echo "Tagged ${main_sha:0:7} as $baseline_tag."
  exit 0
fi

owner=${repo%%/*}
prs=$(gh api "repos/$repo/pulls?state=open&head=$owner:$branch" --jq '.[].number')
has_branch=0
gh api "repos/$repo/git/ref/heads/$branch" >/dev/null 2>&1 && has_branch=1
# A missing tag makes gh print the 404 body and fail; keep only a real commit id.
base_sha=$(gh api "repos/$repo/git/ref/tags/$baseline_tag" --jq .object.sha 2>/dev/null) || base_sha=
[[ $base_sha =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || base_sha=
main_moved=0
[[ -z $base_sha || $base_sha == "$main_sha" ]] || main_moved=1

if [[ -z $prs ]] && ((has_branch == 0 && main_moved == 0)); then
  echo "Already reset: no open PR, no $branch branch, main at the baseline in $repo."
  [[ -n $base_sha ]] || echo "Note: no $baseline_tag tag, so main was not checked (--set-baseline)."
  exit 0
fi

echo "Repository: $repo"
echo "Branch:     $branch"
open_list=none
while read -r pr; do
  [[ -n $pr ]] || continue
  [[ $open_list == none ]] && open_list="#$pr" || open_list+=", #$pr"
done <<<"$prs"
echo "Open PRs:   $open_list"
((main_moved == 0)) || echo "main:       ${main_sha:0:7}, will be restored to ${base_sha:0:7} ($baseline_tag)"
confirm "Close those PRs, delete the branch$( ((main_moved)) && echo ' and restore main')?"

while read -r pr; do
  [[ -n $pr ]] || continue
  gh api --method PATCH "repos/$repo/pulls/$pr" -f state=closed >/dev/null
  echo "Closed PR #$pr."
done <<<"$prs"

if ((has_branch)); then
  gh api --method DELETE "repos/$repo/git/refs/heads/$branch" >/dev/null
  echo "Deleted $branch."
fi
if ((main_moved)); then
  gh api --method PATCH "repos/$repo/git/refs/heads/main" -f "sha=$base_sha" -F force=true >/dev/null
  echo "Restored main to ${base_sha:0:7}."
fi
echo "Demo repository reset."
[[ -n $base_sha ]] || echo "Note: no $baseline_tag tag, so main was not checked (--set-baseline)."
