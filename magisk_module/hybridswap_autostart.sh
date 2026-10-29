#!/system/bin/sh
# ============================================================
# hybridswap_autostart.sh —— 让小米 extm 的回写真正跑起来 (v6.9)
#
# 背景(2026-10-25 实测):
#   小米 umms/extm 会在开机时把 /data/extm/extm_file 做成 dm 设备
#   (dm-swapfile), 并把路径写进 /sys/block/zram0/backing_dev,
#   同时设好 writeback_limit。这一步小米做得没问题。
#   但是 —— 我们的 crystal_hybridswap 驱动里, 真正决定"写不写、写多少"
#   的是 hybridswap 子系统(写 1 到 hybridswap_enable 才会 enable),
#   并且还需要配置内存压力水位 avail_buffers, 否则 auto_policy 处于
#   inactive(configured=0), 永远不会触发回写。
#
# 实测(启用前 bd_stat=0 0 0 / 启用后 bd_stat 持续增长, md5 变化):
#   echo 1 > /sys/block/zram0/hybridswap_enable
#   echo "<avail> <min> <high> <free_swap_thr>" > /dev/memcg/memory.avail_buffers
#
# avail_buffers 语义 (驱动 core.c):
#   cur_avail = Android MemAvailable(MB)
#   low        = cur_avail < min            -> 内存偏低
#   below_high = cur_avail < high           -> 未回到目标水位
#   swap_low   = free_swap_mb < free_swap_thr
#   触发回写 = (low || below_high || swap_low) && zram_gate
#   回写量   = (high - cur_avail) MB  (把可用内存补到 high 水位就停)
#
# ★ 水位自适应: 按 MemTotal / SwapTotal 的比例算, 与设备内存大小无关。
#   基准口径 (来自一加13 op13_zram_extend 的 2200/1800/2200/1536, 按 16G/12G 折算):
#     high = MemTotal × 13.4%      (一加13: 16384×0.134 ≈ 2200)
#     min  = MemTotal × 11.0%      (一加13: 16384×0.110 ≈ 1800)
#     free_swap_thr = SwapTotal × 12.5%   (一加13: 12288×0.125 ≈ 1536)
#
# 可用环境变量覆盖:
#   HS_WAIT_MAX      最长等待秒数(默认 600)
#   HS_AVAIL_HIGH_PCT / HS_AVAIL_MIN_PCT / HS_SWAP_THR_PCT  比例(%)
#   HS_AVAIL_BUF     直接指定四个值 "avail min high thr" (给了就不再自适应)
# ============================================================

MODDIR=/data/adb/modules/lz4kds_sddc
ZRAM=/sys/block/zram0
MEMCG=/dev/memcg
LOG=$MODDIR/hybridswap.log

WAIT_MAX=${HS_WAIT_MAX:-600}
HIGH_PCT=${HS_AVAIL_HIGH_PCT:-13.4}
MIN_PCT=${HS_AVAIL_MIN_PCT:-11.0}
THR_PCT=${HS_SWAP_THR_PCT:-12.5}

ts()  { cut -d' ' -f1 /proc/uptime 2>/dev/null; }
log() { echo "[hs $(ts)s] $*" >> "$LOG" 2>/dev/null; }
klog(){ echo "<6>LZ4KDS-hs: $*" > /dev/kmsg 2>/dev/null; }

[ -d "$MODDIR" ] || exit 0

# 按 boot_id 去重: 同一开机只跑一次
BID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
MARK=$MODDIR/.hs_boot
if [ -n "$BID" ] && [ -f "$MARK" ] && [ "$(cat "$MARK" 2>/dev/null)" = "$BID" ]; then
	log "本开机已处理过, 跳过"
	exit 0
fi
[ -n "$BID" ] && echo "$BID" > "$MARK" 2>/dev/null

bd() { cat $ZRAM/backing_dev 2>/dev/null; }

log "start: 等待小米把 extm 块绑到 backing_dev (最多 ${WAIT_MAX}s)"
i=0
while [ $i -lt "$WAIT_MAX" ]; do
	[ -n "$(bd)" ] && break
	sleep 2
	i=$((i + 2))
done

BD=$(bd)
if [ -z "$BD" ]; then
	log "超时 ${WAIT_MAX}s: backing_dev 仍为空 (本次小米 extm 未启用), 放弃"
	exit 0
fi
log "backing_dev=$BD (等待 ${i}s)"

# --- 0) 计算自适应水位 (MB) ---
if [ -n "$HS_AVAIL_BUF" ]; then
	AVAIL_BUF="$HS_AVAIL_BUF"
	log "avail_buffers: 使用显式指定 [$AVAIL_BUF]"
else
	MEMTOTAL=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
	SWAPTOTAL=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)
	case "$MEMTOTAL" in ''|*[!0-9]*) MEMTOTAL=0 ;; esac
	case "$SWAPTOTAL" in ''|*[!0-9]*) SWAPTOTAL=0 ;; esac
	# 内核 kB -> MB, 按比例取整
	AVAIL_BUF=$(awk -v m="$MEMTOTAL" -v s="$SWAPTOTAL" \
		-v hp="$HIGH_PCT" -v mp="$MIN_PCT" -v tp="$THR_PCT" '
		BEGIN{
			mm = m/1024; sm = s/1024;
			high = int(mm*hp/100 + 0.5);
			min  = int(mm*mp/100 + 0.5);
			thr  = int(sm*tp/100 + 0.5);
			if (min < 256)  min = 256;
			if (high <= min) high = min + 256;
			printf "%d %d %d %d", high, min, high, thr;
		}')
	log "avail_buffers: 自适应计算 [MemTotal=${MEMTOTAL}kB SwapTotal=${SWAPTOTAL}kB / high=${HIGH_PCT}% min=${MIN_PCT}% thr=${THR_PCT}%] -> [$AVAIL_BUF]"
fi

# --- 1) enable hybridswap (值必须是数字 1/0, 写 'enable' 会 -EINVAL) ---
if [ -w $ZRAM/hybridswap_enable ]; then
	echo 1 > $ZRAM/hybridswap_enable 2>/dev/null
	log "hybridswap_enable -> [$(cat $ZRAM/hybridswap_enable 2>/dev/null)]"
else
	log "!! $ZRAM/hybridswap_enable 不可写, 回写可能不会触发"
	exit 0
fi

# --- 2) 写入水位 avail_buffers ---
WROTE=0
for f in $MEMCG/memory.avail_buffers $MEMCG/avail_buffers; do
	if [ -e "$f" ]; then
		if echo "$AVAIL_BUF" > "$f" 2>/dev/null; then
			log "avail_buffers -> $f : $(cat "$f" 2>/dev/null | head -1)"
			klog "avail_buffers set [$AVAIL_BUF]"
			WROTE=1
			break
		fi
	fi
done
[ "$WROTE" = "0" ] && log "!! 未找到可用 avail_buffers 节点 ($MEMCG/memory.avail_buffers)"

# --- 3) 校验 ---
sleep 2
log "verify: enable=[$(cat $ZRAM/hybridswap_enable 2>/dev/null)] wb_limit=[$(cat $ZRAM/writeback_limit 2>/dev/null)] bd_stat=[$(cat $ZRAM/bd_stat 2>/dev/null | tr '\n' ' ')]"
klog "verify enable=[$(cat $ZRAM/hybridswap_enable 2>/dev/null)] bd_stat=[$(cat $ZRAM/bd_stat 2>/dev/null | tr '\n' ' ')]"
exit 0