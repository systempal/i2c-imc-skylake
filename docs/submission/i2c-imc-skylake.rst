.. SPDX-License-Identifier: GPL-2.0

=============================
Kernel driver i2c-imc-skylake
=============================

Supported adapters:
  * Intel Skylake-X / Cascade Lake-X integrated memory controller (iMC)
    SMBus engine, PCU function 8086:2085 (socket LGA 2066, platform X299)

Author: Simone Chifari <simone.chifari@gmail.com>


Description
-----------

The integrated memory controller of Intel Skylake-X and Cascade Lake-X
processors contains an SMBus engine wired to the DDR4 DIMMs.  It reaches the
SPD EEPROMs (0x50-0x57) and the thermal sensors (TSOD, 0x18-0x1f) of the
installed modules, plus whatever else a particular module carries on those
lines.

The engine has two independent channels.  DIMM slots 1 and 2 are on channel 0,
slots 3 and 4 on channel 1, so the driver registers two i2c adapters::

    $ i2cdetect -l | grep iMC
    i2c-6   smbus   iMC SMBus Skylake-X channel 0   SMBus adapter
    i2c-7   smbus   iMC SMBus Skylake-X channel 1   SMBus adapter

Both channels share one hardware engine, so the driver serializes every
transaction across both adapters.


This driver is not enabled by default
-------------------------------------

The SMBus engine has no arbitration mechanism.  System Management Mode, a BMC,
and the memory controller's own closed-loop thermal throttling (CLTT) can all
drive the same registers, and nothing in the PCI ID tells the driver whether
any of them is doing so on a given system.  Two masters using the engine at the
same time can send a transaction to the wrong address or return the wrong data.

The driver therefore refuses to bind unless the operator opts in::

    modprobe i2c-imc-skylake allow_unsafe_access=1

Do this only on a system where concurrent firmware access has been excluded.
Desktop and HEDT boards have no BMC, but CLTT may still be enabled by the
firmware.

The driver reduces, but cannot remove, the risk:

  * every transaction waits for both channels to report idle before it
    touches any register;
  * the previous command state of both channels is saved, the TSOD-active
    state is cleared for the duration of the transfer, and both are restored
    afterwards;
  * after each transfer the command registers are compared against what the
    driver left in them.  A difference means another master used the engine,
    and the transfer is failed with ``-EAGAIN`` rather than reported as
    successful.

The last check is what makes an unarbitrated system detectable: if the log
shows

  ``chN command changed under us (...): another master is using the engine``

then firmware is using the engine and the driver should not be loaded on that
system.


Config space access
-------------------

The engine's registers live at config space offsets 0x9C-0xB8 of the PCU
function.  On x86 the first 256 bytes of config space are reached with the
access method the platform selected at boot, which is normally CF8/CFC.  On the
tested board a write issued that way to the command register has no effect: the
GO bit is never consumed and no SMBus transaction is issued.  The same write
through the memory-mapped (ECAM) path works.

The driver therefore uses ``pci_mmcfg_read_config()`` and
``pci_mmcfg_write_config()``, which force the ECAM path for this device.  It
requires ``CONFIG_PCI_MMCONFIG``; on a system booted with ``pci=nommconf`` the
driver will fail to probe.

The mechanism that drops the CF8/CFC write has not been identified.
``MSR_SMI_COUNT`` does not increase across a failing write, so it is not
attributed to System Management Mode here.


Supported transactions
----------------------

The driver implements SMBus Read/Write Byte Data and Read/Write Word Data.
That covers ee1004 (DDR4 SPD) and jc42 (TSOD).

SMBus Quick and Receive Byte are not implemented, so ``i2cdetect`` cannot scan
these buses.  Address a device directly instead, for example SPD byte 2 of the
EEPROM at 0x50::

    $ i2cget -y 6 0x50 0x02
    0x0c

Block transfers are not implemented.  The engine has block primitives, but no
device on this bus needs them.

Word transfers use the standard SMBus byte order, so ``jc42`` reading through
``i2c_smbus_read_word_swapped()`` gets the value it expects.


Instantiating clients
---------------------

The adapter does not create ``ee1004`` or ``jc42`` clients by itself.  There is
no firmware description of these buses and the driver does not scan.  Create
them explicitly if you want them::

    # echo ee1004 0x50 > /sys/bus/i2c/devices/i2c-6/new_device
    # echo jc42 0x18   > /sys/bus/i2c/devices/i2c-6/new_device

Check first that the address is not already bound to a driver.


Module parameters
-----------------

allow_unsafe_access
  Bool, read-only after load, defaults to false.  The driver does not bind
  unless this is set.  See the section above.
