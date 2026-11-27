# Roadmap

Status as of 2026-11-25. "Built" means the repository holds an apk of the recipe's current version and release; it
does not mean the program was run or tested. Per-package requests are in `docs/requests.md`, current failures in
`docs/unbuildable.md`, the design in `SPEC.md`, the newest session state in `docs/handoff.md`.

Goal: a package set you define builds an image (ISO, disk image, rootfs). The
first target, rebuilding everything on the DKRescue boot disk
(`dkrescue.iso`, the stage 0 image) from recipes, is met; the tree now builds
much more than the disk ever had.

## Where we are

- 3188 recipes in `packages/`: 2809 built, 5 built only at an older version or release, 374 with no main package
  (many never reached, or waiting for one that fails). `repo/x86_64` holds 6852 apk files. 50 more recipes wait in
  `wip/queue`.
- World runs repeat with `--keep-going` (`contrib/worldloop.sh`). Distinct failures: pass 4, 182; pass 6, 60
  (stopped by running out of memory); pass 7, 28 (stopped on request on 2026-11-25). Many fixes are not yet built.
- The work is on branch `new-build-machine`, on GitHub; the newest commits may be unpushed.
- Live ISOs: `images/dkde-devel.toml` was rebuilt on 2026-11-24 and tested in QEMU (BIOS, the disc's boot loader):
  the desktop, the login screen, an X11 sign-in and polkit worked. It was not tested on UEFI, VirtualBox or
  hardware. The other live images were last boot-tested around 2026-11-13 and not since the later package changes.
- Only x86_64 is built. `profiles/aarch64.toml` and `riscv64.toml` exist, nothing more.

## Done milestones

- **B0**: recipe reader, `check`, `graph`; the whole tree checks.
- **B1**: native builds in the unprivileged sandbox, signed apks, signed index,
  dependency scanning (`so:`/`cmd:`/`pc:`), world builds with `-P N`,
  `--keep-going`, a fast work cache (`DKBUILD_FAST_WORK`).
- **Stage 0 replaced**: LLVM, musl, zig, base, kernel, dklilo, dksh, dkde,
  rescue tools, installer and initramfs are all built from recipes.
- **ISO output**: `dkbuild image` makes tar, squashfs, directory and hybrid
  BIOS+UEFI ISO (dklilo). Live ISOs use `live-initramfs`.
- **Package and source discs**: `dkbuild discs` (see below).

## Open milestones

- **B2, stage 2** (roots filled from `repo/` only, a comparison with stage 1, and
  the forgotten-dependency test): not implemented. `tests/forgotten-dep.sh`
  exists but is skipped until stage 2. `base-devel` is built.
  Agreed 2026-11-26, to be started after the audit bug fixes and the next release, once the packages that cannot
  be installed are fixed. In two steps:
  1. **A base image made from `repo/`.** `images/container-build.toml` and `bootstrap-root <tar>` look like the
     two halves; neither has been tried for this. Make them work reliably (perhaps as one command), in a separate
     tree so the working DKRescue root is not replaced. This finds many undeclared dependencies, but not those
     that `base-devel` already includes.
  2. **Stage 2 itself:** each build installs its declared dependencies from `repo/` with `apk add` (checked
     dependencies, install scripts run) instead of unpacking files over the base image.
  Step 1 was tried on 2026-11-27: both commands work, and found gaps in `base-devel` and the toolchain packages,
  fixed in the recipes and to be tried again once they are rebuilt (docs/handoff.md).
  Expect many recipes to fail until their dependencies are declared. Keep DKRescue as the fallback and the first
  bootstrap. Decide whether the base image's version is recorded with each package (changing it rebuilds nothing
  today). Fits before the planned rebuild from an empty repository.
