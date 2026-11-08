# Shared helpers for the OpenSSH for Android module scripts and sshdctl.
# POSIX sh (runs under mksh and busybox ash); always runs as root.

OSA_ID=openssh
OSA_STATE=/data/adb/openssh          # persistent, root-only
OSA_ETC=$OSA_STATE/etc               # sshd_config, ssh_config, host keys, passwd
OSA_RUN=$OSA_STATE/run
OSA_LOG=$OSA_STATE/log
OSA_PREFIX=/product                  # where the module's tree is mounted
ROOT_HOME=/data/root
SHELL_HOME=/data/shell
HOME_LINK=/data/home                 # -> /data/root
OSA_INSTALLED=/data/adb/modules/$OSA_ID       # where the manager keeps disable/remove flags
OSA_UPDATE=/data/adb/modules_update/$OSA_ID   # a pending update (applied at boot or by reload)
: "${MODDIR:=$OSA_INSTALLED}"
OSA_PUB=$MODDIR/product/share/openssh   # appears as /product/share/openssh

TOYBOX=/system/bin/toybox

# Root managers run scripts with umask 0; files we create shouldn't be 0666.
umask 022

osa_log() {
	mkdir -p "$OSA_LOG" 2>/dev/null
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$OSA_LOG/module.log"
}

# A "--- ... ---" line in sshd.log (shown in `sshdctl log` and the WebUI).
# "--- boot " lines mark where each boot's log starts.
osa_mark() {
	mkdir -p "$OSA_LOG" 2>/dev/null
	echo "--- $* ---" >> "$OSA_LOG/sshd.log"
}

# Version of the module files in $1 (default: the ones in use).  module.prop
# can already name a newer version: the manager rewrites the installed one
# when an update is installed, before it's applied.
osa_version() {
	cat "${1:-$MODDIR}/product/share/openssh/version" 2>/dev/null ||
	    sed -n 's/^version=//p' "${1:-$MODDIR}/module.prop" 2>/dev/null
}

osa_busybox() {
	for b in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
		[ -x "$b" ] && { echo "$b"; return 0; }
	done
	return 1
}

osa_manager() {
	if [ -x /data/adb/ksud ]; then echo ksu
	elif [ -x /data/adb/apd ]; then echo apatch
	elif [ -d /data/adb/magisk ]; then echo magisk
	else echo unknown; fi
}

# SELinux domain the root manager runs us in (ksu, magisk, su, ...).
osa_root_domain() {
	d=$(cat /proc/self/attr/current 2>/dev/null | tr -d '\0')
	d=${d#u:r:}; d=${d%%:*}
	echo "${d:-ksu}"
}

osa_manager_bin() {
	for d in /data/adb/ksu/bin /data/adb/ap/bin; do
		[ -d "$d" ] && { echo "$d"; return 0; }
	done
	return 1
}

osa_in_init_ns() {
	[ "$(readlink /proc/self/ns/mnt)" = "$(readlink /proc/1/ns/mnt)" ]
}

osa_ensure_state() {
	mkdir -p "$OSA_ETC" "$OSA_RUN" "$OSA_LOG" "$OSA_STATE/empty"
	chown 0:0 "$OSA_STATE" "$OSA_STATE/empty"
	chmod 700 "$OSA_STATE" "$OSA_ETC" "$OSA_RUN" "$OSA_LOG"
	chmod 755 "$OSA_STATE/empty"
	[ -f "$OSA_ETC/sshd_config" ] || cp "$MODDIR/defaults/sshd_config" "$OSA_ETC/sshd_config"
	[ -f "$OSA_ETC/ssh_config" ] || cp "$MODDIR/defaults/ssh_config" "$OSA_ETC/ssh_config"
	[ -f "$OSA_ETC/passwd" ] || cp "$MODDIR/defaults/passwd" "$OSA_ETC/passwd"
	[ -f "$OSA_ETC/moduli" ] || cp "$MODDIR/defaults/moduli" "$OSA_ETC/moduli"
	mkdir -p "$OSA_ETC/sshd_config.d"
	# v10.6p1-1 shipped "PrintLastLog no", which this build doesn't support.
	grep -q '^PrintLastLog no$' "$OSA_ETC/sshd_config" 2>/dev/null &&
	    sed -i '/^PrintLastLog no$/d' "$OSA_ETC/sshd_config"
	chmod 600 "$OSA_ETC/sshd_config" 2>/dev/null
	chmod 644 "$OSA_ETC/ssh_config" "$OSA_ETC/passwd" "$OSA_ETC/moduli" 2>/dev/null
}

# /data/root (root's home), /data/shell (shell's home), /data/home -> /data/root.
osa_ensure_homes() {
	mkdir -p "$ROOT_HOME/.ssh"
	chown 0:0 "$ROOT_HOME" "$ROOT_HOME/.ssh"
	chmod 700 "$ROOT_HOME" "$ROOT_HOME/.ssh"
	[ -f "$ROOT_HOME/.ssh/authorized_keys" ] || touch "$ROOT_HOME/.ssh/authorized_keys"
	chmod 600 "$ROOT_HOME/.ssh/authorized_keys"
	$TOYBOX chcon u:object_r:system_data_file:s0 "$ROOT_HOME" 2>/dev/null

	mkdir -p "$SHELL_HOME/.ssh"
	chown 2000:2000 "$SHELL_HOME" "$SHELL_HOME/.ssh"
	chmod 700 "$SHELL_HOME" "$SHELL_HOME/.ssh"
	# init's restorecon (e.g. after an OTA) resets unknown /data dirs to
	# system_data_file, which adb-shell's domain can't write.
	case $($TOYBOX ls -Zd "$SHELL_HOME" 2>/dev/null) in
		*shell_data_file*) ;;
		*) $TOYBOX chcon -R u:object_r:shell_data_file:s0 "$SHELL_HOME" 2>/dev/null ;;
	esac

	if [ ! -e "$HOME_LINK" ] && [ ! -L "$HOME_LINK" ]; then
		ln -s "$ROOT_HOME" "$HOME_LINK"
	fi
}

