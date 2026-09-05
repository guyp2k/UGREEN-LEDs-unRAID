# Unraid support

Rebuilt kernel module plus a small control script, for UGREEN NAS hardware on
Unraid. Written after the LED driver hard-locked a DXP6800 Pro on
7.4.0-beta.2; see `docs/investigation-kernel-lockup.md` for the full analysis.

## Why this exists

The Unraid plugin that used to provide this was archived by its author, capped
at `7.4.0-beta.1`, and its final release was byte-identical to a 2024 build.
Its prebuilt module is compiled against a `struct led_classdev` of 416 bytes
while Unraid 7.4.0-beta.2 ships 432, which corrupts kernel memory and hangs the
machine with no recovery short of a power cycle.

## Contents

| File | Purpose |
| --- | --- |
| `install-ugreen-leds.sh` | Boot-time loader with ABI safety checks |
| `ugreen-leds-unraid` | LED control loop |

## Installation

Place on the boot volume and call the installer from `/boot/config/go`:

```bash
mkdir -p /boot/config/ugreen-leds
# copy led-ugreen.ko, module.meta, install-ugreen-leds.sh, ugreen-leds-unraid
cat >> /boot/config/go <<'GO'

if [ -x /boot/config/ugreen-leds/install-ugreen-leds.sh ]; then
  /boot/config/ugreen-leds/install-ugreen-leds.sh >> /var/log/ugreen-leds-install.log 2>&1 &
fi
GO
```

`module.meta` records what the module was built against and **must** accompany it:

```
built_for=6.18.47-Unraid
leds_brightness_hw_changed=y
led_classdev_size=432
priv_offset=0x1b0
```

## The safety checks

`install-ugreen-leds.sh` refuses to load the module unless **both** hold:

1. `built_for` equals `uname -r`.
2. `leds_brightness_hw_changed` matches `CONFIG_LEDS_BRIGHTNESS_HW_CHANGED` in
   `/lib/modules/$(uname -r)/build/config`.

The second check is the important one. `vermagic` does not encode structure
layouts, so a module built with a different `CONFIG_LEDS_*` set loads without
complaint and then writes past the end of its own `led_classdev`. Failing to
load costs you dark LEDs. Loading a mismatched module costs you the machine.

## Behaviour

- **power** - static green
- **netdev** - colour by link speed. The palette deliberately avoids white and
  green so the network LED cannot be mistaken for a disk LED or the power LED.
  100 yellow, 1000 blue, 2500 magenta, 10000 cyan, other orange, link down red.
- **disk1-N** - white when a drive is present in that bay, off when empty

Bay order is model specific and is not the natural `ata` order. On a DXP6800 the
bays map to `ata3 ata4 ata5 ata6 ata1 ata2`.

Polling is deliberately slow. The LED microcontroller shares the SMBus with the
DDR5 SPD sensors and platform firmware, and there is nothing to gain from
driving it several times a second.

## Rebuilding for a new kernel

Unraid ships its kernel configuration at `/lib/modules/$(uname -r)/build/config`.
Build against a matching vanilla kernel tree using that config, then regenerate
`module.meta`. Unraid's own patches touch md/nvme/drm/thunderbolt/scsi/uas and
do not affect the LED class layout.
