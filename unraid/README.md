# UGREEN LED control for Unraid

An Unraid plugin for the UGREEN NAS front-panel LEDs, built after the previous
plugin's prebuilt kernel module started hard-locking machines on Unraid
7.4.0-beta.2.

> ### Tested scope
>
> | | |
> |---|---|
> | **Unraid** | 7.4.0-beta.2 only (kernel `6.18.47-Unraid`) |
> | **Hardware** | UGREEN DXP6800 Pro only |
>
> The plugin is **version capped to 7.4.0-beta.2** and will not install on any
> other Unraid release. Every Unraid version ships a different kernel and needs
> a module built specifically for it.
>
> Other UGREEN models are supported by the underlying driver but have **not**
> been tested here. On an untested model the LED-to-bay mapping may be wrong or
> the LEDs may not light at all. The machine is not at risk either way: the
> loader refuses to load a module that does not match the running kernel.
>
> Install it on a machine you can afford to reboot.

Full analysis: [`docs/investigation-kernel-lockup.md`](../docs/investigation-kernel-lockup.md)

## What went wrong with the old plugin

Unraid enabled `CONFIG_LEDS_BRIGHTNESS_HW_CHANGED` between 7.4.0-beta.1 and
7.4.0-beta.2. That adds 16 bytes to `struct led_classdev`, taking it from 416 to
432 bytes. The previously distributed module was still built against 416, so the
LED core wrote 16 bytes past the module's `cdev` field, over the driver's own
`priv` pointer and into the next array element.

`mutex_lock(&state->priv->mutex)` then locked an address near `0x8`. Not a
mutex, so a CPU spun on it indefinitely, RCU stalled, and the machine became
unusable. It fires from a workqueue on any LED brightness change, so no user
interaction is needed, and `rmmod` cannot recover it because unregistering the
LEDs sets brightness and deadlocks the same way. Only a power cycle works.

The module loaded cleanly throughout, with a valid checksum, because
**`vermagic` does not encode structure layouts**. Nothing in the normal module
loading path can detect this.

## How this plugin avoids repeating it

The module is built against the running kernel's own configuration, which Unraid
ships at `/lib/modules/$(uname -r)/build/config`. Each module package carries a
`module.meta` recording what it was built against:

```
built_for=6.18.47-Unraid
leds_brightness_hw_changed=y
priv_offset=0x1b0
```

`ugreen-leds-install` refuses to load unless **both** hold:

1. `built_for` equals `uname -r`
2. `leds_brightness_hw_changed` matches `CONFIG_LEDS_BRIGHTNESS_HW_CHANGED` in
   the running kernel's config

`build-packages.sh` additionally refuses to *package* a module whose `priv`
offset does not match what the target configuration implies.

Failing to load costs you dark LEDs. Loading a mismatched module costs you the
machine. The plugin always chooses dark LEDs.

## Behaviour

- **power** - static green
- **netdev** - colour by link speed: 100 yellow, 1000 blue, 2500 magenta,
  10000 cyan, other orange, link down red. The palette deliberately avoids white
  and green so the network LED is never mistaken for a disk LED or the power LED.
- **disk1-N** - white when a drive is present in that bay, off when empty

Bay order is model specific and is **not** the natural `ata` order. On a DXP6800
the bays map to `ata3 ata4 ata5 ata6 ata1 ata2`.

Polling is slow by design. The LED microcontroller shares the SMBus with the
DDR5 SPD temperature sensors and platform firmware; driving it several times a
second buys nothing and adds contention.

### Configuration

Optional, at `/boot/config/ugreen-leds/settings.cfg`:

```bash
POLL_INTERVAL=10
COLOR_POWER="0 255 0"
COLOR_DISK_PRESENT="255 255 255"
COLOR_NETDEV_10000="0 255 255"
```

## Building

```bash
# userspace scripts, kernel independent
./build-packages.sh userspace

# kernel module, once per Unraid kernel
./build-packages.sh module <kernel-version> <prepared-kernel-tree>
```

Preparing a kernel tree:

```bash
curl -O https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-<version>.tar.xz
tar -xf linux-<version>.tar.xz && cd linux-<version>
cp /path/to/unraid/config .config      # from /lib/modules/$(uname -r)/build/config
make olddefconfig
make -j$(nproc) modules_prepare
```

Unraid sets neither `CONFIG_MODVERSIONS` nor `CONFIG_MODULE_SIG`, so no symbol
CRCs and no module signing are required. `modules_prepare` alone does not
produce a `Module.symvers`; without one the module builds but records no
`depends=`, so `modprobe` will not pull in `i2c-core` and `led-class`. One can
be reconstructed from a running machine:

```bash
awk '$3 ~ /^__ksymtab_/ { name=substr($3,11); mod=$4; gsub(/[][]/,"",mod);
     if (mod=="") mod="vmlinux"; print name"\t"mod }' /proc/kallsyms \
  | sort -u \
  | awk -F'\t' '{printf "0x00000000\t%s\t%s\tEXPORT_SYMBOL_GPL\t\n", $1, $2}' \
  > Module.symvers
```

Unraid's own kernel patches touch md, nvme, drm, thunderbolt, scsi and uas, and
do not affect the LED class layout, so a vanilla tree with Unraid's config is
sufficient for this module.

## Publishing module builds

The plugin fetches the module package from a GitHub release **tagged with the
exact kernel version**, e.g. `6.18.47-Unraid`, containing
`ugreen_leds-<date>-<kver>-1.txz` and its `.md5`. Without a release for the
running kernel the plugin installs, reports that no build exists, and leaves the
LEDs alone.

## Credit

Kernel module and original tooling by Yuhao Zhou (miskcoo),
<https://github.com/miskcoo/ugreen_leds_controller>. The Unraid packaging
approach follows the plugin previously maintained by ich777.

## Installing

In the Unraid GUI: **Plugins > Install Plugin**, paste:

```
https://github.com/guyp2k/ugreen-leds-unraid/raw/master/unraid/ugreen-leds-unraid.plg
```

The plugin will refuse to install on any Unraid release other than 7.4.0-beta.2.
