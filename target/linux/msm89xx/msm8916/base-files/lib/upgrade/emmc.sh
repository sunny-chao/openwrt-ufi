# Copyright (C) 2021 OpenWrt.org
#

. /lib/functions.sh

emmc_get_magic_long() {
	(${3}cat "$1" | dd bs=4 "skip=${2:-0}" count=1 | hexdump -v -n 4 -e '1/1 "%02x"') 2> /dev/null
}

emmc_identify() {
	identify_magic_long $(emmc_get_magic_long "$@")
}

emmc_get_magic_long_tar() {
	(tar xO${3}f "$1" "$2" | dd bs=4 count=1 | hexdump -v -n 4 -e '1/1 "%02x"') 2> /dev/null
}

emmc_identify_tar() {
	identify_magic_long $(emmc_get_magic_long_tar "$@")
}

emmc_identify_if_gzip() {
	if [ "$(emmc_identify "$1")" = gzip ]; then echo -n z; fi
}

emmc_upgrade_tar() {
	local tar_file="$1"
	local gz="$2"

	[ "$CI_KERNPART" -a -z "$EMMC_KERN_DEV" ] && export EMMC_KERN_DEV="$(find_mmc_part $CI_KERNPART $CI_ROOTDEV)"
	[ "$CI_ROOTPART" -a -z "$EMMC_ROOT_DEV" ] && export EMMC_ROOT_DEV="$(find_mmc_part $CI_ROOTPART $CI_ROOTDEV)"
	[ "$CI_DATAPART" -a -z "$EMMC_DATA_DEV" ] && export EMMC_DATA_DEV="$(find_mmc_part $CI_DATAPART $CI_ROOTDEV)"
	local has_kernel
	local has_rootfs
	local board_dir=$(tar t${gz}f "$tar_file" | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	tar t${gz}f "$tar_file" ${board_dir}/kernel 1>/dev/null 2>/dev/null && has_kernel=1
	tar t${gz}f "$tar_file" ${board_dir}/root 1>/dev/null 2>/dev/null && has_rootfs=1

	[ "$has_kernel" = 1 -a "$EMMC_KERN_DEV" ] &&
		export EMMC_KERNEL_BLOCKS=$(($(tar xO${gz}f "$tar_file" ${board_dir}/kernel | dd of="$EMMC_KERN_DEV" bs=512 conv=fsync 2>&1 | grep "records out" | cut -d' ' -f1)))

	[ "$has_rootfs" = 1 -a "$EMMC_ROOT_DEV" ] && {
		export EMMC_ROOTFS_BLOCKS=$(($(tar xO${gz}f "$tar_file" ${board_dir}/root | dd of="$EMMC_ROOT_DEV" bs=512 conv=fsync 2>&1 | grep "records out" | cut -d' ' -f1)))
		# Account for 64KiB ROOTDEV_OVERLAY_ALIGN in libfstools
		EMMC_ROOTFS_BLOCKS=$(((EMMC_ROOTFS_BLOCKS + 127) & ~127))
	}

	if [ -z "$UPGRADE_BACKUP" ]; then
		if [ "$EMMC_DATA_DEV" ]; then
			dd if=/dev/zero of="$EMMC_DATA_DEV" bs=512 count=8 conv=fsync
		elif [ "$EMMC_ROOTFS_BLOCKS" ]; then
			dd if=/dev/zero of="$EMMC_ROOT_DEV" bs=512 seek=$EMMC_ROOTFS_BLOCKS count=8 conv=fsync
		elif [ "$EMMC_KERNEL_BLOCKS" ]; then
			dd if=/dev/zero of="$EMMC_KERN_DEV" bs=512 seek=$EMMC_KERNEL_BLOCKS count=8 conv=fsync
		fi
	fi

	sync
}

emmc_upgrade_fit() {
	local fit_file="$1"
	[ "$CI_KERNPART" -a -z "$EMMC_KERN_DEV" ] && export EMMC_KERN_DEV="$(find_mmc_part $CI_KERNPART $CI_ROOTDEV)"

	if [ "$EMMC_KERN_DEV" ]; then
		export EMMC_KERNEL_BLOCKS=$(($(get_image "$fit_file" | fwtool -i /dev/null -T - | dd of="$EMMC_KERN_DEV" bs=512 conv=fsync 2>&1 | grep "records out" | cut -d' ' -f1)))

		[ -z "$UPGRADE_BACKUP" ] && dd if=/dev/zero of="$EMMC_KERN_DEV" bs=512 seek=$EMMC_KERNEL_BLOCKS count=8 conv=fsync

		sync
	fi
}

emmc_copy_config() {
	if [ "$EMMC_DATA_DEV" ]; then
		dd if="$UPGRADE_BACKUP" of="$EMMC_DATA_DEV" bs=512 conv=fsync
	elif [ "$EMMC_ROOTFS_BLOCKS" ]; then
		dd if="$UPGRADE_BACKUP" of="$EMMC_ROOT_DEV" bs=512 conv=fsync seek=$EMMC_ROOTFS_BLOCKS
	elif [ "$EMMC_KERNEL_BLOCKS" ]; then
		dd if="$UPGRADE_BACKUP" of="$EMMC_KERN_DEV" bs=512 conv=fsync seek=$EMMC_KERNEL_BLOCKS
	fi

	sync
}

emmc_verify_if_gzip_file() {
	local file="$1"
	local gz="$2"

	if [ "$gz" = z ]; then
		echo "verifying compressed sysupgrade file integrity"
		if ! gzip -t "$file"; then
			echo "corrupted compressed sysupgrade file"
			return 1
		fi
	fi
}

emmc_verify_tar_file() {
	local file="$1"
	local gz="$2"

	echo "verifying sysupgrade tar file integrity"
	if ! tar xO${gz}f "$file" > /dev/null; then
		echo "corrupted sysupgrade tar file"
		return 1
	fi
}

emmc_do_upgrade() {
	local file="$1"
	
	local gz="$(emmc_identify_if_gzip "$file")"
	local file_type="$(emmc_identify "$file" "" "$gz")"
	
	case "$file_type" in
		"fit")
#			emmc_verify_if_gzip_file "$file" "$gz" || return 1
			emmc_upgrade_fit $1
			;;
		*)
