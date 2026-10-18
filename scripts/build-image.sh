#!/usr/bin/env bash
# Build the agent image for linux/amd64, push it to ECR under a unique tag and
# print the immutable reference.
#
#   scripts/build-image.sh [-r <ecr-repository-url>] [-t <tag>] [--no-push]
#
# The repository URL defaults to $ECR_REPOSITORY_URL, then to the Terraform
# output. AWS credentials come from the standard chain (AWS_PROFILE, SSO, env).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repository=${ECR_REPOSITORY_URL:-}
tag=
push=1

usage() { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while (($#)); do
  case $1 in
    -r|--repository) repository=${2:?missing value for $1}; shift 2 ;;
    -t|--tag) tag=${2:?missing value for $1}; shift 2 ;;
    --no-push) push=0; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage 1 >&2 ;;
  esac
done

if [[ -z $repository ]] && command -v terraform >/dev/null; then
  repository=$(terraform -chdir="$repo_root/infra/terraform" output -raw ecr_repository_url 2>/dev/null || true)
fi
if ((push)) && [[ -z $repository ]]; then
  echo "no repository: pass -r, set ECR_REPOSITORY_URL, or apply infra/terraform" >&2
  exit 1
fi
repository=${repository:-amazon-webinar-demo}

if [[ -z $tag ]]; then
  tag=$(git -C "$repo_root" rev-parse --short=12 HEAD)-$(date -u +%Y%m%d%H%M%S)
  git -C "$repo_root" diff --quiet HEAD -- || tag+=-dirty
fi

if ! ((push)); then
  docker buildx build --platform linux/amd64 --load -t "$repository:$tag" \
    -f "$repo_root/Containerfile" "$repo_root"
  echo "built $repository:$tag (not pushed)"
  exit 0
fi

registry=${repository%%/*}
region=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
if [[ -z $region && $registry =~ \.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com ]]; then
  region=${BASH_REMATCH[1]}
fi
aws ecr get-login-password ${region:+--region "$region"} \
  | docker login --username AWS --password-stdin "$registry"

metadata=$(mktemp)
trap 'rm -f "$metadata"' EXIT
docker buildx build --platform linux/amd64 --provenance=false --push \
  -t "$repository:$tag" --metadata-file "$metadata" \
  -f "$repo_root/Containerfile" "$repo_root"

digest=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["containerimage.digest"])' "$metadata")
echo
echo "pushed $repository:$tag"
echo "$repository@$digest"
mkdir -p "$repo_root/artifacts"
echo "$repository@$digest" >"$repo_root/artifacts/image.txt"
