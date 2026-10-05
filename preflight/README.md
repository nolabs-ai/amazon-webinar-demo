# Preflight

`kata-nono-check.yaml` is a throwaway Pod that runs in the `kata-clh` runtime
and uses the pinned nono and the demo profiles to check that:

- the guest kernel exposes Landlock, seccomp user notification, and pidfd;
- the reviewer profile cannot write in the working directory and the developer
  profile can, on both a virtio-fs emptyDir and a tmpfs;
- the reviewer cannot reach the network;
- the credential proxy works with a dummy token; and
- the command policy and ssh-agent broker work.

It needs no Secret, ServiceAccount, or namespace, and never touches a real
credential. Its only outbound calls are to `example.com`, `api.github.com`, and
`ssh.github.com:443`.

The stock Kata 3.27.0 guest kernel has no Landlock, so the demo uses the custom
kernel built from [`../kernel`](../kernel). Run the preflight after the
cluster, Kata, and that kernel are installed.

## Prerequisites

- A cluster with a Kata node and kata-deploy installed, as described in
  [`../infra`](../infra).
- A demo image built for `linux/amd64` that the node can pull.
- Outbound internet access from the node.

## Run

```text
export PREFLIGHT_IMAGE=<account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>

# Substitute only PREFLIGHT_IMAGE; the script inside has its own ${...}.
envsubst '${PREFLIGHT_IMAGE}' < preflight/kata-nono-check.yaml | kubectl apply -f -

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/kata-nono-check --timeout=300s \
  || kubectl wait --for=jsonpath='{.status.phase}'=Failed pod/kata-nono-check --timeout=60s
kubectl logs kata-nono-check
kubectl delete pod kata-nono-check
```

A passing run ends with:

```text
LANDLOCK_ABI=7
PASS=... FAIL=0 INCONCLUSIVE=0
VERDICT: ALL_PASS
```

`uname -r` in the log ends in `-landlock` when the custom kernel is in use.

## Troubleshooting

| Result | Likely cause and action |
|---|---|
| `LANDLOCK_UNAVAILABLE`, `ENOSYS` | The pod is on the stock kernel. Check `uname -r`, that `/opt/kata-guest-kernel/vmlinux-landlock` exists on the node, and that `infra/kata-values.yaml` was applied. |
| `LANDLOCK_UNAVAILABLE`, `EOPNOTSUPP` | Landlock is not in the active LSM list. Enable the `kernel_params` annotation in the manifest. |
| `LANDLOCK_TOO_OLD` | The guest kernel is older than 6.2. Rebuild with `../kernel`. |
| `T1` or `T2` fail on `/workspace` only | Landlock is not enforced on virtio-fs. Use a memory-backed `emptyDir` for the workspace in `k8s/job.yaml`. |
| `T3` fails | The network block was not applied. Run `nono setup --check-only` in the pod. |
| `T5-*` fail | Credential proxy problem. Run `nono run -v` in the pod. |
| `T6-git-ssh-chain` fails | Check `SSH_AUTH_SOCK` and `/etc/nono/github_known_hosts`. |
| `T6-agent-raw` fails | The sandbox can reach the raw agent socket. Do not demo. |
| `PASS_WITH_INCONCLUSIVE` | Some checks need egress. Fix NAT or security groups and rerun. |
| Pod stuck in `ContainerCreating` | The kernel file is missing from the node. Check `kata_guest_kernel_s3_uri`. |
| Pod fails mentioning `/dev/kvm` | Nested virtualization is not enabled. Check the launch template and instance type. |