# World-readable copy of $OSA_ETC/passwd for sshd, ssh and mkshrc (all uids).
osa_publish_passwd() {
	mkdir -p "$OSA_PUB"
	cp -f "$OSA_ETC/passwd" "$OSA_PUB/passwd.tmp" 2>/dev/null || return 1
	chmod 644 "$OSA_PUB/passwd.tmp"
	$TOYBOX chcon u:object_r:system_file:s0 "$OSA_PUB/passwd.tmp" 2>/dev/null
	mv -f "$OSA_PUB/passwd.tmp" "$OSA_PUB/passwd"
}

# init's environment (BOOTCLASSPATH, ANDROID_*, PATH, ...) for sessions, taken
# from zygote so it matches what adbd and apps get, minus script/manager vars.
osa_snapshot_env() {
	z=$(pidof zygote64 2>/dev/null || pidof zygote 2>/dev/null)
	z=${z%% *}
	{
		if [ -n "$z" ] && [ -r "/proc/$z/environ" ]; then
			tr '\0' '\n' < "/proc/$z/environ"
		else
			env
		fi
	} | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' |
	    grep -vE '^((ANDROID_SOCKET_|KSU|MAGISK|APATCH|ZYGISK|LD_|SSH_|OSA_)[A-Za-z0-9_]*|ASH_STANDALONE|MODPATH|MODDIR|OUTFD|ZIPFILE|BOOTMODE|PWD|OLDPWD|SHLVL|_|HOME|USER|LOGNAME|SHELL|TERM|TMPDIR)=' \
	    > "$OSA_RUN/init.env.tmp" && mv -f "$OSA_RUN/init.env.tmp" "$OSA_RUN/init.env"
	chmod 600 "$OSA_RUN/init.env" 2>/dev/null
}

osa_sepolicy_rules() {
	dom=${1:-$(osa_root_domain)}
	cat <<-EOF
	allow { shell runas_app } $dom unix_stream_socket { read write getattr ioctl }
	allow { shell runas_app } $dom fifo_file { read write getattr ioctl }
	allow { shell runas_app } $dom process sigchld
	allow { shell runas_app } $dom fd use
	EOF
}

# Rules for shell@ / app@ sessions (inherited fds and SIGCHLD to sshd).
# Also shipped as sepolicy.rule; applying live again is harmless.
osa_apply_sepolicy() {
	rules=$(osa_sepolicy_rules)
	if [ -x /data/adb/ksud ]; then
		/data/adb/ksud sepolicy patch "$(echo "$rules" | tr '\n' ';' | sed 's/;$//')" >/dev/null 2>&1 && return 0
	fi
	for mp in magiskpolicy /data/adb/ap/bin/magiskpolicy /data/adb/magisk/magiskpolicy; do
		if command -v "$mp" >/dev/null 2>&1 || [ -x "$mp" ]; then
			echo "$rules" | while IFS= read -r r; do "$mp" --live "$r" >/dev/null 2>&1; done
			return 0
		fi
	done
	osa_log "no sepolicy tool found; shell@ and app logins may see SELinux denials"
	return 1
}