- **UEFI, to sort out after the world rebuild** (the user, 2026-11-27; the uncle uses BIOS). Seen in QEMU with OVMF
  on the ISOs made that day:
  1. **dklilo sometimes cannot read the ISO.** `/boot/initrd.img: IoError` or `/boot/vmlinuz: IoError`, or no login
     prompt in 120 s: with the desktop ISO, the first full boot failed, a retry booted, and of 8 repeats 4 booted, 2
     gave IoError and 2 timed out. The ISO's checksum and boot files were right. The CLI ISO booted in its one full
     run; it and the older ISOs were not repeated. The host was heavily loaded (load about 17), not ruled out. The
     loader on an ISO is the **DKRescue image's** dklilo (`dklilo mkiso-images` runs there), not the repository's.
     The error comes from the firmware's BlockIo read (`src/uefi/main.zig`).
  2. **No RTC interrupt** under UEFI on both QEMU machine types (`HPET_emulated: no`, none counted on IRQ 8). The
     `hwclock` service gets by with `--directisa`; the cause is open, and not only UEFI's: the uncle's BIOS machine
     times out the same way. q35 under SeaBIOS worked. A lead, not confirmed: on i440fx under SeaBIOS (kernel loaded
     by QEMU, `-kernel`) the clock worked with `rtc_cmos.use_acpi_alarm=0` and with `hpet=disable`, and timed out
     with `rtc_cmos.use_acpi_alarm=1`. No option was tried under UEFI. RTC wake alarms may be affected too (not
     tried).
- **B3, images**: partly done. The live ISOs boot; the installed-system image
  (`images/fenriros.toml`) still outputs only a tar, and the checks SPEC 13
  attributes to DKRescue's `CONSTRAINTS.md` cannot be run because that file is
  not in this repository (verified: absent).
- **B4 aarch64, B5 riscv64**: profiles only; no cross base set, repo, image or
  boot test. aarch64 is the next large item (zig cc aarch64 cross-builds work).
- **qemu-user and binfmt_misc** (SPEC 14 item 5): open. `qemu` (11.0.1-r2) is not
  built.
- Small: ncurses' C++ binding (`libncurses++w`) is off; turn it on with `-lc++`
  when a package needs it.

## Images and installation

| Item | Status |
|---|---|
| Live ISOs: base (CLI), rescue (DKRescue's successor, with rescue-tools and base-devel), dkde (desktop through greetd) | written; booted in QEMU on UEFI and BIOS around 2026-11-13, not retested since |
| dkde-devel live ISO (with Firefox, GRUB for BIOS, the installer) | 2026-11-24 build tested in QEMU, BIOS only |
| `dkinstaller` 0.0.6 on the live ISOs | built; installation not verified end to end |
| Installed system on UEFI: systemd-boot, ext4 root, no initramfs | documented in docs/install.md (manual) |
| Installed system on BIOS (dklilo or GRUB) | documented in docs/install.md; neither is verified on FenrirOS; grub 2.12-r6 has no recorded boot test |
| Other root file systems (btrfs, XFS) for installs | open: they are modules; design for an installed-system initramfs, and for building them in, is in docs/initramfs.md (not implemented) |
| Containers: `images/container.toml`, `container-build.toml` | written |
| Packages on the install and rescue ISOs (`iso_repo`) | open: no image sets it yet |
| Package ISOs and source ISOs | done, see "dkbuild features" |

Image keys: `packages`, `exclude`, `unwanted` (apk `!name`), `services`, `users`,
`issue`, `console` (agetty or dkconsole), `login` (console or greetd),
`autologin`, `session`, `output`, `iso_repo`.

## Toolchains

- Built: LLVM 23.1.5 (the system toolchain), llvm22 (22.1.8, which the Rust build uses), zig 0.17.1, rust 1.99.1
  from source (seed `rust-bootstrap`), go 1.27, nodejs 26, openjdk, musl 1.2.6, gcc 15.2.0, dart 3.10.3,
  emscripten 6.0.3.
- Not built at the current release: dotnet 10 (an older release is built), ghc 9.14.1 (see docs/unbuildable.md).
- **GCC 15 is opt-in**: `/usr/lib/gcc15`, versioned drivers, all languages that
  do not conflict with LLVM's; a recipe asks for it with `options = ["gcc"]` (GNU
  binutils and GCC instead of clang). Stage 0 of GCC itself is built on Alpine's
  GCC. GCC cross suites (arm-none-eabi, aarch64-none-elf, riscv64-unknown-elf,
  avr) are written. GRUB uses `options = ["gcc"]`. Nothing else builds with GCC
  unless it opts in; C++ from GCC keeps its own libstdc++ apart from libc++.
