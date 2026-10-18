#!/usr/bin/env bash
# Close open PRs from demo/webinar-fix and delete that branch in a disposable
# GitHub repository. The issue and main branch are never changed.
#
#   scripts/reset-demo.sh --repo <owner/name> [--yes]
set -euo pipefail

repo=${GITHUB_REPOSITORY:-}
assume_yes=0
branch=demo/webinar-fix

usage() { sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 1; }

while (($#)); do
  case $1 in
    -R | --repo) repo=${2:?missing value for $1}; shift ;;
    -y | --yes) assume_yes=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  die "--repo <owner/name> is required and must name the disposable demo repository"
for tool in gh jq; do command -v "$tool" >/dev/null || die "$tool not found"; done

owner=${repo%%/*}
prs=$(gh api "repos/$repo/pulls?state=open&head=$owner:$branch" --jq '.[].number')
if [[ -z $prs ]] && ! gh api "repos/$repo/git/ref/heads/$branch" >/dev/null 2>&1; then
  echo "Already reset: no open PR or $branch branch in $repo."
  exit 0
fi

echo "Repository: $repo"
echo "Branch:     $branch"
echo "Open PRs:   ${prs:-none}"
if ((assume_yes == 0)); then
  [[ -t 0 ]] || die "not a terminal; pass --yes to confirm this reset"
  read -r -p "Close those PRs and delete the branch? [y/N] " answer
  [[ $answer == y || $answer == Y ]] || die "aborted"
fi

while read -r pr; do
  [[ -n $pr ]] || continue
  gh api --method PATCH "repos/$repo/pulls/$pr" -f state=closed >/dev/null
  echo "Closed PR #$pr."
done <<<"$prs"

if gh api "repos/$repo/git/ref/heads/$branch" >/dev/null 2>&1; then
  gh api --method DELETE "repos/$repo/git/refs/heads/$branch" >/dev/null
  echo "Deleted $branch."
fi
echo "Demo repository reset. Issue and main branch were not changed."
