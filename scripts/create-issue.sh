#!/usr/bin/env bash
# File scenario/issue.md as an issue in the demo repository and print its
# number (and nothing else) on stdout, so it can be captured:
#
#   ISSUE=$(scripts/create-issue.sh -R <owner>/<disposable-repo>)
#
#   -R, --repo <owner/name>  repository (default: $GITHUB_REPOSITORY, then
#                            nolabs-ai/amazon-webinar-demo)
#   --new                    create another issue even if an open one with the
#                            same title exists (default: reuse it)
#   --dry-run                print what would be filed and exit
#
# Uses your own `gh` login, not the agents' token. Only flags that exist in the
# image's gh 2.23 are used.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo=${GITHUB_REPOSITORY:-nolabs-ai/amazon-webinar-demo}
force_new=0
dry_run=0

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() {
  echo "error: $*" >&2
  exit 1
}

while (($#)); do
  case $1 in
    -R | --repo) repo=${2:?missing value for $1}; shift ;;
    --new) force_new=1 ;;
    --dry-run) dry_run=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repository must look like owner/name, got '$repo'"
for tool in gh jq; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

scenario=$repo_root/scenario/issue.md
[[ $(head -n 1 "$scenario") == '# '* ]] || die "$scenario must start with a '# title' line"
title=$(head -n 1 "$scenario" | sed 's/^# //')
body=$(mktemp)
trap 'rm -f "$body"' EXIT
tail -n +2 "$scenario" | sed '1{/^$/d;}' >"$body"

if ((dry_run)); then
  echo "would file in $repo: $title" >&2
  cat "$body" >&2
  exit 0
fi

if ((!force_new)); then
  existing=$(gh issue list --repo "$repo" --state open --limit 100 --json number,title |
    jq -r --arg title "$title" 'map(select(.title == $title)) | first | .number // empty')
  if [[ -n $existing ]]; then
    echo "issue #$existing with this title is already open in $repo; reusing it (--new to file another)" >&2
    echo "$existing"
    exit 0
  fi
fi

url=$(gh issue create --repo "$repo" --title "$title" --body-file "$body")
number=${url##*/}
[[ $number =~ ^[0-9]+$ ]] || die "could not read an issue number from gh's output: $url"
echo "filed $url" >&2
echo "$number"
