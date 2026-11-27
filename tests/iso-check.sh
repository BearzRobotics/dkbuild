#!/bin/sh
# Is a live ISO made by `dkbuild image` fit to hand out? This is the first stage: it only reads the ISO (no boot, no
# build, little memory), so it can run while packages are building. What it cannot see (booting, the boot menu's keys,
# loading modules, mounting drives, compiling in the image) it lists at the end as NOT CHECKED: a pass here is not a
# tested ISO.
#
#   tests/iso-check.sh [--repo DIR] [--no-report] out/dkde-devel-cli/dkde-devel-cli.iso
#
# It compares the ISO with this tree (the dinit-services boot files) and with the package repository it was made
# from (--repo, default repo/x86_64). Needs xorriso and unsquashfs. The report goes beside the ISO as <iso>.check.txt.
# Exit status: 0 every check passed, 1 a check failed, 2 the ISO could not be read.
set -u
cd "$(dirname "$0")/.." || exit 2
ROOT=$PWD
repo=repo/x86_64
report=yes
while [ $# -gt 1 ]; do
    case $1 in
        --repo) repo=$2; shift 2 ;;
        --no-report) report=no; shift ;;
        *) echo "usage: tests/iso-check.sh [--repo DIR] [--no-report] ISO" >&2; exit 2 ;;
    esac
done
iso=${1:?usage: tests/iso-check.sh [--repo DIR] [--no-report] ISO}
[ -f "$iso" ] || { echo "no ISO at $iso" >&2; exit 2; }
for t in xorriso unsquashfs od sha256sum; do command -v "$t" >/dev/null || { echo "needs $t" >&2; exit 2; }; done

mkdir -p work
W=$(mktemp -d "$ROOT/work/iso-check.XXXXXX") || exit 2
trap 'chmod -R u+rwX "$W" 2>/dev/null; rm -rf "$W"' EXIT
trap 'exit 2' INT TERM

fails=0
passes=0
LOG=$W/report
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
ok() { passes=$((passes + 1)); say "ok    $1"; }
bad() { fails=$((fails + 1)); say "FAIL  $1"; }
detail() { sed 's/^/        /' | tee -a "$LOG"; }

# ---- the ISO itself --------------------------------------------------------------------------------------------
label=$(xorriso -indev "$iso" -pvd_info 2>/dev/null | sed -n "s/^Volume [Ii]d *: '*\([^']*\).*/\1/p" | tr -d ' ')
[ -n "$label" ] || { echo "cannot read the ISO's volume label" >&2; exit 2; }
say "ISO    $iso"
say "label  $label"
say "built  $(date -r "$iso" '+%Y-%m-%d %H:%M')"
say "sha256 $(sha256sum "$iso" | cut -d' ' -f1)"
say ""
xorriso -osirrox on -indev "$iso" -extract /live/rootfs.sfs "$W/rootfs.sfs" -extract /boot "$W/boot" >/dev/null 2>&1
if [ ! -s "$W/rootfs.sfs" ] || [ ! -s "$W/boot/vmlinuz" ] || [ ! -s "$W/boot/dklilo.conf" ]; then
    echo "the ISO lacks live/rootfs.sfs, boot/vmlinuz or boot/dklilo.conf" >&2; exit 2
fi
chmod -R u+rwX "$W"
# one line per entry: "<type> <path> [-> target]" (type: - file, d directory, l link)
unsquashfs -d '' -lls "$W/rootfs.sfs" 2>/dev/null \
    | awk '$1 ~ /^[-dlcbps][rwxsStT-]+$/ { t = substr($1, 1, 1); s = $0; sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ /, "", s); if (s ~ /^\//) print t " " s }' > "$W/list"
[ "$(wc -l < "$W/list")" -gt 1000 ] || { echo "cannot list the root filesystem" >&2; exit 2; }
has() { awk -v p="$1" '{ if ($2 == p) { found = 1; exit } } END { exit !found }' "$W/list"; }
# fetch PATH...: those files, into $W/r
fetch() { unsquashfs -no-xattrs -q -n -f -p 2 -d "$W/r" "$W/rootfs.sfs" "$@" >/dev/null 2>&1; chmod -R u+rwX "$W/r" 2>/dev/null; }

