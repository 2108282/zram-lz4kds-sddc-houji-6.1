// SPDX-License-Identifier: GPL-2.0
/*
 * tpfence.c - Fence dangling tracepoint probes left by unloaded modules
 * Reconstructed from reverse-engineered binary (c) whitewhale0612 / Wcoom
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/string.h>
#include <linux/tracepoint.h>
#include <linux/mm.h>
#include <linux/vmalloc.h>

static char *tp_str = "";
static char *keep_str = "";
static int mode = 1;

module_param_named(tp, tp_str, charp, 0400);
module_param_named(keep, keep_str, charp, 0400);
module_param(mode, int, 0400);

MODULE_PARM_DESC(tp, "Address of tracepoint");
MODULE_PARM_DESC(mode, "0=scan only, 1=fence");

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

static bool probe_suspicious(unsigned long func)
{
	if (!func)
		return false;
	if (in_keep_list(func, keep_str))
		return false;
	return is_vmalloc_or_module_addr((void *)func);
}

static int __init tpfence_init(void)
{
	struct tracepoint *tp;
	struct tracepoint_func *funcs;
	unsigned long tp_addr = parse_hex(tp_str);
	int scanned = 0, suspicious = 0;
	int killed = 0;
	int i;

	if (!tp_addr) {
		pr_alert("TPFENCE no tp= given\n");
		return -EINVAL;
	}

	tp = (struct tracepoint *)tp_addr;
	pr_info("TPFENCE target %px name=%s mode=%d keep=%s\n",
		tp, tp->name ? tp->name : "(null)", mode, keep_str ? keep_str : "(null)");

	funcs = tp->funcs;
	pr_info("TPFENCE funcs ptr=%px\n", funcs);

	if (!funcs) {
		pr_info("TPFENCE funcs=NULL, nothing to do\n");
		return 0;
	}

	for (i = 0; funcs[i].func; i++) {
		unsigned long fn = (unsigned long)funcs[i].func;
		bool susp = probe_suspicious(fn);
		scanned++;
		if (susp)
			suspicious++;
		pr_info("TPFENCE funcs[%d] func=%px [%pS] data=%016lx suspicious=%d\n",
			i, (void *)fn, (void *)fn, (unsigned long)funcs[i].data, susp);
	}

	pr_info("TPFENCE scanned=%d suspicious=%d\n", scanned, suspicious);

	if (!suspicious) {
		pr_info("TPFENCE clean, no suspicious probe\n");
		return 0;
	}

	if (mode == 0) {
		pr_info("TPFENCE scan-only, %d suspicious kept\n", suspicious);
		return 0;
	}

	/* Unregister suspicious probes */
	for (i = 0; funcs[i].func; i++) {
		unsigned long fn = (unsigned long)funcs[i].func;
		if (probe_suspicious(fn)) {
			pr_info("TPFENCE unregister %px\n", (void *)fn);
			tracepoint_probe_unregister(tp, funcs[i].func, funcs[i].data);
			killed++;
		}
	}

	pr_info("TPFENCE done killed=%d\n", killed);

	/* Check after */
	funcs = tp->funcs;
	if (!funcs) {
		pr_info("TPFENCE after funcs=NULL\n");
	} else {
		int count = 0;
		for (i = 0; funcs[i].func; i++) {
			count++;
			pr_info("TPFENCE after[%d] func=%px [%pS]\n",
				i, funcs[i].func, funcs[i].func);
		}
		pr_info("TPFENCE after count=%d\n", count);
	}

	return 0;
}

static void __exit tpfence_exit(void)
{
	pr_info("TPFENCE exit (fence stays)\n");
}

module_init(tpfence_init);
module_exit(tpfence_exit);

MODULE_DESCRIPTION("Fence dangling tracepoint probes left by unloaded modules");
MODULE_LICENSE("GPL");
