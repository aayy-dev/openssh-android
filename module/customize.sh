# Installer (sourced by Magisk / KernelSU / APatch).
# We extract and set permissions ourselves.  The managers' default
# set_perm_recursive runs chown, chmod and chcon once per file; with ~4,200
# files (terminfo, zsh functions) that took about 5 minutes as root on a
# Galaxy S26 FE.  Keep the next line exactly as is: the managers grep for it.
SKIPUNZIP=1

[ "$ARCH" = arm64 ] || abort "! This build is for arm64-v8a only (device: $ARCH)"
[ "$API" -ge 26 ] || abort "! Android 8.0 (API 26) or newer is required"

ui_print "- Extracting module files"
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2 || abort "! Couldn't extract the module files"
ui_print "- OpenSSH for Android $(grep_prop version "$MODPATH/module.prop")"

MODDIR=$MODPATH
. "$MODPATH/common.sh"

ui_print "- Root manager: $(osa_manager), SELinux domain: $(osa_root_domain)"

# Same result as set_perm_recursive (root:root, dirs 0755, files 0644,
# executables 0755, everything system_file) with a handful of processes.
osa_set_perms() {
	chown -R 0:0 "$MODPATH" &&
	chmod -R 0644 "$MODPATH" &&	# also clears x on dirs (fine as root) ...
	chmod -R a+X "$MODPATH" &&	# ... so this gives it back to dirs only
	chmod 0755 "$MODPATH"/product/bin/* "$MODPATH"/product/libexec/* \
	    "$MODPATH"/post-fs-data.sh "$MODPATH"/service.sh \
	    "$MODPATH"/uninstall.sh "$MODPATH"/action.sh &&
	$TOYBOX chcon -hR u:object_r:system_file:s0 "$MODPATH"
}
if ! osa_set_perms; then
	ui_print "  ! Bulk permission change failed, setting them file by file (slow)"
	set_perm_recursive "$MODPATH" 0 0 0755 0644 u:object_r:system_file:s0
	set_perm_recursive "$MODPATH/product/bin" 0 0 0755 0755 u:object_r:system_file:s0
	set_perm_recursive "$MODPATH/product/libexec" 0 0 0755 0755 u:object_r:system_file:s0
	for s in post-fs-data.sh service.sh uninstall.sh action.sh; do
		set_perm "$MODPATH/$s" 0 0 0755
	done
fi

# Applied by the manager at boot; service.sh also applies it live.
osa_sepolicy_rules > "$MODPATH/sepolicy.rule"

ui_print "- Setting up $OSA_STATE, $ROOT_HOME, $SHELL_HOME and $HOME_LINK"
osa_ensure_state
osa_ensure_homes
osa_publish_passwd

if ls /sdcard/Download/authorized_keys /sdcard/Download/*.pub >/dev/null 2>&1; then
	ui_print "- Importing public keys from /sdcard/Download"
	for f in /sdcard/Download/authorized_keys /sdcard/Download/*.pub; do
		[ -f "$f" ] || continue
		while IFS= read -r k; do
			case $k in ssh-*|ecdsa-*|sk-*) ;; *) continue ;; esac
			body=$(echo "$k" | awk '{print $1" "$2}')
			grep -qF "$body" "$ROOT_HOME/.ssh/authorized_keys" && continue
			echo "$k" >> "$ROOT_HOME/.ssh/authorized_keys"
			ui_print "  + ${f##*/}: $(echo "$k" | awk '{print $1, ($3 ? $3 : "(no comment)")}')"
		done < "$f"
	done
	chmod 600 "$ROOT_HOME/.ssh/authorized_keys"
fi

n=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$ROOT_HOME/.ssh/authorized_keys" 2>/dev/null)
ui_print "- Root has ${n:-0} authorized key(s) in $HOME_LINK/.ssh/authorized_keys"
[ "${n:-0}" -gt 0 ] || ui_print "  ! Add one before connecting, e.g.: sshdctl addkey 'ssh-ed25519 AAAA...'"
if [ "$BOOTMODE" = true ] && [ "$(cat "$OSA_RUN/moddir" 2>/dev/null)" = "$MODPATH" ]; then
	# The running copy was this very directory (an update applied without a
	# reboot), and the installer has just deleted and replaced its files, so
	# new SSH connections fail until it's mounted again: switch now.
	ui_print "- The running copy was replaced by this install; switching to it now"
	/system/bin/sh "$MODPATH/product/bin/sshdctl" reload 2>&1 | while IFS= read -r l; do ui_print "  $l"; done
	osa_pid >/dev/null || ui_print "  ! sshd isn't running; check: sshdctl log"
elif [ "$BOOTMODE" = true ] && osa_pid >/dev/null; then
	ui_print "- The running copy keeps working until you switch to this one:"
	ui_print "  soft reboot, or run: sshdctl reload  (WebUI: Apply update)"
else
	ui_print "- After reboot: ssh root@<phone>  (or shell@, or an app package name)"
fi
ui_print "  Manage with the WebUI, the action button, or: sshdctl help"