# ---- 1. which image this is: the name, the label and what it starts ----------------------------------------------
base=$(basename "$iso" .iso)
want=
case $base in
    dkde-devel-cli*) want=FENRIROS_CLI; kind=cli ;;
    dkde-devel*) want=FENRIROS_DKDE; kind=desktop ;;
    *) kind=other ;;
esac
if [ -n "$want" ]; then
    if [ "$label" = "$want" ]; then ok "the file name and the label agree: $kind image"
    else bad "the file is named as the $kind image, but its label is $label (expected $want)"; fi
fi
if grep -q "root=live:LABEL=$label " "$W/boot/dklilo.conf" && ! grep 'root=live:LABEL=' "$W/boot/dklilo.conf" | grep -qv "LABEL=${label}[ \"]"; then
    ok "every boot menu entry looks for this ISO's own label"
else bad "a boot menu entry looks for another label than $label"; fi
if has /etc/dinit.d/boot.d/greetd; then greeter=yes; else greeter=no; fi
case $kind in
    cli) if [ $greeter = no ]; then ok "the command-line image starts no graphical login"; else bad "the command-line image enables greetd"; fi ;;
    desktop) if [ $greeter = yes ]; then ok "the desktop image enables its graphical login"; else bad "the desktop image does not enable greetd"; fi ;;
esac

# ---- 2. the kernel and its modules -------------------------------------------------------------------------------
# the release string, where the x86 boot protocol says it is (offset 0x20e, relative to 0x200)
off=$(od -An -tu2 -j526 -N2 "$W/boot/vmlinuz" | tr -d ' ')
krel=$(dd if="$W/boot/vmlinuz" bs=1 skip=$((off + 512)) count=128 2>/dev/null | tr '\0' '\n' | head -n 1 | awk '{ print $1 }')
mods=$(awk '$1 == "d" && $2 ~ /^\/usr\/lib\/modules\/[^\/]+$/ { sub(/.*\//, "", $2); print $2 }' "$W/list" | tr '\n' ' ')
if [ -n "$krel" ] && [ "$mods" = "$krel " ]; then ok "kernel $krel; its module folder is the only one"
else bad "kernel '$krel', module folder(s): ${mods:-none}"; fi
# the kernel the disc boots is the one installed in the root (what an installation gets), and there is only one
inroot=$(awk '$1 == "-" && $2 ~ /^\/boot\/vmlinuz-/ { print $2 }' "$W/list" | tr '\n' ' ')
if [ "$(echo "$inroot" | wc -w)" = 1 ]; then
    r=${inroot% }
    fetch "${r#/}"
    if cmp -s "$W/r$r" "$W/boot/vmlinuz"; then ok "the kernel the disc boots is byte for byte the root's $r"
    else bad "the kernel the disc boots differs from the root's $r: an installed system would get another one"; fi
else bad "the root has not exactly one kernel in /boot: ${inroot:-none} (the disc takes the last by name)"; fi
# and it is the kernel this tree makes today: images/*.toml name the package `linux`
tver=$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' packages/l/linux/package.toml | head -n 1)
tloc=$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' packages/l/linux/files/config)
if [ "$krel" = "$tver$tloc" ]; then ok "it is the tree's kernel, $tver$tloc"
else bad "the disc's kernel is '$krel', the tree's linux recipe makes '$tver$tloc'"; fi
if has "/usr/lib/modules/$krel/modules.dep" && has "/usr/lib/modules/$krel/modules.alias"; then ok "modules.dep and modules.alias are there"
else bad "no modules.dep or modules.alias for $krel: modules cannot be found by device"; fi
# one module of each kind of directory: built for this kernel?
wrong=0; seen=0
for m in $(awk -v d="/usr/lib/modules/$krel/" '$1 == "-" && index($2, d) == 1 && $2 ~ /\.ko$/ { n = split($2, a, "/"); k = a[7] "/" a[8]; if (!c[k]++) print $2 }' "$W/list" | head -n 25); do
    fetch "${m#/}"
    v=$(grep -a -o 'vermagic=[^[:cntrl:]]*' "$W/r$m" 2>/dev/null | head -n 1 | sed 's/vermagic=//' | awk '{ print $1 }')
    seen=$((seen + 1))
    [ "$v" = "$krel" ] || { wrong=$((wrong + 1)); echo "$m: built for '$v'" | detail; }
