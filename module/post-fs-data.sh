#!/system/bin/sh
# Runs before zygote starts on every boot, including soft reboots, which keep
# processes and mounts from before: retire those, then set up the homes, the
# /product magic mount and /system/etc/mkshrc.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

osa_ensure_state

# Left over from before a soft reboot: the watchdog (a new generation token
# retires it even if killing fails) and the sshd listener, whose binary may
# be from an older version.  Open sessions keep running.  service.sh starts
# sshd again.
echo "boot.$(date +%s).$$" > "$OSA_RUN/watchdog.gen"
osa_kill_watchdogs
if p=$(osa_pid); then
	kill "$p"
	osa_log "stopped sshd left from before a soft reboot (pid $p)"
fi
rm -f "$OSA_RUN/sshd.pid"
osa_mark "boot at $(date '+%Y-%m-%d %H:%M:%S') ($(osa_version))"

# Boot guard: if the last 3 boots never reached sys.boot_completed with this
# module active, disable it instead of risking a bootloop.  The watchdog
# resets the counter once boot completes.
n=$(cat "$OSA_RUN/bootcount" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$OSA_RUN/bootcount"
if [ "$n" -gt 3 ]; then
	echo 0 > "$OSA_RUN/bootcount"
	touch "$MODDIR/disable"
	osa_deactivate "boot did not complete $((n - 1)) times in a row; module disabled"
	exit 0
fi

osa_in_init_ns || osa_log "warning: post-fs-data is not in init's mount namespace"
osa_ensure_homes
osa_publish_passwd
osa_mount_all
