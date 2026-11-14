# Handoff (2026-11-12, before a reboot; updated after the agents finished)

Read this first in the next session. It says where everything stands.

## Before/after the reboot

1. `sudo systemctl mask tmp.mount`, then reboot: /tmp becomes a normal directory
   on the root disk instead of a RAM disk (it took up to 15 GB of RAM and
   pushed swap to 7.1/8 GB). After the reboot `findmnt /tmp` should print
   nothing (or the root filesystem). The root NVMe is 89% full (104 GB free):
   keep an eye on it.
2. `~/.bashrc` now sets `CLAUDE_CODE_TMPDIR=/stuff/tmp/claude`, so Claude Code's
   scratchpad and agent downloads go to /stuff (1.1 TB free). A new Claude Code
   session picks it up; the old scratchpad (in /tmp) is gone after the reboot.
   The Chimera cports checkout used for porting was there: re-clone it with
   `git clone --depth 1 https://github.com/chimera-linux/cports <scratchpad>/cports-full`.

## World

Not running. Claude Code killed it (low memory) at 261 packages built this
pass, while on openocd, openrc-settingsd, openshot. All 16 failures of that
pass have fixes committed but untested (list in git log since 88b01af).
`zig-out` is current (Gradle fixes) and `zig build test` passes;
`outdated --bump` was clean. Restart only when the user asks:

    DKBUILD_FAST_WORK=$HOME/.cache/dkbuild-work ./zig-out/bin/dkbuild world -P 3 --no-check --keep-going --color=always > work/world.log 2>&1; echo "world exit=$?" >> work/world.log

## Written today, not built

- htop 3.5.3, btop 1.4.8, bottom 0.15.0 (1f8cc10)
- gnome-online-accounts 3.58.1 + librest 0.10.2; GOA is an optional dependency
  of dkde: add `gnome-online-accounts-devel` to dkde's builddeps with the dkde
  release that uses it (7e648ac)
- chromium 157 (fetched, not built), electron 42 snapshot, typescript-go,
  rustc-dev, rust-wasm, xdg-utils, ast-grep (earlier today)

## Done after the handoff was first written (all committed, nothing pushed)

- **Recipes from four helper agents** (check + fetch pass, NOT built):
  dcb76ec (mail clients, desktop: 24 recipes), 89444ef (mail servers: 22),
  3b8404b (PHP/Perl web apps: 15), 30c5317 (Docker, Zabbix, Pi-hole, ...: 31).
  Blocked and not written: FileZilla, Netdata, Paperless-ngx, Mayan EDMS,
  Taiga, ERPNext, OpenProject, Twenty, Joplin; not planned: Frappe Books and
  Maybe Finance (archived). Reasons and 16 new questions for the user (4-19)
  are in docs/requests.md.
- **`dkbuild image --verbose`** (9f88da6): lists the packages and shows apk's
  Installing lines live.
- **Unmet so: dependencies** (cf18155), found by `image rescue` failing on
  libpulse-libs -> so:libpulsecommon-17.0.so. Scanner fixes (sibling private
  libraries, /usr/lib libraries without a soname) and release bumps that need
  building: libpulse r2, libproxy r2, tcl r2, tk r2, perl r10 (provides
  so:libperl.so), links r2, bsd-games r3, pipewire r10 (libjack in /usr/lib).
  Only pipewire's files change, so only what builds against pipewire rebuilds.
  The rescue image needs at least libpulse built:
      ./zig-out/bin/dkbuild pkg libpulse libproxy tcl tk perl links bsd-games pipewire
  (or the next world run). Still unmet: metasploit (prebuilt payloads),
  so:libc.musl-x86_64.so.1 (claude-code, bootstraps) - questions 18, 19.
- **`dkbuild prune`** ran: 1222 old packages removed (15 GB -> 11 GB, 3892 left).
- **`dkbuild upstream`** (967e7b3): reports newer upstream releases; overrides
  in upstream.toml; first run: 775 updates of 2100, 145 not checkable
  (`dkbuild upstream --all`). Daily notification: user units in
  contrib/systemd/ (not installed; the user enables them).

