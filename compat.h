/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Out-of-tree build shim. NOT part of the upstream submission: the Makefile
 * force includes it, i2c-imc-skylake.c never does, so the driver source stays
 * free of build conditionals.
 *
 * i2c_register_spd() was split into i2c_register_spd_write_disable() and
 * i2c_register_spd_write_enable() when DDR5 arrived and the caller had to say
 * whether spd5118 should be instantiated at all. The driver targets current
 * mainline and calls the split form; where only the old single function
 * exists it has exactly the semantics this driver wants, since the split is
 * about DDR5 and this part is DDR4 only.
 *
 * HAVE_I2C_REGISTER_SPD_SPLIT comes from the Makefile, which greps the target
 * kernel's header for the symbol. Detecting the API beats guessing the version
 * it appeared in, and it stays right on backported and vendor trees.
 */

#ifndef I2C_IMC_SKYLAKE_COMPAT_H
#define I2C_IMC_SKYLAKE_COMPAT_H

#include <linux/i2c-smbus.h>

#ifndef HAVE_I2C_REGISTER_SPD_SPLIT
static inline void i2c_register_spd_write_disable(struct i2c_adapter *adap)
{
	i2c_register_spd(adap);
}

static inline void i2c_register_spd_write_enable(struct i2c_adapter *adap)
{
	i2c_register_spd(adap);
}
#endif

#endif /* I2C_IMC_SKYLAKE_COMPAT_H */
