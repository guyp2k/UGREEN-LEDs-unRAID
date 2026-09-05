#!/bin/bash
#
# Build the Unraid packages.
#
#   ugreen-leds-unraid-<date>.txz          userspace scripts, kernel independent
#   ugreen_leds-<date>-<kver>-1.txz        kernel module, one per Unraid kernel
#
# The module package carries a module.meta recording what it was built against.
# install-ugreen-leds refuses to load a module whose meta does not match the
# running kernel, which is the whole point: vermagic cannot detect a
# CONFIG_LEDS_* mismatch, and loading one hard-locks the machine.
#
# Usage:
#   ./build-packages.sh userspace
#   ./build-packages.sh module <kernel-version> <path-to-prepared-kernel-tree>

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="$HERE/packages"
DATE="$(date +%Y.%m.%d)"
mkdir -p "$OUT"

die() { echo "ERROR: $*" >&2; exit 1; }

make_txz() {  # <staging-dir> <output-file>
    local stage="$1" out="$2"
    ( cd "$stage" && tar -cJf "$out" . )
    md5sum "$out" | awk '{print $1}' > "$out.md5"
    echo "built $(basename "$out")  md5=$(cat "$out.md5")"
}

build_userspace() {
    local stage; stage="$(mktemp -d)"
    mkdir -p "$stage/usr/bin" "$stage/install"
    install -m0755 "$REPO/scripts/unraid/ugreen-leds-unraid"     "$stage/usr/bin/ugreen-leds-unraid"
    install -m0755 "$REPO/scripts/unraid/install-ugreen-leds.sh" "$stage/usr/bin/ugreen-leds-install"
    cat > "$stage/install/slack-desc" <<'DESC'
       |-----handy-ruler------------------------------------------------------|
ugreen-leds-unraid: ugreen-leds-unraid UGREEN NAS LED control for Unraid
ugreen-leds-unraid:
ugreen-leds-unraid: Control script and guarded module loader for the UGREEN NAS
ugreen-leds-unraid: front-panel LEDs.
ugreen-leds-unraid:
ugreen-leds-unraid: Refuses to load a kernel module built against a different
ugreen-leds-unraid: CONFIG_LEDS_* set than the running kernel.
ugreen-leds-unraid:
DESC
    make_txz "$stage" "$OUT/ugreen-leds-unraid-$DATE.txz"
    rm -rf "$stage"
}

build_module() {
    local kver="${1:-}" ktree="${2:-}"
    [ -n "$kver" ]  || die "kernel version required"
    [ -n "$ktree" ] || die "prepared kernel tree required"
    [ -d "$ktree" ] || die "no such kernel tree: $ktree"

    local kconf="$ktree/.config"
    [ -r "$kconf" ] || die "no .config in $ktree"

    local hw=n
    grep -q '^CONFIG_LEDS_BRIGHTNESS_HW_CHANGED=y' "$kconf" && hw=y

    echo "building module for $kver (CONFIG_LEDS_BRIGHTNESS_HW_CHANGED=$hw)"
    make -C "$ktree" M="$REPO/kmod" clean >/dev/null 2>&1 || true
    make -C "$ktree" M="$REPO/kmod" modules

    local ko="$REPO/kmod/led-ugreen.ko"
    [ -f "$ko" ] || die "module was not produced"

    # Sanity: priv must sit at sizeof(led_classdev) past cdev. Wrong offset here
    # is the exact defect this project exists because of.
    local off
    off="$(objdump -d --no-show-raw-insn "$ko" \
           | awk '/<ugreen_led_set_brightness_blocking>:/,/ret/' \
           | grep -m1 -oE 'mov +0x[0-9a-f]+\(%r[a-z0-9]+\),' \
           | grep -oE '0x[0-9a-f]+' || true)"
    echo "  state->priv offset: ${off:-unknown}"
    if [ "$hw" = y ] && [ "$off" != "0x1b0" ]; then
        die "priv offset $off unexpected for CONFIG_LEDS_BRIGHTNESS_HW_CHANGED=y (want 0x1b0)"
    fi

    local stage; stage="$(mktemp -d)"
    mkdir -p "$stage/lib/modules/$kver/extra" "$stage/boot/config/ugreen-leds" "$stage/install"
    cp "$ko" "$stage/lib/modules/$kver/extra/led-ugreen.ko"
    xz --check=crc32 --lzma2 "$stage/lib/modules/$kver/extra/led-ugreen.ko"

    cat > "$stage/boot/config/ugreen-leds/module.meta" <<META
built_for=$kver
leds_brightness_hw_changed=$hw
priv_offset=${off:-unknown}
built_on=$(date -u +%Y-%m-%dT%H:%M:%SZ)
META
    cat > "$stage/install/slack-desc" <<'DESC'
       |-----handy-ruler------------------------------------------------------|
ugreen_leds: ugreen_leds UGREEN NAS LED kernel module
ugreen_leds:
ugreen_leds: led-ugreen built against a specific Unraid kernel configuration.
ugreen_leds: Ships module.meta so the loader can refuse a mismatch.
ugreen_leds:
DESC
    make_txz "$stage" "$OUT/ugreen_leds-$DATE-$kver-1.txz"
    rm -rf "$stage"
}

case "${1:-}" in
    userspace) build_userspace ;;
    module)    build_module "${2:-}" "${3:-}" ;;
    *)         die "usage: $0 userspace | module <kver> <kernel-tree>" ;;
esac
