# SPDX-License-Identifier: GPL-2.0

obj-$(CONFIG_CRYSTAL_HYBRIDSWAP) += zram.o

zram-y := zcomp.o zms.o zram_drv.o core.o param.o \
	zram_bridge.o memcg.o pressure.o stats.o

zram-$(CONFIG_CRYSTAL_HYBRIDSWAP_SDDC_LZ4KD) += \
	sddc/crystal_sddc_codec.o \
	sddc/lz4kd/lz4kd_encode.o \
	sddc/lz4kd/lz4kd_encode_delta.o \
	sddc/lz4kd/lz4kd_decode.o

# 对齐原版模块：禁用内核态 NEON，避免 kmap_atomic 路径下与渲染中断产生 FPSIMD 冲突死锁

zram-$(CONFIG_CRYSTAL_HYBRIDSWAP_SDDC) += \
	sddc/crystal_sddc.o

zram-$(CONFIG_CRYSTAL_HYBRIDSWAP_SDDC_KUNIT_TEST) += \
	sddc/crystal_sddc_codec_test.o