# ---- magic mount ------------------------------------------------------------
# Copy mode, owner and SELinux label from $1 to $2.
osa_meta() {
	chmod "$(stat -c %a "$1")" "$2" && chown "$(stat -c %u:%g "$1")" "$2" &&
	    $TOYBOX chcon "$($TOYBOX ls -Zd "$1" | cut -d' ' -f1)" "$2"
}

# Put $1 at $2 inside the skeleton: symlinks are copied, dirs rbind, files bind.
osa_place() {
	if [ -L "$1" ]; then
		ln -s "$(readlink "$1")" "$2"
	elif [ -d "$1" ]; then
		mkdir "$2" && osa_meta "$1" "$2" && "$BB" mount --rbind "$1" "$2"
	elif [ -f "$1" ]; then
		touch "$2" && osa_meta "$1" "$2" && "$BB" mount --bind "$1" "$2"
	fi
}

# Fill skeleton dir $2 with the real dir $1 merged with the module dir $3.
osa_mirror() {
	local r="$1" d="$2" m="$3" e n
	for e in "$r"/* "$r"/.[!.]*; do
		[ -e "$e" ] || [ -L "$e" ] || continue
		n=${e##*/}
		if [ -e "$m/$n" ] || [ -L "$m/$n" ]; then
			if [ -d "$e" ] && [ ! -L "$e" ] && [ -d "$m/$n" ] && [ ! -L "$m/$n" ]; then
				mkdir "$d/$n" && osa_meta "$e" "$d/$n" &&
				    osa_mirror "$e" "$d/$n" "$m/$n" || return 1
			else
				osa_place "$m/$n" "$d/$n" || return 1
			fi
		else
			osa_place "$e" "$d/$n" || return 1
		fi
	done
	for e in "$m"/* "$m"/.[!.]*; do
		[ -e "$e" ] || [ -L "$e" ] || continue
		n=${e##*/}
		{ [ -e "$r/$n" ] || [ -L "$r/$n" ]; } && continue
		osa_place "$e" "$d/$n" || return 1
	done
}

# Magic mount: replace $1 (e.g. /product) with a tmpfs that mirrors every
# original entry and adds the module's entries from $2.  Built in a private
# work tmpfs and moved into place in one step; if anything fails nothing is
# mounted.  The tree is made private before the move, so none of its mounts
# share a peer group with the originals (moving it under the shared /product
# gives it new peer groups of its own), and unmounting it later can't reach
# the real /product.
osa_skeleton() {
	target=$1 mod=$2 src=$3
	W=/dev/.osa_mnt S=/dev/.osa_mnt/s
	# Leftover work tree: make it private first so unmounting can't
	# propagate to the originals its rbind copies came from.
	if [ -d "$W" ]; then
		"$BB" mount --make-rprivate "$W" 2>/dev/null
		"$BB" umount -l "$W" 2>/dev/null
	fi
	mkdir -p "$W"
	"$BB" mount -t tmpfs -o mode=0700 osa "$W" || return 1
	"$BB" mount --make-private "$W"
	mkdir "$S" && "$BB" mount -t tmpfs -o mode=0755 "$src" "$S" &&
	    osa_meta "$target" "$S" && osa_mirror "$target" "$S" "$mod"
	ok=$?
	# Private before anything else happens to it, success or not.
	"$BB" mount --make-rprivate "$S" 2>/dev/null
	if [ $ok -eq 0 ]; then
		"$BB" mount --move "$S" "$target"
		ok=$?
	fi
	"$BB" umount -l "$W" 2>/dev/null
	rmdir "$W" 2>/dev/null
	return $ok
}

osa_bb() { [ -n "$BB" ] || BB=$(osa_busybox); [ -n "$BB" ]; }

osa_product_dir() {
	if [ -L /product ]; then readlink -f /product; else echo /product; fi
}

# "id fstype source" of the topmost mount at path $1: the mount at $1 that no
# other mount at $1 is stacked on.
osa_top_mount() {
	awk -v p="$1" '
	$5 == p {
		n++; id[n] = $1; under[$2] = 1
		for (i = 7; i <= NF; i++) if ($i == "-") { fs[$1] = $(i + 1); src[$1] = $(i + 2); break }
	}
	END { for (k = n; k >= 1; k--) if (!(id[k] in under)) { print id[k], fs[id[k]], src[id[k]]; exit } }
	' /proc/self/mountinfo
}

