// SPDX-License-Identifier: GPL-2.0
/*
 * tpzap.c - Zap dangling tracepoint probes to NULL and clean legacy cftypes
 * Enhanced for Xiaomi 14 HyperOS 6.1 kernel
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/string.h>
#include <linux/jump_label.h>
#include <linux/tracepoint.h>
#include <linux/static_call.h>
#include <linux/cgroup.h>

static char *tp_str = "";
static char *klo_str = "";
static char *khi_str = "";
static char *skd_str = "";
static char *scu_str = "";
static char *sckey_str = "";
static char *sctramp_str = "";
static char *keep_str = "";
static char *cft_str = "";
static char *rm_str = "";
static int mode = 1;

module_param_named(tp, tp_str, charp, 0400);
module_param_named(klo, klo_str, charp, 0400);
module_param_named(khi, khi_str, charp, 0400);
module_param_named(skd, skd_str, charp, 0400);
module_param_named(scu, scu_str, charp, 0400);
module_param_named(sckey, sckey_str, charp, 0400);
module_param_named(sctramp, sctramp_str, charp, 0400);
module_param_named(keep, keep_str, charp, 0400);
module_param_named(cft, cft_str, charp, 0400);
module_param_named(rm, rm_str, charp, 0400);
module_param(mode, int, 0400);

MODULE_PARM_DESC(tp, "Address of tracepoint");
MODULE_PARM_DESC(cft, "Address of cftypes to remove");
MODULE_PARM_DESC(rm, "Address of cgroup_rm_cftypes function");
MODULE_PARM_DESC(mode, "0=scan only, 1=zap/clean");

static unsigned long parse_hex(const char *s)
{
	unsigned long val = 0;
	if (!s || !*s)
		return 0;
	if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		s += 2;
	while (*s) {
		int b = hex_to_bin(*s++);
		if (b < 0)
			break;
		val = (val << 4) | b;
	}
	return val;
}

static int in_keep_list(unsigned long func, const char *keep)
{
	char buf[256];
	char *p, *token;

	if (!keep || !*keep)
		return 0;
	strscpy(buf, keep, sizeof(buf));
	p = buf;
	while ((token = strsep(&p, ",")) != NULL) {
		unsigned long addr = parse_hex(token);
		if (addr && addr == func)
			return 1;
	}
	return 0;
}

static int __init tpzap_init(void)
{
	struct tracepoint *tp;
	struct tracepoint_func *funcs;
	unsigned long tp_addr = parse_hex(tp_str);
	unsigned long klo = parse_hex(klo_str);
	unsigned long khi = parse_hex(khi_str);
	unsigned long skd_addr = parse_hex(skd_str);
	unsigned long scu_addr = parse_hex(scu_str);
	unsigned long sckey_addr = parse_hex(sckey_str);
	unsigned long sctramp_addr = parse_hex(sctramp_str);
	unsigned long cft_addr = parse_hex(cft_str);
	unsigned long rm_addr = parse_hex(rm_str);
	int n = 0, kernel_ok = 0, suspect = 0;
	int i;

	/* Clean legacy cftypes if requested */
	if (cft_addr && rm_addr) {
		int (*fn_rm)(struct cftype *) = (void *)rm_addr;
		pr_info("TPZAP invoking cgroup_rm_cftypes(%px) via %px\n",
			(void *)cft_addr, (void *)rm_addr);
		fn_rm((struct cftype *)cft_addr);
		pr_info("TPZAP cgroup_rm_cftypes finished cleanly\n");
	}

	if (!tp_addr) {
		pr_info("TPZAP no tp= specified, probe step skipped\n");
		return 0;
	}

	tp = (struct tracepoint *)tp_addr;
	pr_info("TPZAP target %px name=%s mode=%d\n", tp, tp->name ? tp->name : "(null)", mode);

	funcs = tp->funcs;
	if (!funcs) {
		pr_info("TPZAP funcs=NULL, already clean\n");
		return 0;
	}

	for (i = 0; funcs[i].func; i++) {
		unsigned long fn = (unsigned long)funcs[i].func;
		n++;
		if (klo && khi && fn >= klo && fn < khi) {
			kernel_ok++;
			pr_info("TPZAP [%d] func=%px KERNEL-TEXT legit\n", i, (void *)fn);
		} else if (in_keep_list(fn, keep_str)) {
			kernel_ok++;
			pr_info("TPZAP [%d] func=%px IN-KEEP legit\n", i, (void *)fn);
		} else {
			suspect++;
			pr_info("TPZAP [%d] func=%px [%pS] SUSPECT\n", i, (void *)fn, (void *)fn);
		}
	}

	pr_info("TPZAP audit n=%d kernel_ok=%d suspect=%d key_enabled=%d\n",
		n, kernel_ok, suspect, static_key_enabled(&tp->key));

	if (!suspect) {
		pr_info("TPZAP nothing suspicious\n");
		return 0;
	}

	if (kernel_ok > 0) {
		pr_info("TPZAP REFUSE: %d legit kernel callbacks present\n", kernel_ok);
		return 0;
	}

	if (mode == 0) {
		pr_info("TPZAP scan-only, would zap %d\n", suspect);
		return 0;
	}

	/* mode == 1: Perform zap */
	if (skd_addr) {
		void (*fn_skd)(struct static_key *) = (void *)skd_addr;
		if (static_key_enabled(&tp->key)) {
			fn_skd(&tp->key);
			pr_info("TPZAP static_key_disable called, now enabled=%d\n",
				static_key_enabled(&tp->key));
		}
	}

	if (scu_addr && sckey_addr && sctramp_addr && tp->iterator) {
		void (*fn_scu)(void *, void *) = (void *)scu_addr;
		fn_scu((void *)sckey_addr, tp->iterator);
		pr_info("TPZAP static_call reset to iterator\n");
	}

	/* Zap funcs pointer to NULL */
	WRITE_ONCE(tp->funcs, NULL);
	pr_info("TPZAP funcs -> NULL done (zero alloc), zapped=%d\n", suspect);

	return 0;
}

static void __exit tpzap_exit(void)
{
	pr_info("TPZAP exit\n");
}

module_init(tpzap_init);
module_exit(tpzap_exit);

MODULE_AUTHOR("whitewhale0612 & PairDev");
MODULE_DESCRIPTION("Tracepoint probe zapper and legacy cftype unlinker");
MODULE_LICENSE("GPL");