#			emmc_verify_tar_file "$file" "$gz" || return 1
			emmc_upgrade_tar "$file" "$gz"
			;;
	esac
}

# Check if passed file is a valid one for eMMC sysupgrade.
# Currently it accepts 4 types of files:
# 1) UBI: a ubinized image containing required UBI volumes.
# 2) UBIFS: a UBIFS rootfs volume image.
# 3) FIT: a FIT image containing kernel and rootfs.
# 4) TAR: an archive that includes directory "sysupgrade-${BOARD_NAME}" containing
#         a non-empty "CONTROL" file and required partition and/or volume images.
#
# You usually want to call this function in platform_check_image.
#
# $(1): board name, used in case of passing TAR file
# $(2): file to be checked
emmc_do_platform_check() {
	local board_name="$1"
	local file="$2"

	local gz="$(emmc_identify_if_gzip "$file")"
	local file_type="$(emmc_identify "$file" "" "$gz")"
	local control_length=$( (tar xO${gz}f "$file" "sysupgrade-${board_name//,/_}/CONTROL" | wc -c) 2> /dev/null)

	if [ "$control_length" = 0 ]; then
		control_length=$( (tar xO${gz}f "$file" "sysupgrade-${board_name//_/,}/CONTROL" | wc -c) 2> /dev/null)
	fi
	
	if [ "$control_length" != 0 ]; then
		emmc_verify_tar_file "$file" "$gz" || return 1
	else
		emmc_verify_if_gzip_file "$file" "$gz" || return 1
		if [ "$file_type" != "fit" ]; then
			echo "invalid sysupgrade file"
			return 1
		fi
	fi

	return 0
}