## Follow-ups after the user's answers (all committed)

- php 8.4.27 + php8.5 (663894e), FileZilla + libfilezilla + fzssh (fc7951e),
  commercial add-ons reviewed (c55f9ec, 8a5ef06: Stalwart enterprise and
  Stirling proprietary out - their licences forbid redistribution; Zabbix Java
  gateway built from source), ruby4.0 + OpenProject (see git log). New
  questions 20-23 in docs/requests.md. User policies: memory
  feedback-app-policies.

## 2026-11-13: everything requested is written (nothing built)

Brave, Euro-Office + Libera Suite, Proxmox VE, GHC/ShellCheck, the Haskell
programs on the new hackagedeps store, bashrs, brush, xmessage: all
committed (git log). zig-out has every dkbuild change (hackagedeps,
upstream, image --verbose, scan fixes, unique snapshot temp files);
`zig build test` passes; the whole tree checks (2254 recipes).
Questions 24-38 in docs/requests.md. pve-qemu's snapshot sha256: see git log
(filled in after its fetch).

## Android NDK from source (Claude's own task)

Plan and survey: wip/android-ndk/NOTES.md. Next steps:
1. `src/snapshot-android-ndk.sh` (+ entry in src/fetch.zig snapshot_scripts):
   sparse blob-less shallow clones of the repositories in NOTES.md at
   android-17.0.0_r1 plus platform/ndk at ndk-r30 and build/soong
   (cc/ndkstubgen, cc/symbolfile), widened to the module paths, packed
   reproducibly.
