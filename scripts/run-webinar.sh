#!/usr/bin/env bash
# Start the rehearsed webinar Job. Fixed values live in config/webinar.env.
#
#   scripts/run-webinar.sh [--yes] [--verbose] [--latest | --image <repo>@sha256:<digest>]
#
# By default the frozen digest in config/image is used (scripts/freeze-image.sh);
# --latest uses the newest build (artifacts/image.txt) for rehearsals.
# The screen shows the compact presenter view; --verbose shows the full
# transcript. The saved log is always complete. --yes skips the cluster
# confirmation (the cluster is still printed, with the account ID masked).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=
latest=0
view=presenter
yes_args=()

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 1; }

while (($#)); do
  case $1 in
    --verbose) view=full ;;
    --latest) latest=1 ;;
    -y | --yes) yes_args=(--yes) ;;
    --image) image=${2:?missing value for $1}; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

# shellcheck disable=SC1091  # path is resolved at run time
source "$repo_root/config/webinar.env"
if [[ -z $image ]]; then
  if ((latest)); then
    image=$(cat "$repo_root/artifacts/image.txt" 2>/dev/null || true)
  else
    image=$(cat "$repo_root/config/image" 2>/dev/null || true)
  fi
fi
[[ $image =~ @sha256:[0-9a-f]{64}$ ]] ||
  die "no image digest: nothing is frozen in config/image (scripts/freeze-image.sh); use --latest to run the newest build"

mkdir -p "$repo_root/artifacts"
stamp=$(date -u +%Y%m%dT%H%M%SZ)

echo "Repository: $WEBINAR_REPO  Issue: $WEBINAR_ISSUE"
echo "Model:      $MODEL_PROVIDER/$MODEL_ID"
# The registry host carries the AWS account ID; mask it for the screen only.
echo "Image:      $(sed -E 's/[0-9]{12}/************/g' <<<"$image")"
echo

export MODEL_PROVIDER MODEL_ID MODEL_API MODEL_UPSTREAM_URL STAGE_PAUSE
"$repo_root/scripts/deploy.sh" \
  --repo "$WEBINAR_REPO" \
  --issue "$WEBINAR_ISSUE" \
  --image "$image" \
  --view "$view" \
  "${yes_args[@]}" \
  --log-file "$repo_root/artifacts/demo-$stamp.log"
