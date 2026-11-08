# Roadmap

Goal: a package set you define builds an image (ISO, disk image, rootfs). The
first target is to rebuild everything on the DKRescue boot disk
(`dkrescue.iso`, the stage 0 image) from recipes. Past that, the same
machinery builds software the disk never had.

`dkbuild image` (SPEC 8) is the product: `packages = [...]` in, bootable
image out. Each tier below adds recipes, and only adds dkbuild features when a
recipe needs one.

## Tier 1: replicate the boot disk

SPEC 9.3 gives the wave order. The versions to match are in
`rootfs/dkrescue/` and the build steps in the DKRescue posts.

| Step | Packages | Notes |
|---|---|---|
| Toolchain | linux-headers, musl, **llvm** (building), zig | zig from source once llvm exists |
| Libraries and build tools | zlib, bzip2, xz, lz4, zstd, ncurses, readline, libffi, expat, openssl, cmake, ninja, meson, python, perl, m4, make, ... | Chimera templates via `import-cbuild` |
| Base | coreutils ... util-linux, e2fsprogs, kmod, eudev, shadow, dinit, apk-tools, dklilo, dksh, dkde-console | `base`, `base-devel` metapackages |
| Kernel | linux 6.19 | Config: `/boot/config-6.19-dkrescue` from the ISO |
| Rescue tools | `rescue-tools` meta-package: fsarchiver, ntfs-3g, nwipe, ddrescue, testdisk, chntpw, mdadm, ... (rsync waits on linux-headers) | `images/rescue.toml` |
| Network | dhcpcd, iwd, wpa_supplicant, openssh | `base-net` |
| Desktop | wayland, mesa, labwc, pipewire, gtk3/4, dkde, fonts | The longest tail: ~100 recipes. dkde requires **polkit**, built in its reduced form (no logind, authentication against shadow), which needs dbus, glib and duktape; recipes for polkit and duktape exist, and neither builds yet. |
| Image | squashfs, initramfs, dklilo ISO | `dkbuild image` |

Done when `dkbuild image images/rescue.toml` makes an ISO that boots to the
desktop on the same hardware as `dkrescue.iso`.

Status 2026-11-07: `zig` 0.17.1 builds from source against `llvm22` and passes
`zig run`, `ReleaseSafe` builds, `zig cc` and an aarch64 cross-build. `dksh` and
`dklilo` were rebuilt with it (r2). Note: dkbuild hashes a recipe's whole file,
comments included, so even a comment edit to a built recipe needs a `release`
bump (for `llvm22` that would mean another 3-hour build): edit comments before
the first build.

Open follow-ups from bring-up:
- **ncurses C++ binding** (`libncurses++w`) is off because it failed to link
  (no libc++ on its link line). Turn it back on, with `-lc++` in its link
  flags, when a package needs it (user, 2026-11-07).

## Tier 2: extras on the same base

- **Rust, properly bootstrapped.** Needed by Firefox and many others. Plan:
  1. `rust-bootstrap`: the upstream stage 0 compiler (the ISO already has
     `rust-1.99.0-x86_64-unknown-linux-musl`), repackaged, used only to build.
  2. `rust`: built from source with it, against our `llvm`. Then built again
     with its own output (stage 2) and the two compared, as `dkbuild`
     already does for base.
  3. Like `zig`, the system `rust` is for building repository packages;
     users get rustup.
  **Decided:** the seed compiler is enough. The full source chain (mrustc,
  then every rustc from 1.54) is out of scope.
- **Firefox 159** (built on the ISO already; patches in `firefox-patches/`).
  Needs rust, cbindgen, nodejs (the ISO builds node 26), nasm, GTK 3. Only
  after `rust`.
- **Microsoft Edit** (`edit` 2.0.0): a Rust program, so it follows `rust`. A
  small recipe; a good first test of the Rust bootstrap.

## Tier 3: development tools and desktops

Roughly in this order, because each tests something new:

1. **fish**, **zsh**: small, plain builds (fish is Rust).
2. **go**: bootstraps from a prior Go; same seed-then-rebuild treatment as rust.
3. **openjdk**: needs a boot JDK; the largest bootstrap after Rust.
4. **Session management** (logind): `elogind` (patched for musl) next to
   `seatd`. Both are packages; the image picks one.
5. **qt6**: big, uses our LLVM; unlocks KDE and many apps.
6. **Hyprland** and its configurations, as separate packages. Hyprland has
   no config manager of its own; the dotfile projects bring theirs.
   Candidates: ML4W (`mylinuxforwork/dotfiles`, GPL-3.0, has its own
   installer) and PewDiePie's `dionysus` (no license in the repository, so
   it cannot be packaged without the author's permission; a look-alike would
   be written from scratch). Several configs will fight over `~/.config/hypr`,
   so each ships its files under `/usr/share/<package>/` and a small
   selector (like `dkde-setup --once`) copies one into the user's home.
   Installing two never conflicts on disk. Hyprland ships next to labwc and
   dkde, not instead.

