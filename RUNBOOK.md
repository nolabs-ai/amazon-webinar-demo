# Preparation runbook

Off-air procedure: prepare, rehearse, reset, pause. The on-air sequence is
`LIVE_DEMO.md`; narration and claims are in `PRESENTER_GUIDE.md`. Building the
platform from scratch is covered by `infra/README.md`, `kernel/README.md` and
`preflight/README.md`.

The presentation path uses a funded, capped model API key that nono brokers, so
neither agent can read it. Never point this demo at a production repository.

## Fixed resources

Repository, issue and model route are set in `config/webinar.env`.

| Item | Value |
|---|---|
| AWS account / profile / region | `816301968846` / `admin-webinar` / `eu-west-1` |
| EKS cluster, node group | `webinar-kata`, `kata` |
| Namespace, RuntimeClass | `github-agents-demo`, `kata-clh` |
| ECR repository | `816301968846.dkr.ecr.eu-west-1.amazonaws.com/amazon-webinar-demo` |
| Disposable repository | `MateSaary/webinar-demo-sandbox` (issue 1, branch `demo/webinar-fix`) |

Local tools: `aws`, `kubectl`, `jq`, `envsubst` (gettext), `gh`, Docker with
buildx (Colima or Docker Desktop on Apple silicon), OpenTofu 1.10+ and `helm`
only for infrastructure work.

## Credentials

1. A funded model API key with a spend cap.
2. A fine-grained GitHub token limited to the disposable repository
   (Contents, Issues, Pull requests: read/write).
3. A passphrase-free deploy key with write access to that repository.
4. Administrator access to the AWS account through `admin-webinar`.

Reissue expiring credentials before the webinar, not during a rehearsal.

## 1. Select the account and cluster

Every new terminal:

```text
export AWS_PROFILE=admin-webinar AWS_REGION=eu-west-1
export GITHUB_REPOSITORY=MateSaary/webinar-demo-sandbox
aws sts get-caller-identity          # account must be 816301968846
aws eks update-kubeconfig --name webinar-kata
kubectl config current-context       # must name webinar-kata
```

## 2. Start the Kata node (if paused)

```text
scripts/kata-node.sh start      # status shows the current state
```

A new node downloads the custom guest kernel while booting; allow several
minutes, and start it well before the session.

## 3. Build the image and run the preflight

```text
scripts/build-image.sh -r 816301968846.dkr.ecr.eu-west-1.amazonaws.com/amazon-webinar-demo
export IMAGE=$(cat artifacts/image.txt)    # also read by run-webinar.sh

export PREFLIGHT_IMAGE=$IMAGE
envsubst '${PREFLIGHT_IMAGE}' < preflight/kata-nono-check.yaml | kubectl apply -f -
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/kata-nono-check --timeout=10m
kubectl logs pod/kata-nono-check | tee artifacts/preflight.log
kubectl delete pod kata-nono-check
```

Continue only if the log ends with `FAIL=0`, `INCONCLUSIVE=0`,
`VERDICT: ALL_PASS`. Rehearse the newest build with `--latest` (sections 5–6). Once a digest has
passed the readiness gate, freeze it (see "Freezing the image" below) and do not
build again.

## 4. Credentials in the cluster

```text
scripts/setup-secrets.sh                      # token, deploy key and model key, all prompted
scripts/setup-secrets.sh --model-key-only     # replace just the model key
kubectl -n github-agents-demo get secret github-agents -o json | jq -r '.data | keys[]'
```

Expected keys: `model-api-key`, `ssh-private-key`, `token`. Never decode or
print the Secret.

## 5. Check readiness and reset the disposable repository

```text
scripts/check-ready.sh      # read-only; ends in READY or NOT READY
```

It checks the AWS account, kube context, Kata node, RuntimeClass, Secret key
names, issue, branch and `main` state, and that the image exists in ECR. Add
`--latest` while rehearsing before an image is frozen. Fix any `FAIL` with the
section it names, then reset:

```text
scripts/reset-demo.sh --repo "$GITHUB_REPOSITORY"
scripts/check-ready.sh                            # should now say READY
```

This closes only open PRs from `demo/webinar-fix`, deletes only that branch, and
moves `main` back to the `demo-baseline` tag if a merge changed it. Create that
tag once, while `main` still contains the bug the issue describes:

```text
scripts/reset-demo.sh --repo "$GITHUB_REPOSITORY" --set-baseline
```

If the issue is missing, recreate it with `scripts/create-issue.sh --repo "$GITHUB_REPOSITORY"`
and put the number in `config/webinar.env`.

## 6. Rehearse

```text
scripts/run-webinar.sh --latest       # rehearsal: newest build
scripts/run-webinar.sh                # live: the frozen image in config/image
```

To measure reliability instead of trusting one run, `scripts/rehearse.sh -n 10 --latest`
(or without `--latest` for the frozen image) runs the Job repeatedly, resets between
runs and prints a pass/fail table (seconds, FAIL lines, denials, and why a run failed).
Mint a fresh model key first if you use Bedrock.

The live command is the presenter's exact command. It replaces the previous Job, waits for
the Kata pod, and shows the compact presenter view (`ALLOW`, `DENY`, `PASS`,
`FAIL` lines with elapsed time). The complete transcript and nono audit are
saved to `artifacts/demo-<timestamp>.log`; use `scripts/run-webinar.sh --verbose`
to watch the full transcript instead. The command exits nonzero unless the Job
succeeded. Success ends with a `[VERIFICATION]` block and:

```text
DEMO COMPLETE in 1m32s: approval and merge remain with a person
```

