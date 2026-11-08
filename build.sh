#!/usr/bin/env bash
# Cross-compiles OpenSSH, zsh, bash and rsync for Android and packages them as a
# Magisk / KernelSU / APatch module.
#
#   ./build.sh            build everything and the module zip
#   ./build.sh openssh    build one component (zlib openssl ncurses openssh zsh bash rsync module)
#   ./build.sh clean      remove build/ and out/
#
# Submodules are never modified: each component is exported with `git archive`
# into build/<abi>/src and patched there from patches/<component>/*.patch.
set -euo pipefail

TOP=$(cd "$(dirname "$0")" && pwd)
ABI=${ABI:-arm64-v8a}
API=${API:-26}
NDK=${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/30.0.16248370}}
JOBS=${JOBS:-$(nproc)}

case "$ABI" in
	arm64-v8a) TARGET=aarch64-linux-android; OSSL_TARGET=android-arm64 ;;
	*) echo "unsupported ABI: $ABI" >&2; exit 1 ;;
esac

# ---- Paths compiled into the binaries (see README.md "Layout") --------------
PREFIX=/product                         # mounted over /product by the module
SSH_STATE=/data/adb/openssh             # root-only persistent state
SSH_SYSCONF=$SSH_STATE/etc              # sshd_config, ssh_config, host keys
SHARE=$PREFIX/share
OSA_ETC=$SHARE/openssh/etc              # module-managed global shell rc files
TERMINFO_DIR=$SHARE/terminfo
ANDROID_TMP=/data/local/tmp
ANDROID_PATH=/product/bin:/apex/com.android.runtime/bin:/apex/com.android.art/bin:/apex/com.android.virt/bin:/system_ext/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin

BUILD=$TOP/build/$ABI
SRC=$BUILD/src
SYSROOT=$BUILD/sysroot                  # static deps (headers + .a)
STAGE=$BUILD/stage                      # DESTDIR for runtime files
OUT=$TOP/out

TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64
export PATH="$TC/bin:$PATH"
export CC="$TC/bin/${TARGET}${API}-clang"
export CXX="$TC/bin/${TARGET}${API}-clang++"
export AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib" STRIP="$TC/bin/llvm-strip"
export NM="$TC/bin/llvm-nm" OBJDUMP="$TC/bin/llvm-objdump"
BASE_CFLAGS="-O2 -fPIE -ffunction-sections -fdata-sections -fstack-protector-strong -D_FORTIFY_SOURCE=2"
BASE_LDFLAGS="-pie -Wl,--gc-sections -Wl,-z,relro,-z,now"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }

# export <submodule> into $SRC/<name> and apply patches/<name>/*.patch
fresh_src() {
	local sub=$1 name=${2:-$1}
	rm -rf "${SRC:?}/$name"
	mkdir -p "$SRC/$name"
	git -C "$TOP/$sub" archive --format=tar HEAD | tar -x -C "$SRC/$name"
	local p
	for p in "$TOP/patches/$name"/*.patch; do
		[ -e "$p" ] || continue
		log "patch $name: ${p##*/}"
		patch -d "$SRC/$name" -p1 --no-backup-if-mismatch < "$p"
	done
}

build_zlib() {
	log "zlib"
	fresh_src zlib
	cd "$SRC/zlib"
	CFLAGS="$BASE_CFLAGS" ./configure --static --prefix="$SYSROOT"
	make -j"$JOBS" libz.a
	make install
}

build_openssl() {
	log "openssl"
	fresh_src openssl
	cd "$SRC/openssl"
	ANDROID_NDK_ROOT=$NDK ./Configure "$OSSL_TARGET" -D__ANDROID_API__="$API" \
		--prefix="$SYSROOT" --libdir=lib --openssldir="$SSH_STATE/ssl" \
		no-shared no-tests no-apps no-docs no-module no-engine no-legacy no-dso \
		no-ui-console no-ssl3 no-comp -fPIE -ffunction-sections -fdata-sections
	make -j"$JOBS" build_libs
	make install_dev
}

