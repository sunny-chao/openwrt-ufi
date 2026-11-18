# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/image.mk


define Build/Compile
	$(CP) $(LINUX_DIR)/COPYING $(KDIR)/COPYING.linux
endef

### Image scripts ###
define Build/aboot-img
	mkbootimg \
		--kernel $@ \
		--ramdisk /dev/null \
		--cmdline $(CMDLINE) \
		-o $@.new
	mv $@.new $@
endef

define Build/sparse-img
	img2simg  $@ $@.new
	mv $@.new $@
endef

define Build/aboot-sysupgrade-tar
	rm -f $@.tmp
	$(CP) $@ $@.tmp
	sh $(TOPDIR)/scripts/sysupgrade-tar.sh \
		--board $(if $(BOARD_NAME),$(BOARD_NAME),$(DEVICE_NAME)) \
		--kernel $@.tmp \
		--rootfs $(IMAGE_ROOTFS) \
		$@
	rm -f $@.tmp
endef

### Devices ###
define Device/Default
	PROFILES := Default
	KERNEL = kernel-bin | gzip | append-dtb
	IMAGES := boot.img system.img sysupgrade.img
	IMAGE/boot.img := append-kernel | aboot-img | append-metadata
	IMAGE/system.img := append-rootfs | sparse-img | append-metadata
    IMAGE/sysupgrade.img := append-kernel | aboot-img | aboot-sysupgrade-tar | append-metadata
	DEVICE_DTS_DIR := $(DTS_DIR)/qcom
	DEVICE_DTS = $$(SOC)-$(lastword $(subst _, ,$(1)))
	CMDLINE := "earlycon console=ttyMSM0,115200 rw"
endef

include $(SUBTARGET).mk

$(eval $(call BuildImage))
