# Webinar operator runbook

This is the canonical, copy/paste runbook for the GitHub-agent webinar demo.
It assumes the AWS infrastructure already exists. For rebuilding the platform
from scratch, see `infra/README.md`, `kernel/README.md`, and
`preflight/README.md`.

The production presentation path uses a funded model API key so nono can broker
the model credential without exposing it to either agent. Subscription OAuth is
documented at the end as a test-only fallback; do not use it while claiming that
the model credential is hidden from the agent.

## Fixed demo resources

| Item | Value |
|---|---|
| AWS account | `816301968846` (`nolabs-webinar-demo`) |
| Region | `eu-west-1` |
| AWS profile | `admin-webinar` |
| EKS cluster | `webinar-kata` |
| Kata node group | `kata` |
| Kubernetes namespace | `github-agents-demo` |
| RuntimeClass | `kata-clh` |
| ECR repository | `816301968846.dkr.ecr.eu-west-1.amazonaws.com/amazon-webinar-demo` |
| Disposable repository | `MateSaary/webinar-demo-sandbox` |
| Demo branch | `demo/webinar-fix` |
| Prepared issue | issue `1` |

Never point this demo at a production repository.

## Required local tools

Install `aws`, OpenTofu 1.10 or newer, `kubectl`, `helm`, `jq`, `envsubst`
(`gettext`), `gh`, and Docker with buildx. On Apple silicon, start Colima or
Docker Desktop because the image is built for `linux/amd64`.

Confirm the basics:

```text
aws --version
tofu version
kubectl version --client
gh auth status
docker buildx version
```

## Credentials and permissions

Prepare these before rehearsal day:

1. A funded Anthropic-compatible model API key with a conservative spend cap.
2. A fine-grained GitHub token limited to the disposable repository, with
   repository Contents, Issues, and Pull requests read/write access.
3. A passphrase-free deploy key installed on the disposable repository with
   write access.
4. Administrator access to AWS account `816301968846` through profile
   `admin-webinar`.

The GitHub token and deploy key in the cluster Secret currently belong to the
disposable repository. Reissue expiring credentials before the webinar rather
than discovering expiry during a rehearsal.

## 1. Select the AWS account and cluster

Run this at the start of every terminal session:

```text
export AWS_PROFILE=admin-webinar
export AWS_REGION=eu-west-1
export GITHUB_REPOSITORY=MateSaary/webinar-demo-sandbox

aws sts get-caller-identity
aws eks update-kubeconfig --name webinar-kata --region eu-west-1
kubectl config current-context
kubectl cluster-info
```

The account returned by STS must be `816301968846`, and the current context
must name `webinar-kata`. Stop if either differs.

## 2. Start the Kata node when the cluster is paused

```text
aws eks update-nodegroup-config \
  --cluster-name webinar-kata \
  --nodegroup-name kata \
  --scaling-config minSize=0,maxSize=2,desiredSize=1 \
  --region eu-west-1

aws eks wait nodegroup-active \
  --cluster-name webinar-kata \
  --nodegroup-name kata \
  --region eu-west-1

kubectl wait --for=condition=Ready node \
  -l katacontainers.io/kata-runtime=true --timeout=15m
kubectl get nodes -L katacontainers.io/kata-runtime
kubectl get runtimeclass kata-clh
```

The node downloads the custom Landlock-enabled guest kernel from S3 while it
boots. A new node can therefore take several minutes to become ready.

## 3. Validate infrastructure before touching credentials

Build the current image and push it to ECR:

```text
mkdir -p artifacts
scripts/build-image.sh \
  -r 816301968846.dkr.ecr.eu-west-1.amazonaws.com/amazon-webinar-demo \
  | tee /tmp/webinar-image-build.txt

IMAGE=$(tail -n 1 /tmp/webinar-image-build.txt)
case "$IMAGE" in *@sha256:*) ;; *) echo "No image digest found"; exit 1;; esac
echo "$IMAGE"
```

Run the Kata/nono platform preflight using that exact image:

