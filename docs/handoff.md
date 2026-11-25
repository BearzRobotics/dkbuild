# Handoff (2026-11-24, before installing new disks)

Read this section first. The sections below it are older history.

## State right now

- **World is stopped** (stopped on request during pass 6). Nothing of ours should be running; check with
  `pgrep -af 'worldloop|dkbuild'`. Branch `new-build-machine`, about 580 commits ahead of origin: **nothing is pushed**.
- Pass 4 ended with 178 failures. Pass 5 was stopped after 11 failures, pass 6 early. Many recipe fixes committed since
  are **untested**. Of 478 recipes added since 2026-11-16, 314 had an apk and 164 did not (75 of those had failed in
  pass 4 or 5, 89 had not been attempted).
- **New ISO** (not booted): `out/dkde-devel/dkde-devel.iso`, archived as
  `/mnt/scratch/iso-archive/dkde-devel-20261124-1856.iso` (read-only, with .sha256; the directory is read-only too:
  `chmod u+w` it to add a file). SHA-256 c4398db5357a2dce6698a3a29a72d209783901320d07c9d7fddcae4f1b91ff47.
  It has firefox, grub + grub-i386-pc and dkinstaller 0.0.6. The ISO itself boots with dklilo; GRUB is a choice in
  the installer. **GRUB r6 has no recorded boot test** (the clang-built one installed fine and did not boot).
  The user's uncle will use this ISO. The 16 November dkde-devel ISO was replaced and not archived; the
  20 November one is in the archive.

## Standing orders (also in Claude's memory, project-standing-orders-2026-11-19)

- Keep running `world --keep-going`, fix failures as they come, restart world if it ends or crashes while packages
  remain. A package that cannot be built goes in docs/unbuildable.md, after real fixes were tried.
- No QEMU boots; do not push, release or publish; do not touch other repositories, sessions or processes.
- Upstream sources and build scripts are edited only with `sed` or a `.patch`, each explained in the recipe.
  Features are switched off only with a reason (recipe and docs/disabled-features.md).
- Daily-driver apps still pending: brave, code-oss, kdenlive (and electron, which several apps need).

## Starting world again

    setsid nohup contrib/worldloop.sh >/dev/null 2>&1 &

It continues the pass numbering. Watch `work/worldloop.log` and the newest `work/world<n>.log`. Also watch for silent
hangs (load under 1 and a quiet log): one `pnpm install` once hung for 7 hours. docs/recipe-brief.md is the brief for
recipe-writing helper agents.

## Image builds

`./zig-out/bin/dkbuild image --verbose images/dkde-devel.toml`. On the saturated /stuff disk it crawled (each fsync
waited minutes for a btrfs commit). It ran in about 2 minutes from a temporary tree on the SSD,
`/mnt/scratch/dkbuild/imgtree` (links to images, packages, keys, rootfs, cache and repo; real work/ and out/), run
from inside that tree. The tree can be deleted. With the whole build tree on the new NVMe it is not needed.

## Open