- **Faster GCC upgrades** (planned, 2026-11-27; not started). Every build of gcc starts from Alpine's GCC and does the
  three-stage bootstrap, even when the repository has our own gcc. That is a workaround of ours, not a GCC rule: with
  the previous package as the seed, an Ada tool built during the build did not start (`Error relocating ./xsnamest:
  interfaces__c___elabs: symbol not found`, 2026-11-16, the recipe's r4). Probably a libgnat that does not match the
  tool, **not diagnosed**. The automatic `-libs` splitting is not involved: it came later, and gcc has no `-libs`
  package (libgnat is in gcc-ada).
  - First: reproduce the failure and find which libgnat is loaded; fix it.
  - Normal rebuilds and minor updates: our previous gcc as the seed. For the same version try `--disable-bootstrap`,
    testing Ada both ways. This drops the stage 2/3 comparison, so test the built compiler by other means.
  - Major upgrades, and a rebuild from an empty repository (Alpine's seed again): keep the full bootstrap.
- **Missing: WASI.** No `wasi-libc` package, so Rust's WASI targets do not work and
  Firefox's RLBox libraries are not wasm-sandboxed.
- **Android NDK from source**: planned, not started in code. Survey and steps are
  in `wip/android-ndk/NOTES.md` (a dkbuild snapshot of AOSP pieces, a generator
  for the stubs, then `android-ndk-sysroot`, `-runtimes`, `android-ndk`).
- **Rust in the kernel**: ready, off. The tree has `rust`, `rust-src` and
  `bindgen`; turning it on needs `hostdeps`, `CONFIG_RUST=y` and a release bump.

## Desktops

- **dkde** (default): dkde 0.3.5, dkconsole 0.2.0, dkman 0.6.0 (as `man`), greetd, NetworkManager, gvfs,
  firewalld, PAM and elogind; `desktop-dkde` pulls in the optional dependencies, `desktop-dkde-core` is the rescue
  set. Built; the live ISO reaches the desktop in QEMU. The login screen preselects the X11 session (dkde-wm).
- **Hyprland** 0.57 (`desktop-hyprland`), **labwc**, wayland, mesa, Xorg (`xserver-xorg` 21.1.24), Qt 6, GTK 3/4:
  built.
- **LXQt** (lxqt-panel 2.4.1) and **SDDM**: built. **Plasma 6.8**: written, plasma-workspace and plasma-desktop not
  built. **Xfce**: removed on 2026-11-16.
- **Lomiri**: recipes in `packages/` (moved from the queue); lomiri, mir and qtmir not built.
- XLibre and Phoenix are not packaged.

## Applications

Status words: built, written (not built), failing (last world run), blocked.
Details and per-package notes: `docs/requests.md` and `wip/`.

| Group | Built | Not built (recipe present unless said) |
|---|---|---|
| Shells, CLI, editors | zsh, fish, nushell, vim, gh, msedit, Kate, Zed, Helix, Micro, ttt | emacs, KDevelop, Zig IDE |
| AI | llama-cpp, ollama, whisper.cpp, claude-code, python-docling | llama-index; PyTorch recipe present, state not checked here |
| Web servers and PHP | nginx, caddy, PHP 8.4, Nextcloud, Forgejo, Gitea | |
| Virtualization and containers | ZFS (prebuilt per kernel), Incus, libvirt, moby (Docker), Proxmox VE (`proxmox-ve`, `pve-manager`) | qemu, podman |
| Browsers and mail | Firefox | Thunderbird, Betterbird, Brave; plain Chromium moved to `wip/queue` |
| Electron | | electron, Code - OSS |
| Office and OCR | Euro-Office core, Libera Suite, tesseract, ocrmypdf | LibreOffice, Euro-Office document server, Collabora core |
| Media and graphics | ffmpeg, mpv, OBS, GIMP, Inkscape, Krita | Kdenlive, Blender, Audacity |
| Games and emulators | Wine, dolphin-emu, fdpp | MAME, ScummVM, RetroArch, 0 A.D., dosemu2 (waits for dj64dev) |
| Electronics and CAD | avr-gcc, OpenOCD, ImHex | KiCad, FreeCAD |
| Security | metasploit, SELinux userspace and Red Hat's targeted policy (not tested on a running system) | ufw and SearXNG are only in `wip/queue` |
| Flatpak | flatpak | flatpak-builder |
| snapd | dropped: needs systemd (docs/decisions/0003-no-snapd.md) | |

## dkbuild features

- Dependency stores so that builds stay offline: Go, Rust (`cargodeps`), Zig, npm
  (`npmdeps`, yarn 2+ through `yarn-lock` with the `yarnberry` option, pnpm), Python (`pydeps`, `python-lock`),
  Gradle, NuGet, gems, Dart pub, Haskell (`hackagedeps`, `hackage-lock`).
- Snapshots (`src/scripts/snapshot-*.sh`) for projects whose checkout downloads as it
  builds: electron, brave, dart, dotnet, euro-office and others. `snapshot-android-ndk` is
  planned.
- `selfhost` and `stage0deps` (a toolchain built with a seed, then with itself);
  `noscan`, `!repo-iso`, `@built` subpackage dependencies, `options = ["gcc"]`.
- `dkbuild upstream` (newer upstream releases; `upstream.toml` overrides; units in
  `contrib/systemd/` that the user enables), `outdated [--bump]`, `prune`.
- `dkbuild discs`: repository and source ISOs (`images/repo.toml`,
  `images/source.toml`), one image (`--media usb`) or sets for cd to bd100, each
  disc with a signed MANIFEST and `import.sh`. Tested on a 4-CD set.
  `!repo-iso` keeps a package off the repository disc.
- `import-cbuild` converts Chimera templates. A Solus `package.yml` importer was
  dropped: recipes come from Chimera's templates and Alpine's packaging.
- `image --verbose`, `world --keep-going`, `--tree DIR`.
- Tests: `tests/run-all.sh`, `tests/qemu-iso.sh`.
- The build tree and repository can live on another disk through links (the build machine uses `/mnt/dkbuild`);
  `contrib/worldloop.sh` runs world passes as a systemd user unit.
- Open: dkbuild takes no lock on the repository, so two builds at once can damage its index.

## Blocked and unwritten

- Blocked or not written: Netdata, Cockpit (needs systemd). Paperless-ngx, Mayan EDMS, Taiga, ERPNext, Twenty and
  Joplin are unblocked by `pydeps` and `yarn-lock` but not yet written.
- Unwritten special cases (reasons in `wip/README.md`; PDFium now has a recipe that packages a prebuilt library): Frida, Anki,
  OpenKiosk, Bitwarden desktop, Issie, RustDesk client (Flutter is glibc-only),
  KeePass 2 and gbrainy (Mono), epson escpr2 (source RPM), MatterControl.
- Not planned: Frappe Books and Maybe Finance (archived).
- Not packaged: qt5ct (Qt 5 itself is in the tree now), hfsprogs, waylock, gtklock.
- Unfinished helper work is in `git stash list` ("unfinished agent work
  2026-11-13"): Brave keys and Leo licence, Euro-Office unbundling, legacy OVMF,
  ifupdown2/FRR, PBS client, Erlang/Elixir/RabbitMQ, grpc and Zabbix APM.

## Policies and decisions

- **Inert server packages**: no enabled service, no default credentials, no active
  web site, port or cron job; configuration ships as samples
  (`docs/requests.md`). App-created default logins are acceptable; commercial
  add-ons are included unless the licence forbids redistribution.
- **Static libraries**: every library also ships a `-static` package; never
  `--disable-static` without a stated reason.
- **Build libraries, not disables**: package an optional library instead of
  configuring the feature off, unless there is a reason.
- **Optional dependencies are runtime dependencies on the desktop**
  (`desktop-dkde`).
- **Offline builds**: network only at fetch time; vendor or pin anything a build
  would download.
- **Documented source edits**: `sed` or a `.patch`, but every change is explained
  in the recipe. Editing a built recipe, even a comment, marks it as changed (`dkbuild outdated`).
- **Builds**: Claude runs world and repairs failures when the user asks for that (standing orders in
  docs/handoff.md); since the evening of 2026-11-25 building is stopped until the user asks.
- **GCC exception**: LLVM is the toolchain; GCC only where a recipe opts in.
- **Rust**: a seed compiler is enough (the mrustc chain is out of scope); the
  system `rust` and `zig` are for building packages, users get rustup.
- **Boot**: dklilo for live ISOs, systemd-boot for installed UEFI systems.
- Work order of 2026-11-11: virtualization, then low-level optional features, then
  the Electron family, then Brave and Euro-Office.

## Long term

- **aarch64 and riscv64**: cross base set, repos, images, boot tests; then
  ppc64le, loongarch64, armv7, i686, s390x as LLVM builds them. A bootloader for
  them is open (dklilo covers x86_64 live media only).
- **Clean-rebuild test**: when all packages build, back up `repo/` and rebuild
  everything from an empty repo (stage 0 seeds allowed), then compare.
- **Source-ISO rebuild test**: rebuild from `images/source.toml`'s discs with no
  network.
- **Packages on the install and rescue ISOs** (`iso_repo`), BIOS installs, and
  stage 2 as above.
- Optional per-target GCC cross suites and every LLVM backend stay as they are:
  AVR code is built without LTO.
- **A system-setup tool of our own** (idea, 2026-11-27; only if it becomes important enough: not planned work).
  Modeled on the ideas of Solus's usysconf (the Go version, github.com/getsolus/usysconf, keeps its rules in TOML;
  only its READMEs, some folder listings and recent history were read), written for apk rather than ported.
  - apk keeps deciding when to run it, through its triggers; the tool does the setup and can rerun it to repair a
    system. It tracks no packages.
  - Rules: small TOML files, which packages ship: the program to run, when it is needed, what must run first.
  - Commands: `list`, `run <name>`, `run --all`, and a preview of what would run.
  - Every task safe to run again. Failures logged by name, with a failing exit status and an easy retry.
  - Works on another root (image builds), skipping what needs a running system, such as restarting a service.
  - It may run as root: rules only from protected system folders; commands run without building shell strings.
  - Zig, like the other tools.
  - **First:** wait for a real need (setup scripts repeating the same work, or users needing an easy repair). List
    what today's triggers and install scripts do (some work belongs only to install or removal and must not be
    rerun as repair), test what apk can already rerun, and try a few existing triggers to see whether a separate
    tool makes things simpler. After the uncle's boot problems and the world rebuild.
- **Package deltas** (for discussion, not decided): a patch from the previous
  release of a package to the new one, to cut update downloads. The user knows
  it from the Solus project. Producing them is the easy half (a binary diff of
  the unpacked payloads written at publish time, next to the new `.apk`, with a
  rule for how long old packages are kept); applying them is the hard half
  (apk-tools has no delta support, so it needs a patch or a wrapper; the client
  needs the exact old package or a file-level delta against the installed
  files; the result must verify against the signed package). Reproducible
  builds and early cutoff (SPEC 7) already keep unchanged packages from being
  republished, and make deltas small. Discuss before any work.
