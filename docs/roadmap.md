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
  **Decision for you:** the full source chain (mrustc, then every rustc from
  1.54 on) trusts no binary at all, but takes days of compiling. It's a
  later project, not a blocker. The seed approach above is what Debian,
  Alpine and Chimera do.
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
6. **Hyprland** with a good default config. Needs hyprutils, hyprlang,
   aquamarine and friends, and a `hyprland-config` package so the default
   isn't the bare upstream one. Details to settle with you: the look
   (the two examples linked in the request are the reference), the bar,
   launcher, notifications, wallpaper, and font and icon choices.
   It ships next to labwc and dkde, not instead.

Anything not listed is added the same way: a recipe, `dkbuild check`, `dkbuild
pkg`, and it can go in an image.

## Image definitions

An image file lists packages, excluded patterns, services, users and outputs
(SPEC 8). Different sets (rescue disk, minimal server, Hyprland desktop,
developer workstation) are separate files over the same repo.
