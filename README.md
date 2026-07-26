# Intel Skylake-X iMC SMBus I2C Driver

[![License: GPL v2](https://img.shields.io/badge/License-GPL%20v2-blue.svg)](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)
[![CI](https://github.com/systempal/i2c-imc-skylake/actions/workflows/ci.yml/badge.svg)](https://github.com/systempal/i2c-imc-skylake/actions/workflows/ci.yml)
[![Upstream Status](https://img.shields.io/badge/Upstream-v2%20archived-orange.svg)](https://lore.kernel.org/linux-i2c/20260620144131.415559-1-simone.chifari@gmail.com/T/#t)

An experimental Linux PCI driver for the SMBus engine in the integrated memory
controller (iMC) of Intel Skylake-X and Cascade Lake-X processors
(PCU function `8086:2085`).

The engine reaches the DDR4 DIMMs: SPD EEPROMs at `0x50`-`0x57`, thermal
sensors (TSOD) at `0x18`-`0x1f`, and whatever else a given module carries on
those lines. The driver registers it as two standard Linux I2C adapters, one
per hardware channel, so `i2c-tools`, `decode-dimms` and `lm-sensors` work
without custom raw PCI writes.

> [!WARNING]
> The engine has no arbitration mechanism. SMM, a BMC and the memory
> controller's own closed-loop thermal throttling (CLTT) can drive the same
> registers, and the PCI ID does not tell the driver whether any of them is
> active. The driver is disabled by default and binds only with
> `allow_unsafe_access=1`. Use it only where concurrent firmware access has
> been excluded — and check the log for the interference warning described
> below.

---

## Upstream status

Patch series v2 is archived on
[lore.kernel.org](https://lore.kernel.org/linux-i2c/20260620144131.415559-1-simone.chifari@gmail.com/T/#t)
and received no replies.

The next posting is an RFC in **two patches**:

1. a PCI/x86 change adding `pci_mmcfg_read_config()` / `pci_mmcfg_write_config()`,
   which force config access through the memory-mapped (ECAM) path;
2. this driver, which uses them.

The split exists because those are two decisions belonging to two different
sets of maintainers. See [docs/submission/cover-letter.txt](docs/submission/cover-letter.txt).

**No iMC I2C driver has ever been merged into mainline.** Andy Lutomirski's
`i2c_imc` (2013-2016) and Stefan Schaeckeler's 2020 Broadwell rewrite both
stalled on the same firmware-arbitration problem. This driver does not solve it
either; it detects it. See the cover letter for what that means in practice.

---

## Why the ECAM path

The engine's registers are at config offsets `0x9C`-`0xB8`, inside the first
256 bytes. On x86 that range is dispatched to `raw_pci_ops`, which is CF8/CFC
whenever configuration type 1 is usable; the memory-mapped path is only used
from `0x100` upwards. On the tested X299 board a dword written through CF8/CFC
to the command register does not take effect: the register reads back
unchanged, the GO bit is never consumed, no transaction is issued. The same
write through ECAM works.

What drops the write is **not known**. Earlier revisions of this project
attributed it to System Management Mode; the only evidence was a boot log line
naming the access method, which says nothing about who filters the write, so
that claim has been removed. [tools/probe-cf8-write.sh](tools/probe-cf8-write.sh)
is there to settle it with an `MSR_SMI_COUNT` measurement.

---

## What the driver does about concurrency

* serializes both channels under one mutex and waits for the whole engine to be
  idle before touching any register;
* saves the command state of both channels, clears TSOD_ACTIVE for the duration
  of the transfer, restores both afterwards;
* **compares the command registers after every transfer** against what it left
  in them, and fails with `-EAGAIN` if anything else changed;
* requires a positive sign that the engine accepted the command, because the
  done bits are latched and would otherwise let a never-executed command look
  like a completed one.

If your log shows

```text
i2c-imc-skylake 0000:16:1e.5: ch0 command changed under us (...): another master is using the engine
```

then firmware is using the engine on your system. Unload the driver.

Not implemented: the Broadwell-E iMC driver additionally stops the PCU's TSOD
polling for the duration of a transfer. The equivalent register has not been
identified on this part — see [tools/README.md](tools/README.md).

---

## Origin & use case

This driver started from the need to reach the **ENE KB9012** LED controller on
Kingston FURY DDR4 RGB modules under Linux on X299, which is on the same iMC
SMBus lines. It is device-oriented rather than tied to a DIMM brand; the
practical uses are:

* reading DDR4 SPD data and DIMM thermal sensors with standard tools;
* OpenRGB and other userspace daemons for modules whose controllers sit on
  these buses.

---

## Installation

### Prerequisites

```bash
# Debian / Ubuntu
sudo apt-get install build-essential i2c-tools strace linux-headers-$(uname -r)

# Fedora / RHEL
sudo dnf install gcc i2c-tools make strace kernel-devel
```

### Build & load

```bash
make                          # build
make checkpatch               # style
make reload ALLOW_UNSAFE=1    # load for testing, after checking arbitration
sudo make install             # install into the kernel tree
```

The driver calls `pci_mmcfg_read_config()`, which is added by patch 1 of the
upstream series and is not in any released kernel yet. When the target kernel
lacks it, the build force-includes
[compat/pci-mmcfg-compat.h](compat/pci-mmcfg-compat.h), which reimplements the
two accessors out-of-tree so the driver source stays byte-identical to the
submitted patch. The build prints a warning when the shim is in use. The shim
is **not** part of the upstream submission.

To permit a later `modprobe` or PCI modalias load:

```bash
echo 'options i2c-imc-skylake allow_unsafe_access=1' | \
  sudo tee /etc/modprobe.d/i2c-imc-skylake.conf
```

This opt-in is intentionally not installed by the project.

---

## DKMS

```bash
sudo apt-get install dkms
sudo dkms add .
sudo dkms install -m i2c-imc-skylake -v 1.0.0
```

---

## Verification

```bash
i2cdetect -l | grep iMC
```

```text
i2c-6   smbus           iMC SMBus Skylake-X channel 0                SMBus adapter
i2c-7   smbus           iMC SMBus Skylake-X channel 1                SMBus adapter
```

The driver advertises SMBus BYTE_DATA and WORD_DATA only, so `i2cdetect` cannot
scan the bus. Read a device directly — SPD byte 2 (DDR4 type code `0x0c`) from
EEPROM `0x50` on channel 0:

```bash
sudo i2cget -y 6 0x50 0x02
```

The adapter does not instantiate `ee1004` or `jc42` clients. Check first that
the address is not already bound, then:

```bash
echo ee1004 0x50 | sudo tee /sys/bus/i2c/devices/i2c-6/new_device
echo jc42 0x18 | sudo tee /sys/bus/i2c/devices/i2c-6/new_device
```

Read-only integration test against the module just built:

```bash
make
sudo make test
```

Hardware measurements still owed to the upstream submission are in
[tools/README.md](tools/README.md).

---

## License

GPL v2 only (`GPL-2.0-only`).
