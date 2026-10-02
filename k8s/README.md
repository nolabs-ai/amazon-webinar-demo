# Kubernetes workload

This directory contains the initial Kata Job scaffold. It expects:

- a `kata-clh` RuntimeClass;
- a Kata node labelled and tainted as described in `../infra`;
- a demo image containing nono, Git, GitHub CLI, Pi, the profiles, prompts, and
  a trusted `/demo/bin/run-demo` entrypoint; and
- a Secret named `github-agents` with `token` and `ssh-private-key` keys.

Copy `secret.example.yaml` to the ignored `secret.yaml`, provide disposable demo
credentials, set the image and issue number in `job.yaml`, and then apply the
manifests. Never commit `secret.yaml`.

The Job runs both agents sequentially in one container and therefore in one
Kata microVM. The trusted entrypoint will pass the configured issue number to
the developer and the resulting pull-request number to the reviewer.
