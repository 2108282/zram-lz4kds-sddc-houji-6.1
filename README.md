# ZRAM LZ4KDS + SDDC (小米14 / houji Linux 6.1 GKI 专版)

本项目将基于华为/一加架构的 `crystal_hybridswap` 驱动（LZ4KDS 压缩算法 + SDDC 跨页相似性去重 + ZMS 回写引擎）移植并适配至 **小米14（代号 houji，骁龙 8 Gen 3）官方 6.1 GKI 内核**。

## 模块特性
1. **LZ4KDS 压缩算法**：结合 LZ4KD 与 SDDC（相似性去重），支持 REF/ALIAS/DELTA 状态机。
2. **小米 HyperOS extm 自动对接**：开机后自动侦测 HyperOS 创建的 `dm-swapfile`（挂载至 `backing_dev`），自动开启 `hybridswap_enable` 并按物理内存比例写入自适应水位。
3. **原生 6.1 GKI 适配**：
   - 修复 Linux 6.1 块设备调用语法（`blkdev_get_by_dev` / `blkdev_put`）；
   - 内置 `scan_balance` 枚举定义，消除内核头文件私有接口依赖；
   - 彻底移除 Linux 6.6 专用的 `tpzap.ko` / `tpfence.ko` 补丁驱动（6.1 内核无此 RVH 悬空指针 BUG），驱动环境干净稳定。

## 云端构建产物
每次向仓库推送代码均会自动触发 GitHub Actions 云端编译，编译完成后可在：
- **GitHub Actions -> Artifacts** 下载 zip
- **GitHub Releases** 下载最新 Release 包

刷入方式：Magisk / KernelSU / APatch 模块管理器中直接刷入，重启生效。
