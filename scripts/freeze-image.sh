#!/usr/bin/env bash
# Freeze the image that every rehearsal and the live demo will use.
#
#   scripts/freeze-image.sh [<repo>@sha256:<digest>]
#
# Defaults to the newest build (artifacts/image.txt). Confirms the digest exists
# in ECR, tags it frozen-<date> so the ECR lifecycle policy never expires it, and
# writes it to config/image, which is tracked in git: commit that file so the
# presenter's clone runs exactly this image. Run it once, after the final
# successful rehearsal on this digest.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die() { echo "error: $*" >&2; exit 1; }
case ${1:-} in
  -h | --help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# shellcheck disable=SC1091  # path is resolved at run time
source "$repo_root/config/webinar.env"
image=${1:-$(cat "$repo_root/artifacts/image.txt" 2>/dev/null || true)}
[[ $image =~ ^[^@]+@(sha256:[0-9a-f]{64})$ ]] || die "pass an image as <repo>@sha256:<digest>, or run scripts/build-image.sh first"
digest=${BASH_REMATCH[1]}
tag=frozen-$(date -u +%Y%m%d)

manifest=$(aws ecr batch-get-image --region "$WEBINAR_REGION" --repository-name "$WEBINAR_ECR_REPOSITORY" \
  --image-ids "imageDigest=$digest" --query 'images[0].imageManifest' --output text 2>/dev/null) ||
  die "cannot read $digest from ECR repository $WEBINAR_ECR_REPOSITORY (aws login? wrong digest?)"
[[ -n $manifest && $manifest != None ]] || die "$digest is not in ECR repository $WEBINAR_ECR_REPOSITORY"

existing=$(aws ecr describe-images --region "$WEBINAR_REGION" --repository-name "$WEBINAR_ECR_REPOSITORY" \
  --image-ids "imageDigest=$digest" --query 'imageDetails[0].imageTags' --output text 2>/dev/null || true)
if [[ " $existing " == *" $tag "* ]]; then
  echo "Already tagged $tag."
elif aws ecr put-image --region "$WEBINAR_REGION" --repository-name "$WEBINAR_ECR_REPOSITORY" \
  --image-tag "$tag" --image-manifest "$manifest" >/dev/null; then
  echo "Tagged $digest as $tag."
else
  die "could not tag the image; the ECR lifecycle policy may expire it"
fi

printf '%s\n' "$image" >"$repo_root/config/image"
echo "Frozen: $image"
echo "Now commit config/image. Do not freeze again unless you rebuild and re-rehearse."
