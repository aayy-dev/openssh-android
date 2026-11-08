#!/system/bin/sh
# Late start: SELinux rules, adb over the network, sshd, then the watchdog.
# `service.sh --watchdog GEN` is the watchdog itself (see osa_watchdog).
MODDIR=${0%/*}
. "$MODDIR/common.sh"

if [ "$1" = --watchdog ]; then
	osa_watchdog "$2"
	exit 0
fi

osa_snapshot_env
osa_apply_sepolicy
osa_adb_tcp_apply
rm -f "$OSA_RUN/stopped"
if [ ! -x "$OSA_PREFIX/bin/sshd" ]; then
	# Not mounted: KernelSU's late-load runs service.sh without post-fs-data,
	# then soft-reboots, which runs post-fs-data and this script again.
	# Mounting now would also reach apps that are already running.  If no
	# post-fs-data follows, the watchdog's first check mounts and starts sshd.
	osa_log "service: module files not mounted yet; leaving it to post-fs-data or the watchdog"
elif [ ! -f "$OSA_STATE/no_autostart" ]; then
	/system/bin/sh "$MODDIR/product/bin/sshdctl" start >/dev/null 2>&1
fi
osa_watchdog_spawn
