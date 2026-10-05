#!/usr/bin/env bash
# Check that a kernel config has what nono needs inside the Kata guest.
#
# Usage: verify-config.sh <.config | config.gz | vmlinux>
#
# A vmlinux is checked through its embedded config (CONFIG_IKCONFIG).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kernel/versions.env
. "$here/versions.env"

[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: $0 <.config | config.gz | vmlinux>" >&2; exit 2; }

cfg="$(mktemp)"
trap 'rm -f "$cfg"' EXIT

case "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" in
  7f454c46)  # ELF
    python3 - "$1" > "$cfg" <<'PY'
import sys, zlib
data = open(sys.argv[1], "rb").read()
start = data.find(b"IKCFG_ST")
if start < 0:
    sys.exit("no embedded config (IKCFG_ST) in vmlinux: CONFIG_IKCONFIG missing")
sys.stdout.write(zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(data[start + 8:]).decode())
PY
    ;;
  1f8b*) gzip -dc "$1" > "$cfg" ;;
  *) cp "$1" "$cfg" ;;
esac

fails=0
ok()   { printf 'PASS  %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
val()  { sed -n "s/^CONFIG_$1=//p" "$cfg" | head -1; }

need_y() {  # option, reason
  if [ "$(val "$1")" = y ]; then ok "CONFIG_$1=y ($2)"; else bad "CONFIG_$1 is not =y ($2)"; fi
}

grep -q '^CONFIG_X86_64=y' "$cfg" && ok "x86_64 config" || bad "not an x86_64 config"

# Landlock ABI 4 (TCP port rules, used by nono --block-net) needs 6.7 or later.
ver="$(sed -n 's/^# Linux\/x86\(_64\)\{0,1\} \([0-9][0-9.]*\).*/\2/p' "$cfg" | head -1)"
if [ -z "$ver" ]; then
  bad "cannot read kernel version from config header"
else
  [ "$ver" = "$KERNEL_VERSION" ] && ok "kernel $ver matches pin" || bad "kernel $ver, pin is $KERNEL_VERSION"
  [ "$(printf '%s\n6.7\n' "$ver" | sort -V | head -1)" = 6.7 ] && ok "kernel >= 6.7 (Landlock ABI >= 4)" || bad "kernel < 6.7 (Landlock ABI < 4)"
fi

# Landlock
need_y SECURITY_LANDLOCK "nono sandbox"
need_y SECURITY "LSM framework"
need_y SECURITYFS "/sys/kernel/security/lsm"
lsm="$(val LSM | tr -d '"')"
case ",$lsm," in *,landlock,*) ok "CONFIG_LSM lists landlock" ;; *) bad "CONFIG_LSM does not list landlock (got '$lsm')" ;; esac

# seccomp user notification (nono supervisor)
need_y SECCOMP "seccomp"
need_y SECCOMP_FILTER "seccomp filters and user notification"
need_y UNIX "AF_UNIX / SCM_RIGHTS fd passing to the supervisor"
need_y PROC_FS "/proc (pidfd, status)"
need_y MULTIUSER "uid/gid"

# Isolation + Kata storage
need_y NAMESPACES "namespaces"
need_y USER_NS "user namespaces"
need_y PID_NS "pid namespaces"
need_y NET_NS "net namespaces"
need_y CGROUPS "cgroups"
need_y FUSE_FS "virtio-fs is FUSE based"
need_y VIRTIO_FS "pod volumes (emptyDir, Secrets)"
need_y TMPFS "emptyDir medium Memory"

# Verification and fingerprint
need_y IKCONFIG "embedded config"
need_y IKCONFIG_PROC "/proc/config.gz"
lv="$(val LOCALVERSION | tr -d '"')"
[ "$lv" = "$LOCALVERSION" ] && ok "LOCALVERSION=$lv" || bad "LOCALVERSION is '$lv', expected '$LOCALVERSION'"
# Kata guest kernels are monolithic; a changed release string would break modules.
[ "$(val MODULES)" != y ] && ok "no loadable module support (LOCALVERSION cannot break module loading)" \
  || bad "CONFIG_MODULES=y: guest rootfs modules built for the stock release would not load with LOCALVERSION=$lv"

if [ "$fails" -eq 0 ]; then echo "OK: config satisfies nono's kernel requirements"; else echo "$fails check(s) failed"; exit 1; fi
