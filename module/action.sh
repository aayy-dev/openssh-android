#!/system/bin/sh
# Action button: start or stop sshd and show the status.
MODDIR=${0%/*}
. "$MODDIR/common.sh"
if osa_pid >/dev/null; then
	"$MODDIR/product/bin/sshdctl" stop
else
	"$MODDIR/product/bin/sshdctl" start
fi
echo
"$MODDIR/product/bin/sshdctl" status
sleep 2
