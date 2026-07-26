// SPDX-License-Identifier: GPL-2.0-only
/*
 * Intel Skylake-X iMC SMBus I2C adapter.
 *
 * The integrated memory controller (iMC) on Intel Skylake-X / Cascade Lake-X
 * processors exposes an SMBus engine used to reach the SPD EEPROMs and thermal
 * sensors on DDR4 DIMMs.  The engine is driven through the PCI configuration
 * space of the Sky Lake-E PCU function (8086:2085).  This driver presents that
 * engine as two standard Linux I2C adapters - one per hardware SMBus channel -
 * so that i2c-tools and lm-sensors can use it without bespoke sysfs hacks.
 *
 * Why the config accesses go through pci_mmcfg_{read,write}_config():
 *   The SMBus registers live at offsets 0x9C-0xB8, inside the first 256 config
 *   bytes.  raw_pci_read()/raw_pci_write() dispatch that range to raw_pci_ops,
 *   which on this platform is CF8/CFC (the boot log reports "PCI: Using
 *   configuration type 1").  On the tested board a dword written that way to
 *   the command register does not take effect: the register reads back without
 *   the GO bit ever having been consumed and no SMBus transaction is issued.
 *   The same write through the ECAM window does work, and that is also how the
 *   register layout was confirmed on hardware.  The mechanism behind the
 *   dropped write has not been identified; measurements of MSR_SMI_COUNT
 *   across a failing write show no SMI, so it is not attributed to SMM here.
 *
 * Per-channel register triple within the config space of the function:
 *                  ch0     ch1
 *     CTRL (data)  0xB4    0xB8   write: data byte in bits[23:16]; read: low byte
 *     DATA (cmd)   0x9C    0xA0   command toggle | GO | address | register
 *     STATUS       0xA8    0xAC   bit0 BUSY, bit1 ERROR/NACK,
 *                                 bit2 READ_DONE, bit3 WRITE_DONE
 *   SMBus command byte (DATA bits[15:8]) = (rw << 7) | addr7: the 7-bit slave
 *   address with bit7 = direction (1 write / 0 read).  The register/offset goes
 *   in DATA[7:0].  So 0x50 reads SPD EEPROM 0x50.  This was decoded and
 *   confirmed on hardware.
 *
 * The two channels are independent SMBus buses (DIMMs 1,2 on ch0; DIMMs 3,4 on
 * ch1), hence two i2c_adapter instances exposed as separate /dev/i2c-* nodes.
 * Each channel carries the DIMM SPD EEPROMs (0x50-0x57) and thermal sensors -
 * all reachable by 7-bit address.
 *
 * Bus arbitration / concurrency with firmware:
 *   The driver cannot coordinate with SMM, a BMC, or the iMC's own closed-loop
 *   thermal throttling (CLTT), and the PCI ID alone does not prove that none of
 *   them is active.  Binding is therefore disabled by default and requires
 *   allow_unsafe_access=1, following the same choice made by the earlier iMC
 *   drivers for Sandy Bridge-EP and Broadwell-E.  On top of that, transactions
 *   are serialized across both channels, wait for the complete engine to become
 *   idle, temporarily clear TSOD_ACTIVE, restore the previous command state,
 *   and verify afterwards that no other master modified the command registers
 *   while the transfer was in flight.
 *
 *   Not implemented: the Broadwell-E driver additionally stops the PCU's TSOD
 *   polling for the duration of a transfer (write 0 to the polling interval,
 *   wait 10 ms for in-flight transactions to drain, restore afterwards).  The
 *   equivalent register has not been identified on this part, so a system with
 *   CLTT enabled is expected to trip the interference check below rather than
 *   to be arbitrated against.
 */

#include <linux/bits.h>
#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/iopoll.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/pci_ids.h>

/* expected PCI id of the Sky Lake-E PCU SMBus function */
#define PCU_DEVICE	0x2085
#define PCU_ID		((PCU_DEVICE << 16) | PCI_VENDOR_ID_INTEL)

/* function-global config registers */
#define CFG_VENDOR_DEV	0x00	/* cfg[0]: vendor/device id, for sanity check */
#define CFG_IMC_BUS	0xCC	/* cfg[0xCC] bits[15:8]: iMC SMBus bus number */

