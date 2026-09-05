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
- **disk1-N** - white when a drive is present in that bay, off when empty, and
  flashing briefly on disk activity

Bay order is model specific and is **not** the natural `ata` order. On a DXP6800
the bays map to `ata3 ata4 ata5 ata6 ata1 ata2`.

Polling is slow by design. The LED microcontroller shares the SMBus with the
DDR5 SPD temperature sensors and platform firmware; driving it several times a
second buys nothing and adds contention.

### Disk activity flashing

Activity flashing uses the kernel's `oneshot` LED trigger. The LED sits lit and
blinks dark briefly whenever the block device's I/O counters change.

Every flash costs SMBus transactions on a bus shared with the DDR5 SPD temperature
sensors and platform firmware. Upstream issue #81 reports unexplained hard lockups
on this hardware attributed to driving the LED controller rapidly, on a distribution
that does not use this kernel module at all. That fault is **not** understood and is
**not** the one this project fixed, so the defaults here are deliberately gentler
than the plugin this one replaces: a 0.5 s poll against its 0.5 s poll plus a
separate 500 ms netdev trigger.

If you would rather not drive the bus at all, turn it off:

```bash
DISK_ACTIVITY_BLINK="no"
```

### Configuration

Optional, at `/boot/config/ugreen-leds/settings.cfg`:

```bash
POLL_INTERVAL=10                 # seconds between presence / link-speed checks
DISK_ACTIVITY_BLINK="yes"        # "no" disables activity flashing entirely
ACTIVITY_INTERVAL=0.5            # seconds between I/O counter checks
ACTIVITY_FLASH_MS=80             # length of each flash

COLOR_POWER="0 255 0"
COLOR_DISK_PRESENT="255 255 255"
COLOR_NETDEV_10000="0 255 255"
```

Raising `ACTIVITY_INTERVAL` reduces bus traffic proportionally at the cost of
responsiveness. Nothing writes to the LED controller unless a value actually
changed, so an idle array generates no traffic beyond the slow state refresh.

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

## When Unraid ships a new kernel

The plugin is capped to the Unraid versions it has been built for, and the loader
independently refuses to load a module whose recorded build kernel or
`CONFIG_LEDS_BRIGHTNESS_HW_CHANGED` value does not match the running kernel.

Upgrading Unraid beyond the tested range therefore leaves the **LEDs dark and the
server healthy**. Nothing needs to be done in a hurry.

To support the new kernel:

```bash
# on a machine already upgraded and running the new kernel
./unraid/rebuild-for-kernel.sh --from-host root@your-nas --release
```

The script:

1. reads `uname -r`, `/lib/modules/<kver>/build/config` and `/proc/kallsyms` over ssh
2. downloads matching upstream kernel sources and applies Unraid's configuration
3. fails if `olddefconfig` alters any LED-relevant option
4. runs `modules_prepare` and reconstructs `Module.symvers` so `depends=` is correct
5. builds and packages the module, refusing to package one whose `state->priv`
   offset does not match the configuration
6. verifies `vermagic` names the target kernel
7. optionally creates the GitHub release tagged with the exact kernel version

It deliberately stops short of editing the plugin. Widening `min`/`max`, bumping the
userspace package version and updating the tested-scope tables stay manual, because
claiming support for an Unraid release is a statement about testing, not about
whether a build succeeded.

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
https://github.com/guyp2k/UGREEN-LEDs-unRAID/raw/master/unraid/UGREEN-LEDs-unRAID.plg
```

The plugin will refuse to install on any Unraid release other than 7.4.0-beta.2.
