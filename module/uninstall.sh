#!/system/bin/sh
# Stops sshd and the watchdog and removes the module's mounts and KernelSU
# umount-list entries (a soft reboot wouldn't).  Keeps /data/root,
# /data/shell, /data/home and /data/adb/openssh (host keys and config) so a
# reinstall keeps the same host identity; delete them by hand to remove
# everything.
MODDIR=${0%/*}
. "$MODDIR/common.sh"
if ! osa_in_init_ns && [ -z "$OSA_NSENTER" ]; then
	OSA_NSENTER=1 exec /system/bin/nsenter -t 1 -m -- /system/bin/sh "$0" "$@"
fi
osa_deactivate "module uninstalled"
