#!/bin/bash
#
# Rebuild the LED kernel module for a new Unraid kernel.
#
# Unraid ships a different kernel with most releases, and an out-of-tree module
# must be built against that kernel's own configuration. Building against the
# wrong CONFIG_LEDS_* set produces a module that loads cleanly and then corrupts
# kernel memory, which is the defect this project exists because of. This script
# takes the configuration straight from the machine that will run the module.
#
# Usage:
#   ./rebuild-for-kernel.sh --from-host root@nas [--release]
#   ./rebuild-for-kernel.sh --kver 6.19.2-Unraid --config /path/to/config [--release]
#
#   --from-host   read uname -r, the kernel config and /proc/kallsyms over ssh
#   --kver        kernel version, exactly as uname -r reports it
#   --config      Unraid's kernel config (/lib/modules/<kver>/build/config)
#   --release     also create the GitHub release and upload the package
#   --workdir     where to keep kernel sources (default ~/kbuild-ugreen)
#
# After this succeeds you still need to widen the plugin's min/max, bump the
# userspace package version and merge. The script prints those steps.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORKDIR="${HOME}/kbuild-ugreen"
HOST=""; KVER=""; CONFIG=""; DO_RELEASE=0

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">> $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --from-host) HOST="${2:-}"; shift 2 ;;
        --kver)      KVER="${2:-}"; shift 2 ;;
        --config)    CONFIG="${2:-}"; shift 2 ;;
        --workdir)   WORKDIR="${2:-}"; shift 2 ;;
        --release)   DO_RELEASE=1; shift ;;
        -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
        *)           die "unknown argument: $1" ;;
    esac
done

mkdir -p "$WORKDIR"

# ---------------------------------------------------------------- gather input
KALLSYMS=""
if [ -n "$HOST" ]; then
    info "reading kernel details from $HOST"
    KVER="$(ssh "$HOST" 'uname -r')" || die "could not reach $HOST"
    [ -n "$KVER" ] || die "empty kernel version from $HOST"
    CONFIG="$WORKDIR/config-$KVER"
    scp -q "$HOST:/lib/modules/$KVER/build/config" "$CONFIG" \
        || die "could not fetch /lib/modules/$KVER/build/config from $HOST"
    KALLSYMS="$WORKDIR/kallsyms-$KVER"
    ssh "$HOST" 'cat /proc/kallsyms' > "$KALLSYMS" 2>/dev/null || KALLSYMS=""
fi

[ -n "$KVER" ]   || die "need --kver or --from-host"
[ -n "$CONFIG" ] || die "need --config or --from-host"
[ -r "$CONFIG" ] || die "cannot read config: $CONFIG"

BASE="${KVER%%-*}"                      # 6.19.2-Unraid -> 6.19.2
MAJOR="${BASE%%.*}"                     # 6
info "kernel $KVER (upstream $BASE)"

HW=n
grep -q '^CONFIG_LEDS_BRIGHTNESS_HW_CHANGED=y' "$CONFIG" && HW=y
info "CONFIG_LEDS_BRIGHTNESS_HW_CHANGED=$HW"

# ------------------------------------------------------------- kernel sources
TREE="$WORKDIR/linux-$BASE"
if [ ! -d "$TREE" ]; then
    TARBALL="$WORKDIR/linux-$BASE.tar.xz"
    if [ ! -f "$TARBALL" ]; then
        URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-${BASE}.tar.xz"
        info "downloading $URL"
        curl -fsSL -o "$TARBALL" "$URL" || die "could not download kernel $BASE"
    fi
    info "extracting (this takes a minute)"
    tar -xf "$TARBALL" -C "$WORKDIR" || die "extract failed"
else
    info "reusing existing tree $TREE"
fi

# -------------------------------------------------------------------- prepare
info "configuring with Unraid's config"
cp "$CONFIG" "$TREE/.config"
make -C "$TREE" olddefconfig >/dev/null || die "olddefconfig failed"