build_ncurses() {
	log "ncurses"
	fresh_src ncurses
	mkdir -p "$SRC/ncurses/build" && cd "$SRC/ncurses/build"
	CFLAGS="$BASE_CFLAGS" LDFLAGS="$BASE_LDFLAGS" \
	../configure --host="$TARGET" --build=x86_64-pc-linux-gnu \
		--prefix="$SYSROOT" --datadir="$SHARE" \
		--with-default-terminfo-dir="$TERMINFO_DIR" \
		--with-terminfo-dirs="$TERMINFO_DIR:/system/etc/terminfo" \
		--enable-widec --enable-overwrite --enable-const --enable-ext-colors \
		--enable-ext-mouse --enable-termcap --disable-db-install \
		--without-shared --with-normal --without-debug --without-ada \
		--without-cxx --without-cxx-binding --without-manpages --without-tests \
		--without-progs --disable-stripping --disable-pc-files \
		ac_cv_header_locale_h=no am_cv_langinfo_codeset=no
	make -j"$JOBS" libs
	make install.libs install.includes
	# Legacy names some configure scripts look for.
	local l
	for l in ncurses tinfo curses termcap; do ln -sf libncursesw.a "$SYSROOT/lib/lib$l.a"; done
	# Terminfo database, compiled with the host tic (format is portable).
	rm -rf "$STAGE$TERMINFO_DIR"; mkdir -p "$STAGE$TERMINFO_DIR"
	tic -x -o "$STAGE$TERMINFO_DIR" "$SRC/ncurses/misc/terminfo.src" 2>/dev/null
}

build_openssh() {
	log "openssh"
	fresh_src openssh-portable openssh
	cd "$SRC/openssh"
	autoreconf -fi >/dev/null
	# bionic's unistd.h uses __sentinel__(1); OpenSSH would #define it away.
	CFLAGS="$BASE_CFLAGS" LDFLAGS="$BASE_LDFLAGS -L$SYSROOT/lib" \
	CPPFLAGS="-I$SYSROOT/include -DHAVE_ATTRIBUTE__SENTINEL__=1" \
	./configure --host="$TARGET" --build=x86_64-pc-linux-gnu \
		--prefix="$PREFIX" --sysconfdir="$SSH_SYSCONF" --libexecdir="$PREFIX/libexec" \
		--with-pid-dir="$SSH_STATE/run" --with-privsep-path="$SSH_STATE/empty" \
		--with-privsep-user=nobody \
		--with-default-path="$ANDROID_PATH" --with-superuser-path="$ANDROID_PATH" \
		--with-ssl-dir="$SYSROOT" --with-zlib="$SYSROOT" \
		--without-pam --without-libedit --without-ldns --without-kerberos5 \
		--without-security-key-builtin --disable-security-key \
		--disable-etc-default-login --disable-lastlog --disable-libutil \
		--disable-pututline --disable-pututxline --disable-utmp --disable-utmpx \
		--disable-wtmp --disable-wtmpx --disable-strip --with-mantype=man \
		--with-sandbox=seccomp_filter --with-cflags=-Dfd_mask=int \
		ac_cv_func_endgrent=yes ac_cv_func_fmt_scaled=no \
		ac_cv_func_getlastlogxbyname=no ac_cv_func_readpassphrase=no \
		ac_cv_func_strnvis=no ac_cv_header_sys_un_h=yes ac_cv_lib_crypt_crypt=no \
		ac_cv_search_getrrsetbyname=no ac_cv_func_bzero=yes \
		ac_cv_member_struct_passwd_pw_gecos=no
	make -j"$JOBS"
	local d=$STAGE$PREFIX
	mkdir -p "$d/bin" "$d/libexec"
	install -m755 ssh scp sftp ssh-add ssh-agent ssh-keygen ssh-keyscan "$d/bin/"
	install -m755 sshd "$d/bin/"
	install -m755 sshd-session sshd-auth sftp-server "$d/libexec/"
	install -m755 contrib/ssh-copy-id "$d/bin/ssh-copy-id"
	sed -i '1s|.*|#!/system/bin/sh|' "$d/bin/ssh-copy-id"
	mkdir -p "$STAGE/defaults"
	install -m644 moduli "$STAGE/defaults/moduli"
}

