#!/system/bin/sh
SKIPMOUNT=true
PROPFILE=false
POSTFSDATA=true
LATESTARTSERVICE=true

EXPECT_VER="6.1.138-android14-11-g0c3d559bcd85-ab14529422"
EXPECT_KREL_RE="^6\.1([.-]|$)"

FILES="zram.ko attr.sh post-fs-data.sh service.sh uninstall.sh hybridswap_autostart.sh"
EXTM_BAD_PROPS="persist.miui.extm.dm_opt.enable persist.sys.xring_extm.enable"

print_modname() {
	ui_print "===================================="
	ui_print " ZRAM LZ4KDS (SDDC 去重 + 回写)"
	ui_print " 小米14 (houji) 6.1 内核定制移植版"
	ui_print " LZ4KD + SDDC(REF/ALIAS/DELTA)"
	ui_print "===================================="
	ui_print " 回写适配 HyperOS extm (自动点火)"
	ui_print "===================================="
}

find_resetprop() {
	for p in /data/adb/ksu/bin/resetprop 	         /data/adb/magisk/resetprop 	         /debug_ramdisk/resetprop 	         /sbin/resetprop; do
		[ -x "$p" ] && { echo "$p"; return 0; }
	done
	command -v resetprop 2>/dev/null && return 0
	return 1
}

fix_extm_props() {
	RP=$(find_resetprop)
	if [ -z "$RP" ]; then
		ui_print "- 提示: 找不到 resetprop，跳过 extm 属性清理"
		return 0
	fi
	for prop in $EXTM_BAD_PROPS; do
		val=$($RP get "$prop" 2>/dev/null)
		if [ "$val" = "false" ] || [ "$val" = "0" ]; then
			ui_print "- 清理旧的禁用属性: $prop"
			$RP --delete "$prop" 2>/dev/null
		fi
	done
}

print_modname

KVER=$(uname -r)
ui_print "- 检测到当前内核版本: $KVER"

if ! echo "$KVER" | grep -Eq "$EXPECT_KREL_RE"; then
	ui_print "! 警告: 当前内核版本不是 6.1 ($KVER)"
	ui_print "! 本模块专为 6.1 GKI 内核编译，跨版本可能无法加载"
fi

fix_extm_props

if [ -f "$MODPATH/zram.ko" ]; then
	md5sum "$MODPATH/zram.ko" | cut -d' ' -f1 > "$MODPATH/.ko_md5"
fi

ui_print "- 安装完成，重启手机生效"