/* per-channel register offsets */
#define CH0_CTRL	0xB4
#define CH0_DATA	0x9C
#define CH0_STAT	0xA8
#define CH1_CTRL	0xB8
#define CH1_DATA	0xA0
#define CH1_STAT	0xAC

/*
 * Command word written to the DATA register:
 *   bit29       = command toggle
 *   bit20       = TSOD active state, preserved across transfers
 *   bit19       = GO
 *   bit17       = word transfer
 *   bits[15:8]  = SMBus command byte = (rw << 7) | addr7
 *                   rw bit (0x80): 1 = write, 0 = read
 *                   addr7        : 7-bit SMBus slave address
 *   bits[7:0]   = register/offset within the addressed device
 * For a write the data byte is latched into CTRL[23:16] beforehand.  This
 * encoding was confirmed on hardware: command 0x50 reads SPD EEPROM 0x50
 * (DDR4 signature).
 */
#define COMMAND_TOGGLE	BIT(29)
#define GO_BIT		BIT(19)		/* start transaction */
#define TSOD_ACTIVE_BIT	BIT(20)
#define WORD_BIT	BIT(17)		/* 16-bit word transfer (vs 8-bit byte) */
#define WRITE_OPERATION	BIT(15)
#define COMMAND_PREFIX	(COMMAND_TOGGLE | GO_BIT)
#define COMMAND_KEEP_MASK	(~TSOD_ACTIVE_BIT)
/* command bits this driver produces itself; everything else belongs to nobody
 * we know about, so a change in them during a transfer means interference.
 */
#define COMMAND_OUR_BITS	(COMMAND_TOGGLE | GO_BIT | WORD_BIT | \
				 GENMASK(15, 0))
#define STAT_BUSY	BIT(0)		/* low bit set while transaction in flight */
#define STAT_ERROR	BIT(1)
#define STAT_READ_DONE	BIT(2)
#define STAT_WRITE_DONE	BIT(3)
#define STAT_ANY_DONE	(STAT_ERROR | STAT_READ_DONE | STAT_WRITE_DONE)

/*
 * Polling bounds.  Transactions on the tested system complete in a few
 * milliseconds; these are upper bounds that avoid busy-spinning and cover
 * device clock stretching, not a measured multi-platform worst case.  The
 * mutex is held across a whole transfer, so the worst case a caller on the
 * other channel can wait for is the sum of all of them, roughly 750 ms.
 */
#define IMC_POLL_US		10
#define IMC_IDLE_TIMEOUT_US	50000
#define IMC_GO_TIMEOUT_US	200000
#define IMC_DONE_TIMEOUT_US	50000

static bool allow_unsafe_access;
module_param(allow_unsafe_access, bool, 0444);
MODULE_PARM_DESC(allow_unsafe_access,
		 "allow access without firmware/SMM arbitration (unsafe)");

struct imc_chan {
	unsigned int ctrl, data, stat;
	int idx;			/* channel index 0 or 1 */
};

static const struct imc_chan imc_chans[2] = {
	{ CH0_CTRL, CH0_DATA, CH0_STAT, 0 },
	{ CH1_CTRL, CH1_DATA, CH1_STAT, 1 },
};

/* one driver state object, shared by both per-channel adapters */
struct imc_smbus {
	struct pci_dev *pdev;		/* config space carrying the engine */
	struct device *dev;		/* &pdev->dev, for dev_*() logging */
	struct mutex lock;		/* serialises all SMBus transactions */
					/* needed: both channels share one engine */
	struct i2c_adapter adap[2];	/* one per hardware channel */
	int io_err;			/* sticky config-access error, under lock */
};

struct imc_xfer_state {
	u32 command[ARRAY_SIZE(imc_chans)];
	bool restore[ARRAY_SIZE(imc_chans)];
};

/*
 * Config accessors.  Every access goes through the ECAM path; see the comment
 * at the top of the file.  A failure is recorded in s->io_err and reported
 * once, at the end of the transfer, so the transaction logic does not have to
 * check a return value on every register touch.  A failed read yields all-ones,
 * which no polling loop mistakes for a completed transaction.
 */
