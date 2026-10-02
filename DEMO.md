# Demo overview

This work-in-progress demo runs two GitHub agents in one Kata-isolated Amazon
EKS workload. Kata isolates the workload from the node; nono gives each agent
only the capabilities required for its role.

## Flow

1. A developer agent receives an issue number, fixes the prepared bug, runs the
   tests, commits, pushes `demo/webinar-fix` through `demo-secure`, and opens a
   draft pull request.
2. A reviewer agent receives the pull-request number, reads the linked issue,
   diff, and checks, then comments and approves when appropriate.
3. Both agents attempt actions outside their roles. nono blocks them and records
   the decisions in its audit output.

The developer may push only the designated branch and cannot merge. The
reviewer cannot modify the worktree, create branches, push, request changes, or
merge.

## Security boundaries

- Kata provides a separate guest kernel for the pod.
- nono mediates agent filesystem access, commands, credentials, and GitHub API
  endpoints.
- Git authentication uses a brokered SSH-agent socket; agents cannot read the
  private key.
- GitHub API authentication uses a mounted token that nono replaces with a
  sandbox-visible phantom credential.
- The current developer Git and SSH command sandboxes allow outbound network
  access, while exact argument policies constrain the permitted push. The
  reviewer remains network-denied except for brokered GitHub API routes.
- Kubernetes credentials are not mounted into the demo pod.

## Repository layout

- `.github/workflows/ci.yml` validates the sample application and nono profiles.
- `config/` contains the pinned GitHub SSH host key.
- `demo_app/` contains the small application and prepared bug.
- `infra/` describes the EKS Kata node and runtime contract.
- `k8s/` contains the namespace, service account, Secret example, and Kata Job
  scaffold.
- `profiles/` contains the developer and reviewer nono policies.
- `prompts/` contains the parameterized agent instructions.
- `scenario/` contains the prepared issue text.
- `scripts/` contains local and CI policy tests.
- `Containerfile`, `NONO_VERSION`, and `PI_VERSION` define the agent image and
  pinned runtime versions.

## Current status

- Both profiles validate with nono 0.79.0 on Linux.
- A real sandboxed push to `demo/webinar-fix` succeeded through the developer
  profile; a push to `main` was denied before contacting GitHub.
- The container builds and runs as a non-root user with nono 0.79.0 and Pi
  1.0.0. Filesystem enforcement works inside the container.
- EKS and Kubernetes resources are scaffolded but have not been deployed.

## Remaining work

1. Add the trusted container entrypoint that prepares the workspace and runs Pi
   sequentially under the two profiles.
2. Choose and broker Pi's model authentication.
3. Build and publish the image to a demo ECR repository.
4. Provision the EKS Kata node group and install the pinned Kata runtime.
5. Mount disposable GitHub credentials, run the Job, and rehearse the complete
   issue-to-review flow.

No credentials belong in this repository or in the container image.