The verification lines come from the launcher's own checks (GitHub state and a
credential-read probe under each profile), not from what the agents said.
Failures appear as a `FAIL` line, and the saved log shows why.

Then check the pod and PR from another terminal:

```text
kubectl -n github-agents-demo get pod -l job-name=github-agents-demo -o wide   # kata-clh
gh pr list --repo "$GITHUB_REPOSITORY" --head demo/webinar-fix                 # draft, open
```

### Rehearsing with a different model

Override `config/webinar.env` from the environment; nothing else changes. For
Gemini through its native API (list valid model IDs with
`curl -s "https://generativelanguage.googleapis.com/v1beta/models?key=$KEY" | jq -r '.models[].name'`):

```text
scripts/setup-secrets.sh --model-key-only
MODEL_PROVIDER=gemini MODEL_API=google-generative-ai \
MODEL_UPSTREAM_URL=https://generativelanguage.googleapis.com/v1beta \
MODEL_ID=<model-id> \
scripts/run-webinar.sh --latest
```

### Using Amazon Bedrock (no model key to supply)

Bedrock's Mantle endpoint is regional, so inference stays in the demo account's
region. It is authenticated with a short-term Bedrock API key minted from your AWS
login and written into the Secret. The key is tied to your AWS session and in
practice stopped working after about an hour, so mint it right before a run or a
rehearsal batch, not the day before:

```text
aws sso login --profile admin-webinar
AWS_PROFILE=admin-webinar scripts/setup-secrets.sh --bedrock-key
MODEL_PROVIDER=bedrock MODEL_API=openai-completions \
MODEL_UPSTREAM_URL=https://bedrock-mantle.eu-west-1.api.aws/v1 \
MODEL_ID=openai.gpt-oss-120b \
scripts/run-webinar.sh --latest
```

`MODEL_ID` is any ID from `GET /v1/models` on that endpoint (call it with the key as
a bearer token). Claude models use the Messages API instead:
`MODEL_API=anthropic-messages-bearer` with
`MODEL_UPSTREAM_URL=https://bedrock-mantle.eu-west-1.api.aws/anthropic`. Which
models you can call depends on the agreements accepted for the account
(`aws bedrock get-foundation-model-availability --model-id <id>`).

On a free-tier key with a per-minute quota, add `STAGE_PAUSE=60` to wait between the
two stages. The model key in the Secret must belong to the provider you name here.
Only the Anthropic route has been proven against a real provider; Gemini's native
route has run the full developer stage and most of the reviewer stage. Switch the
Secret back to the webinar key before the final rehearsals.

## 7. Reset after each rehearsal

Jobs are deleted an hour after finishing, so save the log first.

```text
kubectl -n github-agents-demo logs job/github-agents-demo > "artifacts/demo-$(date -u +%Y%m%dT%H%M%SZ)-final.log"
scripts/teardown.sh        # keeps the namespace and Secret; --purge removes the Secret too
scripts/reset-demo.sh --repo "$GITHUB_REPOSITORY"
```

## 8. Pause compute

```text
scripts/kata-node.sh pause
```

## Freezing the image

Run once, after the last successful rehearsal of the image you will present:

```text
scripts/freeze-image.sh      # tags it frozen-<date> in ECR and writes config/image
git add config/image && git commit -m "chore: freeze the webinar image"
scripts/check-ready.sh       # now checks the frozen image, not --latest
```

The tag makes the ECR lifecycle policy keep the image however many test builds
follow. That rule is in `infra/terraform/ecr.tf`; apply it once with
`tofu -chdir=infra/terraform plan` (expect only the lifecycle policy to change)
and then `apply`. Before then, do not push 20 more images after freezing.
Never rebuild after freezing unless you intend to re-rehearse.

## Troubleshooting

| Symptom | Action |
|---|---|
| `branch demo/webinar-fix already exists` | `scripts/reset-demo.sh --repo "$GITHUB_REPOSITORY"` |
| Model reports insufficient credit | `scripts/setup-secrets.sh --model-key-only` with a funded key |
| Pod `Pending` | Kata node not Ready, or its label/taint does not match |
| Pod `ContainerCreating` | Guest kernel missing on the node; see `preflight/README.md` |
| `nono recorded no audit session` | Rerun the preflight; check `nono setup --check-only` in a diagnostic pod |
| Shim socket errors | Prompts must say to run one tool at a time |
| Developer opens no PR / reviewer leaves no comment | Read the first model or tool error above the audit; the launcher fails the Job on purpose |
| Logs gone | Use the saved `artifacts/demo-*.log` |
| `main` is not at the baseline | Someone merged the PR; `scripts/reset-demo.sh` restores it |
| `no image digest` | Nothing frozen: `scripts/freeze-image.sh`, or use `--latest` while rehearsing |

## Readiness gate (before hand-off)

- [ ] `scripts/check-ready.sh` says READY.
- [ ] One clean API-key rehearsal; its `[VERIFICATION]` block shows the credential
      probe passing for both profiles.
- [ ] Three consecutive clean rehearsals, reset to reset, on one frozen image digest.
- [ ] One sanitized successful log and one screen recording kept as the backup.
      Keep its PR: the reset closes it but never deletes it. Do not merge it.
- [ ] `scripts/reset-demo.sh --set-baseline` done, and `config/image` committed
      by `scripts/freeze-image.sh`.
- [ ] `tofu -chdir=infra/terraform plan` reports `No changes` (remote state is in
      `s3://webinar-kata-kernel-816301968846`; never apply from another backend).
- [ ] Day before: GitHub token, deploy key, model balance, AWS access, issue and
      branch state re-checked.
