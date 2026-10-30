#!/system/bin/sh
# lz4kds_sddc service —— 启动成功确认(熔断复位) + 小米 extm 回写自动点火
#
# 只有系统真正走到 boot_completed, 才认为本次驱动替换成功, 把 boot_count 清零。
# 若替换导致卡在 init, boot_count 会累积, 下次开机 post-fs-data 自动禁用模块。

MODDIR=/data/adb/modules/lz4kds_sddc
LOG=$MODDIR/load.log
STG=$MODDIR/bootstage.log

upseconds() { cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1; }
log()   { echo "[svc $(upseconds)s] $*" >> "$LOG" 2>/dev/null; }
kmark() { echo "<6>LZ4KDS-svc: $*" > /dev/kmsg 2>/dev/null; }
stage() { echo "[$(upseconds)s] svc/$1 bootid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '-')" >> "$STG" 2>/dev/null; }

[ -d "$MODDIR" ] || exit 0
stage start

# 双保险兜底：如果 swap 未激活，立即执行 swapon 避免锁屏内存耗尽
if ! grep -q zram /proc/swaps 2>/dev/null; then
	DS=$(cat /sys/block/zram0/disksize 2>/dev/null)
	if [ -n "$DS" ] && [ "$DS" != "0" ]; then
		/system/bin/mkswap /dev/block/zram0 2>>"$LOG" || mkswap /dev/block/zram0 2>>"$LOG"
		/system/bin/swapon /dev/block/zram0 2>>"$LOG" || swapon /dev/block/zram0 2>>"$LOG"
		log "service.sh fallback swapon: rc=$? swaps=[$(grep zram /proc/swaps 2>/dev/null)]"
	fi
fi

i=0
while [ $i -lt 150 ]; do
	[ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
	sleep 2
	i=$((i + 1))
done

if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
	echo 0 > "$MODDIR/boot_count" 2>/dev/null
	ALG=$(timeout 3 cat /sys/block/zram0/comp_algorithm 2>/dev/null)
	SW=$(grep -c zram /proc/swaps 2>/dev/null)
	log "boot_completed OK -> counter reset | comp=[$ALG] zram_in_swap=$SW"
	kmark "boot_completed OK comp=[$ALG]"
	stage boot_completed

	# 系统成功启动进入桌面，停止秒级追踪
	pkill -f "/data/local/tmp/live_trace.sh" 2>/dev/null || true
	echo "=== BOOT COMPLETED SUCCESSFULLY at $(date +%T) ===" >> /data/local/tmp/freeze_trace.log
	sync

	# --- v6.9: 回写交给小米 extm ---
	# 小米 umms/extm 会把 extm 块(dm-swapfile)绑到 zram0/backing_dev;
	# 但它绑好之后, 还需要驱动侧把 hybridswap 子系统 enable 并配好水位,
	# 回写才会真正跑。hybridswap_autostart.sh 在后台等 backing_dev 出现后
	# 自动完成这两步(自带 boot_id 去重与超时保护)。
	EXTM_ON=$(getprop persist.miui.extm.enable 2>/dev/null)
	if [ "$EXTM_ON" = "0" ]; then
		log "extm disabled -> 跳过回写自动点火"
		stage extm_off_skip
	elif [ -f "$MODDIR/hybridswap_autostart.sh" ]; then
		rm -f "$MODDIR/.hs_boot" 2>/dev/null
		if command -v setsid >/dev/null 2>&1; then
			setsid sh "$MODDIR/hybridswap_autostart.sh" >/dev/null 2>&1 < /dev/null &
		else
			nohup sh "$MODDIR/hybridswap_autostart.sh" >/dev/null 2>&1 < /dev/null &
		fi
		log "hybridswap autostart started (extm 回写自动点火)"
		stage hs_autostart_start
	fi

	# --- v7.1: 若出现新的小米 kpanic 崩溃包, 且崩溃栈不是我们的, 复位熔断计数 ---
	# 小米稳定性包通常在崩溃后约 2 分钟才生成, 所以放到 boot_completed 后查。
	if [ -f "$MODDIR/attr.sh" ]; then
		. "$MODDIR/attr.sh" 2>/dev/null
		VZ=$(ls -t /data/miuilog/stability/reboot/-1_ke_*.zip 2>/dev/null | head -1)
		if [ -n "$VZ" ]; then
			VN=$(basename "$VZ")
			if [ "$(cat "$MODDIR/last_ke_seen" 2>/dev/null)" != "$VN" ]; then
				echo "$VN" > "$MODDIR/last_ke_seen" 2>/dev/null
				if command -v unzip >/dev/null 2>&1; then
					timeout 30 unzip -p "$VZ" temp/last_kmsg > "$MODDIR/last_ke.kmsg" 2>/dev/null
					if [ -s "$MODDIR/last_ke.kmsg" ]; then
						B=$(blame_crash "$MODDIR/last_ke.kmsg")
						log "new kpanic pkg [$VN] attribution: $B"
						case "$B" in
						OTHER:*) echo 0 > "$MODDIR/boot_count" 2>/dev/null; log "kpanic NOT ours [$B] -> boot_count reset" ;;
						esac
					fi
				fi
			fi
		fi
	fi

	# 活体标记: 120s 后写一条, 用来判断开机后有没有再次重启
	( sleep 120; echo "[$(upseconds)s] svc/late-alive bootid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '-') hs=[$(cat /sys/block/zram0/hybridswap_enable 2>/dev/null)] bd_stat=[$(cat /sys/block/zram0/bd_stat 2>/dev/null | tr '\n' ' ')]" >> "$STG" 2>/dev/null ) &
else
	log "boot_completed NOT reached in 300s"
	kmark "boot_completed NOT reached"
	stage boot_completed_TIMEOUT
fi