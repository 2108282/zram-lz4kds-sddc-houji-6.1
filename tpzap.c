// SPDX-License-Identifier: GPL-2.0
/*
 * tpzap.c - Zap dangling tracepoint probes to NULL after disabling static key
 * Reconstructed from reverse-engineered binary (c) whitewhale0612 / Wcoom
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/string.h>
#include <linux/jump_label.h>
#include <linux/tracepoint.h>
#include <linux/static_call.h>

static char *tp_str = "";
static char *klo_str = "";
static char *khi_str = "";
static char *skd_str = "";
static char *scu_str = "";
static char *sckey_str = "";
static char *sctramp_str = "";
static char *keep_str = "";
static int mode = 1;

module_param_named(tp, tp_str, charp, 0400);
module_param_named(klo, klo_str, charp, 0400);
module_param_named(khi, khi_str, charp, 0400);
module_param_named(skd, skd_str, charp, 0400);
module_param_named(scu, scu_str, charp, 0400);
module_param_named(sckey, sckey_str, charp, 0400);
module_param_named(sctramp, sctramp_str, charp, 0400);
module_param_named(keep, keep_str, charp, 0400);
module_param(mode, int, 0400);

MODULE_PARM_DESC(tp, "Address of tracepoint");
MODULE_PARM_DESC(mode, "0=scan only, 1=zap to NULL");

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
	int n = 0, kernel_ok = 0, suspect = 0;
	int i;

	if (!tp_addr) {
		pr_alert("TPZAP no tp= given\n");
		return -EINVAL;
	}

	tp = (struct tracepoint *)tp_addr;
	pr_info("TPZAP target %px name=%s mode=%d\n", tp, tp->name ? tp->name : "(null)", mode);

	pr_info("TPZAP key=%px sc_key=%px sc_tramp=%px iter=%px\n",
		&tp->key, tp->static_call_key, tp->static_call_tramp, tp->iterator);

	pr_info("TPZAP op addr: skd=%lx scu=%lx params(sckey=%lx sctramp=%lx)\n",
		skd_addr, scu_addr, sckey_addr, sctramp_addr);

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
		} else {
			pr_info("TPZAP static_key already disabled\n");
		}
	} else {
		pr_info("TPZAP WARN: no skd addr, static key NOT disabled (funcs must be non-NULL or iterator will fault)\n");
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
	pr_info("TPZAP exit (zap stays)\n");
}

module_init(tpzap_init);
module_exit(tpzap_exit);

MODULE_DESCRIPTION("Zap tracepoint funcs to NULL after disabling its static key");
MODULE_LICENSE("GPL");
