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

The fixes were made in a temporary clone on the home drive, deleted on 2026-11-27; work from `/stuff/git/dkbuild`.
The build directories are links to /mnt/dkbuild again, but `tests/` writes its trees on /stuff, where sandboxes once
sat for 10 to 25 minutes flushing to disk (2026-11-25): the test suite may be slow or seem stuck there. Run from
/stuff on 2026-11-27 it passed, in 31 minutes.

## 2026-11-27: `-libs` depends on its main package; repository ISO tried

- New in dkbuild (SPEC.md 5.7): `-libs` depends on the main package when that holds files the libraries could need.
  `!libs-main` opts out (llvm, libtool, ffmpeg, cups, unbound, mariadb, postgresql). By a survey of the repo, 301 of
  580 packages with a `-libs` gain it (before the opt-outs), **only once rebuilt**. `tests/libs-main.sh`; the full
  suite passed before the opt-out recipe edits (31 minutes from /stuff).
- Both dkde-devel images also list sane-backends, libheif, libmbim, libqmi and openal-soft. Keep the long list of
  main packages there until an image of rebuilt packages works without it, then trim it.
- A rebuild from an empty repository can publish changed packages under the same release. Tried with dummy packages:
  `apk upgrade` skips those; `apk upgrade --available` takes them and their new dependencies (it can also downgrade:
  `--simulate` first; not tried with real rebuilt packages or an incomplete repository).
- `out/fenriros-repo-test/fenriros-repo-test.iso`: a repository disc made from the recipes of 82c91d37 (they match
  the builds), without 13 recipes never rebuilt at their version. On an unpacked dkde-devel system (not booted):
  `import.sh`, `apk update` and adding the five packages above worked. Today's recipes would leave 94 recipes out.
- The `useradd` warning about /usr/bin/nologin in image logs: shadow r7 lacks the link; r8 has it (not built).

## 2026-11-27: the development toolchain, and stage 2 step 1

- Compile tests in the unpacked `out/dkde-devel-cli` ISO (not booted; the desktop ISO's log lists the same missing
  packages): zig and a plain C program with `gcc-15` worked. clang, clang++, CMake, rustc, cargo, static links and
  anything linking `-lm` failed (`g++-15` too). `base-devel` lacked llvm-libcxx-devel; musl's empty `libm.a` and
  the like were in musl-static; libc++.a and libunwind.a in llvm-static; there was no `cc` or `c++`; `rust` did not
  depend on `rust-libs`, which held the one link rustc loads its library by.
- Fixed in the recipes, **none built**: `base-devel` r3 lists musl-static, llvm-libcxx-devel and the new
  llvm-libcxx-static; musl r6 has the empty archives in musl-devel; llvm (r8) has `cc` and `c++` in llvm-clang;
  rust r8 `replaces` rust-libs. dkbuild: a link no longer goes into `-libs` without the file it leads to (only
  rust was affected, of 580), and a build root gets what a `-static` depends on. The ISOs need rebuilding after
  the packages.
- On a system installed from the old images: `apk add llvm-libcxx-devel musl-static llvm-static rust-libs`, then
  `ln -s clang /usr/bin/cc` and `ln -s clang++ /usr/bin/c++` (tried in the unpacked ISO). `g++-15` programs need
  `-static` or `-Wl,-rpath,/usr/lib/gcc15/lib`, as the gcc recipe says. With dummy packages: after the rebuild,
  an upgrade that left an old musl-static in place beside the new musl-devel stopped on a file conflict; upgrading
  both worked. So upgrade the whole system.
- Stage 2 step 1: `dkbuild image images/container-build.toml` and `bootstrap-root --dest` work unchanged, tried in
  `/mnt/dkbuild/stage2-tree` (its `repo/` and `rootfs/dkrescue` are links to the real ones). The root made from
  today's packages passes `bootstrap-root`'s check, runs zig and takes `apk add` over it, but cannot compile C
  until the packages above are rebuilt. It also lacks `file`, `unzip`, `bzip2`, `ps`, `getconf` and `ld`: not yet
  decided which belong in `base-devel`.

## 2026-11-27: the dkde-devel ISOs made again "for now"; the uncle's boot problems

- Both `out/dkde-devel*/*.iso` (made 09:24 and 09:26; sha256 `e7df778c...52bf` desktop, `2b78d8d8...7c1f` cli): every
  main package whose -libs is there, the toolchain packages above, and tree (new recipe, built by the user). Checked
  unpacked, **not booted**: the compilers (cc, c++, gcc-15, rustc, cargo, zig, CMake), tree, the boot files,
  `dinit-check`, no -libs without its main package. The 2026-11-26 ISOs are kept in `/mnt/dkbuild/iso/*-final.iso`.