done
if [ $seen -gt 0 ] && [ $wrong = 0 ]; then ok "$seen sampled modules are built for $krel"
else bad "$wrong of $seen sampled modules are not built for $krel"; fi
if has "/boot/config-${krel%%-*}-${krel#*-}" || [ -n "$(awk '$2 ~ /^\/boot\/config-/ { print $2 }' "$W/list")" ]; then
    cfg=$(awk '$1 == "-" && $2 ~ /^\/boot\/config-/ { print $2; exit }' "$W/list")
    fetch "${cfg#/}"
    miss=
    for o in CONFIG_EXT4_FS=y CONFIG_EXT4_USE_FOR_EXT2=y 'CONFIG_NTFS3_FS=[ym]' 'CONFIG_FUSE_FS=[ym]' 'CONFIG_VFAT_FS=[ym]' CONFIG_MODULES=y CONFIG_DEVTMPFS_MOUNT=y; do
        grep -Eq "^$o\$" "$W/r$cfg" || miss="$miss $o"
    done
    if [ -z "$miss" ]; then ok "the kernel config has ext2 (through ext4), ext4, ntfs3, fuse, vfat and modules"
    else bad "the kernel config lacks:$miss"; fi
else bad "no kernel config in /boot to check"; fi

# ---- 3. loading modules ------------------------------------------------------------------------------------------
miss=
for p in /usr/sbin/modprobe /usr/sbin/udevd /usr/bin/udevadm /usr/lib/udev/rules.d/80-drivers.rules /etc/dinit.d/boot.d/udevd /etc/dinit.d/boot.d/udev-trigger; do
    has "$p" || miss="$miss $p"
done
if [ -z "$miss" ]; then ok "modprobe, udev, its driver rule and its boot services are there"
else bad "missing for loading modules:$miss"; fi

# ---- 4. the boot files are this tree's ---------------------------------------------------------------------------
files="early-filesystems.sh early-filesystems auxfscheck filesystems filesystems.sh late-filesystems late-filesystems.sh rootfscheck rootfscheck.sh rootrw rootrw.sh hwclock hwclock.sh udevd udev-trigger udev-settle modules modules.sh"
paths=; for f in $files; do paths="$paths etc/dinit.d/$f"; done
# shellcheck disable=SC2086
fetch $paths
differ=
for f in $files; do
    src=packages/d/dinit-services/files/$f
    [ -f "$src" ] || continue
    cmp -s "$src" "$W/r/etc/dinit.d/$f" || differ="$differ $f"
    case $f in
        *.sh) awk -v p="/etc/dinit.d/$f" '$2 == p { f = 1 } END { exit !f }' "$W/list" && [ -x "$W/r/etc/dinit.d/$f" ] || differ="$differ $f(not-executable)" ;;
    esac
done
if [ -z "$differ" ]; then ok "the boot files are the tree's dinit-services files"
else bad "boot files that differ from the tree (an older dinit-services, or changed by hand):$differ"; fi

