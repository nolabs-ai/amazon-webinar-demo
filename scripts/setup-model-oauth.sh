#!/usr/bin/env bash
# Add or replace only the model OAuth credential in the existing demo Secret.
# The GitHub token, deploy key and optional model API key are left untouched.
#
#   scripts/setup-model-oauth.sh [--yes] [path-to-pi-auth.json]
set -euo pipefail

# shellcheck source=scripts/kube-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kube-common.sh"
assume_yes=0
auth_file=$HOME/.pi/agent/auth.json
while (($#)); do
  case $1 in
    -y | --yes) assume_yes=1 ;;
    -h | --help) sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) auth_file=$1 ;;
  esac
  shift
done

for tool in kubectl jq; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
[[ -f $auth_file && -r $auth_file ]] || die "cannot read $auth_file"
if jq -e '.anthropic.type == "oauth" and (.anthropic.access | type == "string") and (.anthropic.refresh | type == "string")' \
  "$auth_file" >/dev/null 2>&1; then
  auth_json=$(jq -c '{anthropic: .anthropic}' "$auth_file")
elif jq -e '.auth_mode == "chatgpt" and (.tokens.access_token | type == "string") and (.tokens.refresh_token | type == "string")' \
  "$auth_file" >/dev/null 2>&1; then
  auth_json=$(jq -c '
    .tokens.access_token as $access
    | ($access | split(".")[1] | gsub("-"; "+") | gsub("_"; "/") | . + "===" | @base64d | fromjson | .exp * 1000) as $expires
    | {"openai-codex": {type: "oauth", access: $access, refresh: .tokens.refresh_token, expires: $expires,
                         accountId: .tokens.account_id}}
  ' "$auth_file")
else
  die "$auth_file has neither a Pi Anthropic OAuth credential nor a Codex ChatGPT login"
fi

require_cluster
kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1 ||
  die "Secret $namespace/$secret_name not found; run scripts/setup-secrets.sh first"

# Pass the patch on stdin so neither token appears in argv or a temporary file.
printf '%s' "$auth_json" | jq -Rs \
  '{data: {"model-auth-json": (. | @base64)}}' |
  kubectl -n "$namespace" patch secret "$secret_name" --type merge --patch-file /dev/stdin >/dev/null
unset auth_json

echo "Secret $namespace/$secret_name updated with model-auth-json; existing keys were preserved."