- **audacity:** configure downloads dependencies (muse_deps). Not fixed. Plan: `-DEXTDEPS_OVERRIDE_ALL=SYSTEM`, and
  the source-only deps (muse_deps/recipes/*/spec.cmake has URLs and sha256) as sources, placed in the extdeps
  download cache (`$HOME/.cache/extdeps/downloads/<name>/`).
- **pc:libpng:** the user asked whether "apk add can't resolve pc:libpng although libpng is in the repo" was fixed.
  No record of it was found; where it happened is not known yet; not investigated further.
- **ghc:** diagnostics added in r8, not yet read. **dotnet** r8: NU1109 (Newtonsoft.Json). **euro-office-documentserver**
  r7: unconfirmed. **emacs** libgccjit: config.log tail added. **qt6-qtwebengine:** may have more libc++ errors.
- **onnxruntime:** its GitHub repository answered 404 (blocks calibre speech, fastembed, rapidocr, mineru). Recheck.
- **zig-ide** (new), 0ad, helix, hetty, hexchat, heaptrack, sdbus-cpp, ibus, libdbusmenu,
  ayatana-indicator-datetime: fixed or written, untested.
- `zed.toml` in the top directory is an untracked stray (a copy of Zed's Cargo manifest); delete if nobody wants it.

## Disks (before the change)

| Disk | Size and type | Use |
|---|---|---|
| nvme0n1 (Samsung 990 EVO Plus) | 1 TB NVMe | / and /boot/efi, 86% full |
| sda | 500 GB SATA SSD, **ext2** (no journal) | /mnt/scratch: repo, logs, fast work, ISO archive, other data (enwiki 109 GB, ...) |
| sdb (ST4000DM004) | 4 TB SMR hard disk, btrfs | /stuff: git trees, source cache, work, out |

`repo/x86_64` and `logs/x86_64` are links into `/mnt/scratch/dkbuild/`. Sizes: repo 24 GB, logs 3.8 GB, source
tarballs 68 GB (the other cache/ stores were not measured), fast work 5.4 GB.

## Moving to the new 2 TB NVMe (proposed, not done)

1. **Before opening the case:** back up the git history (it exists only on /stuff), `~/.config/dkbuild/signing.rsa`
   (the repository signing key; only keys/*.pub is in the tree) and `~/.claude/projects/-stuff-git-dkbuild/`.
2. Identify the new disks by size and serial (`lsblk -o NAME,SIZE,MODEL,SERIAL`) before any mkfs: device names can
   change when disks are added. /etc/fstab uses UUIDs and a label, so existing mounts should not care.
3. `mkfs.ext4 -L build` on the new NVMe partition; mount with `noatime,nofail` at e.g. /mnt/build; fstrim.timer on.
4. Move the whole tree (cache, repo, logs, work, rootfs, keys, out, .git), turning the two links back into real
   directories (`rsync -aHAX`, world stopped). Keep the path /stuff/git/dkbuild working (a bind mount of
   /mnt/build/dkbuild there): Claude's memory and session are filed under that path, and nothing then needs checking
   for old absolute paths. The bind mount needs an fstab line ordered after both file systems.
5. Run with `DKBUILD_FAST_WORK=""` (build roots then live in work/ on the NVMe).
6. First checks: `zig build test`, `./zig-out/bin/dkbuild check`, `./zig-out/bin/dkbuild outdated` (it must not ask
   to rebuild everything), one small `dkbuild pkg`, then start the loop.
7. New 4 TB drive: backups (git, signing key, ISO archive, a copy of repo/ and of cache/sources; some upstream
   sources disappear, as onnxruntime's did).

---

# Handoff (2026-11-12, before a reboot; updated after the agents finished)

The project roadmap is docs/roadmap.md (rewritten 2026-11-13 to match reality).

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

Run 3 was started 2026-11-13 16:14 (`--color=never`, log work/world3.log) and was
still running at 20:24; run 4 has not been started. Older note: Claude Code killed
an earlier pass (low memory) at 261 packages built, while on openocd, openrc-settingsd, openshot. All 16 failures of that
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

## 2026-11-13: world runs 1-3, fixes, new packages (nothing pushed; master = new-build-machine)

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
PAM file only when a user has an empty password), `seat` ("seatd"|"elogind": with greetd, "elogind"
makes greetd wait for elogind and adds pam_elogind to its PAM file; the image lists the elogind package and
service itself; used by dkde-devel so Shut Down needs no password), `unwanted` (apk `!name`). images/dkde.toml
boots through greetd on VT 7 with NetworkManager, no base-net, unwanted dhcpcd.

**Open / watch:** the Rust source build and the FFmpeg libraries are the biggest untested
chains; xavs2/davs2/libdc1394 may not build; VT 7 for greetd and dkde-session as an
initial_session are unconfirmed; `dkbuild upstream` for brush now follows brush-shell tags.
Uncommitted on purpose: images/rescue.toml.save (the user's editor backup).

## Recipe script gotchas (2026-11-22)

- The recipe macro expander turns every `%%` into one `%`, wherever it stands (src/macro.zig): shell's longest-suffix removal
  `${x%%pat}` reaches the build script as the shortest one, `${x%pat}`. The two agree only when the pattern can match once
  (`${b%%:*}` on `name:js`); with a pattern that can match twice they differ (betterbird's series lines `## patch  ## comment`
  came out as `## patch  #`). Use `sed` or `cut` in recipes, or `${x%${x#?}}`-style tricks that need no `%%`. `${x##pat}`
  is not affected.
- Scripts run under dash: no `${x/a/b}`, no `[[ ]]`, no arrays; quotes inside a variable that is expanded unquoted
  (`MUOPTS='LD="a b"'`) are literal characters.
