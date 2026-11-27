# Handoff (2026-11-27, the audit's fixes and the other session's work are merged)

Read this section first.

## What changed

An audit of dkbuild, its tests and the recipes found about 124 distinct problems; all are fixed on
`new-build-machine`, one commit or small group at a time (`docs/bugs/`, ignored by git, has the reports and
`PROGRESS.md` what each fix was checked with). SPEC.md, the manpage and docs/install.md describe the new behaviour.

Behaviour that is new:
- `pkg` builds more: whatever goes into the build root of anything it builds.
- One `pkg`, `world` or `prune` per tree at a time. `prune` refuses while anything fetches or builds, or when a
  recipe does not load.
- A repository disc stops on recipes with only older packages (`unbuilt = "skip"`); `import.sh` wants a trusted key.
- `import-cbuild` replaces a draft only with `--force`.
- Snapshot scripts run in the sandbox (Brave's and Electron's need `nodejs` built first).
- Library interfaces include symbol versions; input hashes include links and executable bits. Old records are still
  accepted.
- Snapshot pins of brave, electron, dotnet and dart name full commits and checksums: update them with the version.

## Not verified

- **Most changed recipes are not built.** A test build in a scratch tree built the packages for fusermount3's setuid
  bit, the new pc: provides, cglm, links, openvpn, screen, mandoc, cpio, dialog, lpeg, cronie, dbus, shadow,
  policycoreutils, nethack and ggrep (their contents were not inspected one by one). `bsd-games` failed there; its
  fix has not been built. `rpi-imager` (new) is not built. Firefox, thunderbird and betterbird no longer pass
  `--disable-hardening`: if one of them now fails, look there first.
- No real disc set was made or imported. No real Gradle, Maven or NuGet restore ran.
- Of the snapshots, only git ones were remade (six, all matching); brave, dart, dotnet, electron, euro-office and
  scratch-media were not. .NET's `prep-source-build` still downloads things dkbuild does not pin.
- `contrib/worldloop.sh` was not run. Entries already in the crate, Zig, Maven and NuGet stores are not re-checked.

## Next

1. **Full rebuild from an empty repository** (planned): back up `repo/` first, no `--force`. Before it,
   `dkbuild upstream --refresh` and bring in updates: security first, no pre-releases, hold major toolchain and
   language versions, OpenSSL stays on 3.5 LTS, linux-headers follows the kernel.
2. Profile-wide hardening flags (stack protector, full RELRO) rebuild everything, so the full rebuild is the time to
   decide on them. So far only the packages with setuid programs have them.
3. After the release: a base image generated from our own repository, then stage 2 build roots (docs/roadmap.md).

## The merge and the checkout on /stuff

On 2026-11-27 all of the other session's commits (up to its 82c91d37: grub, dklilo, dkinstaller, the dkde-devel and
dkde-devel-cli images, firefox 161, install triggers for the glib, mime and desktop caches) were replayed onto
`new-build-machine`, and `/stuff/git/dkbuild` was moved to it. Its old state is the local branch
`backup/before-audit-merge-2026-11-27`. v0.0.1 does not include this merge. `tests/run-all.sh` passed on the merged
tree (one test skipped by design); `check` passed; `outdated` against the built records reports nothing.

- screen is r3: both sides had made an r2, and the built one lacks the audit's `files/screen.conf` fix.
- firefox is r2: the built r1 had `--disable-hardening`. It has not been built without it.
- `out/dkde-devel*/*.iso` (2026-11-26 evening) were built before the merge. Claude did not boot them. GRUB's boot
  test is in docs/packbug/grub.md.

Before `wallet-engine` is built with the new code, delete its old dependency list once (below).

# Earlier: Handoff (2026-11-25, bug fixing: the build directories are local for now)

## Work is in ~/dkbuild-bugfix for now

/stuff (a shingled desktop drive, btrfs) stalled while testing the fixes: sandboxes sat for 10 to 25 minutes flushing
to it. **The bug fixes are made in a clone, `~/dkbuild-bugfix` (home NVMe), with its own real build directories**;
there the tests take under a minute. `/stuff/git/dkbuild` is behind `origin/new-build-machine` until it is pulled (it
holds an uncommitted copy of the first fix, now committed: `git checkout src/sandbox.zig && rm tests/isolation.sh`
before pulling). The bug reports (`docs/bugs/`, ignored by git) are current in the clone only.

## After the bug fixes: one thing to do by hand in the real cache

