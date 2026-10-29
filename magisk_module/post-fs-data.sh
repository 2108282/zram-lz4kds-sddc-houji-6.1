#!/system/bin/sh
# lz4kds_sddc post-fs-data —— v4
#
# v3 教训:
#   - KSU 更新后首次启动会把脚本执行两次(modules_update 路径 + modules 路径),
#     第一次的目录会被中途移走 -> 用 ${0%/*} 得到的路径失效, ko/日志全丢。
#   - `cat /dev/kmsg > file` 在本设备产出全 0 文件, 取证无效。
# 本版对策:
#   - MODDIR 用绝对路径
#   - 校验 ko md5 (防止用旧 ko)
#   - 去重: 同一启动 20s 内的第二次执行直接跳过
#   - insmod 前后立即 `dmesg > 文件` 落盘(即便随后卡死, 日志已在磁盘)
#   - 每步 echo 到 /dev/kmsg 打标记, 内核日志里可追踪

MODDIR=/data/adb/modules/lz4kds_sddc
LOG=$MODDIR/load.log
KREL=$(uname -r)
STOCK=/system_dlkm/flatten/lib/modules/zram.ko
[ -f "" ] || STOCK=/system_dlkm/lib/modules//kernel/drivers/block/zram/zram.ko
[ -f "" ] || STOCK=
OURS=$MODDIR/zram.ko
# ko 完整性期望值: 优先取安装时由 customize.sh 写入的 .ko_md5(随每次打包自动更新),
# 缺失时回落到内置值。这样 "改了 ko 却忘了改脚本" 不会再导致开机被拦。
EXPECT_KO_MD5=$(cat "$MODDIR/.ko_md5" 2>/dev/null | tr -dc '0-9a-f' | head -c 32)
[ -n "$EXPECT_KO_MD5" ] || EXPECT_KO_MD5=df2ac6e143df2b2e38de2dd0453fa22b

uptime_s() { cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1; }
log()      { echo "[pfd $(uptime_s)s] $*" >> "$LOG" 2>/dev/null; }
kmark()    { echo "<6>LZ4KDS: $*" > /dev/kmsg 2>/dev/null; }
# 开机阶段埋点: 若设备在早期非正常重启, 这里能看出死在哪一步
stage()    { echo "[$(uptime_s)s] pfd/$1 bootid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '-')" >> "$MODDIR/bootstage.log" 2>/dev/null; }

[ -d "$MODDIR" ] || exit 0

log "=== start v5 argv0=$0 ==="
kmark "start v4 argv0=$0"
stage start

[ -f "$MODDIR/disable" ] && { log "disabled"; exit 0; }
[ -f "$OURS" ]  || { log "FATAL: no ko";  exit 0; }
[ -f "$STOCK" ] || { log "FATAL: no stock"; exit 0; }

# ko 版本校验 (防止 KSU 更新中途读到旧 ko)
AM=$(md5sum "$OURS" 2>/dev/null | cut -d' ' -f1)
if [ "$AM" != "$EXPECT_KO_MD5" ]; then
	log "ko md5 mismatch: got=$AM -> abort"
	kmark "ko md5 mismatch -> abort"
	exit 0
fi

# 去重: 同一启动内的重复执行 (KSU 双跑) 跳过。
# v4 教训: 原本用 last_run_uptime 去重, 但该值跳重启后有残留
# -> 新启动 uptime 很小, Δ<20 成立 -> 误判 dup, 替换根本不执行。
# 改用 boot_id 做启动标识, 只在“同一次启动”内去重。
TS_F=$MODDIR/last_run_uptime
BOOTID_F=$MODDIR/last_boot_id
NOW=$(uptime_s)
BID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '-')
if [ -f "$TS_F" ] && [ -f "$BOOTID_F" ]; then
	LAST=$(cat "$TS_F" 2>/dev/null || echo 0)
	LASTBID=$(cat "$BOOTID_F" 2>/dev/null)
	case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
	if [ -n "$BID" ] && [ "$LASTBID" = "$BID" ] && [ "$LAST" -gt 0 ] && [ "$NOW" -gt 0 ] && [ $((NOW - LAST)) -lt 20 ]; then
		log "dup exec same-boot (Δ=$((NOW-LAST))s), skip"
		kmark "dup exec Δ=$((NOW-LAST))s skip"
		exit 0
	fi