static u32 imc_reg(struct imc_smbus *s, unsigned int off)
{
	u32 val;
	int ret;

	ret = pci_mmcfg_read_config(s->pdev, off, 4, &val);
	if (ret) {
		s->io_err = ret;
		return ~0U;
	}

	return val;
}

static void imc_set(struct imc_smbus *s, unsigned int off, u32 val)
{
	int ret;

	ret = pci_mmcfg_write_config(s->pdev, off, 4, val);
	if (ret)
		s->io_err = ret;
}

static u32 imc_busy_mask(struct imc_smbus *s)
{
	u32 busy = 0;
	int i;

	for (i = 0; i < ARRAY_SIZE(imc_chans); i++)
		if (imc_reg(s, imc_chans[i].stat) & STAT_BUSY)
			busy |= BIT(i);

	return busy;
}

static int imc_wait_engine_idle(struct imc_smbus *s)
{
	u32 busy;
	int ret;

	ret = read_poll_timeout(imc_busy_mask, busy, !busy || s->io_err,
				IMC_POLL_US, IMC_IDLE_TIMEOUT_US, false, s);
	if (ret)
		dev_warn_ratelimited(s->dev,
				     "engine busy on channel mask 0x%x\n", busy);

	return ret;
}

static int imc_wait_go_clear(struct imc_smbus *s, const struct imc_chan *c)
{
	u32 val;

	return read_poll_timeout(imc_reg, val, !(val & GO_BIT) || s->io_err,
				 IMC_POLL_US, IMC_GO_TIMEOUT_US, false,
				 s, c->data);
}

static int imc_wait_done(struct imc_smbus *s, const struct imc_chan *c,
			 u32 *status)
{
	u32 val;
	int ret;

	ret = read_poll_timeout(imc_reg, val,
				(!(val & STAT_BUSY) && (val & STAT_ANY_DONE)) ||
				s->io_err,
				IMC_POLL_US, IMC_DONE_TIMEOUT_US, false,
				s, c->stat);
	*status = val;

	return ret;
}

static int imc_wait_transfer(struct imc_smbus *s, const struct imc_chan *c,
			     u32 *status)
{
	u32 command;
	int ret;

	ret = imc_wait_go_clear(s, c);
	if (ret)
		*status = imc_reg(s, c->stat);
	else
		ret = imc_wait_done(s, c, status);
	if (!ret)
		return 0;
	if (!(*status & STAT_BUSY) || (*status & STAT_ANY_DONE))
		return ret;

	command = imc_reg(s, c->data);
	imc_set(s, c->data, command ^ COMMAND_TOGGLE);
	imc_reg(s, c->data);

	ret = imc_wait_done(s, c, status);
	if (ret)
		dev_warn_ratelimited(s->dev,
				     "ch%d recovery timed out (stat 0x%08x)\n",
				     c->idx, *status);

	return ret;
}

static int imc_check_status(struct imc_smbus *s, const struct imc_chan *c,
			    u32 status, u32 expected, u8 addr, u8 reg)
{
	if (status & STAT_ERROR) {
		dev_dbg(s->dev, "addr 0x%02x reg 0x%02x NACK (stat 0x%08x)\n",
			addr, reg, status);
		return -ENXIO;
	}

	/* Done bits are latched; only the bit for this operation is required. */
	if (!(status & expected)) {
		dev_warn_ratelimited(s->dev,
				     "ch%d unexpected completion for addr 0x%02x reg 0x%02x (stat 0x%08x)\n",
				     c->idx, addr, reg, status);
		return -EIO;
	}

	return 0;
}

/*
 * The done bits are latched and the driver has found no way to clear them, so
 * a transaction that is never started at all would otherwise be indistinguish-
 * able from one that completed: STATUS still shows the previous DONE and the
 * caller would receive the previous transaction's data as valid.
 *
 * Require one of two positive signs that the engine acted on the command: the
 * GO bit was observed set in the read-back that follows the command write, or
 * STATUS changed during the transfer.  Neither of them appearing means nothing
 * happened.
 */
static bool imc_engine_responded(bool go_seen, u32 status_pre, u32 status)
{
	return go_seen || status != status_pre;
}

/*
 * Detect a second master.  Compare the command registers against what this
 * driver left in them: for the channel it drove, only the bits it does not own;
 * for the other channel, all of them.  A difference means firmware, a BMC or
 * CLTT touched the engine while the transfer was in flight, so the result
 * cannot be trusted.
 */