# Is mount id $2 (at path $1) one this module made?
#  - /system/etc/mkshrc: a bind of a file from this module's directory.
#  - /product: a tmpfs with at least one bind from this module's directory
#    and none from another module's (so another module's or a metamodule's
#    tmpfs that mirrors ours is never mistaken for ours).
# The module directory may be modules/ or modules_update/, and "//deleted"
# once the manager has replaced it.
osa_mount_is_ours() {
	case $1 in
	/system/etc/mkshrc)
		awk -v id="$2" '$1 == id && $4 ~ /\/adb\/modules(_update)?\/openssh\// { f = 1 } END { exit !f }' /proc/self/mountinfo ;;
	*)
		awk -v id="$2" '
		$1 == id { for (i = 7; i <= NF; i++) if ($i == "-") { fs = $(i + 1); break } }
		$2 == id && $4 ~ /\/adb\/modules(_update)?\// {
			if ($4 ~ /\/adb\/modules(_update)?\/openssh\//) ours = 1; else other = 1
		}
		END { exit !(fs == "tmpfs" && ours && !other) }' /proc/self/mountinfo ;;
	esac
}

# Unmount what this module mounted at $1, including copies stacked by
# earlier versions or left over from before a soft reboot.  Stops at the
# first mount that isn't ours.  Each tree is made private first so the
# unmount stays in this namespace.  With $2 = dry, only report.
osa_unmount_ours() {
	_n=0
	while [ $_n -lt 8 ]; do
		_t=$(osa_top_mount "$1")
		[ -n "$_t" ] && osa_mount_is_ours "$1" "${_t%% *}" || return 0
		if [ "$2" = dry ]; then echo "would unmount $1: mount $_t"; return 0; fi
		if ! { "$BB" mount --make-rprivate "$1" && "$BB" umount -l "$1"; }; then
			osa_log "mount: unmounting the old $1 ($_t) failed"
			return 1
		fi
		osa_log "mount: unmounted the old $1 ($_t)"
		_n=$((_n + 1))
	done
}

# Our mounts as zygote and webview_zygote see them.  Those namespaces hold
# slave copies, which the private unmount above doesn't reach, and a new
# mount propagating in would be tucked underneath the old copy, so apps
# forked later would still see the old files.  Remove them in place, with
# the same ownership check.  (Not running during post-fs-data.)
osa_unmount_zygotes() {
	_t=$(osa_product_dir)
	for _z in $(pidof zygote64 zygote webview_zygote 2>/dev/null); do
		[ "$(readlink /proc/$_z/ns/mnt)" = "$(readlink /proc/self/ns/mnt)" ] && continue
		/system/bin/nsenter -t "$_z" -m -- /system/bin/sh -c '
			MODDIR=$1; . "$MODDIR/common.sh"; BB=$2
			osa_unmount_ours /system/etc/mkshrc
			osa_unmount_ours "$3"' sh "$MODDIR" "$BB" "$_t"
	done
}

# KernelSU applies its umount list to apps only after a module mount has
# been reported (ksu_handle_umount checks ksu_module_mounted), which a
# metamodule normally does.  Without one, report ours.  try_umount removes
# whatever is on top of a listed path, so our entries must only be listed
# while our mounts are in place (see osa_mount_all / osa_deactivate).
osa_ksu_notify_mounted() {
	[ -x /data/adb/ksud ] && /data/adb/ksud kernel notify-module-mounted >/dev/null 2>&1
	return 0
}

# KernelSU's umount list lives in the kernel, so it survives soft reboots:
# delete our entries before adding them (no duplicates) and whenever our
# mounts go away (or apps set to "umount modules" would lose the real
# /product).
osa_umount_list() {
	[ -x /data/adb/ksud ] || return 0
	for _p in "$(osa_product_dir)" /system/etc/mkshrc; do
		/data/adb/ksud kernel umount del "$_p" >/dev/null 2>&1
		[ "$1" = add ] && /data/adb/ksud kernel umount add "$_p" -f 2 >/dev/null 2>&1
	done
	return 0
}