fi
echo "$NOW" > "$TS_F" 2>/dev/null
echo "$BID" > "$BOOTID_F" 2>/dev/null

# 熔断: 上一次启动替换后没有走到 boot_completed(系统没起来) -> 自动禁用。
#
# v6.9.1 修复: 原实现只用单一计数器 boot_count, 不区分"上一次启动"和"本次启动的
# 重复执行"。而 KSU 在同一次开机会把 post-fs-data 跑两次(modules_update + modules
# 路径), 于是同一秒内 1->2 直接被判成"连续两次启动失败" -> 误触发熔断。
# 真机现场(2026-10-26 00:0x): load.log 只有同一个 13s 内的两条记录,
# boot_count=1 -> insmod 成功 -> 第二次 -> boot_count=2 -> CIRCUIT BREAKER -> disable。
# 改法: 用 boot_id 记账。同一个 boot_id 内重复执行不再累加;
#       只有 boot_id 变了(确实是新的一次启动)才认为上一次启动失败了。
CNT_F=$MODDIR/boot_count      # 仍保存计数(兼容旧版, 也让 service.sh 清零)
BID_F=$MODDIR/boot_count_bid  # 上一次记过账的 boot_id
CNT=$(cat "$CNT_F" 2>/dev/null || echo 0)
case "$CNT" in ''|*[!0-9]*) CNT=0 ;; esac
LASTBID_C=$(cat "$BID_F" 2>/dev/null)

# --- v7.0/v7.1 崩溃归因: 上一次启动的失败到底是不是我们引起的? ---
# 背景(2026-10-27): 设备存在一个与本模块无关的内核 BUG(mm/usercopy.c:102,
# 'kmalloc-96 offset 80' 被当成大缓冲区), 在 16s / 33s 反复触发 panic; 也有
# 无日志的 hang。这会让本模块背锅 —— 每次开机都没跑到 boot_completed -> 熔断自禁。
#
# v7.1 两级免责(避免被设备侧的既有 bug 误熔断):
#   ① “替换前的失败” 一律不计: 上次开机连 rmmod 都没跑到还失败, 肯定不是我们
#      (last_replace_bid 标记: 只有真的开始改 zram 的那次启动才写)
#   ② “能拿到崩溃栈且栈不是我们” 的失败, 计数归零
#      (来源: 上次快照 last_crash.kmsg, 或 小米 kpanic 收集包 -1_ke_*.zip)
CRASH_F=$MODDIR/last_crash.kmsg
CRASH_TAG_F=$MODDIR/last_crash.tag
CRASH_PREV=$MODDIR/last_crash.prev.kmsg
REPLACE_BID_F=$MODDIR/last_replace_bid   # 真正开始改 zram 的那次启动 boot_id
[ -f "$MODDIR/attr.sh" ] && . "$MODDIR/attr.sh" 2>/dev/null

# ⚠ 顺序很关键: 先归因(读上一次的快照), 再采集覆盖。
# 若先采集, 上一次的崩溃现场就被本次的日志盖掉了。
# 采集失败不阻塞主流程。
collect_crash_snapshot() {
	[ "$(cat "$CRASH_TAG_F" 2>/dev/null)" = "$BID" ] && return
	if [ -f "$CRASH_F" ]; then
		mv -f "$CRASH_F" "$CRASH_PREV" 2>/dev/null
	fi
	# 注: `cat /dev/kmsg > f` 在本机无效, 但 dmesg 可用(dmesg_restrict=0, root)。
	timeout 8 dmesg 2>/dev/null | tail -c 400000 > "$CRASH_F.tmp" 2>/dev/null
	if [ -s "$CRASH_F.tmp" ]; then
		mv -f "$CRASH_F.tmp" "$CRASH_F" 2>/dev/null
		echo "$BID" > "$CRASH_TAG_F" 2>/dev/null
		log "crash-snapshot saved ($(wc -c < "$CRASH_F" 2>/dev/null) bytes)"
	else
		rm -f "$CRASH_F.tmp" 2>/dev/null
	fi
}

