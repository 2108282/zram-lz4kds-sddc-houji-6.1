#!/system/bin/sh
# attr.sh —— 崩溃归因公共函数 (v7.2), 由 post-fs-data.sh / service.sh source。
#
# 用法: blame_crash <kmsg文件>  ->  OUR | UNKNOWN[:reason]
#
# 大坑1(2026-10-27 实测): 不能对整个日志 grep 关键字。
#   `Modules linked in:` 那几行会列出几百个模块名(adsprpc 就在里面),
#   全段 grep 会把任意崩溃都判成 OTHER:fastrpc —— 假免责, 危险。
# 正确: 只取 `Call trace:` 之后到 `---[ end trace` / `Kernel panic` 之间的栈帧。
#
# 大坑2(2026-10-27 下午, 重要更正): 栈里出现 fastrpc/devkmsg **不等于**与我方无关。
#   `usercopy` / `devkmsg_write` 只是"检测到"越界写的那一步 —— 它发现 kmalloc-96
#   对象已被写坏(offset 80 处只剩 16B 却要写 68~96B)。真正的写入者可能是别的代码
#   (比如本模块开机早期的内核结构操作)。实测: 禁用本模块后开机不再崩; 启用则在
#   16~19s 反复崩(init/sscrpcd/rmt_storage 轮流暴露, 报错完全相同)。
#   → 这些栈**不再免责**, 一律返回 UNKNOWN(计入熔断), 让熔断真正能保护。
#   只有崩溃栈里明确出现我方符号时才判 OUR。

blame_crash() {
	_F=$1
	[ -f "$_F" ] || { echo "UNKNOWN"; return; }
	_S=$(awk '
		/Call trace:/ { f=1; next }
		f && (/---\[ end trace/ || /Kernel panic/) { exit }
		f { print }
	' "$_F" 2>/dev/null)
	[ -n "$_S" ] || { echo "UNKNOWN"; return; }
	case "$_S" in
	*"crystal_"*|*"HYB_ZRAM"*|*"zram_writeback"*) echo "OUR"; return ;;
	esac
	# 仅作日志标注用, 不影响计数(都计入)。
	case "$_S" in
	*"fastrpc"*|*"adsprpc"*|*"sscrpcd"*) echo "UNKNOWN:fastrpc"; return ;;
	*"devkmsg_write"*) echo "UNKNOWN:devkmsg" ; return ;;
	esac
	echo "UNKNOWN"
}