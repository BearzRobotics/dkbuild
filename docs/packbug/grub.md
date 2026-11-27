# grub: an installed system does not boot (rescue prompt)

| | |
|---|---|
| Package | `grub` (`packages/g/grub`) and its platform subpackages |
| Versions seen | 2.12-r4 and 2.12-r6 |
| Severity | High: every GRUB install we boot-tested is unbootable, and the install reports success |
| Found | 2026-11-26, QEMU install tests for dkinstaller 0.0.7 |
| Status | Fixed in 2.12-r7 (`"!strip"`; current recipe is r8). 2026-11-26: GRUB installs on ext4 booted in QEMU on BIOS and UEFI. XFS roots not tested. The text below is the report as written before the fix |
| Likely owner | dkbuild's strip step, not GRUB's source and not dkinstaller |

## Symptom

`grub-install` and `update-grub` finish without errors. The first boot of the installed disk then stops.

BIOS:

    GRUB loading.
    Welcome to GRUB!

    error: disk `hd0,gpt3' not found.
    Entering rescue mode...
    grub rescue>

UEFI:

    error: no such partition.
    Entering rescue mode...
    grub rescue>

In the UEFI rescue shell (r4), `ls` lists `(hd0)` and no partitions. `prefix` and `root` correctly name
`hd0,gpt3`. The GPT on that disk was checked from the host: protective MBR present, header and entry-table
checksums correct.

## What was tested

| Image | GRUB | Firmware | Installer | Result |
|---|---|---|---|---|
| dkinstall-test.iso (built 11-19) | 2.12-r4 | BIOS | 0.0.6 and 0.0.7 code | rescue prompt |
| dkinstall-test.iso | 2.12-r4 | UEFI | 0.0.6 and 0.0.7 code | rescue prompt |
| dkde-devel.iso (built 11-25) | 2.12-r6 | BIOS | 0.0.7 code | rescue prompt (screenshot checked) |
| dkde-devel.iso | 2.12-r6 | UEFI | | not tested: its image.log does not list `grub-x86_64-efi` |

"0.0.7 code" is the build from before the later XFS-only change; these installs used an ext4 root. On the same
images, ext4 installs with dklilo booted (and systemd-boot on UEFI, on dkinstall-test).

## Evidence: the modules have lost their start symbol

Modules read from `/usr/lib/grub/<platform>/` on the installed disks:

| Version | Platform | Modules checked | `grub_mod_init` | Local function symbols |
|---|---|---|---|---|
| r4 | i386-pc | biosdisk, part_gpt, ext2 | none | none |
| r4 | x86_64-efi | part_gpt, ext2, normal | none | none |
| r6 | i386-pc | biosdisk, part_gpt, ext2, normal | none | none |

GRUB finds a module's start function by looking for the local symbol `grub_mod_init` in the module's symbol
table. Without it the module loads and no error is shown, but it never registers anything: no BIOS disk driver
(`biosdisk`) and no GPT partition map (`part_gpt`). That matches both symptoms. It would also apply to modules
built into the core image, which is made from the same `.mod` files.

## Suspected cause

`src/build.zig`, `strip_script` (about line 146), runs after `install` for any recipe without `"!strip"`:

    *) if [ "$(head -c4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ]; then llvm-strip --strip-unneeded "$f" || true; fi ;;

GRUB's `.mod` files are relocatable ELF objects, so they match. `--strip-unneeded` removes local symbols that no
relocation needs, which includes `grub_mod_init`. The script already leaves `*.o` files alone, but `.mod` files
do not match that pattern. GRUB's own build strips modules too, but is expected to keep this symbol
(`genmod.sh`, `-K grub_mod_init`; from knowledge of upstream, not checked against the 2.12 source here).

## About the r6 note in `package.toml`

The note says the Clang-built r3/r4 does not boot because "the modules' init functions do not take effect", and
r6 moved to GCC. The diagnosis of the init functions fits, but the GCC build fails the same way on BIOS, and the
strip step runs whichever compiler is used. So Clang is probably not the cause. Whether anything else is wrong
with a Clang build is unknown. `docs/install.md` says r6 has no recorded boot test.

## Proposed fix (not built or tested)

1. In `packages/g/grub/package.toml`:

       options = ["gcc", "!strip"]

   and set `release = 7`.

   This turns off stripping for the whole package, so the tools stay unstripped and the package grows. A
   narrower fix is to skip `*.mod` in `strip_script` (a `*.mod) ;;` case beside `*.o`). That affects every
   package with `.mod` files, such as Fortran module files, which are not ELF and are skipped today anyway.
2. Correct the r6 comment in `package.toml`.

Other recipes that ship relocatable ELF files which are looked up by local symbol name could be hit the same
way; this was not checked.

## How to verify

1. Rebuild `grub`. For each platform built, this must print a match:

       readelf -sW <pkg>/usr/lib/grub/i386-pc/biosdisk.mod | grep grub_mod_init
       readelf -sW <pkg>/usr/lib/grub/x86_64-efi/part_gpt.mod | grep grub_mod_init

2. Rebuild dkinstall-test.iso with the new GRUB, including `grub-i386-pc` and `grub-x86_64-efi`.
3. In the dkinstaller repository, build the binary and boot-test both firmware types:

       zig build --release=safe -Dtarget=x86_64-linux-musl -Dcpu=baseline
       python3 tests/qemu/loader_test.py --iso ISO --binary zig-out/bin/dkrescue-install --firmware bios --bootloader grub
       python3 tests/qemu/loader_test.py --iso ISO --binary zig-out/bin/dkrescue-install --firmware uefi --bootloader grub

4. If the image's kernel has XFS built in (linux r4 or later), repeat with `--root-fs xfs`. dkinstaller 0.0.7
   makes XFS in a form GRUB 2.12 can read (`-i nrext64=0,exchange=0 -n parent=0`); that install completes but
   has never been boot-tested.

To read a module from a test disk without root (the start sector of partition 3 comes from `sfdisk -d`):

    debugfs -R 'dump /usr/lib/grub/i386-pc/biosdisk.mod biosdisk.mod' 'target.img?offset=<start*512>'
    readelf -sW biosdisk.mod

## Until it is fixed

Use dklilo, or systemd-boot on UEFI. dkinstaller needs no change for this bug.
