/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Out-of-tree compatibility shim - NOT part of the upstream submission.
 *
 * i2c-imc-skylake.c reaches the PCU function's config space with
 * pci_mmcfg_read_config() / pci_mmcfg_write_config(), which are added by
 * patch 1/2 of the series ("PCI: provide config access forced through the
 * ECAM path").  A stock kernel does not have them yet.
 *
 * The Makefile force-includes this header when the target kernel lacks those
 * symbols, so the driver source stays byte-identical to the submitted patch
 * while remaining testable on an unpatched kernel.  It reimplements the two
 * accessors the way earlier revisions of the driver did it: locate the ECAM
 * base in the ACPI MCFG table and map the function's config page.
 *
 * Limitations, acceptable for a test shim and for nothing else:
 *   - a single device at a time (there is one PCU function per system);
 *   - dword accesses only, which is all the driver issues;
 *   - no participation in the PCI core's config-space locking.  That is
 *     precisely the problem patch 1/2 exists to solve.
 */

#ifndef IMC_PCI_MMCFG_COMPAT_H
#define IMC_PCI_MMCFG_COMPAT_H

#include <linux/acpi.h>
#include <linux/device.h>
#include <linux/io.h>
#include <linux/pci.h>

#define IMC_COMPAT_CFG_SIZE	0x1000UL

static void __iomem *imc_compat_cfg;
static resource_size_t imc_compat_phys;

static u64 imc_compat_mmcfg_base(struct pci_dev *pdev)
{
	unsigned int seg = pci_domain_nr(pdev->bus);
	unsigned int bus = pdev->bus->number;
	struct acpi_table_header *hdr;
	struct acpi_table_mcfg *mcfg;
	struct acpi_mcfg_allocation *e;
	unsigned long n, i;
	u64 base = 0;

	if (ACPI_FAILURE(acpi_get_table(ACPI_SIG_MCFG, 0, &hdr)))
		return 0;

	mcfg = (struct acpi_table_mcfg *)hdr;
	if (hdr->length < sizeof(*mcfg)) {
		acpi_put_table(hdr);
		return 0;
	}
	e = (struct acpi_mcfg_allocation *)(mcfg + 1);
	n = (hdr->length - sizeof(*mcfg)) / sizeof(*e);
	for (i = 0; i < n; i++) {
		if (e[i].pci_segment == seg &&
		    bus >= e[i].start_bus_number &&
		    bus <= e[i].end_bus_number) {
			base = e[i].address;
			break;
		}
	}
	acpi_put_table(hdr);

	return base;
}

static void imc_compat_unmap(void *data)
{
	iounmap(imc_compat_cfg);
	imc_compat_cfg = NULL;
	imc_compat_phys = 0;
}

static void __iomem *imc_compat_map(struct pci_dev *pdev)
{
	resource_size_t phys;
	u64 base;

	base = imc_compat_mmcfg_base(pdev);
	if (!base)
		return NULL;

	phys = base +
	       ((resource_size_t)pdev->bus->number << 20) +
	       ((resource_size_t)PCI_SLOT(pdev->devfn) << 15) +
	       ((resource_size_t)PCI_FUNC(pdev->devfn) << 12);

	if (phys < base || phys + IMC_COMPAT_CFG_SIZE < phys)
		return NULL;

	if (imc_compat_cfg && imc_compat_phys == phys)
		return imc_compat_cfg;
	if (imc_compat_cfg)
		return NULL;	/* a second device would need a real cache */

	imc_compat_cfg = ioremap_uc(phys, IMC_COMPAT_CFG_SIZE);
	if (!imc_compat_cfg)
		return NULL;
	imc_compat_phys = phys;

	if (devm_add_action_or_reset(&pdev->dev, imc_compat_unmap, NULL))
		return NULL;

	return imc_compat_cfg;
}

static inline int pci_mmcfg_read_config(struct pci_dev *dev, int where,
					int size, u32 *val)
{
	void __iomem *cfg;

	if (size != 4 || (where & 3) || where + size > 0x1000) {
		*val = ~0U;
		return -EINVAL;
	}

	cfg = imc_compat_map(dev);
	if (!cfg) {
		*val = ~0U;
		return -ENXIO;
	}

	*val = readl(cfg + where);

	return 0;
}

static inline int pci_mmcfg_write_config(struct pci_dev *dev, int where,
					 int size, u32 val)
{
	void __iomem *cfg;

	if (size != 4 || (where & 3) || where + size > 0x1000)
		return -EINVAL;

	cfg = imc_compat_map(dev);
	if (!cfg)
		return -ENXIO;

	writel(val, cfg + where);

	return 0;
}

#endif /* IMC_PCI_MMCFG_COMPAT_H */