# Mount the module's files from $MODDIR, replacing whatever an earlier boot,
# version or reload of this module left mounted.
osa_mount_all() {
	osa_bb || { osa_log "mount: no busybox found"; return 1; }
	case $(osa_manager) in ksu) src=KSU ;; *) src=magisk ;; esac
	target=$(osa_product_dir)

	# Unlist first: KernelSU must never unmount /product for a new app while
	# what's on top isn't ours (that would take the real /product away).
	osa_umount_list del
	osa_unmount_zygotes
	osa_unmount_ours /system/etc/mkshrc
	osa_unmount_ours "$target" || return 1
	if osa_skeleton "$target" "$MODDIR/product" "$src"; then
		osa_log "mount: $target ready from $MODDIR ($(osa_version))"
	else
		osa_log "mount: building $target failed, nothing mounted"
		osa_umount_list del
		rm -f "$OSA_RUN/moddir"
		return 1
	fi

	# /system/etc/mkshrc: keep a copy of the stock file, then bind ours.
	if grep -q "OpenSSH for Android" /system/etc/mkshrc 2>/dev/null; then
		osa_log "mount: /system/etc/mkshrc is still ours after unmounting; leaving it"
	else
		cp -f /system/etc/mkshrc "$OSA_PUB/etc/mkshrc.stock" 2>/dev/null &&
		    chmod 644 "$OSA_PUB/etc/mkshrc.stock" &&
		    $TOYBOX chcon u:object_r:system_file:s0 "$OSA_PUB/etc/mkshrc.stock"
		"$BB" mount --bind "$OSA_PUB/etc/mkshrc" /system/etc/mkshrc ||
		    osa_log "mount: binding /system/etc/mkshrc failed"
	fi

	# Follow the manager's per-app "umount modules" setting like other modules.
	osa_umount_list add
	osa_ksu_notify_mounted
	echo "$MODDIR" > "$OSA_RUN/moddir"
	return 0
}

# Undo everything the module set up at runtime: needed for disable, remove
# and uninstall when only soft reboots are possible (ephemeral root), since
# those leave processes, mounts and KernelSU's umount list in place.
osa_deactivate() {
	echo "off.$$" > "$OSA_RUN/watchdog.gen"
	osa_kill_watchdogs
	if p=$(osa_pid); then kill "$p"; fi
	rm -f "$OSA_RUN/sshd.pid" "$OSA_RUN/moddir"
	osa_umount_list del
	if osa_bb; then
		osa_unmount_zygotes
		osa_unmount_ours /system/etc/mkshrc
		osa_unmount_ours "$(osa_product_dir)"
	fi
	echo openssh-keepawake > /sys/power/wake_unlock 2>/dev/null
	osa_log "deactivated: $*"
}

# ---- watchdog ---------------------------------------------------------------
# One watchdog per boot or reload.  Each has a generation token; writing a
# new one to watchdog.gen retires the old loop at its next check even if it
# can't be killed (post-fs-data does this first thing after a soft reboot).
osa_gen_ok() { [ "$(cat "$OSA_RUN/watchdog.gen" 2>/dev/null)" = "$1" ]; }

