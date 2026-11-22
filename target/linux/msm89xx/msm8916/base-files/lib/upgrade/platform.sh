# SPDX-License-Identifier: GPL-2.0-only

. /lib/functions.sh

REQUIRE_IMAGE_METADATA=1
RAMFS_COPY_BIN='mkfs.ext4'

log_upgrade() {
	v "$*"
	[ -c /dev/pmsg0 ] && echo "sysupgrade: $*" > /dev/pmsg0
}

get_part_bytes() {
	local dev_name="${1#/dev/}"
	local sectors
	sectors=$(cat "/sys/class/block/${dev_name}/size" 2>/dev/null)
	[ -n "$sectors" ] && echo $((sectors * 512))
}

unmount_overlay_part() {
	local data_dev="$1"
	umount -l /tmp/root/overlay 2>/dev/null
	umount -l /overlay 2>/dev/null
	umount "$data_dev" 2>/dev/null || umount -l "$data_dev" 2>/dev/null
}

platform_check_image() {
	local tar_file="$1"
	local board_dir

	board_dir=$(get_image "$tar_file" | tar -tf - | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	if [ -z "$board_dir" ]; then
		v "Invalid sysupgrade archive: missing sysupgrade-* directory"
		return 1
	fi

	local boot_dev=$(find_mmc_part "boot")
	local rootfs_dev=$(find_mmc_part "rootfs")

	if [ -z "$boot_dev" ] || [ -z "$rootfs_dev" ]; then
		v "ERROR: Could not find boot or rootfs eMMC partitions"
		return 1
	fi

	local boot_max=$(get_part_bytes "$boot_dev")
	local rootfs_max=$(get_part_bytes "$rootfs_dev")

	local kernel_size root_size
	kernel_size=$(get_image "$tar_file" | tar -tvf - "${board_dir}/kernel" 2>/dev/null | awk '{print $3}')
	root_size=$(get_image "$tar_file" | tar -tvf - "${board_dir}/root" 2>/dev/null | awk '{print $3}')

	if [ -z "$kernel_size" ] || [ -z "$root_size" ]; then
		v "ERROR: Archive missing kernel or root image"
		return 1
	fi

	if [ -n "$boot_max" ] && [ "$kernel_size" -gt "$boot_max" ]; then
		v "ERROR: Kernel size ($kernel_size B) exceeds $boot_dev ($boot_max B)"
		return 1
	fi

	if [ -n "$rootfs_max" ] && [ "$root_size" -gt "$rootfs_max" ]; then
		v "ERROR: Rootfs size ($root_size B) exceeds $rootfs_dev ($rootfs_max B)"
		return 1
	fi

	return 0
}

platform_pre_upgrade() {
	for svc in modemmanager hostapd wpa_supplicant; do
		[ -x "/etc/init.d/$svc" ] && /etc/init.d/$svc stop 2>/dev/null
	done
}

platform_do_upgrade() {
	local tar_file="$1"
	local board_dir

	[ -c /dev/pmsg0 ] && exec 2>>/dev/pmsg0

	board_dir=$(get_image "$tar_file" | tar -tf - | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	local boot_dev=$(find_mmc_part "boot")
	local rootfs_dev=$(find_mmc_part "rootfs")

	if [ -z "$board_dir" ] || [ -z "$boot_dev" ] || [ -z "$rootfs_dev" ]; then
		log_upgrade "ERROR: Missing archive directory or target eMMC partitions"
		return 1
	fi

	log_upgrade "Flashing kernel/dtb to $boot_dev..."
	if ! get_image "$tar_file" | tar -xOf - "${board_dir}/kernel" | dd of="$boot_dev" bs=64k conv=fsync; then
		log_upgrade "ERROR: Failed writing kernel to $boot_dev"
		return 1
	fi

	log_upgrade "Flashing rootfs to $rootfs_dev..."
	if ! get_image "$tar_file" | tar -xOf - "${board_dir}/root" | dd of="$rootfs_dev" bs=64k conv=fsync; then
		log_upgrade "ERROR: Failed writing rootfs to $rootfs_dev"
		return 1
	fi

	# Wipe overlay partition (mmcblk0p15) if sysupgrade -n was requested
	if [ "$SAVE_CONFIG" != "1" ]; then
		local data_dev=$(find_mmc_part "rootfs_data")
		if [ -n "$data_dev" ]; then
			log_upgrade "Formatting overlay partition $data_dev as ext4..."
			unmount_overlay_part "$data_dev"
			if ! mkfs.ext4 -F -q -L rootfs_data "$data_dev"; then
				log_upgrade "ERROR: Failed formatting $data_dev"
				return 1
			fi
		else
			log_upgrade "WARNING: rootfs_data partition not found"
		fi
	fi

	log_upgrade "Upgrade write complete, syncing..."
	sync
}

platform_copy_config() {
	local data_dev=$(find_mmc_part "rootfs_data")
	[ -z "$data_dev" ] && return 0

	unmount_overlay_part "$data_dev"

	mkdir -p /tmp/overlay_mnt
	if mount -t ext4 "$data_dev" /tmp/overlay_mnt 2>/dev/null || {
		log_upgrade "Converting $data_dev to ext4 before restoring config..."
		mkfs.ext4 -F -q -L rootfs_data "$data_dev" &&
		mount -t ext4 "$data_dev" /tmp/overlay_mnt
	}; then
		cp -af "$UPGRADE_BACKUP" "/tmp/overlay_mnt/$BACKUP_FILE"
		sync
		umount /tmp/overlay_mnt
	else
		log_upgrade "ERROR: Failed mounting $data_dev to copy backup config"
	fi
	rmdir /tmp/overlay_mnt 2>/dev/null
}
