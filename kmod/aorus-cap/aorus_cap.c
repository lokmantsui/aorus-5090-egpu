// SPDX-License-Identifier: GPL-2.0
/*
 * aorus_cap - apply the AORUS eGPU bridge link cap from signed kernel code.
 *
 * Under Secure Boot the kernel runs in lockdown "integrity" mode, which bans
 * userspace writes to PCI config space (LOCKDOWN_PCI_ACCESS). That kills the
 * setpci-based `aorus-bridge apply` path: it can still *read* the bridge's
 * LnkCtl2 but can no longer *write* it, so the Gen3 + Hardware-Autonomous-
 * Speed-Disable cap never lands and the eGPU dies in the GSP link-speed storm.
 *
 * This module performs exactly that one write (LnkCtl2: set bit 5 + Target
 * Link Speed, then retrain) from in-kernel, where lockdown does not apply. It
 * is DKMS-built and MOK-signed, so it loads under Secure Boot alongside the
 * signed nvidia modules. All detection / TB-tunnel gating / idempotency still
 * lives in the aorus-bridge userspace helper; this module is only the write.
 *
 *   modprobe aorus_cap bridge=0000:2a:01.0 target=3 bit5=1 retrain=1
 *
 * Params mirror aorus-bridge semantics:
 *   bridge  - PCI BDF of the parent bridge above the eGPU (required)
 *   target  - Target Link Speed generation 1..4 (0 = leave unchanged); the
 *             gen number equals the LNKCTL2_TLS field value (Gen3 == 0x3)
 *   bit5    - set LnkCtl2 Hardware Autonomous Speed Disable (default true)
 *   retrain - trigger a link retrain after changing LnkCtl2 (default true)
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/pci.h>

static char *bridge;
module_param(bridge, charp, 0444);
MODULE_PARM_DESC(bridge, "PCI BDF of the bridge above the eGPU, e.g. 0000:2a:01.0");

static int target = 3;
module_param(target, int, 0444);
MODULE_PARM_DESC(target, "Target Link Speed generation 1-4 (0 = leave unchanged)");

static bool bit5 = true;
module_param(bit5, bool, 0444);
MODULE_PARM_DESC(bit5, "LnkCtl2 Hardware Autonomous Speed Disable (bit 5): 1=set (apply), 0=clear (restore)");

static bool retrain = true;
module_param(retrain, bool, 0444);
MODULE_PARM_DESC(retrain, "Trigger a link retrain after changing LnkCtl2");

static int aorus_parse_bdf(const char *s, unsigned int *dom, unsigned int *bus,
			   unsigned int *slot, unsigned int *func)
{
	if (sscanf(s, "%x:%x:%x.%x", dom, bus, slot, func) == 4)
		return 0;
	*dom = 0;
	if (sscanf(s, "%x:%x.%x", bus, slot, func) == 3)
		return 0;
	return -EINVAL;
}

static int __init aorus_cap_init(void)
{
	unsigned int dom, bus, slot, func;
	struct pci_dev *dev;
	u16 lnkctl2, new2, lnkctl;
	int ret;

	if (!bridge) {
		pr_err("aorus_cap: 'bridge' parameter is required\n");
		return -EINVAL;
	}
	if (aorus_parse_bdf(bridge, &dom, &bus, &slot, &func)) {
		pr_err("aorus_cap: cannot parse bridge BDF '%s'\n", bridge);
		return -EINVAL;
	}
	if (target < 0 || target > 4) {
		pr_err("aorus_cap: target=%d out of range (0-4)\n", target);
		return -EINVAL;
	}

	dev = pci_get_domain_bus_and_slot(dom, bus, PCI_DEVFN(slot, func));
	if (!dev) {
		pr_err("aorus_cap: bridge %s not found on PCI bus\n", bridge);
		return -ENODEV;
	}
	if (!pci_is_pcie(dev)) {
		pr_err("aorus_cap: %s is not a PCIe device\n", bridge);
		pci_dev_put(dev);
		return -ENODEV;
	}

	ret = pcie_capability_read_word(dev, PCI_EXP_LNKCTL2, &lnkctl2);
	if (ret) {
		pr_err("aorus_cap: reading LNKCTL2 on %s failed\n", bridge);
		pci_dev_put(dev);
		return pcibios_err_to_errno(ret);
	}

	new2 = lnkctl2;
	/* bit5 is authoritative: set it on apply (bit5=1), clear it on restore
	 * (bit5=0). This lets the same module drive both aorus-bridge paths.
	 */
	if (bit5)
		new2 |= PCI_EXP_LNKCTL2_HASD;
	else
		new2 &= ~PCI_EXP_LNKCTL2_HASD;
	if (target >= 1) {
		new2 &= ~PCI_EXP_LNKCTL2_TLS;
		new2 |= (target & PCI_EXP_LNKCTL2_TLS);
	}

	if (new2 == lnkctl2) {
		pr_info("aorus_cap: %s LNKCTL2 already 0x%04x - no change\n",
			bridge, lnkctl2);
		pci_dev_put(dev);
		return 0;
	}

	ret = pcie_capability_write_word(dev, PCI_EXP_LNKCTL2, new2);
	if (ret) {
		pr_err("aorus_cap: writing LNKCTL2 on %s failed\n", bridge);
		pci_dev_put(dev);
		return pcibios_err_to_errno(ret);
	}
	pr_info("aorus_cap: %s LNKCTL2 0x%04x -> 0x%04x (bit5=%d target=Gen%d)\n",
		bridge, lnkctl2, new2, bit5, target);

	if (retrain) {
		ret = pcie_capability_read_word(dev, PCI_EXP_LNKCTL, &lnkctl);
		if (!ret) {
			pcie_capability_write_word(dev, PCI_EXP_LNKCTL,
						   lnkctl | PCI_EXP_LNKCTL_RL);
			pr_info("aorus_cap: %s retrain triggered\n", bridge);
		} else {
			pr_warn("aorus_cap: %s LNKCTL read failed; skipped retrain\n",
				bridge);
		}
	}

	pci_dev_put(dev);
	return 0;
}

static void __exit aorus_cap_exit(void)
{
	/* Nothing to undo: the cap is a bridge register state, not a resource. */
}

module_init(aorus_cap_init);
module_exit(aorus_cap_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Apply the AORUS eGPU PCIe bridge link cap from signed kernel code");
MODULE_VERSION("0.1");