# Kill watchdog loops (service.sh) other than this process, including the
# v10.6p1-1/-2 ones, which have no generation token.  One grep over all
# cmdlines: spawning a process per pid is slow as root on some devices.
osa_kill_watchdogs() {
	# toybox: NUL-separated records (-z); busybox's grep needs -a instead.
	for _f in $($TOYBOX grep -l -z '[/]openssh/service[.]sh' /proc/[0-9]*/cmdline 2>/dev/null); do
		_pid=${_f#/proc/}; _pid=${_pid%/cmdline}
		# SIGKILL: mksh puts off SIGTERM until its `sleep 300` returns.
		[ "$_pid" = "$$" ] || kill -9 "$_pid" 2>/dev/null
	done
}

osa_watchdog_spawn() {
	osa_kill_watchdogs
	_gen=$(date +%s).$$
	echo "$_gen" > "$OSA_RUN/watchdog.gen"
	/system/bin/sh "$MODDIR/service.sh" --watchdog "$_gen" </dev/null >/dev/null 2>&1 &
}

osa_watchdog() {
	gen=$1
	until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
	osa_gen_ok "$gen" || exit 0
	echo 0 > "$OSA_RUN/bootcount"
	osa_keepawake_apply
	osa_update_description
	# Every 5 minutes while awake (sleep doesn't wake a suspended device);
	# the first check after 1 minute if sshd isn't up yet.
	_wait=300; osa_pid >/dev/null || _wait=60
	while :; do
		sleep $_wait; _wait=300
		osa_gen_ok "$gen" || exit 0          # a newer boot or reload took over
		if [ -f "$OSA_INSTALLED/disable" ] || [ -f "$OSA_INSTALLED/remove" ]; then
			osa_deactivate "module disabled or marked for removal"
			exit 0
		fi
		[ -d "$MODDIR" ] || exit 0           # files moved by an update; the next boot takes over
		osa_sweep_wakelocks
		if p=$(osa_pid); then
			osa_ksu_mark "$p"
		elif [ ! -f "$OSA_RUN/stopped" ] && [ ! -f "$OSA_STATE/no_autostart" ]; then
			osa_log "watchdog: sshd not running, restarting"
			/system/bin/sh "$MODDIR/product/bin/sshdctl" start >/dev/null 2>&1
		fi
	done
}

# ---- sshd -------------------------------------------------------------------
osa_pid() {
	p=$(cat "$OSA_RUN/sshd.pid" 2>/dev/null)
	[ -n "$p" ] && grep -q sshd "/proc/$p/cmdline" 2>/dev/null && echo "$p"
}

# KernelSU only applies its `su` hook (/system/bin/su) to "marked" processes,
# and processes started from the root manager's scripts aren't marked.
# Marking the sshd listener lets every session it starts (they inherit the
# mark) use su like an adb shell does.  No-op elsewhere.
osa_ksu_mark() {
	[ -x /data/adb/ksud ] || return 0
	case $(/data/adb/ksud debug mark get "$1" 2>/dev/null) in
	*unmarked*) /data/adb/ksud debug mark mark "$1" >/dev/null 2>&1 ;;
	esac
	return 0
}

# Same name adb shell shows (adbd sets HOSTNAME from the device name).
# Override by writing a name to $OSA_ETC/hostname.
osa_hostname() {
	h=$(cat "$OSA_ETC/hostname" 2>/dev/null)
	[ -n "$h" ] || h=$(getprop ro.build.product)
	[ -n "$h" ] || h=$(getprop ro.product.device)
	echo "${h:-android}"
}

# Drop wakelocks left by sshd-session processes that were killed.
osa_sweep_wakelocks() {
	for l in $(cat /sys/power/wake_lock 2>/dev/null); do
		case $l in openssh-[0-9]*)
			[ -d "/proc/${l#openssh-}" ] || echo "$l" > /sys/power/wake_unlock
		esac
	done
}

# adb over the network on a fixed port (what `adb tcpip PORT` does, which a
# soft reboot resets).  $OSA_STATE/adb_tcp_port holds the port; absent = off.
osa_adb_tcp_apply() {
	want=$(cat "$OSA_STATE/adb_tcp_port" 2>/dev/null)
	cur=$(getprop service.adb.tcp.port)
	if [ -n "$want" ] && [ "$cur" != "$want" ]; then
		setprop service.adb.tcp.port "$want" && setprop ctl.restart adbd &&
		    osa_log "adb: listening on tcp port $want"
	elif [ -z "$want" ] && [ -n "$cur" ] && [ "$1" = off ]; then
		setprop service.adb.tcp.port "" && setprop ctl.restart adbd &&
		    osa_log "adb: stopped listening on tcp port $cur"
	fi
	return 0
}

osa_keepawake_apply() {
	if [ -f "$OSA_STATE/keepawake" ]; then
		echo openssh-keepawake > /sys/power/wake_lock
	else
		echo openssh-keepawake > /sys/power/wake_unlock 2>/dev/null
	fi
}

# The manager shows $OSA_INSTALLED/module.prop, whichever copy is mounted.
osa_update_description() {
	prop=$OSA_INSTALLED/module.prop
	[ -w "$prop" ] || return 0
	if p=$(osa_pid); then
		port=$(awk 'tolower($1) == "port" { print $2; exit }' "$OSA_ETC/sshd_config")
		keys=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$ROOT_HOME/.ssh/authorized_keys" 2>/dev/null)
		d="Running on port ${port:-22} (pid $p), ${keys:-0} root key(s). Connect: ssh root@$(osa_hostname)"
		[ -f "$OSA_STATE/keepawake" ] && d="$d. Keep-awake on"
	else
		d="Stopped. Start it with the action button, the WebUI or: sshdctl start"
	fi
	[ "$MODDIR" != "$OSA_INSTALLED" ] && d="$d. Running $(osa_version) (applied without a reboot)"
	sed -i "s|^description=.*|description=$d|" "$prop"
}
