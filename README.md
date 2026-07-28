# Intel Skylake-X iMC SMBus I2C Driver

[![License: GPL v2](https://img.shields.io/badge/License-GPL%20v2-blue.svg)](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)
[![CI](https://github.com/systempal/i2c-imc-skylake/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/systempal/i2c-imc-skylake/actions/workflows/ci.yml?query=branch%3Amain)
[![Upstream Status](https://img.shields.io/badge/Upstream-v3%20ready%20to%20post-yellow.svg)](https://lore.kernel.org/linux-i2c/20260620144131.415559-1-simone.chifari@gmail.com/T/#t)

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

The next posting is `[PATCH v3]`, a single patch. See
[docs/submission/cover-letter.txt](docs/submission/cover-letter.txt).

**No iMC I2C driver has ever been merged into mainline.** Andy Lutomirski's
`i2c_imc` (2013-2016) and Stefan Schaeckeler's 2020 Broadwell rewrite both
stalled on the same firmware-arbitration problem. This driver does not solve it
either; it detects it. See the cover letter for what that means in practice.

---

## Retracted: the CF8/CFC claim

The v2 posting claimed that firmware filters CF8/CFC config writes to
the PCU function, and that the registers were reachable only through the
memory-mapped window. **That was wrong.** It was never tested directly; the
only evidence was a boot log line naming the access method.

Measured on this board, driver unloaded:

```console
# setpci -s 16:1e.5 9c.L=20085002    # read SPD 0x50, register 0x02
# setpci -s 16:1e.5 9c.L
20005002                             # GO consumed
# setpci -s 16:1e.5 a8.L
0000500c                             # READ_DONE, no error
# setpci -s 16:1e.5 b4.L
0000000c                             # SPD byte 2: DDR4 type code
```

The command executes and returns correct data through the ordinary accessors,
and `MSR_SMI_COUNT` does not move across it. The driver now uses
`pci_read_config_dword()` and `pci_write_config_dword()` like any other driver.
Reproduce with [tools/probe-cf8-transaction.sh](tools/probe-cf8-transaction.sh).

---

## What the driver does about concurrency

* serializes both channels under one mutex and waits for the whole engine to be
  idle before touching any register;
* saves the command state of both channels, clears TSOD_ACTIVE for the duration
  of the transfer, restores both afterwards;
* **compares the command registers after every transfer** against what it left
  in them, and fails with `-EAGAIN` if anything else changed;
* reads the command word back and requires it to be the one just written,
  because the done bits are latched and a stale DONE would otherwise let a
  command that never reached the register look like a completed transfer.

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
sudo dkms install -m i2c-imc-skylake -v "$(cat VERSION)"
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

The driver implements SMBus Receive Byte, Send Byte, BYTE_DATA and WORD_DATA.
SMBus Quick is deliberately not implemented (a write probe into `0x30`-`0x37`
is how an EE1004 SPD is write-protected), so scan in read mode:

```bash
sudo i2cdetect -y -r 6
```

SPD EEPROMs are instantiated automatically at probe (`ee1004`, counted from
DMI), so `decode-dimms` works with no manual step. `ee1004` owns those
addresses once bound: read the SPD through the driver, not with raw `i2cget`:

```bash
sudo cat /sys/bus/i2c/devices/6-0050/eeprom | hexdump -C | head
```

`jc42` is not instantiated (no firmware description of these buses); add it by
hand where a thermal sensor is populated:

```bash
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
