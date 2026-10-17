# Kubernetes workload

The demo is one Job: a single container in one Kata microVM that runs the trusted
launcher `/demo/bin/run-demo`, which runs the developer and then the reviewer
agent under nono.

## Prerequisites

- the cluster, Kata runtime (`kata-clh` RuntimeClass) and Kata node described in
  [`../infra`](../infra), with the Landlock guest kernel from
  [`../kernel`](../kernel); [`../preflight`](../preflight) passes;
- an agent image pushed with `scripts/build-image.sh`, which prints the
  immutable `repo@sha256:...` reference;
- a disposable demo repository containing this repo's content, with an open
  issue (`scripts/create-issue.sh`), a fine-grained GitHub token for it, and a
  deploy key with write access;
- an API key for an Anthropic-compatible model provider.

## Run it

```text
export GITHUB_REPOSITORY=<owner>/<disposable-repo>   # used by create-issue.sh and deploy.sh
scripts/build-image.sh                  # note the repo@sha256:... line
scripts/setup-secrets.sh                # prompts; creates the Secret in the cluster
ISSUE=$(scripts/create-issue.sh)        # once per rehearsal
scripts/deploy.sh --issue "$ISSUE" --image <repo@sha256:...>   # or: --repo <owner/name>
scripts/teardown.sh                     # when done (--purge also removes the Secret)
```

`deploy.sh` checks that `kubectl` points at a reachable cluster, applies the
namespace, service account and Job (replacing an earlier Job), streams the logs
and exits non-zero unless the Job succeeded. The logs hold, per stage, Pi's
transcript, nono's audit summary and every decision nono denied.

Before rerunning, close the demo pull request and delete the `demo/webinar-fix`
branch on GitHub; `run-demo` stops early if the branch still exists.

## Files

| File | Purpose |
|---|---|
| `namespace.yaml` | Namespace with the `restricted` Pod Security level |
| `service-account.yaml` | Service account without a token (no Kubernetes API access) |
| `secret.example.yaml` | Shape of the Secret, for reference only; use `scripts/setup-secrets.sh` instead |
| `job.yaml` | Job template; `deploy.sh` fills in the image digest, issue number and repository |

## The Secret

`github-agents` has three keys, mounted at `/run/secrets/github`:

| Key | Content |
|---|---|
| `token` | GitHub token; nono's proxy injects it into `api.github.com` requests |
| `ssh-private-key` | Deploy key, no passphrase; loaded into an `ssh-agent` the agents cannot reach directly |
| `model-api-key` | Model provider key; nono's proxy injects it into model API calls |

`scripts/setup-secrets.sh` reads them from the terminal without echo and sends
them to the API server over stdin: no file, no manifest, nothing in argv. Never
create `secret.yaml` from the example for real credentials.

The volume uses `defaultMode: 0440`. The files are owned by root and the
container runs as uid 1000 with `fsGroup: 1000`, so the group must be able to
read them; with `0400` the launcher could not. The agents do not rely on file
modes: their nono profiles grant no access under `/run/secrets`.

## Job settings

- **Image**: a digest, never a tag, so the Job runs exactly the image that was
  rehearsed.
- **Model**: `MODEL_PROVIDER`, `MODEL_ID`, `MODEL_API` and `MODEL_UPSTREAM_URL`
  select the provider (the default is Anthropic); its key goes in the Secret.
  The launcher renders the proxy route from them: `anthropic-messages` injects
  `x-api-key` and allows `POST /v1/messages` (+ `count_tokens`);
  `openai-completions` and `openai-responses` inject `Authorization: Bearer` and
  allow `POST /chat/completions` or `/responses` below an upstream that ends in
  `/v1` (OpenAI, OpenRouter, vLLM, Ollama). Only the Anthropic route has been
  tested against a real provider. A Bedrock bearer token is a possible later
  variant and is not wired up.
- **Audit**: nono's audit trail lives in an `emptyDir` at
  `/home/node/.local/state/nono`.
- **Lifetime**: `activeDeadlineSeconds: 2700` bounds a hung run and
  `ttlSecondsAfterFinished: 3600` removes the Job, pod and logs an hour after it
  finishes; read or save the logs before then.
- **Workspace**: an `emptyDir` at `/workspace`; the launcher clones into `/workspace/repo`, a directory it owns (the mount point itself is root-owned, which git refuses as "dubious ownership").

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `... is missing, empty or unreadable` | The Secret is missing a key, or the volume mode/`fsGroup` was changed |
| `branch demo/webinar-fix already exists` | A previous rehearsal's branch; delete it (and close its PR) |
| `issue #N not found` | Create it with `scripts/create-issue.sh` in the same repository |
| Pod stuck `ContainerCreating` | See the troubleshooting table in [`../preflight/README.md`](../preflight/README.md) |
| `nono recorded no audit session` | nono failed to start: run the preflight, check the guest kernel and `nono setup --check-only` |
| A Pi stage ends without a PR or comment | Read the transcript above it; denials of paths Pi needs show under `Capability Decisions` in the audit |