build_zsh() {
	log "zsh"
	fresh_src zsh
	cd "$SRC/zsh"
	./Util/preconfig >/dev/null
	CFLAGS="$BASE_CFLAGS" LDFLAGS="$BASE_LDFLAGS -L$SYSROOT/lib" CPPFLAGS="-I$SYSROOT/include" \
	./configure --host="$TARGET" --build=x86_64-pc-linux-gnu \
		--prefix="$PREFIX" --datadir="$SHARE" --enable-etcdir="$OSA_ETC" \
		--disable-dynamic --disable-restricted-r --disable-gdbm --disable-pcre \
		--disable-cap --enable-multibyte --enable-unicode9 \
		--with-term-lib="ncursesw" --with-tcsetpgrp \
		--enable-function-subdirs --disable-site-fndir --disable-additional-fpath \
		zsh_cv_sys_nis=no zsh_cv_sys_nis_plus=no \
		zsh_cv_shared_environ=yes zsh_cv_shared_tgetent=yes zsh_cv_shared_tigetstr=yes \
		zsh_cv_sys_dynamic_clash_ok=yes zsh_cv_sys_dynamic_execsyms=yes \
		zsh_cv_sys_dynamic_rtld_global=yes zsh_cv_sys_dynamic_strip_exe=yes \
		zsh_cv_sys_dynamic_strip_lib=yes zsh_cv_rlim_t_is_longer=no \
		zsh_cv_rlim_t_is_quad_t=no zsh_cv_type_rlim_t_is_unsigned=yes \
		zsh_cv_sys_elf=yes zsh_cv_getcwd_malloc=yes zsh_cv_use_getcwd=yes \
		zsh_cv_sys_link=yes zsh_cv_sys_killesrch=yes zsh_cv_sys_sigsuspend=yes \
		zsh_cv_sys_path_dev_fd=/proc/self/fd \
		ac_cv_func_getpwent=yes ac_cv_func_getpwnam=yes
	# Link every module statically, except ones needing libraries Android
	# lacks and zsh/newuser (the first-run wizard).
	sed -i -E -e '/^name=zsh\/(main|cap|db\/gdbm|pcre|example|newuser) /!s/link=(no|dynamic|either)/link=static/' \
	          -e '/^name=zsh\/(cap|db\/gdbm|pcre|example|newuser) /s/link=[a-z]+/link=no/' config.modules
	make -j"$JOBS" prep >/dev/null 2>&1 || true
	make -j"$JOBS"
	local d=$STAGE$PREFIX
	install -m755 Src/zsh "$d/bin/zsh"
	make install.fns DESTDIR="$STAGE" >/dev/null
}

