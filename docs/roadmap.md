# Roadmap

Status as of 2026-11-13. Numbers are approximate (taken from file names in
`repo/`, not from a build log). Per-package requests and their status live in
`docs/requests.md`; the design is in `SPEC.md`; the newest session state is in
`docs/handoff.md`.

Goal: a package set you define builds an image (ISO, disk image, rootfs). The
first target, rebuilding everything on the DKRescue boot disk
(`dkrescue.iso`, the stage 0 image) from recipes, is met; the tree now builds
much more than the disk ever had.

## Where we are

- About 2300 recipes in `packages/`; `repo/x86_64` holds about 4850 apks
  (about 4400 distinct names; older releases stay until `dkbuild prune`).
  Roughly 700 recipes were not yet built on 2026-11-13.
- History: 2026-11-06 to 2026-11-13, about 690 commits. Nothing pushed.
- World runs: run 1 had 45 failures, run 2 had 28 (libcamera blocked 654
  packages), run 3 (started 2026-11-13 16:14, `--keep-going`) was still running
  at 20:24 with about 22 failures logged so far. Every fix since run 1 is
  untested until run 4, which has not been started (the user starts builds).
- Three live ISOs (base, rescue, dkde) boot to a login or the desktop in QEMU on
  UEFI and BIOS (logs in `work/qemu-*.log`, script `tests/qemu-iso.sh`). Only
  `out/dkde/dkde.iso` is on disk now; the base and rescue ISOs were not rebuilt
  after the later package changes (unverified that they still build).
- Only x86_64 is built. `profiles/aarch64.toml` and `riscv64.toml` exist, nothing
  more.

## Done milestones

- **B0**: recipe reader, `check`, `graph`; the whole tree checks.
- **B1**: native builds in the unprivileged sandbox, signed apks, signed index,
  dependency scanning (`so:`/`cmd:`/`pc:`), world builds with `-P N`,
  `--keep-going`, a fast work cache (`DKBUILD_FAST_WORK`).
- **Stage 0 replaced**: LLVM 22, musl, zig, base, kernel, dklilo, dksh, dkde,
  rescue tools, installer and initramfs are all built from recipes.
- **ISO output**: `dkbuild image` makes tar, squashfs, directory and hybrid
  BIOS+UEFI ISO (dklilo). Live ISOs use `live-initramfs`.
- **Package and source discs**: `dkbuild discs` (see below).

## Open milestones

- **B2, stage 2** (roots filled from `repo/` only, a comparison with stage 1, and
  the forgotten-dependency test): not implemented. `tests/forgotten-dep.sh`
  exists but is skipped until stage 2. `base-devel` is written, not yet built; the
  rescue image installing it from `repo/` will exercise the `apk add base` half.
- **B3, images**: partly done. The live ISOs boot; the installed-system image
  (`images/fenriros.toml`) still outputs only a tar, and the checks SPEC 13
  attributes to DKRescue's `CONSTRAINTS.md` cannot be run because that file is
  not in this repository (verified: absent).
- **B4 aarch64, B5 riscv64**: profiles only; no cross base set, repo, image or
  boot test. aarch64 is the next large item (zig cc aarch64 cross-builds work).
- **qemu-user and binfmt_misc** (SPEC 14 item 5): open. `qemu` is a recipe but
  has no separate qemu-user package and is not built.
- Small: ncurses' C++ binding (`libncurses++w`) is off; turn it on with `-lc++`
  when a package needs it.

## Images and installation