# 小米稳定性包里有更精确的崩溃栈(含完整 Call trace), 优先用它。
blame_from_vendor() {
	_VZ=$(ls -t /data/miuilog/stability/reboot/-1_ke_*.zip 2>/dev/null | head -1)
	[ -n "$_VZ" ] || { echo "UNKNOWN"; return; }
	_VN=$(basename "$_VZ")
	[ "$(cat "$MODDIR/last_ke_seen" 2>/dev/null)" = "$_VN" ] && { echo "UNKNOWN"; return; }
	echo "$_VN" > "$MODDIR/last_ke_seen" 2>/dev/null
	command -v unzip >/dev/null 2>&1 || { echo "UNKNOWN"; return; }
	timeout 30 unzip -p "$_VZ" temp/last_kmsg > "$MODDIR/last_ke.kmsg" 2>/dev/null
	[ -s "$MODDIR/last_ke.kmsg" ] || { echo "UNKNOWN"; return; }
	blame_crash "$MODDIR/last_ke.kmsg"
}

if [ -n "$BID" ] && [ "$LASTBID_C" = "$BID" ]; then
	# 本次启动已经记过账了(KSU 双跑的第二趟) -> 不累加
	log "boot_count=$CNT (same boot_id, not incremented)"
else
	# 归因(只有真的换了 boot_id 才做, 否则谈的就不是“上一次启动”)
	if [ -n "$LASTBID_C" ]; then
		# ① 上一次启动有没有真的开始改 zram?
		PREV_RAN=0
		[ "$(cat "$REPLACE_BID_F" 2>/dev/null)" = "$LASTBID_C" ] && PREV_RAN=1
		BLAME=UNKNOWN
		if [ "$PREV_RAN" = "1" ]; then
			BLAME=$(blame_from_vendor)
			[ "$BLAME" = "UNKNOWN" ] && BLAME=$(blame_crash "$CRASH_F")
			log "prev-boot attribution: $BLAME"
		fi
		case "$BLAME" in
		OTHER:*)
			# 与本模块无关的崩溃: 计数清零, 避免设备侧既有 bug 把 SDDC 熔断。
			log "prev crash NOT ours [$BLAME] -> counter reset to 0 (no fault)"
			CNT=0
			;;
		esac
		if [ "$PREV_RAN" != "1" ]; then
			# 上一次启动根本没跑到改 zram 就失败了 -> 与替换无关, 不计。
			log "prev boot ($LASTBID_C) died BEFORE replacement -> not counted"
			CNT=0
		else
			CNT=$((CNT + 1))
		fi
	fi
	echo "$CNT" > "$CNT_F" 2>/dev/null
	[ -n "$BID" ] && echo "$BID" > "$BID_F" 2>/dev/null
	log "boot_count=$CNT (new boot_id)"
fi

# 归因读完了, 现在才能采集覆盖(下一次开机用)。
collect_crash_snapshot

if [ "$CNT" -ge 3 ]; then
	log "CIRCUIT BREAKER: $CNT boots in a row never reached boot_completed -> disable"
	kmark "CIRCUIT BREAKER count=$CNT -> disable"
	touch "$MODDIR/disable"
	exit 0
fi

# 铁律检查
grep -q 'zram' /proc/swaps 2>/dev/null && { log "ABORT: zram in swap"; exit 0; }
if grep -q '^zram ' /proc/modules 2>/dev/null; then
	ALG=$(timeout 2 cat /sys/block/zram0/comp_algorithm 2>/dev/null)
	case "$ALG" in *lz4kds*) log "already ours: $ALG"; exit 0;; esac
	DS=$(timeout 2 cat /sys/block/zram0/disksize 2>/dev/null)
	log "stock running, disksize=$DS"
	case "$DS" in ""|0) : ;; *) log "ABORT: disksize=$DS initialized"; exit 0 ;; esac
else
	log "no zram loaded"
fi
grep -q '^zsmalloc ' /proc/modules 2>/dev/null || { log "ABORT: no zsmalloc"; exit 0; }