## Tier 4: applications

Where a recipe comes from decides the work. Checked against the Chimera
cports tree (`origin/master`, 2026-11-07):

| Package | In cports? | Plan |
|---|---|---|
| ruby, qemu (system, user, tools), flatpak (+builder), libreoffice, qt6, openjdk 17/21/25, go, rust, zsh, elogind, nodejs, firefox | yes | `import-cbuild`, then review. Their `rust-bootstrap` and `go-bootstrap` are the seeds. |
| **X server** | no Xorg server in cports | **XLibre** (`X11Libre/xserver`, 25.1.11, an Xorg fork, meson build) is the X server. Written by hand: `xlibre-xserver` plus its libinput driver; the modesetting driver is built in. The X libraries come from cports. |
| **Phoenix** (`external-mirrors/phoenix`) | no | An X server written in Zig from scratch, GPL-3.0, 0.1.0. Upstream says it is not for end users: it only runs nested inside another X server. Packaged as `phoenix` for experiments, built with our `zig`; it needs one Zig dependency (`translate-c`), so it waits for the Zig dependency fetch (SPEC 9.4). Not a replacement for XLibre yet. |
| hyprland, fish, edit | no | Hand-written recipes (Hyprland also needs its own libraries: hyprutils, hyprlang, aquamarine, ...). |
| **Fritzing** | no | Hand-written: Qt6 and Boost; the parts library is a separate download. |
| **ImHex** | no | Hand-written: C++ with many bundled third-party libraries (imgui, capstone, nlohmann-json, glfw, ...); cports already has capstone, glfw and nlohmann-json. |

Order inside the tier: ruby and qemu first (plain builds that prove the
toolchain), then XLibre, flatpak, Qt-based Fritzing and ImHex, and LibreOffice
last (it is the largest build in the tree, hours on this machine).

Anything not listed is added the same way: a recipe, `dkbuild check`, `dkbuild
pkg`, and it can go in an image.

## Image definitions

An image file lists packages, excluded patterns, services, users and outputs
(SPEC 8). Different sets (rescue disk, minimal server, Hyprland desktop,
developer workstation) are separate files over the same repo.

## Long term: optional GCC, more targets

LLVM stays the toolchain; **nothing builds with GCC unless its recipe opts
in** (`options = ["gcc"]`, a per-recipe switch of `CC`, `CXX`, `AR` and the
cross files). GCC itself is ordinary recipes, built only when something asks
for it: binutils, gmp, mpfr, libmpc, isl, and gcc configured for musl targets
(musl-cross-make style). GCC-built C links against musl and the tree as usual;
GCC-built C++ brings libstdc++, kept apart from the tree's libc++ (one C++
runtime per program). First user: GRUB 2, which also gives BIOS installs a
bootloader beside dklilo.

GCC comes as a **complete cross suite per target**: binutils, gcc and the C
library, for every architecture FenrirOS supports (musl) and for the common
embedded targets (newlib or the target's own libc): `avr` (avr-gcc,
avr-binutils, avr-libc), `arm-none-eabi`, `aarch64-none-elf`,
`riscv64-unknown-elf` / `riscv32`, and others as they are needed, packaged
the way Arch packages `arm-none-eabi-gcc`.

LLVM is built with **every backend**, stable and experimental (`all`), so
clang cross-compiles for the same targets (AVR, ARM, RISC-V, Xtensa for the
ESP32, ...). Code for AVR is built **without LTO**.

Targets beyond x86_64, aarch64 and riscv64, as many as LLVM (or GCC, where
LLVM can't) builds well: ppc64le, loongarch64, armv7, i686, s390x and others.
Each is a profile (SPEC.md 6.1) plus whatever recipes need per-architecture
care.

## ISO package repositories, and a source ISO

`dkbuild image` can put packages on the ISO (`apks/<arch>/` with a signed
`Packages.adb`), as Alpine's install media do: the live system lists the disc
as a repository (`/run/live/medium/apks/<arch>/Packages.adb`), so `apk add`
and an installer work offline, and an installed system can use a mounted disc
the same way (optionally tagged, `@cdrom ...`).

Two discs, made by `dkbuild image`: the **repository ISO** above (with
`"all"`: every package, the offline package source for machines without a
repository server, and a restore of any installed system), and a **source
ISO**: `cache/` (every source tarball and the vendored Go, Rust and Zig
dependencies), the git tree at that point and the stage 0 build image, enough
to rebuild the whole distribution with no network. The private signing key is
on neither.