| Item | Status |
|---|---|
| Live ISOs: base (CLI), rescue (DKRescue's successor, with rescue-tools and base-devel), dkde (desktop through greetd) | done, boot in QEMU on UEFI and BIOS |
| `dkinstaller` 0.0.2 on the live ISOs | written, built; not verified end to end on hardware |
| Installed system on UEFI: systemd-boot, ext4 root, no initramfs | done (docs/install.md, manual) |
| Installed system on BIOS (GRUB is a package) | open: no documented path |
| Other root file systems (btrfs, XFS) for installs | open: they are modules; the initramfs exists for live images only |
| Containers: `images/container.toml`, `container-build.toml` | written |
| Packages on the install and rescue ISOs (`iso_repo`) | open: no image sets it yet |
| Package ISOs and source ISOs | done, see "dkbuild features" |

Image keys: `packages`, `exclude`, `unwanted` (apk `!name`), `services`, `users`,
`issue`, `console` (agetty or dkconsole), `login` (console or greetd),
`autologin`, `session`, `output`, `iso_repo`.

## Toolchains

- Built: llvm22 (22.1.8, every backend), zig 0.17.1 from source, rust 1.99.1 from
  source against llvm22 (seed `rust-bootstrap`; rust-wasm, rust-src and rustc-dev
  included; rustup built), go 1.27 (seed `go-bootstrap`), openjdk 17/21/25,
  musl with mimalloc, nodejs, ruby 3.4 and 4.0, php 8.4 and 8.5, perl, python.
- Written, not built or not confirmed: dotnet 10 (self-hosted), dart, ghc 9.14
  (stage 0 on Alpine's GHC), emscripten.
- **GCC 15 is opt-in**: `/usr/lib/gcc15`, versioned drivers, all languages that
  do not conflict with LLVM's; a recipe asks for it with `options = ["gcc"]` (GNU
  binutils and GCC instead of clang). Stage 0 of GCC itself is built on Alpine's
  GCC. GCC cross suites (arm-none-eabi, aarch64-none-elf, riscv64-unknown-elf,
  avr) are written. GRUB uses `options = ["gcc"]`. Nothing else builds with GCC
  unless it opts in; C++ from GCC keeps its own libstdc++ apart from libc++.
- **Missing: WASI.** No `wasi-libc` package, so Rust's WASI targets do not work and
  Firefox's RLBox libraries are not wasm-sandboxed.
- **Android NDK from source**: planned, not started in code. Survey and steps are
  in `wip/android-ndk/NOTES.md` (a dkbuild snapshot of AOSP pieces, a generator
  for the stubs, then `android-ndk-sysroot`, `-runtimes`, `android-ndk`).
- **Rust in the kernel**: ready, off. The tree has `rust`, `rust-src` and
  `bindgen`; turning it on needs `hostdeps`, `CONFIG_RUST=y` and a release bump.

## Desktops

- **dkde** (default): dkde 0.2.0, dkconsole 0.2.0, dkman 0.5.0 (as `man`), greetd,
  NetworkManager (DHCP; `base-net` is not used on the dkde image), gvfs and
  GNOME Online Accounts. `desktop-dkde` pulls in dkde's optional dependencies.
  Built; the ISO boots to the desktop. VT 7 for greetd and `dkde-session` as the
  initial session are still unconfirmed on hardware.
- **Hyprland** 0.57 and its libraries (`desktop-hyprland`): built. Dotfile configs
  (ML4W, dionysus) are only an idea: no recipes; dionysus has no licence.
- **labwc**, wayland, mesa, xwayland, Qt 6 (6.12), GTK 3/4: built.
- **Plasma 6.8** (Frameworks, Gear, PIM, SDDM), **Xfce 4.20**, **LXQt**: written
  (imported from Chimera), not built.
- **X server**: written as `xserver-xorg` 21.1.24 plus
  `xserver-xorg-input-libinput`, not built. XLibre is not packaged (verified:
  there is no xlibre recipe). **Phoenix** (a Zig X server) is not packaged
  either (verified: no recipe).

## Applications

Status words: built, written (not built), failing (last world run), blocked.
Details and per-package notes: `docs/requests.md` and `wip/`.

| Group | Status |
|---|---|
| Shells and CLI: zsh, fish, nushell, vim, gh, msedit | built |
| AI: llama.cpp, ollama, aimgr, claude-code | built; whisper.cpp written |
| Web servers and PHP: nginx, caddy, php 8.4 | built |
| Virtualization: ZFS (prebuilt per kernel flavor), Incus, libvirt, qemu, Docker/podman | zfs, incus, libvirt built; qemu, Docker written |
| Proxmox VE 9.2 (about 130 recipes) | written, partly failing (pve-rs) |
| Browsers: Firefox (patches in `packages/f/firefox/patches`), Thunderbird, Chromium | written, not built |
| Electron family: electron, Code - OSS, Brave | written, not built (after Chromium) |
| Office: LibreOffice, Euro-Office + Libera Suite, OCR (tesseract, ocrmypdf), printing | OCR built; the rest written |
| Media and graphics: ffmpeg (24 extra codec libraries), mpv, GStreamer, GIMP, Inkscape, Krita, Kdenlive, Blender | ffmpeg stack written (built before the extra libraries); apps written, not built |
| Games and emulators: wine, MAME, dolphin-emu, ScummVM, RetroArch | written, not built |
| Electronics and CAD: KiCad, FreeCAD, avr-gcc, OpenOCD, ImHex | avr-gcc and ImHex built; the rest written |
| Security tools | written (metasploit built) |
| Server web apps (help desks, ERP, mail, project management, finance) | written, inert, not built; some failing |
| Flatpak (+ builder), Flathub as default remote | written, not built |

## dkbuild features

- Dependency stores so that builds stay offline: Go, Rust (`cargodeps`), Zig, npm
  (`npmdeps`, yarn 2+ through `yarn-lock`, pnpm), Python (`pydeps`, `python-lock`),
  Gradle, NuGet, gems, Dart pub, Haskell (`hackagedeps`, `hackage-lock`).
- Snapshots (`src/snapshot-*.sh`) for projects whose checkout downloads as it
  builds: electron, brave, dart, dotnet, euro-office. `snapshot-android-ndk` is
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
  planned and does not exist (verified: nothing in `src/`).
- `image --verbose`, `world --keep-going`, `--tree DIR`.
- Tests: `tests/run-all.sh`, `tests/qemu-iso.sh`, `work/pipeline.sh`.

## Blocked and unwritten

- Blocked or not written: Netdata, Cockpit (needs systemd). Paperless-ngx, Mayan EDMS, Taiga, ERPNext, Twenty and
  Joplin are unblocked by `pydeps` and `yarn-lock` but not yet written.
- Unwritten special cases (reasons in `wip/README.md`): PDFium, Frida, Anki,
  OpenKiosk, Bitwarden desktop, Issie, RustDesk client (Flutter is glibc-only),
  KeePass 2 and gbrainy (Mono), epson escpr2 (source RPM), MatterControl.
- Not planned: Frappe Books and Maybe Finance (archived).
- Not packaged: qt5ct (no Qt 5), hfsprogs, waylock, gtklock.
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
  in the recipe. A recipe edit (even a comment) needs a `release` bump.
- **The user runs builds**: nothing here starts `world` or `pkg`; recipes are
  written and checked, logs are read afterwards.
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
