# Manjaro-Patched `nvidia-open-dkms` Build Pipeline

If you run Manjro and have Gigabyte Aorus RTX 5090 AI Box, which cannot handle any work, because it crashes your machine,
you came to the right place.

If you want to make sure that this repo is what you need, have a look at [this GitHub issue](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979).

This repo is a Manjaro adaptation of [apnex/nvidia-driver-injector](https://github.com/apnex/nvidia-driver-injector),
which first demonstrated that this set of driver and system patches actually works.

## Overview

There is a lot of detailed information about the issue in the driver-injector repository and the GitHub issue linked above.
I am not going to repeat all of that here, instead I am going to provide a high level overview.

The nvidia driver version 610.43.02 has much improved in terms of support for an RTX50xx connected over Thunderbolt. It does not require any patches in order to make the GPU reliably available at least in CUDA capacity.

The problems originating from Thunderbolt link negotiation still persist. This requires a set of system patches, namely:

* setting link speed
* loading nvidia modules only **after** the link speed has been established

To ensure the nvidia modules are not loaded automatically, the are blacklisted and applied fake install method `/bin/false`.
For setting link speed and loading the nvidia modules afterwards we use a systemd service, triggered by a udev
rule when the eGPU appears (the Thunderbolt tunnel can come up well after boot).

On machines with **Secure Boot** enabled the link-speed write cannot be done from userspace, so it is delegated to
a small signed kernel module — see [Secure Boot](#secure-boot).

The install tool patches up configuration (see below).

The uninstall tool tries to restore the system state to what it was prior to the installation.

### Supported distributions

The tooling auto-detects the host's initramfs system:

* **Arch / Manjaro** — uses `mkinitcpio` and `/etc/mkinitcpio.conf`.
* **Debian / Ubuntu** — uses `update-initramfs` and `/etc/initramfs-tools/modules`.

Everything else (GRUB cmdline, `modprobe.d` policy, the systemd service and the
helper binaries) is identical across distributions. You can force a backend with
`INITRAMFS_BACKEND=mkinitcpio` or `INITRAMFS_BACKEND=initramfs-tools` if detection
guesses wrong.

**This works on my machine. It has not been tested on anyone else's.**

## Install

```bash
./install.sh
```

This does the following:

- Removes conflicting NVIDIA modules from the initramfs module list
  (`/etc/mkinitcpio.conf` on Arch/Manjaro, `/etc/initramfs-tools/modules` on Debian/Ubuntu)
- Rewrites `/etc/modprobe.d/*.conf` to disable conflicting NVIDIA modules
- Rewrites `/etc/default/grub` with correct kernel parameters for the GPU bridge
- Installs `aorus-bridge` and `aorus-modules` binaries to `/usr/local/bin`
- Installs a udev rule (`/etc/udev/rules.d/99-aorus-egpu.rules`) that starts
  `aorus.service` when the eGPU's PCI function appears — the Thunderbolt tunnel
  can enumerate tens of seconds into boot, after `systemd-udev-settle`, so a
  plain boot-ordered oneshot loses the race and never runs
- **Under Secure Boot only:** builds, MOK-signs and installs the `aorus_cap`
  DKMS kernel module (see [Secure Boot](#secure-boot))
- Regenerates the initramfs (`mkinitcpio -P` or `update-initramfs -u`) and GRUB configs if they were changed

**Installation creates backup files** (marked with `.aorus.*` suffix) for all files it modifies
and for all files it installs. **`uninstall.sh` uses these backups to reverse the changes**.

If `mkinitcpio` or GRUB configs change during installation, a reboot is required.

### Options

Dry run (no changes, just prints what would happen):

```bash
sudo ./install.sh --dry-run
```

## Secure Boot

The bridge cap works by writing the parent bridge's PCIe `LnkCtl2` register
(Target Link Speed + Hardware Autonomous Speed Disable). Normally `aorus-bridge`
does this from userspace with `setpci`. **With Secure Boot enabled, the kernel
runs in lockdown mode, which bans userspace writes to PCI config space** — so the
`setpci` write is silently refused and the cap never lands. The GPU then storms
off the Thunderbolt bus and the machine either freezes or comes up without the
GPU. (Signing the `setpci` binary does not help; lockdown gates the userspace
interface regardless of signature.)

The fix is `kmod/aorus-cap/` — a tiny kernel module that performs exactly that
one register write from in-kernel, where lockdown does not apply. `install.sh`
builds it via DKMS and, on Ubuntu, DKMS auto-signs it with your enrolled MOK, so
it loads under Secure Boot alongside the signed NVIDIA modules. `aorus-bridge`
detects lockdown at runtime (via `/sys/kernel/security/lockdown`) and delegates
the write to the module; with Secure Boot off it uses `setpci` exactly as before.

**Requirements when Secure Boot is on:**

* `dkms` installed.
* A MOK enrolled in firmware that DKMS signs modules with (the same setup you
  already need for the DKMS NVIDIA driver — e.g. `/var/lib/shim-signed/mok` on
  Ubuntu). If your NVIDIA modules load under Secure Boot, this will too.

By default the module is installed **only when Secure Boot is enabled** (detected
via `mokutil --sb-state`). Override with the `AORUS_CAP_MODULE` environment
variable:

```bash
sudo AORUS_CAP_MODULE=always ./install.sh   # always build/sign/install the module
sudo AORUS_CAP_MODULE=never  ./install.sh    # never touch it (default when Secure Boot is off)
```

After installing with Secure Boot on, `aorus.service` should log
`kernel lockdown active — applying cap via signed aorus_cap module`, and
`dmesg | grep aorus_cap` should show the `LnkCtl2` write.

## Uninstall

Reverses everything `install.sh` did:

```bash
./uninstall.sh
```

This does the following:

- Restores the initramfs module list (`mkinitcpio.conf` or `initramfs-tools/modules`), `grub`, and `modprobe.d` files from their `.aorus.*` backups
- Removes files installed by this repo (those without backups), including the udev rule
- Disables the `aorus.service` systemd unit
- Removes the `aorus_cap` DKMS module (`dkms remove`) if it was installed
- Restores the live bridge state and unloads NVIDIA modules (including `aorus_cap`)

**It relies on the backup files created by `install.sh`.**
If a backup is missing for a managed file, uninstall tries to remove the file entirely
(instead of restoring).

If managed configs were dirty, a reboot is required.

### Options

Dry run:

```bash
sudo ./uninstall.sh --dry-run
```

This will only show what would be done, without enacting any changes.

