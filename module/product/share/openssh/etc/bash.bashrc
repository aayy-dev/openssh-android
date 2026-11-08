# Global bashrc (OpenSSH for Android module, replaced on update).
# Your ~/.bashrc runs after this.
[[ $- == *i* ]] || return 0

export _OSA_SHELL=1
export TMPDIR=${TMPDIR:-/data/local/tmp}
export LANG=${LANG:-C.UTF-8}
if [[ ${HOME:-/} == / ]]; then
	case $UID in
	0)	[[ -d /data/root ]] && export HOME=/data/root ;;
	2000)	[[ -d /data/shell ]] && export HOME=/data/shell ;;
	esac
fi
[[ $PWD == / && $HOME != / ]] && cd ~

HISTFILE=$HOME/.bash_history
HISTSIZE=10000
HISTFILESIZE=10000
HISTCONTROL=ignoreboth
shopt -s histappend checkwinsize

# adbd and sshd set HOSTNAME to the device name; Android's own hostname is
# "localhost".
[[ -n $HOSTNAME && $HOSTNAME != localhost ]] || HOSTNAME=$(getprop ro.build.product 2>/dev/null)
export HOSTNAME=${HOSTNAME:-localhost}
if (( EUID == 0 )); then _osa_c=31; else _osa_c=32; fi
PS1="\[\e[${_osa_c}m\]\u@\${HOSTNAME}\[\e[0m\]:\[\e[34m\]\w\[\e[0m\] \\$ "
unset _osa_c
