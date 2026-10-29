// SPDX-License-Identifier: GPL-2.0
/*
 * tpscan.c - Scan all system tracepoints to find dangling callbacks in module area
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/string.h>
#include <linux/tracepoint.h>
#include <linux/mm.h>
#include <linux/vmalloc.h>

static char *lo_str = "";
static char *hi_str = "";

module_param_named(lo, lo_str, charp, 0400);
module_param_named(hi, hi_str, charp, 0400);

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

static int __init tpscan_init(void)
{
	unsigned long lo = parse_hex(lo_str);
	unsigned long hi = parse_hex(hi_str);
	tracepoint_ptr_t const *begin, *end, *iter;
	int total_tp = 0, suspicious_tp = 0;

	if (!lo || !hi || lo >= hi) {
		pr_alert("TPSCAN invalid lo/hi range\n");
		return -EINVAL;
	}

	begin = (tracepoint_ptr_t const *)lo;
	end = (tracepoint_ptr_t const *)hi;

	pr_info("TPSCAN scanning tracepoints from %px to %px\n", begin, end);

	for (iter = begin; iter < end; iter++) {
		struct tracepoint *tp = tracepoint_ptr_deref(iter);
		struct tracepoint_func *funcs;
		int i;

		if (!tp)
			continue;
		total_tp++;
		funcs = tp->funcs;
		if (!funcs)
			continue;

		for (i = 0; funcs[i].func; i++) {
			void *fn = funcs[i].func;
			if (is_vmalloc_or_module_addr(fn)) {
				suspicious_tp++;
				pr_info("TPSCAN TP [%s] at %px has SUSPECT func[%d]=%px [%pS]\n",
					tp->name ? tp->name : "unnamed", tp, i, fn, fn);
			}
		}
	}

	pr_info("TPSCAN scan done: total_tp=%d suspicious_tp=%d\n", total_tp, suspicious_tp);
	return 0;
}

static void __exit tpscan_exit(void)
{
	pr_info("TPSCAN exit\n");
}

module_init(tpscan_init);
module_exit(tpscan_exit);

MODULE_DESCRIPTION("Scan all system tracepoints for module callbacks");
MODULE_LICENSE("GPL");