for opt in CONFIG_LEDS_BRIGHTNESS_HW_CHANGED CONFIG_LEDS_CLASS CONFIG_LOCALVERSION; do
    a="$(grep -E "^${opt}[= ]" "$CONFIG"        || true)"
    b="$(grep -E "^${opt}[= ]" "$TREE/.config"  || true)"
    [ "$a" = "$b" ] || die "config drift on $opt: unraid='$a' tree='$b'"
done
info "config applied with no drift on LED options"

info "running modules_prepare"
make -C "$TREE" -j"$(nproc)" modules_prepare >/dev/null || die "modules_prepare failed"

# Module.symvers is not produced by modules_prepare. Without it the module still
# builds and loads, but records no depends=, so modprobe will not pull in
# i2c-core and led-class on its own. Reconstruct it when we have a live kernel.
if [ -n "$KALLSYMS" ] && [ -s "$KALLSYMS" ]; then
    info "reconstructing Module.symvers from the running kernel"
    awk '$3 ~ /^__ksymtab_/ { name=substr($3,11); mod=$4; gsub(/[][]/,"",mod);
         if (mod=="") mod="vmlinux"; print name"\t"mod }' "$KALLSYMS" \
      | sort -u \
      | awk -F'\t' '{printf "0x00000000\t%s\t%s\tEXPORT_SYMBOL_GPL\t\n", $1, $2}' \
      > "$TREE/Module.symvers"
    info "  $(wc -l < "$TREE/Module.symvers") exported symbols"
else
    info "no kallsyms available; module will build without depends="
fi

# ---------------------------------------------------------------------- build
info "building the module package"
"$HERE/build-packages.sh" module "$KVER" "$TREE"

PKG="$(ls -1 "$HERE"/packages/ugreen_leds-*-"$KVER"-1.txz 2>/dev/null | tail -1)"
[ -n "$PKG" ] || die "no package was produced"

# ------------------------------------------------------------------- validate
info "validating the built module"
KO="$REPO/kmod/led-ugreen.ko"
VM="$(objcopy -O binary --only-section=.modinfo "$KO" /dev/stdout 2>/dev/null | tr '\0' '\n' | grep '^vermagic=' || true)"
DEP="$(objcopy -O binary --only-section=.modinfo "$KO" /dev/stdout 2>/dev/null | tr '\0' '\n' | grep '^depends=' || true)"
echo "   $VM"
echo "   $DEP"
case "$VM" in
    *"$KVER"*) ;;
    *) die "vermagic does not mention $KVER" ;;
esac

# ------------------------------------------------------------------- release
if [ "$DO_RELEASE" -eq 1 ]; then
    command -v gh >/dev/null || die "gh is required for --release"
    info "creating release $KVER"
    gh release create "$KVER" \
        --title "Kernel module for $KVER" \
        --notes "led-ugreen built against the kernel configuration Unraid ships with $KVER.

CONFIG_LEDS_BRIGHTNESS_HW_CHANGED=$HW

The plugin fetches this automatically. Do not install it by hand on another kernel: vermagic cannot detect a CONFIG_LEDS_* mismatch, and loading a mismatched module corrupts kernel memory." \
        "$PKG" "$PKG.md5" || die "release failed"
else
    info "skipping release (pass --release to publish)"
fi

cat <<DONE

Built: $(basename "$PKG")

Remaining steps, which are deliberately manual:

  1. Widen the plugin version range in unraid/ugreen-leds-unraid.plg
       min="<lowest tested Unraid>"  max="<this Unraid version>"
  2. Bump the userspace package version and rebuild it:
       PKG_VERSION=<new> ./unraid/build-packages.sh userspace
     then update the md5 entity in the plg to match.
     Do NOT delete the previous userspace package; cached plg copies still ask
     for it and would 404 mid-install.
  3. Update the tested-scope tables in README.md and unraid/README.md.
  4. Commit, open a PR, merge, then install on a machine you can afford to reboot.

DONE
