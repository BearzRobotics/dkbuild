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
| Rescue tools | fsarchiver, ntfs-3g, nwipe, ddrescue, testdisk, btrfs-progs, ... | list is in the iso post |
| Network | dhcpcd, iwd, wpa_supplicant, openssh | `base-net` |
| Desktop | wayland, mesa, labwc, pipewire, gtk3/4, dkde, fonts | The longest tail: ~100 recipes |
| Image | squashfs, initramfs, dklilo ISO | `dkbuild image` |

Done when `dkbuild image images/dkrescue.toml` makes an ISO that boots to the
desktop on the same hardware as `dkrescue.iso`.

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
| **Xorg** | partly: protocols, xinit, xkbcomp, xrandr, xwayland, but **no Xorg server** and no `xf86-*` drivers | Write `xorg-server` (meson) by hand; libinput and the modesetting driver cover the hardware the ISO supports. The X libraries come from cports. |
| hyprland, fish, edit | no | Hand-written recipes (Hyprland also needs its own libraries: hyprutils, hyprlang, aquamarine, ...). |
| **Fritzing** | no | Hand-written: Qt6 and Boost; the parts library is a separate download. |
| **ImHex** | no | Hand-written: C++ with many bundled third-party libraries (imgui, capstone, nlohmann-json, glfw, ...); cports already has capstone, glfw and nlohmann-json. |

Order inside the tier: ruby and qemu first (plain builds that prove the
toolchain), then Xorg, flatpak, Qt-based Fritzing and ImHex, and LibreOffice
last (it is the largest build in the tree, hours on this machine).

Anything not listed is added the same way: a recipe, `dkbuild check`, `dkbuild
pkg`, and it can go in an image.

## Image definitions

An image file lists packages, excluded patterns, services, users and outputs
(SPEC 8). Different sets (rescue disk, minimal server, Hyprland desktop,
developer workstation) are separate files over the same repo.