`wallet-engine` and `uniffi-bindgen-cpp` share a source, and the cache's list for it is uniffi-bindgen-cpp's (BC-06,
fixed: lists are now named by everything that decides them). wallet-engine keeps the plain name, so before it is
built delete that list once (uniffi-bindgen-cpp then fetches or has already taken its own copy):

    rm /mnt/dkbuild/cache/cargodeps/45d22ed481dc4fab07390abfa811c095c424e11c745e87b9d0d27b40efa17da2.list

## Links removed while the bug fixes are made

So that fixing and testing cannot touch the repository or the built packages, these six links were replaced by
**real, local directories** on 2026-11-25. Nothing under /mnt/dkbuild was changed or removed.

| In the source tree | Was a link to |
|---|---|
| `repo/x86_64` | `/mnt/dkbuild/repo/x86_64` |
| `logs/x86_64` | `/mnt/dkbuild/logs/x86_64` |
| `cache` | `/mnt/dkbuild/cache` |
| `work` | `/mnt/dkbuild/work` |
| `rootfs` | `/mnt/dkbuild/rootfs` |
| `out` | `/mnt/dkbuild/out` |

The local `rootfs/dkrescue` was unpacked from `./dkrescue.iso`; everything else started empty. **To put the links
back** when the fixes are done (this deletes only the local, throwaway directories; check `ls -ld` shows real
directories first, and never add a trailing slash to a name that is already a link):

    for l in repo/x86_64 logs/x86_64 cache work rootfs out; do
        [ -L "$l" ] || { chmod -R u+rwX "$l"; rm -rf -- "$l"; ln -s "/mnt/dkbuild/$l" "$l"; }
    done

## Handoff (2026-11-25, build tree on the new drive)

Read this section first. The sections below it are older history.

## Layout now

The source (git tree) is in /stuff/git/dkbuild. The build tree and repository are on the new 2 TB NVMe, ext4, mounted
at **/mnt/dkbuild**. These are links in the source tree (.gitignore covers them):
`repo/x86_64`, `logs/x86_64`, `cache`, `work`, `rootfs`, `out` -> `/mnt/dkbuild/...`.

- Checked after the move: all 4595 files in cache/sources match their SHA-256 names; repo and logs matched the old
  copies by checksum; `zig build test`, `check`, `outdated` (nothing), `pkg sdbus-cpp libdbusmenu`, and an image of
  dkde-devel (1.5 minutes, run from the source tree) all worked. The other cache/ stores were copied by rsync without
  a second checksum pass.
- Not copied: the 86 old subdirectories of work/ (build roots and scratch checkouts), and one unreadable setuid helper
  in the old rootfs/dkrescue (image builds recreate it). The old directories are still on /stuff as `cache.old`,
  `work.old`, `rootfs.old` and `out.old` (ignored through .git/info/exclude). **Not deleted:** they can go when the
  user says so.
- /mnt/scratch: dkbuild's own folders (dkbuild/, dkbuild-work/) were removed after those checks. The other data there
  was left alone. iso-archive keeps the 20 November ISO and the good one (the broken 18:56 one was deleted); the
  directory is read-only (`chmod u+w` to change it).
- /etc/fstab still has `default,nofail 0 0` for /mnt/dkbuild; `defaults,noatime,nofail 0 2` was advised (needs root).
- The new 4 TB drive is not set up. Suggested use: backups (ISOs, a copy of repo/ and cache/sources, the signing key).
  Signing key backups, made 2026-11-25 (unencrypted; directory 0700, file 0600): `/mnt/dkbuild/dkbuild-key-backup/`
  and `/mnt/scratch/dkbuild-key-backup/`. Not on the 4 TB drive yet (root owns its file system) and deliberately not
  on /stuff (Samba shares it read-write, as the build user). All copies are in one machine: an encrypted copy on a
  drive kept offline is still wanted. A key kept elsewhere can be
  given with `--key FILE` (`discs` got it on 11-25; docs/setup-ubuntu.md, 8).

## /stuff

**/stuff (btrfs) lost its last writes in the 11-24 reboot** (files went back to about 18:36-18:55; GitHub had the
commits). Processes had been stuck waiting for commits, and the kernel logs "BTRFS error: incorrect extent count"
(11-20 and 11-24). Not diagnosed. Do not trust it with the only copy of anything; no `btrfs check --repair`.

## ISO