# ---- 5. mount helpers where mount(8) looks -----------------------------------------------------------------------
# libmount runs mount.<type> and umount.<type> only from /sbin (here /usr/sbin), /sbin/fs.d and /sbin/fs
if grep -q '^l /sbin -> usr/sbin$' "$W/list"; then
    awk '$2 ~ /^\/usr\/bin\/u?mount\.[^\/]+$/ { n = $2; sub(/.*\//, "", n); print n }' "$W/list" | sort -u > "$W/inbin"
    awk '$2 ~ /^\/usr\/sbin\/u?mount\.[^\/]+$/ { n = $2; sub(/.*\//, "", n); print n }' "$W/list" | sort -u > "$W/insbin"
    lost=$(comm -23 "$W/inbin" "$W/insbin" | tr '\n' ' ')
    if [ -z "$lost" ]; then ok "every mount helper is in /usr/sbin, where mount looks"
    else bad "mount helpers only in /usr/bin, which mount never runs: $lost"; fi
    # a link there must lead to something
    broken=$(awk '$1 == "l" && $2 ~ /^\/usr\/sbin\/u?mount\./ { print $2 " " $4 }' "$W/list" | while read -r l t; do
        case $t in /*) p=$t ;; ../*) p=/usr/${t#../} ;; *) p=/usr/sbin/$t ;; esac
        has "$p" || echo "$l -> $t"
    done)
    if [ -n "$broken" ]; then bad "mount helper links that lead nowhere:"; echo "$broken" | detail; fi
else
    bad "/sbin is not the link to usr/sbin this check expects"
fi

# ---- 6. the boot loader on the disc is the image's own -------------------------------------------------------------
fetch usr/sbin/dklilo
if [ -x "$W/r/usr/sbin/dklilo" ] && mkdir -p "$W/loader" && "$W/r/usr/sbin/dklilo" mkiso-images "$W/loader" >/dev/null 2>&1; then
    # xorriso writes a table into bytes 8..63 of the BIOS image: everything else must be the same
    same() { [ "$(wc -c < "$1")" = "$(wc -c < "$2")" ] && cmp -s -n 8 "$1" "$2" && cmp -s -i 64 "$1" "$2"; }
    if same "$W/loader/eltorito.bin" "$W/boot/dklilo/eltorito.bin"; then ok "the BIOS boot loader is the image's own dklilo"
    else bad "the BIOS boot loader on the disc was not written by the image's dklilo (the build machine's old one?)"; fi
else
    bad "cannot run the image's dklilo to compare the boot loader"
fi

# ---- 7. tools that were missing before ----------------------------------------------------------------------------
case $kind in
    cli | desktop)
        miss=
        for p in /usr/bin/cc /usr/bin/c++ /usr/bin/clang /usr/bin/rustc /usr/bin/cargo /usr/bin/zig /usr/bin/make /usr/bin/tree \
            /usr/lib/libm.a /usr/lib/libc.a /usr/lib/libunwind.so /usr/lib/libunwind.a /usr/lib/libc++.a /usr/include/c++/v1/string /usr/bin/nologin; do
            has "$p" || miss="$miss $p"
        done
        if [ -z "$miss" ]; then ok "the compilers, the libraries static links need, tree and nologin are there"
        else bad "missing (present is not the same as working: compiling is not checked here):$miss"; fi
        ;;
esac

# ---- 8. libraries whose main package was left out ------------------------------------------------------------------
if [ -d "$repo" ]; then
    fetch usr/lib/apk/db/installed
    db=$W/r/usr/lib/apk/db/installed
    if [ -s "$db" ]; then
        sed -n 's/^P://p' "$db" | sort > "$W/installed"
        awk '/^P:/ { p = substr($0, 3) } /^V:/ { v = substr($0, 3); if (p ~ /-libs$/) print p, v }' "$db" | while read -r p v; do
            m=${p%-libs}
            grep -qx -- "$m" "$W/installed" || { [ -f "$repo/$m-$v.apk" ] && echo "$m"; }
        done > "$W/nomain"
        if [ -s "$W/nomain" ]; then
            bad "$(wc -l < "$W/nomain") libraries are installed without their main package, which the repository has:"
            tr '\n' ' ' < "$W/nomain" | fold -s -w 100 | detail
            echo | detail
        else ok "no -libs package lacks a main package the repository has ($(grep -c . "$W/installed") packages installed)"; fi
    else bad "no apk database in the image: apk could not update it"; fi
    keys=$(awk '$1 == "-" && $2 ~ /^\/etc\/apk\/keys\/./' "$W/list" | wc -l)
    if [ "$keys" -gt 0 ]; then ok "apk has a signing key to trust"; else bad "no key in /etc/apk/keys: no repository could be trusted"; fi
else
    bad "no repository at $repo (--repo DIR): the installed packages were not checked"
fi

# ---- the verdict ---------------------------------------------------------------------------------------------------
say ""
say "NOT CHECKED here (needs a boot, a build or real hardware): that it boots with BIOS; the boot menu's keys; services;"
say "  /run/dinitctl; double mounts; hwclock; modules actually loading; mounting NTFS, ext2 and ext4; compiling C, C++,"
say "  static, Rust and Zig; the desktop starting; console switching; installing; UEFI; any real computer."
say ""
if [ $fails = 0 ]; then say "RESULT: the $passes file checks passed. This is not a tested ISO (see NOT CHECKED)."
else say "RESULT: $fails check(s) FAILED, $passes passed. Do not hand out this ISO."; fi
if [ $report = yes ]; then cp "$LOG" "$iso.check.txt" 2>/dev/null || echo "(could not write $iso.check.txt)" >&2; fi
[ $fails = 0 ]