- **The tree's dkbuild does not make the same images:** they were made with a one-off copy
  (`/mnt/dkbuild/stage2-tree/dkbuild-cclinks`, only `src/image.zig` differs) that links `cc` and `c++` to clang and
  writes dinit-services r9's `early-filesystems.sh`, `auxfscheck` and `filesystems` over r8's. The temporary lines in
  the two image files, and the one-off, go once the packages are rebuilt (`rust-libs` will then not exist).
- Reported by the uncle, fixed in dinit-services r9 (not built): the boot fsck checked noauto and mounted entries
  (reproduced with `fsck -N`); early boot mounted without looking, and `/dev` under another source name than fstab's
  (`mount -a` then mounts again: reproduced with `mount -f`). `/run/dinitctl` missing: **cause not confirmed**; dinit
  only looks again after a `starts-rwfs` service, so `filesystems` has that option now. On a running system
  `kill -USR1 1` remakes the socket (from dinit's source, not tried). Wanted from him: `findmnt`, `/etc/fstab`,
  `ls -l /run/dinitctl`.
- `hwclock -s` times out on the uncle's BIOS machine too. dinit-services r9 and the one-off now run `hwclock.sh`,
  which tries `--directisa` after a failure. The uncle uses BIOS; **the UEFI problems found in QEMU wait until after
  the world rebuild** (docs/roadmap.md). The boot test scripts are in `/mnt/dkbuild/stage2-tree/qemu`.
- The ISOs were made again with that (09:55, 09:57; sha256 `b0920b8c...d92c` desktop, `cc8d9b25...02e8` cli; these
  replace the ones above). BIOS boots in QEMU: both ISOs, the cli also on q35: nothing mounted twice, /run/dinitctl
  there, no failed service, the desktop's programs run. The `--directisa` fallback was seen to work and set the time
  (i440fx, `rtc_cmos.use_acpi_alarm=1`, which reproduces the timeout). Installing was not tried. The full test suite
  passed before the later boot script and tree changes (24 ok, forgotten-dep skipped by design).
- Asked the uncle to try `rtc_cmos.use_acpi_alarm=0` once from the boot menu (a lead, not confirmed).
- He reinstalls from the new ISO. To update it later: a repository (disc, folder or server) of the rebuilt packages,
  `apk update`, `apk upgrade --available --simulate` first; then `apk del rust-libs`.
- Updates, agreed order: security fixes, then patch releases and the KDE sets, then GCC and chosen others, the rest
  after the rebuild. **LLVM is not to be updated now** (nor flang, clang-tools-extra and the others that share its
  version). `dkbuild upstream --refresh` gave 1129 results (work/upstream/report.txt); no recipe updated yet.

## 2026-11-27: the ISOs' boot loader was the build machine's; the uncle's flashing console

- **dkbuild bug, fixed:** `dkbuild image` ran a bare `dklilo`, so every ISO's boot loader was written
  by the DKRescue root's old one (0.0.1), whatever the image installed. At a BIOS menu its keyboard did nothing
  (reproduced in QEMU; dklilo 418b6bf, in 0.0.5, says it never worked and that disk read errors looked like
  success). It now runs the image's `/target/usr/sbin/dklilo` for `mkiso-images` and `isohybrid`. The UEFI
  `IoError` above was seen with the old loader; not tried since (UEFI waits).
- **New ISOs** (10:50, 10:52; replace all earlier ones): sha256 `f734547b...7c7f` desktop, `57441d9e...e921` cli.
  Package checks passed; BIOS menu Down+Enter boots the `-safe` entry (nomodeset) on both; normal BIOS boots good.
- **Open:** on the uncle's computer, with the previous CLI live ISO, the console flashes between blank and text, the
  login prompt over and over, on other ttys too, and something "looks like" a greeter. Cause unknown; not seen in
  QEMU. The CLI ISO's files enable no greetd and nothing there depends on it. To do: try the `-safe` entry; if it
  still happens, get the ISO's sha256, a photo or video, the graphics hardware, and whether the 2026-11-26 final ISO
  does it too.

## 2026-11-27: security updates, first batch (48 recipes; none built)

- Method: Alpine's secdb (secdb.alpinelinux.org/edge, main and community) matched by recipe name against our versions:
  62 recipes with a fix in a newer version, 17 where Alpine patched our version. Leads, not proof; recipes Alpine names
  otherwise or does not package are not covered.
- Updated, in series where possible (gstreamer 1.28.9, samba 4.23.13, django 5.2.19, libpcap 1.10.7, mbedtls 3.6.8,
  libssh 0.11.5, ruby 3.4.13, valkey 9.1.4; openjdk the `+2` releases, with `--with-version-build=2`; util-linux went
  to 2.42.4, mostly to a version at or past Alpine's fix). Checked: sources fetched, patches apply, source edits still
  match, license files present. **Not built**: configure and compile changes show only in the rebuild.
- **Not confirmed fixed** (not named in the new release's own notes): mbedtls CVE-2026-50580, -90471; libssh
  CVE-2026-59842, -59851; ruby CVE-2026-80212, -80213 (ruby-lang.org names the other four of Alpine's six as fixed
  already in 3.4.12). For the rest, the new version is at or past the one Alpine says holds the fix.
- **Left:** the 17 same-version patches (openssl, sudo, libssh2, avahi, qt6-qtwebengine, ...), and updates that change
  series: ffmpeg 9, incus 7, mbedtls 4, pkgconf 3, giflib 6, gzip 1.15, patch 2.8, gpgme 2.3, libraw, libcdio,
  libvpx 1.16, opencc, uriparser 1.0 and others in Alpine's list that this batch does not name.

## 2026-11-27: security updates, second batch: the "same version" cases (15 recipes; none built)

- Security patches from Alpine added to openssl, libssh2, sudo, libsndfile, openjpeg, rapidjson, tinyxml, heimdal,
  unzip (zip bomb parts 4-7 and its switch), and from its 3.23-stable branch to avahi, giflib and busybox; opusfile's
  from the xiph commit Alpine uses. perl to 5.40.5, patch to 2.8.1. Each patch applies without fuzz after the
  recipe's own, to the cached source; each recipe says where its patches came from. musl already had both fixes.
- Heimdal's CVE-2018-16860 patch applied cleanly **onto a source that already had the fix** and was left out. After
  adding a patch, look for its added code in the unpatched file: applying proves nothing by itself.
- **Open:** avahi CVE-2025-68276, -68468, -68471, CVE-2026-24401, -34933 (not in 3.23's set); unzip CVE-2021-4217,
  CVE-2022-0529, -0530 (Alpine's patches do not apply after ours), and its CVE-2015-7696, -7697 not looked at;
  qt6-qtwebengine's list (not looked at); giflib's two fixed only in 6.x.

## 2026-11-27: Incus 7.7.0, for its security fixes (not built)

- The user: upgrade where the security problems are major; hold ffmpeg 9. GitHub's published advisories for lxc/incus
  read that day: 116, every one with 7.7.0 or earlier among its fixed versions; most are fixed only in 7.x. No 6.x
  release that fixes them all was found.
- Needs Linux 6.12, LXC 6.0, QEMU 8.2, nftables 1.0, dnsmasq 2.90 (met). The recipe now makes the translation
  catalogs first (7.x embeds them; the tarball has none) and leaves the generate-* developer tools out. A 6.x
  server's database is upgraded for good on first start; lxd-to-incus is gone. incus-ui is still 0.22.1: not
  checked against 7.7.

## 2026-11-27: ffmpeg stays on 8.x (held, the user's decision; 9.0 not taken)

- None of the seven CVEs Alpine lists as fixed in 9.0.2 is open in our 8.1.3: ffmpeg.org/security lists
  CVE-2026-30999 as fixed in 8.1.2, and the fix commits it names for the other six (listed under 9.0) reverse-apply
  cleanly to the 8.1.3 source, so their changes are in it. Only those seven were looked at.
- ffmpeg builds against samba (`--enable-libsmbclient`), not the other way round; samba went to 4.23.13 on this day,
  so the rebuild is the first test of that pair. The user: ffmpeg was a pain to get built with it.

## `wallet-engine`'s cached dependency list: nothing to do

An earlier note asked for `cache/cargodeps/45d22ed4...da2.list` to be deleted by hand: it was uniffi-bindgen-cpp's
list under the name wallet-engine uses (BC-06; the two share a source). On 2026-11-27 the file was already gone (when
and why is not recorded). Only its `.config.toml` was left, which the next fetch overwrites: without the list,
wallet-engine's dependencies are fetched afresh. Not tried.

# Earlier: Handoff (2026-11-25, build tree on the new drive)

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
