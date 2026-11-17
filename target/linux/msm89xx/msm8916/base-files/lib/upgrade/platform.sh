platform_check_image() {
	local board=$(cat /tmp/sysinfo/board_name 2>/dev/null)
	emmc_do_platform_check "$board" "$@"
	return $?
}

platform_do_upgrade() {
	CI_KERNPART="boot"
	CI_ROOTPART="rootfs"
	CI_DATAPART="rootfs_data"
	emmc_do_upgrade "$1"
	return $?
}
