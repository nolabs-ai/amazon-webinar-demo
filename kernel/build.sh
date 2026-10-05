#!/usr/bin/env bash
# Build the Kata guest kernel for kata-clh with Landlock enabled.
#
# Runs Kata's build-kernel.sh from the pinned release with the flags used for
# its x86_64 kernel asset, plus fragments/landlock.conf. Requires x86_64 Linux.
#
#   kernel/build.sh                 build in the builder container (needs docker)
#   kernel/build.sh --native        build on this host (needs the packages in
#                                   Containerfile.builder)
#   kernel/build.sh --setup-only    merge and check the config without compiling
#
# Environment: OUT (default kernel/out), WORK (default kernel/.work).
# Output: $OUT/vmlinux-<kernel>-<config rev>-landlock, config-..., SHA256SUMS.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kernel/versions.env
. "$here/versions.env"

OUT="${OUT:-$here/out}"
WORK="${WORK:-$here/.work}"
BUILDER_IMAGE="${BUILDER_IMAGE:-nono-kata-kernel-builder:ubuntu22.04}"
KATA_REPO=https://github.com/kata-containers/kata-containers.git

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*" >&2; }

mode=container
setup_only=0
for arg in "$@"; do
  case "$arg" in
    --native) mode=native ;;
    --setup-only) setup_only=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg (see --help)" ;;
  esac
done

[ "$(uname -m)" = x86_64 ] || die "this builds an x86_64 guest kernel and must run on x86_64 (host is $(uname -m)). See kernel/README.md."

if [ "$mode" = container ]; then
  command -v docker >/dev/null || die "docker not found (or use --native)"
  repo_root="$(cd "$here/.." && pwd)"
  mkdir -p "$OUT" "$WORK"
  OUT="$(cd "$OUT" && pwd)"
  WORK="$(cd "$WORK" && pwd)"
  for d in "$OUT" "$WORK"; do
    case "$d" in "$repo_root"/*) ;; *) die "$d must be inside $repo_root so the container can see it" ;; esac
  done
  info "building builder image $BUILDER_IMAGE"
  docker build -q -t "$BUILDER_IMAGE" -f "$here/Containerfile.builder" "$here" >/dev/null
  exec docker run --rm \
    -v "$repo_root:$repo_root" -w "$repo_root" \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -e OUT="$OUT" -e WORK="$WORK" -e ALLOW_KERNEL_DRIFT="${ALLOW_KERNEL_DRIFT:-0}" \
    "$BUILDER_IMAGE" \
    "$here/build.sh" --native ${setup_only:+--setup-only}
fi

# Native mode
for tool in git curl make gcc flex bison bc python3 patch; do
  command -v "$tool" >/dev/null || die "missing build tool: $tool (see Containerfile.builder for the package list)"
done

mkdir -p "$OUT" "$WORK"
OUT="$(cd "$OUT" && pwd)"
WORK="$(cd "$WORK" && pwd)"
kata="$WORK/kata-containers-$KATA_VERSION"
kb="$kata/tools/packaging/kernel/build-kernel.sh"

if [ ! -d "$kata/.git" ]; then
  info "fetching Kata $KATA_VERSION (packaging tree only)"
  git clone --quiet --depth 1 --branch "$KATA_VERSION" --filter=blob:none --sparse "$KATA_REPO" "$kata"
  git -C "$kata" sparse-checkout set --no-cone /tools/packaging /versions.yaml
fi
got="$(git -C "$kata" rev-parse HEAD)"
[ "$got" = "$KATA_COMMIT" ] || die "tag $KATA_VERSION resolves to $got, pinned $KATA_COMMIT. Delete $kata and investigate before trusting it."

# The pins must match what the Kata release ships.
kata_kver="$(awk '/^  kernel:/{f=1;next} f&&/^    version:/{gsub(/["v ]/,"",$2);print $2;exit}' "$kata/versions.yaml")"
kata_cfgver="$(tr -d '[:space:]' < "$kata/tools/packaging/kernel/kata_config_version")"
[ "$kata_cfgver" = "$KATA_CONFIG_VERSION" ] || die "Kata config version is $kata_cfgver, versions.env says $KATA_CONFIG_VERSION"
if [ "$kata_kver" != "$KERNEL_VERSION" ]; then
  [ "${ALLOW_KERNEL_DRIFT:-0}" = 1 ] || die "Kata $KATA_VERSION ships kernel $kata_kver, versions.env says $KERNEL_VERSION (set ALLOW_KERNEL_DRIFT=1 to build a different kernel than Kata tested)"
  info "WARNING: building kernel $KERNEL_VERSION, not the $kata_kver Kata $KATA_VERSION ships"
fi

install -m 0644 "$here/fragments/landlock.conf" "$kata/tools/packaging/kernel/configs/fragments/common/landlock.conf"

# Same flags as kata-deploy's x86_64 kernel asset.
ksrc="$WORK/kernel-src"
args=(-v "$KERNEL_VERSION" -f -u "$KERNEL_URL" -x -m -k "$ksrc")

export KBUILD_BUILD_USER=nono KBUILD_BUILD_HOST=kata-kernel-build
KBUILD_BUILD_TIMESTAMP="$(git -C "$kata" show -s --format=%cd --date=format:'%a %b %e %H:%M:%S UTC %Y' HEAD)"
export KBUILD_BUILD_TIMESTAMP

info "setup: download kernel $KERNEL_VERSION, merge Kata fragments + landlock.conf"
( cd "$WORK" && "$kb" "${args[@]}" setup )

info "checking merged config before compiling"
"$here/verify-config.sh" "$ksrc/.config"
[ "$setup_only" = 1 ] && { info "setup-only: config is at $ksrc/.config"; exit 0; }

info "compiling"
( cd "$WORK" && "$kb" "${args[@]}" build )

info "installing"
rm -rf "$OUT/root"
( cd "$WORK" && DESTDIR="$OUT/root" PREFIX=/opt/kata "$kb" "${args[@]}" install )

share="$OUT/root/opt/kata/share/kata-containers"
name="vmlinux-$KERNEL_VERSION-$KATA_CONFIG_VERSION-landlock"
cp "$share/vmlinux-$KERNEL_VERSION-$KATA_CONFIG_VERSION" "$OUT/$name"
cp "$share/config-$KERNEL_VERSION-$KATA_CONFIG_VERSION" "$OUT/config-$KERNEL_VERSION-$KATA_CONFIG_VERSION-landlock"
rm -rf "$OUT/root"

info "verifying the built vmlinux"
"$here/verify-config.sh" "$OUT/$name"

{
  echo "kata_version=$KATA_VERSION"
  echo "kata_commit=$KATA_COMMIT"
  echo "kata_config_version=$KATA_CONFIG_VERSION"
  echo "kernel_version=$KERNEL_VERSION"
  echo "gcc=$(gcc --version | head -1)"
  echo "built_at=$(date -u +%FT%TZ)"
} > "$OUT/BUILD-INFO.txt"
( cd "$OUT" && sha256sum "$name" "config-$KERNEL_VERSION-$KATA_CONFIG_VERSION-landlock" > SHA256SUMS )

info "done: $OUT/$name"
cat "$OUT/SHA256SUMS"
