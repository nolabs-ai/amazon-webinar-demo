# Landlock-enabled Kata guest kernel

nono sandboxes agents with Landlock and seccomp. The guest kernel that
kata-deploy 3.27.0 ships for `kata-clh` (Linux 6.18.12) is built without
`CONFIG_SECURITY_LANDLOCK`, so nono cannot sandbox anything inside a stock Kata
pod. This directory builds a replacement guest kernel and describes how it
reaches the nodes.

The kernel is Kata's own, built with Kata's `build-kernel.sh` at the pinned
release plus one config fragment.

| | |
|---|---|
| Kata release | 3.27.0, commit pinned in `versions.env` |
| Kernel | 6.18.12, Landlock ABI 7 (nono needs 3 or later, port rules need 4 or later) |
| Build flags | `-x -m`, as used for Kata's x86_64 kernel asset |
| Added | `fragments/landlock.conf`: Landlock, `CONFIG_LSM` with `landlock` first, securityfs, embedded config, `-landlock` release suffix |
| Guest `uname -r` | `6.18.12-landlock` |
| Target | x86_64 only |

## Files

| File | Purpose |
|---|---|
| `versions.env` | Pins for the Kata release and commit, kernel version, and Kata config revision |
| `fragments/landlock.conf` | The config change, merged by Kata's own build step |
| `build.sh` | Fetches the pinned Kata packaging tree, checks the pins, builds, and verifies the result |
| `Containerfile.builder` | Build environment matching Kata's kernel builder image |
| `verify-config.sh` | Checks a `.config`, `config.gz`, or `vmlinux` for what nono needs |

Build output goes to `kernel/out/`, which is gitignored.

## Build

The build requires x86_64 Linux with Docker.

The [Kata guest kernel workflow](../.github/workflows/kernel.yml) runs
`build.sh` on a hosted runner. Pull requests that touch `kernel/` run
`build.sh --setup-only`, which merges the fragments and checks the config
without compiling. Pushes to `main` and manual runs do the full build and keep
the kernel as a workflow artifact:

```text
gh workflow run kernel.yml
gh run watch
```

Without Actions, run `kernel/build.sh` on a temporary x86_64 instance with
Docker (for example `c7i.2xlarge`) and copy `kernel/out/*` off the instance.

Fragment edits can be checked on an arm64 machine under emulation:

```text
docker build --platform linux/amd64 -t nono-kata-kernel-builder:test -f kernel/Containerfile.builder kernel
docker run --rm --platform linux/amd64 -v "$PWD:$PWD" -w "$PWD" -e HOME=/tmp \
  -e WORK=/tmp/kwork -e OUT=/tmp/kout nono-kata-kernel-builder:test \
  kernel/build.sh --native --setup-only
```

## Verify

`build.sh` runs `verify-config.sh` on the merged config and on the finished
`vmlinux`. To check an artifact manually:

```text
kernel/verify-config.sh kernel/out/vmlinux-6.18.12-181-landlock
```

The final check is behavioral: run the [preflight](../preflight/README.md) pod
on a node.

## Deploy to nodes

kata-deploy has no chart value for the guest kernel. The kernel is instead
delivered through the node and a `customRuntimes` entry:

1. Build or download the kernel and check it:

   ```text
   gh run download <run-id> -n kata-kernel-landlock -D kernel/out
   kernel/verify-config.sh kernel/out/vmlinux-6.18.12-181-landlock
   ( cd kernel/out && sha256sum -c SHA256SUMS )
   ```

2. Upload it to a private S3 bucket in the cluster's region under a new key:

   ```text
   aws s3 cp kernel/out/vmlinux-6.18.12-181-landlock \
     s3://<bucket>/kata/vmlinux-6.18.12-181-landlock
   ```

3. Set `kata_guest_kernel_s3_uri` in `infra/terraform/terraform.tfvars` and
   apply. The node user data downloads the file to
   `/opt/kata-guest-kernel/vmlinux-landlock` before the kubelet starts.
4. Run `infra/install-kata.sh`. `infra/kata-values.yaml` defines a `kata-clh`
   custom runtime that reuses the `clh` config and sets that kernel path.
5. Run the preflight.

Each kernel needs a new S3 key. The URI is part of the node user data, so a new
key rolls the node group onto the new kernel.

`kernel_params` is deliberately not set in the drop-in. The kernel lists
`landlock` first in `CONFIG_LSM`, and a `kernel_params` key in a drop-in
replaces the whole value, dropping the parameters kata-deploy sets.

## Update

Everything that selects the kernel is pinned in `versions.env`. `build.sh`
refuses to build if the Kata tag does not resolve to `KATA_COMMIT`, or if
`KERNEL_VERSION` and `KATA_CONFIG_VERSION` differ from what that release ships.

To move to a new Kata release, together with `KATA_CHART_VERSION` in
`infra/install-kata.sh`:

1. Note the kernel version and `kata_config_version` the release ships.
2. Resolve the tag to a commit with
   `git ls-remote https://github.com/kata-containers/kata-containers 'refs/tags/<version>*'`.
3. Update `versions.env` and the file names in the docs.
4. Run `kernel/build.sh --setup-only`. Remove anything from `landlock.conf`
   that the new release already provides.
5. Run the full build, verify, upload under a new S3 key, and update
   `kata_guest_kernel_s3_uri`.
6. Re-run the preflight.

To use a newer patch release of the same kernel series than Kata ships, set
`KERNEL_VERSION` and run `build.sh` with `ALLOW_KERNEL_DRIFT=1`.

Landlock ABI by kernel version: 6.2 is 3, 6.7 is 4, 6.10 is 5, 6.12 is 6, and
6.15 or later is 7. Profiles that use `--block-net` port rules need 6.7 or
later.
