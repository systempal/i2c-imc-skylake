# Intel Skylake-X iMC SMBus I2C Driver

[![License: GPL v2](https://img.shields.io/badge/License-GPL%20v2-blue.svg)](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)
[![Kernel Compatibility](https://img.shields.io/badge/Kernel-6.x%20%7C%207.x-green.svg)](#)
[![Code Style: checkpatch](https://img.shields.io/badge/checkpatch-clean-brightgreen.svg)](#)
[![Upstream Status](https://img.shields.io/badge/Upstream-Submitted%20(v2)-orange.svg)](https://lore.kernel.org/linux-i2c/)

A modern Linux PCI bus driver for the integrated Memory Controller (iMC) SMBus controller found in Intel Skylake-X and Cascade Lake-X (HEDT X299, function ID `8086:2085`) processors. 

This driver maps the iMC SMBus engine and registers it as two standard Linux I2C adapters (one per physical channel), allowing native userspace tools like `i2c-tools` and `lm-sensors` to interact with target devices (such as DDR4 DIMM SPD EEPROMs and thermal sensors) without custom raw PCI port-IO writes.

---

## Origin & Use Case

This driver was born out of the need to control the RGB lighting effects on **Kingston FURY DDR4 RGB** memory modules under Linux on the Intel X299 (HEDT) platform.

These memory modules carry an onboard **ENE KB9012** LED controller accessible via the SMBus channels of the CPU's integrated memory controller (iMC). However, standard Linux tools and OpenRGB could not communicate with them because:
1. The X299 System Management Mode (SMM) firmware traps standard port-based PCI configuration writes, breaking standard driver access.
2. The iMC SMBus channels were not exposed as standard Linux I2C buses.

By resolving the MMCONFIG base and using ECAM MMIO, this driver bypasses SMM and registers the physical memory channels as standard `/dev/i2c-*` adapters. 

While the kernel driver itself is kept 100% generic and brand-agnostic (to comply with Linux upstream requirements), its primary practical use cases are:
* Driving userspace Linux daemons for hardware/software-rendered RGB lighting animations without screen or GUI lag.
* Enabling compatibility with OpenRGB for memory modules on Skylake-X / Cascade Lake-X systems.
* Reading standard DDR4 SPD data and DIMM thermal sensor metrics using standard utilities like `decode-dimms`.

---

## Upstream Status

This driver is currently submitted for review to the Linux kernel `linux-i2c` subsystem mailing list for mainlining (patch series v2). See the [lore.kernel.org linux-i2c archive](https://lore.kernel.org/linux-i2c/) for the discussion thread.

---

## Technical Features & SMM Bypass

* **ECAM MMIO Access**: On the X299 platform, System Management Mode (SMM) firmware traps and drops legacy port-based (`CF8/CFC`) configuration space writes to the PCU function. This driver bypasses the trap by resolving the MMCONFIG base from the ACPI `MCFG` table and accessing the registers directly via ECAM MMIO memory-mapped pages.
* **Dual Channel Support**: Registers two independent I2C buses (`iMC SMBus Skylake-X channel 0` and `channel 1`), mapping physically to DIMM slots 1-2 and 3-4 respectively.
* **Clean Lifecycle**: Fully compliant with the `devm` kernel framework. All mapped registers, adapters, and mutexes are cleaned up automatically upon driver unbinding.
* **Zero Out-of-Tree Brandings**: Code is completely generic and compliant with standard Linux kernel styling guidelines.

---

## Installation

### Prerequisites

Ensure you have kernel headers and compiler utilities installed:

```bash
# Debian / Ubuntu
sudo apt-get install build-essential linux-headers-$(uname -r)

# Fedora / RHEL
sudo dnf install gcc make kernel-devel
```

### Manual Build & Load

1. **Compile the driver**:
   ```bash
   make
   ```
2. **Test style compliance**:
   ```bash
   make checkpatch
   ```
3. **Load immediately (testing)**:
   ```bash
   make reload
   ```
4. **Install permanently into the kernel tree**:
   ```bash
   sudo make install
   ```

---

## DKMS Support (Dynamic Kernel Module Support)

To build and load the driver automatically on every kernel upgrade:

1. **Install DKMS**:
   ```bash
   sudo apt-get install dkms
   ```
2. **Register the module**:
   ```bash
   sudo dkms add .
   ```
3. **Build and install**:
   ```bash
   sudo dkms install -m i2c-imc-skylake -v 1.0
   ```

---

## Verification & Testing

Once loaded, verify that the two channels are registered successfully:

```bash
i2cdetect -l | grep iMC
```

Expected output:
```text
i2c-6   smbus           iMC SMBus Skylake-X channel 0                SMBus adapter
i2c-7   smbus           iMC SMBus Skylake-X channel 1                SMBus adapter
```

You can scan for SPD EEPROMs (usually located at addresses `0x50-0x57`) on channel 0:
```bash
sudo i2cdetect -y 6
```

---

## License

This driver is licensed under the **GPL v2 only** (`GPL-2.0-only`).