static int imc_check_interference(struct imc_smbus *s, const struct imc_chan *c,
				  const struct imc_xfer_state *state)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(imc_chans); i++) {
		u32 mask = i == c->idx ? ~COMMAND_OUR_BITS : ~0U;
		u32 expect = state->command[i] & COMMAND_KEEP_MASK;
		u32 now = imc_reg(s, imc_chans[i].data);

		if (!((now ^ expect) & mask))
			continue;

		dev_warn_ratelimited(s->dev,
				     "ch%d command changed under us (0x%08x -> 0x%08x): another master is using the engine\n",
				     i, expect, now);
		return -EAGAIN;
	}

	return 0;
}

static void imc_restore_xfer(struct imc_smbus *s,
			     const struct imc_xfer_state *state)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(imc_chans); i++) {
		if (!state->restore[i])
			continue;
		/*
		 * Mask GO: the saved word is only meant to put the previous
		 * address, register and TSOD state back, never to re-arm a
		 * transaction that was already in flight when we found it.
		 */
		imc_set(s, imc_chans[i].data, state->command[i] & ~GO_BIT);
		imc_reg(s, imc_chans[i].data);
	}
}

static int imc_prepare_xfer(struct imc_smbus *s, const struct imc_chan *c,
			    struct imc_xfer_state *state)
{
	int i, ret;

	ret = imc_wait_engine_idle(s);
	if (ret)
		return ret;

	for (i = 0; i < ARRAY_SIZE(imc_chans); i++) {
		state->command[i] = imc_reg(s, imc_chans[i].data);
		state->restore[i] = i == c->idx ||
				    (state->command[i] & TSOD_ACTIVE_BIT);
		if (!(state->command[i] & TSOD_ACTIVE_BIT))
			continue;

		imc_set(s, imc_chans[i].data,
			state->command[i] & COMMAND_KEEP_MASK);
		imc_reg(s, imc_chans[i].data);
		ret = imc_wait_go_clear(s, &imc_chans[i]);
		if (ret) {
			imc_restore_xfer(s, state);
			return ret;
		}
	}

	return 0;
}

static int imc_access(struct imc_smbus *s, const struct imc_chan *c, u8 addr,
		      u8 reg, char read_write, int size, u16 *value)
{
	struct imc_xfer_state state = {};
	u32 command, expected, raw, status_pre, status = 0;
	bool go_seen;
	int ret;

	ret = imc_prepare_xfer(s, c, &state);
	if (ret)
		return ret;

	command = COMMAND_PREFIX | ((u32)addr << 8) | reg;
	if (size == I2C_SMBUS_WORD_DATA)
		command |= WORD_BIT;

	if (read_write == I2C_SMBUS_WRITE) {
		raw = size == I2C_SMBUS_WORD_DATA ? swab16(*value) : *value;
		imc_set(s, c->ctrl, raw << 16);
		imc_reg(s, c->ctrl);
		command |= WRITE_OPERATION;
	}

	status_pre = imc_reg(s, c->stat);
	imc_set(s, c->data, command);
	/* read back to flush the write and to see whether GO was accepted */
	go_seen = imc_reg(s, c->data) & GO_BIT;

	ret = imc_wait_transfer(s, c, &status);
	if (ret)
		goto restore_command;

	if (!imc_engine_responded(go_seen, status_pre, status)) {
		dev_warn_ratelimited(s->dev,
				     "ch%d command not accepted for addr 0x%02x reg 0x%02x (stat 0x%08x unchanged, GO never seen)\n",
				     c->idx, addr, reg, status);
		ret = -ETIMEDOUT;
		goto restore_command;
	}

	expected = read_write == I2C_SMBUS_WRITE ?
		   STAT_WRITE_DONE : STAT_READ_DONE;
	ret = imc_check_status(s, c, status, expected, addr, reg);
	if (ret)
		goto restore_command;

	ret = imc_check_interference(s, c, &state);
	if (ret)
		goto restore_command;

	if (read_write == I2C_SMBUS_READ) {
		raw = imc_reg(s, c->ctrl);
		*value = size == I2C_SMBUS_WORD_DATA ?
			 swab16(raw & 0xffff) : raw & 0xff;
	}

restore_command:
	imc_restore_xfer(s, &state);

	return ret;
}

