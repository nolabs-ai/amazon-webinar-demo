# Secure GitHub Agents on Amazon EKS

Work in progress.

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

The demo is under active development and is not yet ready for general use.

## Tooling

The nono version used to validate the demo policies is pinned in
[NONO_VERSION](NONO_VERSION).

Initial deployment scaffolding lives in [infra](infra) and [k8s](k8s). It is
not yet a complete or production-ready deployment.

## Safety

Development and rehearsal should use a dedicated disposable repository and
demo identity. Credentials must not be committed, included in container images,
printed in logs, or exposed directly to agent processes.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