```text
export PREFLIGHT_IMAGE=$IMAGE
envsubst '${PREFLIGHT_IMAGE}' < preflight/kata-nono-check.yaml | kubectl apply -f -
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded \
  pod/kata-nono-check --timeout=10m
kubectl logs pod/kata-nono-check | tee artifacts/preflight.log
kubectl delete pod kata-nono-check
```

Do not continue unless the log ends with `FAIL=0`, `INCONCLUSIVE=0`, and
`VERDICT: ALL_PASS`.

## 4. Create or refresh the Kubernetes Secret

This replaces the GitHub token, deploy key, and model API key together. It
prompts securely and never places credentials in a manifest or command line.

```text
scripts/setup-secrets.sh
kubectl -n github-agents-demo get secret github-agents \
  -o json | jq -r '.data | keys[]'
```

Expected required keys:

```text
model-api-key
ssh-private-key
token
```

Never decode or print the Secret during a webinar or rehearsal.

## 5. Prepare the disposable GitHub repository

Accept the repository invitation if necessary, then verify local access:

```text
gh repo view "$GITHUB_REPOSITORY"
gh issue view 1 --repo "$GITHUB_REPOSITORY"
```

Reset artifacts from the previous run:

```text
scripts/reset-demo.sh --repo "$GITHUB_REPOSITORY"
```

The reset script closes only open PRs whose head is `demo/webinar-fix` and
deletes only that branch. It does not change issue 1 or `main`.

If the prepared issue is missing, recreate or reuse it:

```text
ISSUE=$(scripts/create-issue.sh --repo "$GITHUB_REPOSITORY")
echo "$ISSUE"
```

For the established demo repository, `ISSUE=1` is expected.

## 6. Run the API-key demo

Use the immutable image digest produced in step 3:

```text
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

MODEL_AUTH=api-key \
MODEL_PROVIDER=anthropic \
MODEL_ID=claude-sonnet-5-5 \
MODEL_API=anthropic-messages \
MODEL_UPSTREAM_URL=https://api.anthropic.com \
scripts/deploy.sh \
  --repo "$GITHUB_REPOSITORY" \
  --issue "${ISSUE:-1}" \
  --image "$IMAGE" \
  --log-file "artifacts/demo-$STAMP.log"
```

The script confirms the cluster, replaces only the previous Kubernetes Job,
waits for the Kata pod, streams its logs, saves a copy, and exits nonzero if the
Job fails.

Success ends with all of these statements:

```text
DEMO COMPLETE
Pull request #... is open and unmerged
the reviewer left 1 comment(s)
Job succeeded.
```

Also verify in another terminal:

```text
kubectl -n github-agents-demo get pod -l job-name=github-agents-demo -o wide
gh pr list --repo "$GITHUB_REPOSITORY" --head demo/webinar-fix
```

The pod must use RuntimeClass `kata-clh`; the PR must be draft, open, and
unmerged.

## 7. What to show during the webinar

Use the single streamed log to narrate this sequence:

1. The launcher identifies the model route, issue, SSH key fingerprint, clone,
   and immutable image execution context.
2. The developer reads the issue, reproduces the bug, creates the designated
   branch, fixes it, runs tests, commits, pushes, and opens a draft PR.
3. The developer attempts to merge; nono denies the `gh` invocation.
4. The developer audit shows the allowed git-to-SSH chain and denied merge.
5. The reviewer reads the issue, PR, and diff, then runs the tests and posts one
   plain-text verdict comment.
6. The reviewer attempts to branch, approve, and merge. The branch and merge
   commands are denied; the approval endpoint returns `Forbidden`.
7. The launcher independently confirms that the PR remains open and unmerged
   and that the comment count increased.

The human presenter then opens the PR in the browser and explains that a human
identity performs the actual approval and merge.

## 8. Reset after each rehearsal

Save the logs before cleanup; completed Jobs are automatically removed after
one hour.

```text
kubectl -n github-agents-demo logs job/github-agents-demo \
  > "artifacts/demo-$STAMP-final.log"
scripts/teardown.sh
scripts/reset-demo.sh --repo "$GITHUB_REPOSITORY"
```

`teardown.sh` deletes the Job and its pod but keeps the namespace and Secret.
Use `--purge` only when you intend to remove the Secret too.

## 9. Pause compute between sessions