# --- 卸载 stock ---
if grep -q '^zram ' /proc/modules 2>/dev/null; then
	# v7.1: 标记“本次启动真的开始改 zram 了”, 供下次开机归因
	echo "$BID" > "$REPLACE_BID_F" 2>/dev/null
	kmark "step: rmmod stock"
	rmmod zram 2>>"$LOG"; RC=$?
	log "rmmod rc=$RC"
	[ "$RC" = "0" ] || { log "keep stock"; exit 0; }
	i=0; while [ $i -lt 15 ]; do [ -e /sys/block/zram0 ] || break; sleep 0.2; i=$((i+1)); done
	log "post-rmmod: sysfs=$([ -e /sys/block/zram0 ] && echo Y || echo N)"
	kmark "post-rmmod sysfs_zram0=$([ -e /sys/block/zram0 ] && echo Y || echo N)"
fi


# --- 加载 ours ---
dmesg > "$MODDIR/dmesg_before_insmod.log" 2>/dev/null
kmark "step: insmod ours"
insmod "$OURS" num_devices=1 2>>"$LOG"; RC=$?
log "insmod rc=$RC"
dmesg > "$MODDIR/dmesg_after_insmod.log" 2>/dev/null
kmark "insmod done rc=$RC"

if [ "$RC" != "0" ]; then
	log "insmod failed -> restore stock"
	grep -q '^zram ' /proc/modules 2>/dev/null && rmmod zram 2>>"$LOG"
	insmod "$STOCK" 2>>"$LOG"; log "restore rc=$?"
	kmark "insmod failed, stock restored"
	exit 0
fi

i=0; while [ $i -lt 20 ]; do [ -e /sys/block/zram0 ] && break; sleep 0.2; i=$((i+1)); done
log "zram0 present=$([ -e /sys/block/zram0 ] && echo Y || echo N)"
kmark "zram0 present=$([ -e /sys/block/zram0 ] && echo Y || echo N)"


# Linux 6.1 内核无 RVH 悬空指针 BUG，无需加载 tpzap.ko
log "kernel 6.1: clean environment, skip fence/zap"
kmark "clean environment ok"

MAJ=$(timeout 2 cat /sys/block/zram0/dev 2>/dev/null | cut -d: -f1)
log "sysfs dev=[$MAJ] node=$(ls -l /dev/block/zram0 2>&1)"
if [ -n "$MAJ" ] && [ ! -e /dev/block/zram0 ]; then
	mknod /dev/block/zram0 b "$MAJ" 0 2>>"$LOG"; log "mknod rc=$?"
fi
chmod 660 /dev/block/zram0 2>/dev/null
chown root system /dev/block/zram0 2>/dev/null

timeout 3 sh -c 'echo lz4kds > /sys/block/zram0/comp_algorithm' 2>>"$LOG"
log "algo save rc=$? now=[$(timeout 2 cat /sys/block/zram0/comp_algorithm 2>/dev/null)]"
kmark "algo set done"

# 立即设置 16GB disksize 并建立 swap，打破系统启动时等待 swap 的死锁循环
DS=$(cat /sys/block/zram0/disksize 2>/dev/null)
if [ "$DS" = "0" ] || [ -z "$DS" ]; then
	echo 16G > /sys/block/zram0/disksize 2>>"$LOG"
	log "disksize set to 16G rc=$? (val=[$(cat /sys/block/zram0/disksize 2>/dev/null)])"
	mkswap /dev/block/zram0 2>>"$LOG"
	swapon /dev/block/zram0 -p 32758 2>>"$LOG"
	log "swapon rc=$? (swaps=[$(grep zram /proc/swaps 2>/dev/null)])"
	kmark "zram0 16G swap online"
fi

# --- v6.6: 开机绑定改到 service.sh (boot_completed 之后) ---
# v6.5 教训: 在 post-fs-data 里创建 1GiB 镜像 + 绑 loop, 跟设备早期的
# /data 初始化/加密流程打架, 会触发一次非正常重启(并把 wb.conf 丢成全零)。
# 改到 boot_completed 之后 late-bind (已验证可用), 且只在镜像缺失时重建。
# 二进制的 hook 没变, bootbind 内容一并搬到 service.sh 里执行。
stage pre-bootbind-skip
log "bootbind 延到 boot_completed 后再做 (v6.6)"

# --- v6.9: 回写交给小米 extm (不再有任何拦截/清理) ---
# 本阶段只负责换驱动 + 设算法。回写的"点火"在 service.sh (boot_completed 后) 做。

dmesg > "$MODDIR/dmesg_final.log" 2>/dev/null
stage done
log "DONE v6.6"
kmark "DONE v6.6"
exit 0
