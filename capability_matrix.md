## Capability matrix

| Capability | Developer | Reviewer |
|---|---:|---:|
| Read issue, PR, diff, and repository | Allow | Allow |
| Modify the worktree | Allow | Deny |
| Run tests | Allow | Allow |
| Push `demo/webinar-fix` | Allow | Deny |
| Open a draft PR | Allow | Deny |
| Post a PR comment | Not needed | Allow |
| Approve or merge | Deny | Deny |
| Read raw GitHub/model credentials | Deny | Deny |
| Use unrestricted network access | Deny | Deny |

## Architecture diagram draft

A possible source for a slide. These are the main components; implementation
details could go in an appendix.

```mermaid
flowchart LR
  P[Presenter] -->|starts one Job| EKS[Amazon EKS]
  subgraph K[One Kata microVM: separate guest kernel]
    L[Trusted launcher]
    D[Developer agent\nnono developer profile]
    R[Reviewer agent\nnono reviewer profile]
    CP[Credential and command mediation]
    L --> D
    L --> R
    D --> CP
    R --> CP
  end
  EKS --> K
  CP -->|permitted model requests| M[Model API]
  CP -->|permitted REST calls| GH[GitHub API]
  D -->|designated branch only| SSH[Brokered SSH push]
  SSH --> GH
```

