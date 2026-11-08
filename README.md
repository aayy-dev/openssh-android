# OpenSSH for Android

A Magisk / KernelSU / APatch module that runs a real OpenSSH server on
Android and puts the OpenSSH client tools, **zsh**, **bash** and **rsync** on
the standard shell `PATH`, working around Android's lack of `/etc/passwd`,
PAM, `crypt()` and normal group handling.

- `ssh root@phone`, `ssh shell@phone` (an exact copy of `adb shell`), or an
  app: `ssh com.example.app@phone` / `ssh u0_a123@phone` (like `run-as`).
- `ssh phone` with any other username (e.g. your laptop's) logs in as root.
- Keys only. Root's keys live in `/data/home/.ssh/authorized_keys`.
- Binaries appear in `/product/bin` (first in Android's `PATH`) through a
  self-contained magic mount, so it works the same with or without a
  KernelSU metamodule.
- `/system/etc/mkshrc` is replaced so `adb shell` and `su` land in your home
  directory and start your preferred shell.
- `su` works in SSH sessions the same way it does in `adb shell`.
- Updates and reinstalls apply with a soft reboot, or with no reboot at all
  (`sshdctl reload` or the WebUI's "Apply update"): made for ephemeral root
  setups that can't afford a full reboot.
- Optional adb over the network (port 5555) after every boot.
- Wakelock while sessions are open, optional "always awake", a KernelSU
  WebUI, an action button and the `sshdctl` command.

Built from the submodules in this repo: OpenSSH 10.6p1, OpenSSL 3.5, zlib,
ncurses 6.6, zsh 5.9.2, bash 5.3 and rsync 3.5. arm64-v8a, Android 8.0+.

## Install

1. Optional: put your public key(s) in `/sdcard/Download/authorized_keys` or
   `/sdcard/Download/*.pub`; the installer imports them for root.
2. Flash `out/openssh-android-*-arm64-v8a.zip` in your root manager and
   reboot.
3. `ssh root@<phone>`. Add more keys any time with
   `sshdctl addkey 'ssh-ed25519 AAAA...'`, the WebUI, or by editing
   `/data/home/.ssh/authorized_keys`.

Easiest with adb: copy your key to the phone before flashing, and the
installer picks it up:

```sh
adb push ~/.ssh/id_ed25519.pub /sdcard/Download/
```

After the reboot, `sshdctl` is on the PATH:

```sh
adb shell su -c "sshdctl addkey '$(cat ~/.ssh/id_ed25519.pub)'"
```

## Accounts

| Login | Becomes | Home | SELinux |
|---|---|---|---|
| `root@` or any unknown name | uid 0 | `/data/root` (`/data/home` links here) | root manager's domain |
| `shell@` | uid 2000 with adbd's 14 groups | `/data/shell` | `u:r:shell:s0` |
| `system@`, `radio@`, ... | that Android uid | `/` | root manager's domain (like `su 1000`) |
| `com.example.app@`, `u0_a123@` | the app's uid and gids | the app's data dir | `u:r:runas_app:s0:cN,...` (like `run-as`) |

Root's keys work for every account. `shell@` also accepts keys in
`/data/shell/.ssh/authorized_keys`, which adb shell can edit without root.

`HOME` is the real path (`/data/root`) rather than the `/data/home`
symlink because sshd's StrictModes resolves `authorized_keys` and walks up to
the home directory by its literal path.

## Shells

Pick the interactive shell per account:

```sh
sshdctl shell root zsh       # or bash, sh
sshdctl shell shell bash
```

It applies to interactive ssh logins and to `adb shell` / `su` (through the
module's `/system/etc/mkshrc`). Commands (`ssh phone cmd`), scp, sftp and
rsync always run under `/system/bin/sh`, so they work the same whatever
you choose. Personal settings go in `~/.zshrc`, `~/.bashrc` or `~/.profile`
(for sh); the module's global defaults run before them.

## Managing

- **WebUI** (KernelSU, APatch, or the KsuWebUI / MMRL apps): start/stop,
  apply an installed update, options, shells, authorized keys,
  `sshd_config` / `ssh_config` editors and the log (this boot or all boots,
  with a clear button).
- **Action button**: start or stop the server.
- **`sshdctl`**: `start | stop | restart | reload | status | test | log |
  adb | shell | addkey | import | keepawake | wakelock | autostart | paths`.
  `sshdctl log` shows this boot's log, `--all` every boot, `--clear`
  empties it.
- The hostname (prompts, WebUI) is `ro.build.product`, the name `adb shell`
  shows; write another name to `/data/adb/openssh/etc/hostname` to change it.

| What | Where |
|---|---|
| sshd config | `/data/adb/openssh/etc/sshd_config` (+ `sshd_config.d/*.conf`) |
| client config | `/data/adb/openssh/etc/ssh_config`, `~/.ssh/config` |
| host keys | `/data/adb/openssh/etc/ssh_host_*_key` |
| accounts (home, shell) | `/data/adb/openssh/etc/passwd` |
| logs | `/data/adb/openssh/log/sshd.log`, `module.log` |

## Soft reboots, updates and ephemeral root

A soft reboot (KernelSU's, or the one `ksud late-load` does after loading
root) keeps running processes, mounts and KernelSU's umount list. The module
handles that on every boot: it stops the sshd and watchdog left from before
(open SSH sessions keep running), removes the mounts it made earlier and
mounts again from the current files, so an update or reinstall takes effect
with a soft reboot.

To switch without any reboot, install the update and run `sshdctl reload`
(WebUI: **Apply update**). It mounts the new files, restarts sshd and the
watchdog, and leaves open sessions alone; the next boot moves the update
into place as usual. Zygote's copies are replaced too, so apps started
afterwards get the new files (and KernelSU's per-app unmount); apps that are
already running keep the copy they had until they restart.

Disabling or removing the module takes effect within 5 minutes without a
reboot: the watchdog stops sshd, removes the mounts and drops the module's
entries from KernelSU's umount list, which otherwise survive soft reboots.
`sshdctl start` brings everything back after re-enabling.

`adb tcpip 5555` lasts until the next full reboot. `sshdctl adb on` (WebUI:
"adb over the network") sets port 5555 again on every boot, including after
dfroot or another late-load root comes back; `sshdctl adb 5037` picks another
port, `sshdctl adb off` stops it.

## Battery and sleep

A listening sshd costs nothing while idle. On Wi-Fi the phone normally wakes
for incoming connections; the module holds a wakelock from the moment a
connection is accepted until it closes, so long jobs keep running with the
screen off (`sshdctl wakelock off` to disable). `sshdctl keepawake on` keeps
the CPU awake permanently for the rare network that drops wake-up packets;
that is the only setting with a real battery cost.

## How it works

- **Users**: `patches/openssh/0001-android-support.patch` adds `android.c`.
  Every `getpwnam()`/`getpwuid()` in OpenSSH goes through a shim that
  returns the real home and shell (from
  `/product/share/openssh/passwd`, a copy of the root-only accounts file).
  Logins map unknown names to root, package names to app uids, set
  adbd's/zygote's supplementary groups, and switch SELinux domain with a
  `setcon` (like `run-as`) right before the shell starts. The username the
  client sent is left untouched because the client signs it.
- **Environment**: sessions get init's environment (`BOOTCLASSPATH`,
  `ANDROID_*`, `PATH`, ...) captured from zygote at boot, so `am`, `pm`,
  `cmd`, `content` etc. work.
- **Bionic fixes**: no `crypt()` (password auth fails cleanly), stubbed
  SSHFP lookups, the bionic atrace fd guard in sshd-auth, `prctl` allowed to
  fail in the seccomp sandbox, configure's Linux settings for Android.
- **Mounting**: `post-fs-data.sh` builds a tmpfs copy of `/product` (every
  original entry bind-mounted back, plus `bin`, `libexec`, `share`) in a
  private work mount and moves it into place in one step; on any error
  nothing is mounted. The result is made private so unmounting it can never
  propagate to other modules' mounts. It is registered with KernelSU's
  umount list, so apps you set to "umount modules" don't see it.
- **Soft reboots**: each mount is recognized as the module's own by where
  its files come from (`/data/adb/modules*/openssh`), so only those are
  removed, each made private first so the unmount can't reach other mounts.
  A generation token in `/data/adb/openssh/run` retires old watchdogs.
- **`su`**: KernelSU applies its `/system/bin/su` hook only to processes it
  has marked, and processes started from module scripts aren't marked; the
  module marks the sshd listener (`ksud debug mark`) and every session
  inherits it.
- **Boot guard**: if three boots in a row don't complete with the module
  active, it disables itself. KernelSU/Magisk safe mode works too.

## Caveats

- Apps you set to "umount modules" in KernelSU don't see `/product/bin` or
  the custom mkshrc; adb, root shells and SSH sessions do. KernelSU only
  unmounts anything for apps after a module reports a mount (metamodules do
  this), so the module reports its own with `ksud kernel notify-module-mounted`.
  Whether apps without their own profile are unmounted is KernelSU's
  "umount modules by default" setting.
- `/data/root`, `/data/shell` and `/data/adb/openssh` are protected by
  Android's metadata encryption but not per-user file encryption. That is
  what lets sshd start before the first unlock.
- Developed on KernelSU (Galaxy S26 FE, Android 17). The SELinux rules are
  generated for the root manager's domain at install (`ksu`, `magisk`, ...);
  Magisk and APatch are expected to work but haven't been tested yet.
- No FIDO/U2F keys plugged into the phone (`*-sk` keys from your computer
  work fine).

## Uninstall

Removing the module stops sshd and removes its mounts (also on a soft
reboot). `/data/root`, `/data/shell`, `/data/home`
and `/data/adb/openssh` (host keys and config) are kept so a reinstall keeps
the same host identity; delete them by hand to remove everything.

## Building

Requires the Android NDK (r30 by default; set `ANDROID_NDK_ROOT`), autoconf,
automake, bison, perl, make, `tic` (ncurses) and `zip`.

```sh
git submodule update --init
./build.sh            # everything, then out/openssh-android-<ver>-arm64-v8a.zip
./build.sh openssh    # one component: zlib openssl ncurses openssh zsh bash rsync module
```

Submodules are never modified: each component is exported with `git archive`
into `build/` and patched from `patches/<component>/`.

## Licenses

The module scripts are MIT (see `LICENSE`). Bundled software keeps its own
license: OpenSSH (BSD), OpenSSL (Apache 2.0), zlib (zlib), ncurses (MIT),
zsh (MIT-style), bash and rsync (GPLv3).
