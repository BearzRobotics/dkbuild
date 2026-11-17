# Rescue and backup tool set: recipe notes (2026-11-16)

All recipes are in packages/<letter>/<name>/ (main tree), not built. `check`: every one passes.
`fetch`: every source (and the Rust crates / Python packages of bcachefs-tools, borgmatic,
duplicity) downloaded with its sha256 verified. Nothing was built.

## Imported from Chimera (reviewed, names fixed, TODOs resolved)
pv, lsof, ncdu (1.22, the C series), mc, dialog, lshw (GUI split into lshw-gui), fio 3.43,
mbuffer (autotools build instead of CMake), btrbk 0.32.7 (Chimera's BSD-date/readlink patches
dropped: GNU coreutils here), lftp 4.9.3 (needtrio patch is upstream now), screen (tmpfiles +
PAM files, not setuid), kpartx 0.15.1 (make -f create-config.mk; only kpartx built),
stress-ng 0.22.02 (more optional libs linked).

## Written from scratch
partclone (all filesystems with libs here; not JFS/ReiserFS/UFS/VMFS/OpenZFS/ISA-L), clonezilla +
drbl (drbl installs only the function library, helpers, lang and conf Clonezilla sources; the
server programs are left out; `clonezilla` dialog TUI = bin/sbin scripts + dialog),
udpcast, par2cmdline 1.4.0 (turbo has no release tarballs), safecopy, foremost 1.5.7,
gpart 0.3, rsnapshot (perl; no cron, no config in use), duplicity 3.2.2 (pydeps: fasteners,
httplib2, requests-oauthlib, boto3...), rdiff-backup 2.2.7 (2.x is Python+C/librsync; the Rust
3.0 is not released, so no cargodeps), bup 0.34.1, borgmatic 2.2.0 (pydeps: ruamel.yaml),
sg3-utils 1.49 (name with '-': names forbid '_'), lsscsi 0.33, memtester 4.7.1,
memtest86+ 9.00 (option gcc, builds build/<arch>/mt86plus; untested), snapper 0.12.1 (Chimera
import; 0.13.x does not take the patches; cron script kept as an example only, dinit service
not enabled), hwinfo 26.0, bcachefs-tools 1.39.7 (cargodeps + bindgen; unverified).
New dependency libraries written: librsync, rhash, libthreadar (for dar), libx86emu (hwinfo),
python-pyxattr, python-pylibacl (rdiff-backup, bup).

## Skipped
- scalpel: upstream is abandoned (no release since 2013; "Scalpel 2.0" is a stale git fork); foremost
  covers the same job.
- par2cmdline-turbo: not packaged (git tags only, no release tarballs); par2cmdline instead.

## Caveats to watch in the first run
- hwinfo: includes <sys/io.h> (x86 only in musl): aarch64 will need a patch.
- bcachefs-tools: libunwind.pc is written by the recipe (LLVM's libunwind has none); first build may find musl issues.
- memtest86+: needs GCC/GNU ld (gcc option); mapping from $arch covers x86_64 and aarch64.
- foremost: fopen64 -> fopen via sed; check the musl build.
- dar: python binding, UPX, dar_static, HTML docs off (reasons in the recipe).
- duplicity/rdiff-backup: setup.py uses distutils through setuptools; first build shows if the shim suffices.
- backup-tools / rescue-tools meta packages (existing recipes) were not edited; their rundeps can
  now add: partclone, clonezilla, duplicity, rdiff-backup, bup, borgmatic, btrbk, rsnapshot, dar, snapper...