build_bash() {
	log "bash"
	fresh_src bash
	cd "$SRC/bash"
	CFLAGS="$BASE_CFLAGS -DSYS_BASHRC=\\\"$OSA_ETC/bash.bashrc\\\" -DSYS_BASH_LOGOUT=\\\"$OSA_ETC/bash.bash_logout\\\" -DDEFAULT_PATH_VALUE=\\\"$ANDROID_PATH\\\" -DSTANDARD_UTILS_PATH=\\\"/system/bin:/system/xbin\\\"" \
	LDFLAGS="$BASE_LDFLAGS -L$SYSROOT/lib" CPPFLAGS="-I$SYSROOT/include" \
	./configure --host="$TARGET" --build=x86_64-pc-linux-gnu --prefix="$PREFIX" \
		--without-bash-malloc --with-curses --enable-readline --disable-nls \
		--enable-job-control --enable-multibyte --without-libintl-prefix \
		bash_cv_job_control_missing=present bash_cv_sys_siglist=yes \
		bash_cv_func_sigsetjmp=present bash_cv_unusable_rtsigs=no \
		bash_cv_getcwd_malloc=yes bash_cv_func_strcoll_broken=no \
		bash_cv_wcwidth_broken=no bash_cv_printf_a_format=yes \
		bash_cv_dev_fd=standard bash_cv_dev_stdin=present \
		bash_cv_sys_named_pipes=present bash_cv_ulimit_maxfds=yes \
		bash_cv_getenv_redef=yes bash_cv_func_ctype_nonascii=no \
		bash_cv_wexitstatus_offset=8 bash_cv_fnmatch_equiv_fallback=no \
		ac_cv_func_getpwent=yes ac_cv_rl_version=8.3
	make -j"$JOBS"
	install -m755 bash "$STAGE$PREFIX/bin/bash"
}

build_rsync() {
	log "rsync"
	fresh_src rsync
	cd "$SRC/rsync"
	CFLAGS="$BASE_CFLAGS" LDFLAGS="$BASE_LDFLAGS -L$SYSROOT/lib" CPPFLAGS="-I$SYSROOT/include" \
	./configure --host="$TARGET" --build=x86_64-pc-linux-gnu --prefix="$PREFIX" \
		--with-rsyncd-conf="$SSH_STATE/etc/rsyncd.conf" \
		--disable-md2man --disable-xxhash --disable-zstd --disable-lz4 \
		--disable-openssl --disable-idn --disable-debug --with-included-popt=yes \
		--with-included-zlib=yes --enable-ipv6=yes
	make -j"$JOBS" rsync
	install -m755 rsync "$STAGE$PREFIX/bin/rsync"
}

strip_stage() {
	local f
	for f in "$STAGE$PREFIX"/bin/* "$STAGE$PREFIX"/libexec/*; do
		file -b "$f" | grep -q ELF && "$STRIP" --strip-unneeded "$f"
	done
}

build_module() {
	log "module"
	strip_stage
	local m=$BUILD/module
	rm -rf "$m"; mkdir -p "$m"
	cp -a "$TOP/module/." "$m/"
	cp -a "$STAGE$PREFIX/." "$m/product/"
	install -Dm644 "$STAGE/defaults/moduli" "$m/defaults/moduli"
	find "$m" -name '.gitkeep' -delete
	local ver vcode
	ver=$(sed -n 's/^version=//p' "$m/module.prop")
	vcode=$(sed -n 's/^versionCode=//p' "$m/module.prop")
	mkdir -p "$OUT"
	local zip="$OUT/openssh-android-${ver}-${ABI}.zip"
	rm -f "$zip"
	(cd "$m" && zip -qr9 -X "$zip" . -x '*.DS_Store')
	log "built $zip ($(du -h "$zip" | cut -f1)), versionCode $vcode"
}

all() {
	build_zlib; build_openssl; build_ncurses; build_openssh
	build_zsh; build_bash; build_rsync; build_module
}

mkdir -p "$SRC" "$SYSROOT" "$STAGE$PREFIX/bin" "$STAGE$PREFIX/libexec"
[ -x "$CC" ] || { echo "NDK clang not found: $CC" >&2; exit 1; }

if [ $# -eq 0 ]; then all; exit 0; fi
for c in "$@"; do
	case "$c" in
		clean) rm -rf "$TOP/build" "$OUT" ;;
		all) all ;;
		zlib|openssl|ncurses|openssh|zsh|bash|rsync|module) "build_$c" ;;
		*) echo "unknown component: $c" >&2; exit 1 ;;
	esac
done