/*
 * Standard SMBus transfer callback.  The per-channel imc_chan is stashed in the
 * adapter's algo_data.  The command word carries the 7-bit address, so
 * SPD EEPROMs (0x50-0x57) are reachable on each channel.  BYTE_DATA and
 * WORD_DATA are supported; larger transfers would need the engine's block
 * primitives, which are not used by the devices on this bus.
 */
static s32 imc_smbus_xfer(struct i2c_adapter *adap, u16 addr,
			  unsigned short flags, char read_write, u8 command,
			  int size, union i2c_smbus_data *data)
{
	struct imc_smbus *s = i2c_get_adapdata(adap);
	const struct imc_chan *c = adap->algo_data;
	u16 val = 0;
	u8 reg;
	int ret;

	if (flags & I2C_M_TEN)
		return -EAFNOSUPPORT;
	if (addr > 0x7f)
		return -EINVAL;

	if (size != I2C_SMBUS_BYTE_DATA && size != I2C_SMBUS_WORD_DATA)
		return -EOPNOTSUPP;
	if (read_write != I2C_SMBUS_READ && read_write != I2C_SMBUS_WRITE)
		return -EINVAL;

	reg = command;

	mutex_lock(&s->lock);
	s->io_err = 0;

	if (read_write == I2C_SMBUS_WRITE) {
		if (size == I2C_SMBUS_WORD_DATA) {
			dev_dbg(s->dev, "ch%d W addr=%02x reg=%02x val=%04x\n",
				c->idx, addr, reg, data->word);
			val = data->word;
		} else {
			val = data->byte;
			dev_dbg(s->dev, "ch%d W addr=%02x reg=%02x val=%02x\n",
				c->idx, addr, reg, val);
		}
		ret = imc_access(s, c, addr, reg, read_write, size, &val);
	} else {
		ret = imc_access(s, c, addr, reg, read_write, size, &val);
		if (size == I2C_SMBUS_WORD_DATA) {
			if (!ret)
				data->word = val;
			dev_dbg(s->dev, "ch%d R addr=%02x reg=%02x -> %04x (ret %d)\n",
				c->idx, addr, reg, val, ret);
		} else {
			if (!ret)
				data->byte = val;
			dev_dbg(s->dev, "ch%d R addr=%02x reg=%02x -> %02x (ret %d)\n",
				c->idx, addr, reg, val, ret);
		}
	}

	/*
	 * A config-space failure invalidates whatever the transaction logic
	 * concluded, so it wins over any other result.
	 */
	if (s->io_err) {
		dev_warn_ratelimited(s->dev, "config access failed: %d\n",
				     s->io_err);
		ret = s->io_err;
	}
	mutex_unlock(&s->lock);

	return ret;
}

static u32 imc_func(struct i2c_adapter *adap)
{
	return I2C_FUNC_SMBUS_BYTE_DATA | I2C_FUNC_SMBUS_WORD_DATA;
}

static const struct i2c_algorithm imc_algo = {
	.smbus_xfer	= imc_smbus_xfer,
	.functionality	= imc_func,
};

static int imc_suspend(struct device *dev)
{
	struct imc_smbus *s = dev_get_drvdata(dev);
	int i;

	for (i = 0; i < ARRAY_SIZE(s->adap); i++)
		i2c_mark_adapter_suspended(&s->adap[i]);

	return 0;
}

