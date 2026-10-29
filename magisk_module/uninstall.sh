#!/system/bin/sh
# lz4kds_sddc 卸载: 清 preinit rc + 清理状态, 恢复正常 stock zram
MODDIR=${0%/*}
rm -f /metadata/watchdog/ksu/modules.rc 2>/dev/null
rm -f "$MODDIR/.preinit_ok" "$MODDIR/.hs_boot" "$MODDIR/hybridswap.log" 2>/dev/null
# 历史版本遗留的持久配置目录
rm -rf /data/adb/lz4kds_sddc 2>/dev/null
echo "[uninstall] preinit rc removed, state cleaned"