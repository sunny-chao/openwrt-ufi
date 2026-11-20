# SPDX-License-Identifier: GPL-2.0-only

PART_NAME=firmware
REQUIRE_IMAGE_METADATA=1

RAMFS_COPY_BIN='blkid blockdev mkfs.ext4'
RAMFS_COPY_DATA=''

platform_check_image() {
	return 0
}

platform_pre_upgrade() {
	# Stop memory-heavy services before pivoting to RAM on 384MB/512MB boards
	for svc in modemmanager hostapd wpa_supplicant; do
		[ -x "/etc/init.d/$svc" ] && /etc/init.d/$svc stop 2>/dev/null
	done
}

platform_do_upgrade() {
	local tar_file="$1"
	local board_dir=$(get_image "$tar_file" | tar -tf - | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	if [ -z "$board_dir" ]; then
		v "ERROR: Invalid sysupgrade archive (missing sysupgrade-* directory)"
		return 1
	fi

	local boot_dev=$(find_mmc_part "boot")
	local rootfs_dev=$(find_mmc_part "rootfs")

	# Fall back to stock Android GPT names if custom OpenWrt GPT isn't used
	[ -z "$rootfs_dev" ] && rootfs_dev=$(find_mmc_part "system")

	if [ -z "$boot_dev" ] || [ -z "$rootfs_dev" ]; then
		v "ERROR: Could not find boot or rootfs eMMC partitions"
		return 1
	fi

	v "Flashing kernel/dtb to $boot_dev..."
	get_image "$tar_file" | tar -xOf - "${board_dir}/kernel" | dd of="$boot_dev" bs=4096 conv=fsync

	v "Flashing rootfs to $rootfs_dev..."
	get_image "$tar_file" | tar -xOf - "${board_dir}/root" | dd of="$rootfs_dev" bs=4096 conv=fsync

	# Wipe overlay partition if sysupgrade -n (do not save config) was requested
	if [ "$UPGRADE_OPT_SAVE_CONFIG" -ne 1 ]; then
		local data_dev=$(find_mmc_part "rootfs_data")
		[ -z "$data_dev" ] && data_dev=$(find_mmc_part "userdata")
		if [ -n "$data_dev" ]; then
			v "Formatting overlay partition $data_dev..."
			mkfs.ext4 -F -L rootfs_data "$data_dev"
		fi
	fi
}

platform_copy_config() {
	local data_dev=$(find_mmc_part "rootfs_data")
	[ -z "$data_dev" ] && data_dev=$(find_mmc_part "userdata")

	if [ -n "$data_dev" ]; then
		mkdir -p /tmp/overlay_mnt
		if mount -t ext4 "$data_dev" /tmp/overlay_mnt 2>/dev/null; then
			cp -af "$UPGRADE_BACKUP" "/tmp/overlay_mnt/$BACKUP_FILE"
			sync
			umount /tmp/overlay_mnt
		else
			# Format fresh if overlay wasn't valid ext4 yet, then copy config
			mkfs.ext4 -F -L rootfs_data "$data_dev"
			mount -t ext4 "$data_dev" /tmp/overlay_mnt && {
				cp -af "$UPGRADE_BACKUP" "/tmp/overlay_mnt/$BACKUP_FILE"
				sync
				umount /tmp/overlay_mnt
			}
		fi
		rmdir /tmp/overlay_mnt 2>/dev/null
	fi
}