static int imc_resume(struct device *dev)
{
	struct imc_smbus *s = dev_get_drvdata(dev);
	int i;

	for (i = 0; i < ARRAY_SIZE(s->adap); i++)
		i2c_mark_adapter_resumed(&s->adap[i]);

	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(imc_pm_ops, imc_suspend, imc_resume);

static int imc_pci_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct imc_smbus *s;
	u8 imc_bus_hw;
	u32 cfg0, cc;
	int ret, i;

	if (!allow_unsafe_access) {
		dev_info(&pdev->dev,
			 "firmware/SMM arbitration is unknown; set allow_unsafe_access=1 to bind\n");
		return -ENODEV;
	}

	s = devm_kzalloc(&pdev->dev, sizeof(*s), GFP_KERNEL);
	if (!s)
		return -ENOMEM;

	/*
	 * No pci_enable_device(): the driver uses no BAR, no interrupt and no
	 * DMA.  The engine is reached entirely through config space, which does
	 * not require the function's memory or I/O decoding to be enabled.
	 */
	s->pdev = pdev;
	s->dev = &pdev->dev;
	pci_set_drvdata(pdev, s);
	ret = devm_mutex_init(&pdev->dev, &s->lock);
	if (ret)
		return ret;

	ret = pci_mmcfg_read_config(pdev, CFG_VENDOR_DEV, 4, &cfg0);
	if (ret) {
		dev_err(&pdev->dev,
			"no memory-mapped path to config space: %d\n", ret);
		return ret;
	}
	if (cfg0 != PCU_ID) {
		dev_err(&pdev->dev, "wrong device through ECAM (cfg[0]=0x%08x)\n",
			cfg0);
		return -ENODEV;
	}

	/*
	 * Cross-check the iMC bus number against the configuration register
	 * value: cfg[0xCC] bits[15:8] = the iMC SMBus bus number as seen by
	 * the PCU.  On all known Skylake-X / Cascade Lake-X boards this matches
	 * the probed bus number.
	 * A mismatch means the accessor landed on the wrong function - warn but
	 * continue; the binding is already locked to 8086:2085.
	 */
	ret = pci_mmcfg_read_config(pdev, CFG_IMC_BUS, 4, &cc);
	if (ret)
		return ret;
	imc_bus_hw = (cc >> 8) & 0xFF;

	if (imc_bus_hw && imc_bus_hw != (u8)pdev->bus->number)
		dev_warn(&pdev->dev,
			 "cfg[0xCC] reports iMC bus 0x%02x but probed bus=0x%02x\n",
			 imc_bus_hw, (u8)pdev->bus->number);
	else
		dev_dbg(&pdev->dev,
			"cfg[0xCC]=0x%08x iMC bus 0x%02x confirmed\n",
			cc, imc_bus_hw);

	/*
	 * Lifetime safety: the I2C core guarantees that smbus_xfer callbacks
	 * are not invoked after i2c_del_adapter() returns. Since we use
	 * devm_i2c_add_adapter(), the adapter is automatically removed on
	 * driver detach, and no concurrent xfer can be in flight at that point.
	 */
	for (i = 0; i < ARRAY_SIZE(s->adap); i++) {
		struct i2c_adapter *a = &s->adap[i];

		a->owner     = THIS_MODULE;
		a->algo      = &imc_algo;
		a->algo_data = (void *)&imc_chans[i];
		a->dev.parent = &pdev->dev;
		/*
		 * One retry: interference from another master is reported as
		 * -EAGAIN and is usually over by the next attempt.
		 */
		a->retries = 1;
		i2c_set_adapdata(a, s);
		snprintf(a->name, sizeof(a->name),
			 "iMC SMBus Skylake-X channel %d", i);

		ret = devm_i2c_add_adapter(&pdev->dev, a);
		if (ret) {
			dev_err(&pdev->dev,
				"i2c_add_adapter ch%d failed: %d\n", i, ret);
			return ret;
		}
	}

	dev_dbg(&pdev->dev, "registered 2 SMBus channels\n");
	return 0;
}

static const struct pci_device_id imc_pci_ids[] = {
	{ PCI_DEVICE(PCI_VENDOR_ID_INTEL, PCU_DEVICE) },
	{ }
};
MODULE_DEVICE_TABLE(pci, imc_pci_ids);

/*
 * All resources (mutex, i2c adapters) are devm-managed and are released
 * automatically after probe returns or during device unbinding, so no .remove
 * callback is needed.  The register state is deliberately left as-is on
 * unbind: the engine carries no driver-private latched state that needs
 * teardown, and the SMBus controls we drive are side-band registers the rest
 * of the kernel does not touch.
 */
static struct pci_driver imc_driver = {
	.name     = "i2c-imc-skylake",
	.id_table = imc_pci_ids,
	.probe    = imc_pci_probe,
	.driver.pm = pm_sleep_ptr(&imc_pm_ops),
};
module_pci_driver(imc_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Simone Chifari");
MODULE_DESCRIPTION("Intel Skylake-X iMC SMBus I2C adapter");