**Good ISO:** /mnt/dkbuild/iso/dkde-devel-20261124-2134.iso (also in /mnt/scratch/iso-archive), SHA-256
6ac1e86caa39f3e7ee98a2517bf37bd68d58ee04f77b12ff86008872d603cdf7. Fixed in elogind r7, polkit r7, dbus r7,
dinit-services r8. Tested in QEMU (BIOS, the disc's boot loader, standard VGA and virtio): desktop, login screen,
sign-in (X11 session), polkit answers. **2026-11-25: the user reports it booting on real hardware** (the machine and
what was tried on it are not recorded). Its live/rootfs.sfs unpacks completely with unsquashfs 4.7.5 (a "no valid
squashfs superblock" report: unsquashfs given the whole .iso prints exactly that). **Not tested:** VirtualBox, installing to a disk, GRUB (r6 has
no recorded boot test). The login screen preselects "dkde (X11, dkde-wm)" (dkde's choice; not changed).
out/dkde-devel/dkde-devel.iso is whatever the last image build made.

## Standing orders (also in Claude's memory, project-standing-orders-2026-11-19)

- **World is stopped at the user's request; this overrides the next point until they ask for builds again.**
- When world is wanted: keep running `world --keep-going`, fix failures as they come, restart it if it ends or
  crashes while packages remain. A package that cannot be built goes in docs/unbuildable.md, after real fixes were
  tried.
- No QEMU boots (the user allowed it for testing the 11-24 ISO); do not push, release or publish without being asked;
  do not touch other repositories, sessions or processes.
- Upstream sources and build scripts are edited only with `sed` or a `.patch`, each explained in the recipe.
  Features are switched off only with a reason (recipe and docs/disabled-features.md).
- Daily-driver apps still pending: brave, code-oss, kdenlive (and electron, which several apps need).

## World

**The user is busy fixing bugs in other projects (util-core among them) and will come back to building after that.**

**Stopped on 2026-11-25 (about 19:00) at the user's request, during pass 7 (it was building firefox). Do not start it
again until the user asks.** The repo was pruned afterwards (no stale packages; 27 packages that no recipe provides
were left in place: mostly the removed Xfce and old libopenraw and libgtop files, but also `rustc-dev`, `zfs-kmod` and
`postgresql-client-libs`, which should be understood before anyone deletes them; brave lists rustc-dev as a build
dependency).

How to start it, when asked:

    systemd-run --user --unit=dkworld --collect -p OOMPolicy=continue --working-directory="$PWD" \
        --setenv=PATH="$PATH" "$PWD/contrib/worldloop.sh"

Stop it with `systemctl --user stop dkworld`. It runs outside the terminal on purpose: on 2026-11-25 at 10:31 the OOM
killer took a 20 GB rustc (30 GB of RAM) and systemd stopped the whole terminal tab: world pass 6 and the Claude
session with it. The service still ends if the user logs out (lingering is off). firefox's gkrust needs the most
memory seen so far.

It continues after the highest pass number. Watch `work/worldloop.log` and the newest `work/world<n>.log`. Also watch
for silent hangs (load under 1 and a quiet log): one `pnpm install` once hung for 7 hours. Build roots are in work/
(DKBUILD_FAST_WORK is empty unless set). docs/recipe-brief.md is the brief for recipe-writing helper agents.

Distinct failures: pass 4, 182; pass 6, 60 (not finished: OOM); pass 7, 28 (stopped). Most recipe fixes committed on
11-25 have **not been built**: pass 7 read the recipes when it started.

## Image builds

`./zig-out/bin/dkbuild image --verbose images/dkde-devel.toml`

## Security updates of 2026-11-25 (recipes only: NOT built)

openssl 3.6.5, python 3.14.10, nginx 1.30.8, linux and linux-headers 7.3.6, firefox and thunderbird 161.0 (they need
nss >= 3.133: nss 3.134 and nspr 4.41), httpd 2.4.71, webkitgtk 2.54.3, gnutls 3.8.14, dbus 1.16.4, git 2.56.1,
exim 4.100.2, haproxy 3.4.8. Sources fetched; every patch of these recipes applies (firefox/thunderbird lfs64.patch
and gnutls no-mini-dtls-fragments.patch rebased onto changed context). Checksums matched published ones for openssl,
python, linux, git, firefox, thunderbird, httpd, webkitgtk, haproxy, nss and nspr; nginx and exim had good PGP
signatures (keys fetched from their own sites); gnutls and dbus were only downloaded over HTTPS. The D-Bus release
notes were not read (the site blocked the fetch).

- **openssl: decided 2026-11-25, now 3.5.9 (long-term, to 2030)**, not 3.6.5. Evidence: 3.6 added 23 libcrypto
  functions and removed none; a scan of the newest build of every package (261 link libcrypto/libssl) found only
  osslsigncode using one. In the build image only OpenSSL's own files do (and its loader_attic engine, which an
  openssl package laid over the image does not replace). Build roots take the recipe's exact version, so the lower
  number is safe there; **after building openssl, run `dkbuild prune` before making an image**, since apk would
  prefer the older-built, higher-numbered 3.6.1 still in repo/. A 24 Nov advisory (Low) names 3.5.10, which had no
  download tag on 11-25: update to it when it is out (the check is held to 3.5).
- **Toward OpenSSL 4:** the same scan against 4.1.0 (257 libcrypto and 19 libssl functions removed, mostly the
  ENGINE API) found 31 of the 261 packages using one in their current builds, among them curl, nginx, httpd, python,
  nodejs, postgresql libs, openvpn, wpa-supplicant, tor, cmake, python-cryptography, ruby. That is not a count of
  what would break (many projects leave ENGINE out when built against 4), and it misses source changes (ASN1_STRING
  opaque, const changes). Suggested route: aim for the next 4.x long-term release (April 2027 by upstream's
  schedule), after test-building those 31 against 4.x.
- linux-lts 6.18.65 was added to the batch (checksum matched kernel.org's); zfs and virtualbox modules follow it.
- `dkbuild upstream` no longer reports pre-releases without `prerelease = true` in upstream.toml. **The user chose
  to keep all current ones** (2026-11-25): libcaca, libmspack, simde, winlab (opted in there) and the 46 recipes on
  git snapshots (they stay on their commits; the check reports releases newer than them).

## Open

- **Failing packages:** the table under "Under investigation" in docs/unbuildable.md has the state of each (ghc,
  dotnet, euro-office-documentserver, electron, brave, dj64dev, emacs, fceux, lomiri-url-dispatcher, mattermost,
  pdfcraft). audacity, abiword (new package wv), aisleriot (guile r5), dia and others have fixes committed and untried.
- **Source discs (fixed 2026-11-25, src/discs.zig):** they now carry every dependency store; creating them no longer
  fails on harmless file names (the private-key check now compares contents with the signing key, plus the name
  signing.rsa), on apostrophes, or on cache/ and repo/ being links (that also affected repository discs). Tested on a
  tiny throwaway tree (source and repo disc, import.sh, key guard). **Not tested:** the real tree (about 1.75
  million store files, 58 GiB, plus 64 GiB of sources): one xorriso -map line per file and a MANIFEST of some
  hundreds of MB on every disc may be too slow or large; and no offline rebuild from a disc has been tried.
  `dkbuild doctor` still does not check for python3, go, cargo, zig or patch.
- **Other problems the docs audit found (nothing changed in code):**
  - src/image.zig writes the commented repository line `#@cdrom /mnt/cdrom/apks/<arch>/Packages.adb`, but
    src/discs.zig puts a disc's index under `/data/apks/<arch>/` (a unit test expects the image.zig form too).
  - packages/s/systemd-boot's gen-systemd-boot writes `root=UUID=`, which needs an initramfs; without one it boots
    only if `SD_BOOT_CMDLINE` gives `root=PARTUUID=` (docs/install.md says how). Not boot-tested.
  - dkinstaller 0.0.6 (read, not tested) leaves greetd's `initial_session`, the `nullok` PAM copy and the live
    /etc/issue in an installed system. With another user name the live user is deleted, so the leftover session names
    no account (what greetd then does is untested); if the chosen name is the live user's, it would probably be
    logged in without a password. Note for that project: /stuff/git/dkinstaller/docs/live-greetd-leftovers.md.
- **onnxruntime:** its GitHub repository answered 404 (blocks calibre speech, fastembed, rapidocr, mineru). Recheck.
- **NTFS drive not shown in dkde-file:** packaging looked complete from the build logs; not tested on a running
  system (see docs/requests.md). The dkde side is being looked at separately.
- **pc:libpng:** the user asked whether "apk add can't resolve pc:libpng although libpng is in the repo" was fixed.
  No record of it was found; where it happened is not known; not investigated further.
- **Never built:** zig-ide, 0ad, cmark-gfm, wv, howard-hinnant-date, and cmark r2.
- **ISO:** the user will test it in VirtualBox; GRUB on BIOS has never been tested (an offer to test it in QEMU was
  not answered).
- **Old directories:** work.old, rootfs.old and out.old were deleted on 2026-11-25; `cache.old` on /stuff is kept
  as a second copy of the downloaded sources until there is a real backup.
- Local commits are not pushed (`git log origin/new-build-machine..HEAD`).

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