```text
aws eks update-nodegroup-config \
  --cluster-name webinar-kata \
  --nodegroup-name kata \
  --scaling-config minSize=0,maxSize=2,desiredSize=0 \
  --region eu-west-1
```

Terraform intentionally ignores desired-size drift, so pausing this way does
not create a Terraform change.

## Troubleshooting

| Symptom | Action |
|---|---|
| `branch demo/webinar-fix already exists` | Run `scripts/reset-demo.sh --repo "$GITHUB_REPOSITORY"`. |
| Model reports insufficient credit | Replace the model key with a funded key and rerun setup-secrets. |
| Pod remains `Pending` | Confirm the Kata node is Ready and its taint/toleration and label match. |
| Pod remains `ContainerCreating` | Verify the custom guest kernel exists on the node; see `preflight/README.md`. |
| `nono recorded no audit session` | Run the preflight and `nono setup --check-only` inside a diagnostic pod. |
| Command-mediation shim socket errors | Ensure prompts say to run one tool at a time; do not rely on parallel tool calls. |
| Reviewer cannot read check runs | Expected with the current fine-grained token; the webinar flow no longer requests check runs. |
| Developer opens no PR | Read the first model/tool error above the audit; the launcher intentionally fails the Job. |
| Reviewer leaves no comment | Read its transcript and endpoint denials; the launcher intentionally fails the Job. |
| Logs disappeared | The Job TTL is one hour. Use `--log-file` during deployment. |

## Known limitations to state plainly

- In the API-key path, model and GitHub credentials are brokered by nono and
  raw Secret files are inaccessible to both profiles.
- GitHub endpoint rules match HTTP method and path, not request bodies or
  GraphQL operations. The profiles therefore deny GraphQL entirely.
- The agents share one GitHub identity, so the reviewer posts a comment rather
  than a formal approval.
- The sentinel domain `nono-deny-all.invalid` represents deny-all direct
  session networking because nono currently rejects `network.block` together
  with credential routes and treats an empty allow-list as allow-all.
- The developer git/SSH child sandboxes permit network internally; exact
  invocation policies constrain the branch, remote, SSH host, and repository.
- This demo shows role separation inside one Kata guest. Separate pods and
  credentials would provide stronger production defense in depth.

## Test-only Codex OAuth fallback

The full E2E flow was proven with Pi's `openai-codex` provider and the existing
Codex login, but OAuth makes the credential readable to Pi and allows direct
access to the Codex backend. Use this only for functional rehearsals:

```text
scripts/setup-model-oauth.sh "$HOME/.codex/auth.json"

MODEL_AUTH=oauth \
MODEL_PROVIDER=openai-codex \
MODEL_ID=gpt-5.6-sol \
MODEL_API=openai-responses \
MODEL_UPSTREAM_URL=https://chatgpt.com/backend-api \
scripts/deploy.sh \
  --repo "$GITHUB_REPOSITORY" \
  --issue "${ISSUE:-1}" \
  --image "$IMAGE" \
  --log-file "artifacts/oauth-$STAMP.log"
```

Anthropic subscription OAuth was rejected for third-party Pi usage because it
requires funded extra usage; it is not a no-cost fallback.

## One-time infrastructure safety check

The OpenTofu state is remote at
`s3://webinar-kata-kernel-816301968846/tfstate/webinar-kata.tfstate`.
`infra/terraform/backend.tf` must exist before initialization. Never apply from
a directory that is not using that backend.

```text
tofu -chdir=infra/terraform init
tofu -chdir=infra/terraform plan
```

Expected result for an unchanged platform: `No changes`.

## Final readiness gate

Before hand-off, complete all of these:

- Run one clean API-key E2E rehearsal; OAuth success alone does not prove model
  credential brokering through the whole workflow.
- Run three consecutive clean rehearsals from reset to reset.
- Save one successful log and one screen recording as the backup demo.
- Confirm the GitHub token, deploy key, model key balance, and AWS access on the
  day before the webinar.
- Confirm the presenter can explain the API-key path versus OAuth test mode.
- Decide whether to keep or remove the temporary OAuth code before merging.
- Merge the implementation branch only after CI and the API-key rehearsal pass.