2. A generator (Python, in the recipe's files/) that reads the `ndk_headers` /
   `ndk_library` modules and installs headers, runs ndkstubgen per arch/API
   (21..37), compiles stubs and crt objects.
3. Recipes: android-ndk-sysroot, android-ndk-runtimes (compiler-rt, libunwind,
   libc++ per Android arch from the tree's LLVM), android-ndk (layout,
   wrappers, ndk-build, cmake toolchain, glslc link to shaderc).
4. Phase 2: static bionic (libc.a), simpleperf, lldb-server.
Survey checkouts: work/ndk/aosp.

## Still open (unchanged)

- Questions in docs/requests.md: Kerberos for curl (Heimdal vs MIT), ast-grep keep/drop.
- Brave (wip/brave/NOTES.md), Euro-Office, Proxmox VE after Chromium.
- Unwritten special cases: PDFium, Frida, Anki, OpenKiosk, Bitwarden desktop,
  Issie, RustDesk client (Flutter is glibc-only), KeePass 2 and gbrainy (Mono),
  epson escpr2 (source RPM), MatterControl (Windows-only).
- The old dotnet snapshot (10.0.114 seed) in cache/snapshots can be deleted.
- Nothing pushed.

## 2026-11-13, after the user's answers (requests.md "Answers")

Done and committed: noscan + musl-alpine-compat + metasploit r2, stalwart r2
(no SEL code), syncthing r2, git-annex r2, pydeps + python-lock, yarn-lock
(yarn 2+ via the npm store; tested on Joplin's lock).
Four helper agents stopped part-way (login error); the user said to skip
them for now. Their unfinished work is in `git stash list` ("unfinished
agent work 2026-11-13"): Brave keys/Leo licence, Euro-Office unbundling +
fonts, legacy OVMF, ifupdown2/FRR/libyang/rtrlib + pvenetcommit, PBS client,
erlang/elixir/rabbitmq-server, grpc + Zabbix APM. None of it checked yet.
Next with the new stores: Paperless-ngx, Mayan EDMS, Taiga, ERPNext (pydeps),
Twenty, Joplin (yarn-lock).

## 2026-11-14: world runs 1-3, fixes, new packages (nothing pushed; master = new-build-machine)

**World runs.** Run 1: 45 failed / 660 skipped. Run 2: 28 failed (libcamera blocked
654 skipped). Run 3 (started 16:14, `--color=never`; later runs use
`--color=always`, read with `less -R`) was still going: its 596-package skip was one
failure, libvisual-plugins (po/Makefile top_builddir; gst-plugins-base needs it), fixed
in r3. Run 4 has NOT been started: the user starts it. Every fix below is untested until
run 4. A hung compile (dovecot's test-json-generator.c, clang -O2) was killed by hand;
dovecot r2 builds that file at -O0 first (not confirmed to avoid the hang).

**Fixed (committed, untested):** libcamera r3 (install loop exit status), btop, kronosnet,
libfilezilla r4, libobjc2, opensp, libmodbus, indi, imhex, open-isns, mariadb r3 (PCDIR),
gcc r2, ruby4.0, perl-authen-pam/xml-sax, opensmtpd, libmemcached-awesome r3, vectorscan,
thin-provisioning-tools, tini, ghc r4 (hsc2hs response file `--target=`), python-jpype1,
libpathrs, stalwart r3, the Gradle ones (dkbuild sets -Dorg.gradle.native=false; ghidra
flat repo patch, geogebra pin, logisim checkstyle, coulomb, zaproxy add-ons, stirling),
dart, dotnet r5 (stub liblttng-ust-tracepoint for the seed SDK), euro-office-v8,
euro-office-core r2 (third-party sources), gdevelop r4, jogamp r4, listmonk, vikunja,
uptime-kuma, scratch-desktop, pi-hole, kismet r4, libofx r3 (libxml++2 new, auto_ptr shim),
moby, rspamd (!lto, unconfirmed), exim, gnustep-base, the Proxmox Rust ones.

**New recipes:** base-devel (LLVM, zig, Rust, nasm, yasm, cmake, autotools, ...), yasm,
rust-bootstrap + `rust` built from source against llvm22 (selfhost; rust-wasm and
rustc-dev are now part of it; WASI targets need a wasi-libc package that does not exist),
24 FFmpeg libraries (opencore-amr, vo-amrwbenc, libilbc, codec2, kvazaar, libvmaf,
libaribcaption, libaribb24, zeromq, libvpl, libudfread, mujs, flite, shine, quirc,
rabbitmq-c, vvenc, xavs2, davs2, uavs3d, svt-jpeg-xs, oapv, libdc1394, libraw1394,
libiec61883, libavc1394), whisper.cpp (private ggml under /usr/lib/whisper.cpp), ffmpeg r8
and mpv r5 with everything on (left off: chromaprint and opencv, which depend on ffmpeg;
OSS; celt), sox-ng r3 (ffmpeg, AMR), dkman 0.5.0 (-Dinstall-as-man), dkconsole 0.2.0,
dkde 0.2.0, greetd 0.10.3, and dkde's optional dependencies (brightnessctl, qt6ct, kvantum,
swaylock, tmux, webp-pixbuf-loader, papirus-icon-theme, gnome-online-accounts-gtk,
f2fs-tools, jfsutils, reiserfsprogs, nilfs-utils, udftools, fatresize). Not packaged:
qt5ct (no Qt5), hfsprogs (no portable source), waylock, gtklock.
desktop-dkde r4 pulls them all in (policy: optional deps are runtime deps). gvfs r2 has
the GOA/OneDrive/Google backends on; dkde depends on gvfs, gnome-online-accounts and
NetworkManager.

**Image tool (src/image.zig, SPEC section 8):** `issue` (writes /etc/issue), `console`
("agetty"|"dkconsole": tty1-5 on dkconsole, tty6 and serial stay agetty; the autologin VT
stays agetty), `login` ("console"|"greetd": greetd initial_session for autologin; nullok
PAM file only when a user has an empty password), `unwanted` (apk `!name`). images/dkde.toml
boots through greetd on VT 7 with NetworkManager, no base-net, unwanted dhcpcd.

**Open / watch:** the Rust source build and the FFmpeg libraries are the biggest untested
chains; xavs2/davs2/libdc1394 may not build; VT 7 for greetd and dkde-session as an
initial_session are unconfirmed; `dkbuild upstream` for brush now follows brush-shell tags.
Uncommitted on purpose: images/rescue.toml.save (the user's editor backup).
