# Secure GitHub Agents on Amazon EKS

This repository contains a webinar demo showing how two GitHub-focused agents
can run in the same Kata-isolated Amazon EKS workload while receiving different
capabilities from [nono](https://nono.sh/).

The demo follows two agents:

- A developer agent fixes a prepared bug, pushes a branch, and opens a pull
  request.
- A reviewer agent reads the issue and pull request and leaves review feedback,
  but cannot create branches, push code, or merge.

Both agents may use the same underlying GitHub credential. The demo shows how
nono can restrict each agent according to its role even when that credential
has broader permissions.

Kata provides the workload isolation boundary. nono provides finer-grained
filesystem, command, network, and credential controls for the agents and the
tools they invoke inside the workload.

The platform and the complete two-agent workflow have been proven on the real
EKS/Kata environment. See [DEMO.md](DEMO.md) for the evidence and status.

## Tooling

The nono version used to validate the demo policies is pinned in
[NONO_VERSION](NONO_VERSION). The Pi version intended for the agent image is
pinned in [PI_VERSION](PI_VERSION).

Infrastructure lives in [infra](infra), [kernel](kernel) and
[preflight](preflight); the Job and the scripts to run it live in [k8s](k8s) and
[scripts](scripts). This is a demo, not a production deployment.

## Where to start

| You are... | Read |
|---|---|
| Presenting live | [LIVE_DEMO.md](LIVE_DEMO.md) |
| Preparing or rehearsing | [RUNBOOK.md](RUNBOOK.md) |
| Planning the talk, slides and Q&A | [PRESENTER_GUIDE.md](PRESENTER_GUIDE.md) |
| Reviewing the design and security boundaries | [DEMO.md](DEMO.md), [k8s/README.md](k8s/README.md) |
| Looking for future work | [docs/backlog.md](docs/backlog.md) |

## Safety

Development and rehearsal should use a dedicated disposable repository and
demo identity. Credentials must not be committed, included in container images,
printed in logs, or exposed directly to agent processes.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
