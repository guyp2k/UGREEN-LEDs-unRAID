#!/bin/bash
#
# Boot-time installer for the UGREEN LED driver on Unraid.
#
# Refuses to load the module unless it matches the running kernel, both by
# version AND by the LED configuration options that determine the size of
# struct led_classdev. A module built against a different CONFIG_LEDS_* set
# loads happily and then corrupts its own private data, which hard-locks the
# machine with no recovery short of a power cycle. Checking is cheap.

set -u

DIR=/boot/config/ugreen-leds
META="$DIR/module.meta"
KVER="$(uname -r)"
KCONFIG="/lib/modules/${KVER}/build/config"

log() { logger -t ugreen-leds-install "$*"; echo "ugreen-leds-install: $*"; }

# The module normally arrives as a Slackware package installed under
# /lib/modules/<kver>/extra. A hand-placed copy under $DIR is also accepted so
# the loader works for a manual install too.
KO=""
for cand in \
    "/lib/modules/${KVER}/extra/led-ugreen.ko.xz" \
    "/lib/modules/${KVER}/extra/led-ugreen.ko" \
    "$DIR/led-ugreen.ko"; do
    [ -r "$cand" ] && { KO="$cand"; break; }
done
[ -n "$KO" ] || { log "ERROR: led-ugreen module not found in /lib/modules/${KVER}/extra or $DIR"; exit 1; }
log "module: $KO"

# ---- guard 1: kernel version -------------------------------------------------
built_ver="$(grep -m1 '^built_for=' "$META" 2>/dev/null | cut -d= -f2-)"
if [ -z "$built_ver" ]; then
    log "ERROR: $META missing built_for, refusing to load"
    exit 1
fi
if [ "$built_ver" != "$KVER" ]; then
    log "REFUSING TO LOAD: module built for '$built_ver', running kernel is '$KVER'."
    log "Rebuild the module for this kernel. LEDs stay off; the system stays up."
    exit 1
fi

# ---- guard 2: LED ABI-relevant config ---------------------------------------
# CONFIG_LEDS_BRIGHTNESS_HW_CHANGED adds 16 bytes to struct led_classdev.
# A mismatch here is invisible to vermagic and is fatal at runtime.
built_hwchanged="$(grep -m1 '^leds_brightness_hw_changed=' "$META" 2>/dev/null | cut -d= -f2-)"
if [ -r "$KCONFIG" ]; then
    if grep -q '^CONFIG_LEDS_BRIGHTNESS_HW_CHANGED=y' "$KCONFIG"; then
        running_hwchanged=y
    else
        running_hwchanged=n
    fi
    if [ -n "$built_hwchanged" ] && [ "$built_hwchanged" != "$running_hwchanged" ]; then
        log "REFUSING TO LOAD: CONFIG_LEDS_BRIGHTNESS_HW_CHANGED is '$running_hwchanged' in the"
        log "running kernel but the module was built with '$built_hwchanged'. struct led_classdev"
        log "sizes differ; loading this would corrupt kernel memory. Rebuild required."
        exit 1
    fi
else
    log "WARNING: $KCONFIG unreadable, cannot verify LED config. Proceeding on version match only."
fi

# ---- load --------------------------------------------------------------------
modprobe i2c-dev    2>/dev/null
modprobe i2c-i801   2>/dev/null
modprobe led-class  2>/dev/null

if ! lsmod | grep -q '^led_ugreen'; then
    loaded=0
    case "$KO" in
        /lib/modules/*)
            depmod -a 2>/dev/null
            modprobe led-ugreen 2>/dev/null && loaded=1
            ;;
    esac
    if [ "$loaded" -eq 0 ]; then
        case "$KO" in
            *.xz) xz -dc "$KO" > /tmp/led-ugreen.ko 2>/dev/null \
                    && insmod /tmp/led-ugreen.ko 2>/dev/null && loaded=1
                  rm -f /tmp/led-ugreen.ko ;;
            *)    insmod "$KO" 2>/dev/null && loaded=1 ;;
        esac
    fi
    [ "$loaded" -eq 1 ] || { log "ERROR: could not load the module"; exit 1; }
    log "module loaded (built for $built_ver)"
fi

# ---- instantiate the LED controller on the i801 SMBus ------------------------
i2c_dev="$(ls -d /sys/bus/i2c/devices/i2c-* 2>/dev/null | while read -r d; do
    [ "$(cat "$d/name" 2>/dev/null)" = "SMBus I801 adapter at efa0" ] && { basename "$d"; break; }
done)"
if [ -z "$i2c_dev" ]; then
    for d in /sys/bus/i2c/devices/i2c-*; do
        case "$(cat "$d/name" 2>/dev/null)" in
            *"I801"*) i2c_dev="$(basename "$d")"; break ;;
        esac
    done
fi
if [ -z "$i2c_dev" ]; then
    log "ERROR: no i801 SMBus adapter found"
    exit 1
fi

if [ ! -d "/sys/bus/i2c/devices/${i2c_dev#i2c-}-003a" ]; then
    echo "led-ugreen 0x3a" > "/sys/bus/i2c/devices/$i2c_dev/new_device" 2>/dev/null \
        && log "LED controller instantiated at 0x3a on $i2c_dev" \
        || { log "ERROR: could not instantiate device"; exit 1; }
fi

# ---- start the control script ------------------------------------------------
sleep 1
rm -f /var/run/ugreen-leds-unraid.lock
setsid nohup "$DIR/ugreen-leds-unraid" > /var/log/ugreen-leds.log 2>&1 < /dev/null &
log "control script started"
