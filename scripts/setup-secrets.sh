#!/usr/bin/env bash
# Create or update the Kubernetes Secret `github-agents` straight in the cluster:
# the GitHub token, the SSH deploy key and the model API key are read from the
# terminal (never echoed) and sent to the API server over stdin. Nothing is
# written to disk and nothing is placed in argv or in a manifest.
#
#   scripts/setup-secrets.sh [--yes] [--model-key-only] [--bedrock-key]
#
# --model-key-only replaces just the model API key in the existing Secret.
# --bedrock-key    does the same with a short-term Amazon Bedrock API key minted
#                  from your current AWS credentials (no key to supply). It is
#                  tied to the AWS session and lasts about an hour in practice.
#                  Needs `pip install aws-bedrock-token-generator`.
#
# Use a disposable repository, a fine-grained token limited to it, and a deploy
# key (with write access) for the same repository.
set -euo pipefail

# shellcheck source=scripts/kube-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kube-common.sh"
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
assume_yes=0
model_only=0
bedrock=0

while (($#)); do
  case $1 in
    -y | --yes) assume_yes=1 ;;
    --model-key-only) model_only=1 ;;
    --bedrock-key) model_only=1 bedrock=1 ;;
    -h | --help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

for tool in kubectl jq ssh-keygen; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
[[ -t 0 ]] || die "run this from a terminal: the secrets are prompted for, not read from a pipe"

require_cluster

if ((model_only)); then
  kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1 ||
    die "Secret $namespace/$secret_name not found; run without --model-key-only first"
  if ((bedrock)); then
    # Uses the AWS credential chain (AWS_PROFILE, e.g. admin-webinar after
    # `aws sso login`) and the region of the cluster; the key is region-bound.
    export AWS_REGION=${AWS_REGION:-${WEBINAR_REGION:-eu-west-1}}
    model_api_key=$(python3 -c 'from aws_bedrock_token_generator import provide_token; print(provide_token(), end="")') ||
      die "could not mint a Bedrock key (pip install aws-bedrock-token-generator; aws sso login)"
  else
    read -r -s -p "Model API key (input hidden): " model_api_key
    echo
  fi
  [[ -n $model_api_key ]] || die "empty model API key"
  printf '%s' "$model_api_key" | jq -Rs '{data: {"model-api-key": (. | @base64)}}' |
    kubectl -n "$namespace" patch secret "$secret_name" --type merge --patch-file /dev/stdin >/dev/null
  unset model_api_key
  echo "Secret $namespace/$secret_name: model-api-key replaced; other keys untouched."
  exit 0
fi

read -r -s -p "GitHub token (input hidden): " github_token
echo
[[ -n $github_token ]] || die "empty token"

read -r -p "Path to the SSH private key (no passphrase): " key_path
key_path=${key_path/#\~/$HOME}
[[ -f $key_path && -r $key_path ]] || die "cannot read $key_path"
# Fails for a passphrase-protected key (-P '') or a file that is not a key.
ssh-keygen -y -P '' -f "$key_path" >/dev/null 2>&1 ||
  die "$key_path is not a usable private key (it must have no passphrase and mode 0600)"
ssh_private_key=$(<"$key_path")$'\n' # keep the trailing newline OpenSSH requires

read -r -s -p "Model API key (input hidden): " model_api_key
echo
[[ -n $model_api_key ]] || die "empty model API key"

kubectl apply -f "$repo_root/k8s/namespace.yaml" >/dev/null

# jq reads the values from its own environment, builds the Secret and base64
# encodes it; kubectl reads the manifest on stdin. No file, no argv.
export github_token ssh_private_key model_api_key namespace secret_name
jq -n '{
  apiVersion: "v1", kind: "Secret",
  metadata: {name: env.secret_name, namespace: env.namespace},
  type: "Opaque",
  data: {
    "token": (env.github_token | @base64),
    "ssh-private-key": (env.ssh_private_key | @base64),
    "model-api-key": (env.model_api_key | @base64)
  }}' | kubectl apply -f - >/dev/null
unset github_token ssh_private_key model_api_key

echo "Secret $namespace/$secret_name applied with keys: $(kubectl -n "$namespace" get secret "$secret_name" -o json | jq -r '.data | keys | join(", ")')"
