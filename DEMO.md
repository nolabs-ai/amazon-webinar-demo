# Demo overview

This demo runs two GitHub agents ([Pi](https://github.com/earendil-works/pi))
in one Kata-isolated Amazon EKS workload. Kata isolates the workload from the
node; nono gives each agent only the capabilities required for its role. The
trusted launcher `bin/run-demo` runs them one after the other.

## Flow

1. A developer agent receives an issue number, fixes the prepared bug, runs the
   tests, commits, pushes `demo/webinar-fix` through `demo-secure`, and opens a
   draft pull request.
2. A reviewer agent receives the pull-request number, reads the linked issue,
   diff, and checks, then leaves a comment that opens with a plain-text verdict
   (`Verdict: APPROVE` or `Verdict: CHANGES SUGGESTED`).
3. Both agents attempt actions outside their roles: the developer tries to
   merge its pull request, the reviewer tries to create a branch, to submit an
   approving review through the API, and to merge. nono blocks them, and the launcher prints nono's audit summary and every
   denied decision after each stage (`kubectl logs`).

The developer may push only the designated branch and cannot merge. The
reviewer is comment-only: it cannot modify the worktree, create branches, push,
approve, request changes, or merge. Both agents share one GitHub token, so they
are one GitHub identity; GitHub rejects approving your own pull request, and a
review verdict is not part of the role in any case. The real approval and merge
are left to a person, in the GitHub UI under their own identity, as the closing
step of the demo.

## Security boundaries

- Kata provides a separate guest kernel for the pod.
- nono mediates agent filesystem access, commands, credentials, and GitHub API
  endpoints.
- Git authentication uses a brokered SSH-agent socket; agents cannot read the
  private key.
- GitHub API authentication uses a mounted token that nono replaces with a
  sandbox-visible phantom credential, restricted to REST endpoints per role (see
  below).
- The model API key is brokered the same way: nono's proxy reads it from a file
  and injects it into calls to the model host; the agents see a placeholder
  (`LLM_API_KEY`) and a loopback base URL, and may only `POST /v1/messages`
  there. The key and the deploy key are unreadable from either profile.
- Both agent sessions are proxy-only: the model route is the only network
  destination, and direct sockets are blocked. (The Git and SSH command
  sandboxes still allow outbound network access, while exact argument policies
  constrain the permitted push.)
- Kubernetes credentials are not mounted into the demo pod.

## GitHub API surface and the GraphQL gap

nono's endpoint policy matches the HTTP method and path of a request, never its
body. The high-level `gh` commands in the pinned image (Debian's gh 2.23.0:
`gh pr create`, `view`, `checks`, `comment`, `review`, and `gh issue view`) all
call `POST /graphql`, where queries and mutations share one endpoint. Allowing
it would let an agent run `mergePullRequest`, `enablePullRequestAutoMerge`, or
`addPullRequestReview` and sidestep both the REST merge deny and the
comment-only reviewer. nono 0.79.0 has no way to restrict GraphQL operations.

So the agents do not use GraphQL at all:

- `gh` is limited to `gh api`, and the prompts use explicit REST paths (read the
  issue and pull request, open a draft pull request, post a comment).
- `/graphql` is refused for every method by the endpoint policy and, for
  `gh api graphql`, by an argv rule. `gh pr merge` stays denied by argv, and
  `PUT /pulls/*/merge` by the endpoint policy.
- The agents' own network is proxy-only, so they cannot reach GitHub directly;
  the token is only injected into requests that pass the endpoint policy.

Residual gaps, stated plainly:

- Allowed endpoints are bounded by method and path only. `POST
  /repos/.../issues/*/comments` accepts any text, and `POST /repos/.../pulls`
  can open a pull request from any branch the token can read.
- The GitHub token is broader than either role. nono, not the token, is what
  stops an agent from merging; anything running outside the sandbox with the
  token could merge.
- If GraphQL were re-enabled for convenience (for example to use `gh pr
  comment`), a GraphQL mutation could merge or approve; do not do that unless
  nono gains operation-level matching.

## Repository layout

- `.github/workflows/ci.yml` lints the scripts, tests the launcher and the
  cluster scripts with fakes, validates and tests the nono profiles, and
  validates the manifests.
- `bin/` contains the trusted launcher `run-demo` and the in-sandbox Pi wrapper
  `pi-agent`.
- `config/` contains the pinned GitHub SSH host key.
- `demo_app/` contains the small application and prepared bug.
- `infra/`, `kernel/` and `preflight/` describe, build and check the EKS Kata
  node, the Landlock guest kernel and the runtime contract.
- `k8s/` contains the namespace, service account, Secret example, and Kata Job.
- `profiles/` contains the developer and reviewer nono policies.
- `prompts/` contains the parameterized agent instructions.
- `scenario/` contains the prepared issue text.
- `scripts/` builds the image, creates the issue and the Secret, deploys and
  tears down the Job, and holds the tests.
- `Containerfile`, `NONO_VERSION`, and `PI_VERSION` define the agent image and
  pinned runtime versions.

## Running it

See [k8s/README.md](k8s/README.md). In short: `scripts/build-image.sh`,
`scripts/setup-secrets.sh`, `scripts/create-issue.sh`, `scripts/deploy.sh`.

## Current status

Done and proven on the cluster:

- The AWS account, EKS cluster, Kata runtime with a custom Landlock guest
  kernel, and the image build and push (`scripts/build-image.sh`).
- The preflight pod passes all 16 checks, including Landlock enforcement on a
  virtio-fs `emptyDir`, the credential proxy, command mediation and the
  ssh-agent broker.
- Both profiles set `linux.af_unix_mediation = "pathname"`; a pathname Unix
  socket a sandboxed process needs must be granted with `filesystem.unix_socket`.
- Both profiles validate with nono 0.79.0 on Linux. A real sandboxed push to
  `demo/webinar-fix` succeeded through the developer profile; a push to `main`
  was denied before contacting GitHub.

Written and tested locally, but not yet run on the cluster:

- The launcher, the Pi wrapper and the new profile rules, tested here with fake
  nono, Pi and GitHub (`scripts/test-run-demo.sh`) and, for the model route, on
  a macOS nono 0.79.0 build.
- On Linux, `scripts/test-profiles.sh` covers the model key, the REST-only gh
  policy and the comment-only reviewer in CI.

Not yet proven end to end:

- Pi, under the sandbox, reaching the model through nono's proxy and completing
  the task (paths Pi needs, loopback proxy with `NO_PROXY`, `af_unix_mediation`).
- The full flow with real GitHub: push, draft PR through `gh api`, the reviewer's
  comment, the denied attempts, and the audit output in `kubectl logs`.
- The Secret volume mode (`0440`) and the ssh-agent key load on the cluster.

## Remaining work

1. Rebuild the image, create the Secret and run `scripts/deploy.sh` once; fix
   whatever the first end-to-end run shows (the commands are in
   [k8s/README.md](k8s/README.md)).
2. Rehearse the flow a few times against the disposable repository and decide
   what to show live (the logs, `nono audit show`, `nono why`).
3. Open question for review: the GraphQL gap above, and whether the demo should
   accept the loss of `gh pr create/comment` for it.

No credentials belong in this repository or in the container image.
