//! `dkbuild image` (SPEC.md 8): a root filesystem made with apk from the
//! repository this tree built, with users and services set up, written out as
//! a directory, a tarball and/or a squashfs.
//!
//! Everything runs in the sandbox on the build machine (rootfs/dkrescue), as
//! uid 0 of a user namespace: apk can chown files to root and run install
//! scripts in a chroot, and nothing on the host is touched except the output
//! directory, `out/<name>/`. Files are root-owned inside the sandbox and owned
//! by the calling user on the host, which is why the tarball and squashfs are
//! also made inside: they record root ownership.

const std = @import("std");
const cfg = @import("cfg.zig");
const sandbox = @import("sandbox.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const User = struct {
    name: []const u8,
    groups: []const []const u8 = &.{},
    /// "locked" (no password login), "empty" (no password), or a crypt(3) hash.
    password: []const u8 = "locked",
    shell: []const u8 = "/bin/bash",
};

pub const Image = struct {
    name: []const u8,
    arch: []const u8 = "x86_64",
    packages: []const []const u8,
    /// Patterns (`*` within a name) no package named in `packages` may match.
    exclude: []const []const u8 = &.{},
    /// Packages that must not be installed, even as a dependency: passed to apk as
    /// `!name`, so it stops with a conflict when something in the image requires
    /// one, instead of installing it. (`exclude` only checks the names in `packages`.)
    unwanted: []const []const u8 = &.{},
    /// Repository lines written (active) to /etc/apk/repositories: a path to a
    /// Packages.adb or a URL, as apk reads them. The file also always carries a
    /// commented-out entry for a repository disc mounted at /mnt/cdrom.
    repositories: []const []const u8 = &.{},
    /// dinit services started at boot.
    services: []const []const u8 = &.{},
    users: []const User = &.{},
    hostname: []const u8 = "fenriros",
    /// The ISO's volume label, which the live init looks for; default: the
    /// name in capitals.
    label: []const u8 = "",
    /// A user logged in on tty1 at boot without a password (agetty
    /// --autologin): a live system, or a kiosk-like desktop.
    autologin: []const u8 = "",
    /// A command every user's login shell runs on tty1 (`exec`), such as
    /// `dkde-session`: with autologin, the machine boots to the desktop.
    session: []const u8 = "",
    /// The text of /etc/issue, which agetty prints before `login:` on each text
    /// console (`\r` kernel, `\l` tty, `\n` host); empty keeps the package's.
    /// A live image says there which user to log in as.
    issue: []const u8 = "",
    /// The login program on the text consoles: "agetty" (the default) or
    /// "dkconsole" (experimental). With dkconsole the image gets the package, and
    /// tty1-tty5 run `dkconsole --vt N`; tty6 and the serial console stay on
    /// agetty as the way in if it fails (dkconsole also hands a VT to agetty by
    /// itself when it cannot start). The autologin VT (tty1) stays on agetty:
    /// dkconsole's login-program is only a path, with no way to log a user in.
    console: []const u8 = "agetty",
    /// How the graphical session is reached: "console" (the default: `autologin`
    /// and `session` act on tty1, above) or "greetd": the image has greetd
    /// (the package; enable the service) and `autologin` + `session` become
    /// greetd's `initial_session` (that user's first session, started without a
    /// password, running `session`), leaving the gettys alone. After logging out
    /// the greeter asks for a login; a user whose password is "empty" can log in
    /// with nothing typed, because the image's /etc/pam.d/greetd then gets
    /// `nullok` (the package's has none).
    login: []const u8 = "console",
    /// What gives the graphical session its seat: "seatd" (the default: the
    /// `seatd` service) or "elogind" (the `elogind` service, which also
    /// registers the login session, so the desktop's Shut Down and Restart need
    /// no password). With greetd, "elogind" makes the image's greetd service
    /// wait for elogind instead of seatd and puts pam_elogind in its PAM file.
    seat: []const u8 = "seatd",
    /// Any of "rootfs", "tar", "squashfs", "iso".
    output: []const []const u8,
};

pub const Diagnostic = cfg.Diagnostic;
pub const Error = error{InvalidImage} || Allocator.Error;

const known_outputs = [_][]const u8{ "rootfs", "tar", "squashfs", "iso" };

pub fn parse(arena: Allocator, text: []const u8, diag: *Diagnostic) Error!Image {
    return parseChecked(arena, text, diag) catch |err| switch (err) {
        error.Invalid => error.InvalidImage,
        error.OutOfMemory => |e| e,
    };
}

fn parseChecked(arena: Allocator, text: []const u8, diag: *Diagnostic) cfg.Error!Image {
    const root = try cfg.parse(arena, text, diag);
    try cfg.onlyKeys(arena, diag, root, &.{ "name", "arch", "packages", "exclude", "unwanted", "repositories", "services", "users", "hostname", "label", "autologin", "session", "issue", "console", "login", "seat", "output" }, "");
    var img: Image = .{
        .name = try cfg.reqString(arena, diag, root, "name"),
        .packages = try cfg.optStrings(arena, diag, root, "packages"),
        .exclude = try cfg.optStrings(arena, diag, root, "exclude"),
        .unwanted = try cfg.optStrings(arena, diag, root, "unwanted"),
        .repositories = try cfg.optStrings(arena, diag, root, "repositories"),
        .services = try cfg.optStrings(arena, diag, root, "services"),
        .output = try cfg.optStrings(arena, diag, root, "output"),
    };
    if (try cfg.optString(arena, diag, root, "arch")) |a| img.arch = a;
    if (try cfg.optString(arena, diag, root, "hostname")) |h| img.hostname = h;
    if (try cfg.optString(arena, diag, root, "autologin")) |u| img.autologin = u;
    if (try cfg.optString(arena, diag, root, "session")) |c| img.session = c;
    if (try cfg.optString(arena, diag, root, "console")) |c| img.console = c;
    if (!std.mem.eql(u8, img.console, "agetty") and !std.mem.eql(u8, img.console, "dkconsole"))
        return cfg.fail(arena, diag, "'console' must be \"agetty\" or \"dkconsole\"", .{});
    if (try cfg.optString(arena, diag, root, "login")) |l| img.login = l;
    if (try cfg.optString(arena, diag, root, "seat")) |v| img.seat = v;
    if (!std.mem.eql(u8, img.login, "console") and !std.mem.eql(u8, img.login, "greetd"))
        return cfg.fail(arena, diag, "'login' must be \"console\" or \"greetd\"", .{});
    if (try cfg.optString(arena, diag, root, "issue")) |t| img.issue = t;
    if (std.mem.indexOf(u8, img.issue, "DKISSUE_EOF") != null) return cfg.fail(arena, diag, "'issue' may not contain DKISSUE_EOF", .{});
    if (std.mem.indexOfAny(u8, img.session, "'\n") != null) return cfg.fail(arena, diag, "'session' may not contain quotes or newlines", .{});
    if (try cfg.optString(arena, diag, root, "label")) |l| img.label = l else {
        const up = try arena.dupe(u8, img.name);
        for (up) |*c| c.* = std.ascii.toUpper(c.*);
        img.label = up;
    }
    if (img.packages.len == 0) return cfg.fail(arena, diag, "'packages' is empty", .{});
    if (img.output.len == 0) return cfg.fail(arena, diag, "'output' is empty; give any of rootfs, tar, squashfs, iso", .{});
    for (img.output) |o| if (!contains(&known_outputs, o))
        return cfg.fail(arena, diag, "unknown output '{s}'; give any of rootfs, tar, squashfs, iso", .{o});
    if (contains(img.output, "iso") and !contains(img.packages, "live-initramfs"))
        return cfg.fail(arena, diag, "the iso output needs 'live-initramfs' in packages (the live system's initramfs)", .{});
    if (std.mem.eql(u8, img.name, "archive")) return cfg.fail(arena, diag, "name 'archive' is taken: out/archive/ keeps dated ISOs", .{});
    if (img.label.len > 32) return cfg.fail(arena, diag, "label '{s}' is longer than an ISO volume label (32)", .{img.label});
    for (img.repositories) |r| if (r.len == 0 or std.mem.indexOfAny(u8, r, "\n\r") != null or std.mem.indexOf(u8, r, "DKREPO_EOF") != null)
        return cfg.fail(arena, diag, "repositories: one non-empty line each, no newlines", .{});
    for (img.unwanted) |u| {
        if (!plainWord(u)) return cfg.fail(arena, diag, "unwanted '{s}': only letters, digits, '-', '_', '.', '+'", .{u});
        if (contains(img.packages, u)) return cfg.fail(arena, diag, "package '{s}' is in both 'packages' and 'unwanted'", .{u});
    }
    for (img.packages) |p| for (img.exclude) |x| if (glob(x, p))
        return cfg.fail(arena, diag, "package '{s}' matches exclude pattern '{s}'", .{ p, x });
    // out/<name> is deleted and replaced by each successful run: ".." would be the build tree itself.
    for ([_][]const u8{ img.name, img.arch }) |s| if (!safeWord(s) or s[0] == '.' or s[0] == '-')
        return cfg.fail(arena, diag, "'{s}': a name or arch is letters, digits, '-', '_', '.', '+', and does not start with '.' or '-'", .{s});
    for ([_][]const []const u8{ img.packages, img.services, &.{ img.name, img.hostname, img.label } }) |list| for (list) |s| if (!plainWord(s))
        return cfg.fail(arena, diag, "'{s}': only letters, digits, '-', '_', '.', '+', and not starting with '-'", .{s});

    if (root.get("users")) |v| {
        const items = switch (v) {
            .array => |a| a.items.items,
            else => return cfg.fail(arena, diag, "'users' must be a list of [[users]] tables", .{}),
        };
        const users = try arena.alloc(User, items.len);
        for (items, users) |item, *u| {
            const t = switch (item) {
                .table => |t| t,
                else => return cfg.fail(arena, diag, "'users' must be a list of [[users]] tables", .{}),
            };
            try cfg.onlyKeys(arena, diag, t, &.{ "name", "groups", "password", "shell" }, "users");
            u.* = .{ .name = try cfg.reqString(arena, diag, t, "name"), .groups = try cfg.optStrings(arena, diag, t, "groups") };
            if (try cfg.optString(arena, diag, t, "password")) |p| u.password = p;
            if (try cfg.optString(arena, diag, t, "shell")) |s| u.shell = s;
            for ([_][]const []const u8{ &.{u.name}, u.groups }) |list| for (list) |s| if (!plainWord(s))
                return cfg.fail(arena, diag, "user '{s}': '{s}': only letters, digits, '-', '_', '.', '+'", .{ u.name, s });
            if (std.mem.indexOfAny(u8, u.password, "'\n") != null or std.mem.indexOfAny(u8, u.shell, "'\n ") != null)
                return cfg.fail(arena, diag, "user '{s}': password and shell may not contain quotes, spaces or newlines", .{u.name});
        }
        img.users = users;
    }
    if (img.autologin.len > 0) {
        if (!safeWord(img.autologin)) return cfg.fail(arena, diag, "autologin '{s}': only letters, digits, '-', '_', '.', '+'", .{img.autologin});
        for (img.users) |u| {
            if (std.mem.eql(u8, u.name, img.autologin)) break;
        } else return cfg.fail(arena, diag, "autologin '{s}' is not one of the [[users]]", .{img.autologin});
    }
    if (!std.mem.eql(u8, img.seat, "seatd") and !std.mem.eql(u8, img.seat, "elogind"))
        return cfg.fail(arena, diag, "seat '{s}': give \"seatd\" or \"elogind\"", .{img.seat});
    if (std.mem.eql(u8, img.login, "greetd") and img.autologin.len > 0 and img.session.len == 0)
        return cfg.fail(arena, diag, "login = \"greetd\" with 'autologin' needs 'session' (the command greetd starts for that user)", .{});
    return img;
}

/// The script that makes the image, run in the sandbox. /target is the root
/// being made, /dkrepo the repository (read-only), /dkkeys the trusted keys,
/// /out the output directory.
pub fn script(arena: Allocator, img: Image) Allocator.Error![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    const w = struct {
        fn add(a: Allocator, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
            try list.appendSlice(a, try std.fmt.allocPrint(a, fmt, args));
        }
    };
    try s.appendSlice(arena,
        \\set -eu
        \\# One stream, in order (the log, and `dkbuild image --verbose`).
        \\exec 2>&1
        \\# A root left by an earlier run holds files of other users, which only
        \\# this namespace may remove.
        \\find /target -mindepth 1 -delete
        \\echo '==> packages'
        \\mkdir -p /target/etc/apk/keys
        \\cp /dkkeys/*.pub /target/etc/apk/keys/
        \\
    );
    try w.add(arena, &s, "apk add --root /target --initdb --arch {s} --keys-dir /target/etc/apk/keys --repository /dkrepo/Packages.adb --no-network --no-cache", .{img.arch});
    for (img.packages) |p| try w.add(arena, &s, " {s}", .{p});
    if (std.mem.eql(u8, img.console, "dkconsole") and !contains(img.packages, "dkconsole")) try s.appendSlice(arena, " dkconsole");
    for (img.unwanted) |u| try w.add(arena, &s, " '!{s}'", .{u});
    try s.appendSlice(arena, "\n");
    try w.add(arena, &s, "echo '{s}' > /target/etc/hostname\n", .{img.hostname});
    // /etc/apk/repositories: the configured repositories, then the repository disc (commented out)
    try s.appendSlice(arena, "cat > /target/etc/apk/repositories <<'DKREPO_EOF'\n");
    for (img.repositories) |r| try w.add(arena, &s, "{s}\n", .{r});
    try w.add(arena, &s,
        \\# apk package repositories, one per line: a path to a Packages.adb, or a URL.
        \\#
        \\# FenrirOS repository disc (an ISO made by `dkbuild discs`, or its USB image), for
        \\# installing without a network: mount the disc, uncomment the line below, run
        \\# `apk update`. For example:
        \\#
        \\#     mkdir -p /mnt/cdrom && mount -o ro /dev/sr0 /mnt/cdrom
        \\#
        \\# (Every disc keeps it under data/; a directory filled by a disc's import.sh has apks/ without it.
        \\# One disc of a set of several has the whole index but only some of the packages.)
        \\# The @cdrom tag keeps the disc to packages you ask for with `apk add name@cdrom`;
        \\# remove the tag to make it an ordinary source for every package.
        \\#
        \\#@cdrom /mnt/cdrom/data/apks/{0s}/Packages.adb
        \\DKREPO_EOF
        \\
    , .{img.arch});

    try s.appendSlice(arena, "echo '==> services'\nmkdir -p /target/etc/dinit.d/boot.d\n");
    for (img.services) |sv| try w.add(arena, &s,
        \\if [ -e /target/etc/dinit.d/{0s} ]; then ln -sfn ../{0s} /target/etc/dinit.d/boot.d/{0s}
        \\elif [ -e /target/usr/lib/dinit.d/{0s} ]; then ln -sfn /usr/lib/dinit.d/{0s} /target/etc/dinit.d/boot.d/{0s}
        \\else echo "error: service '{0s}' is in no installed package" >&2; exit 1; fi
        \\
    , .{sv});

    const greetd = std.mem.eql(u8, img.login, "greetd");
    if (img.session.len > 0 and !greetd) try w.add(arena, &s,
        \\mkdir -p /target/etc/skel
        \\cat >> /target/etc/skel/.profile <<'EOF'
        \\# The desktop starts on the first console (dkbuild image: session).
        \\# Once only: a session may read this file again (dkde-session does).
        \\if [ "$(tty)" = /dev/tty1 ] && [ -z "${{WAYLAND_DISPLAY:-}}" ] && [ -z "${{SESSION_STARTED:-}}" ]; then
        \\    export SESSION_STARTED=1
        \\    exec {s}
        \\fi
        \\EOF
        \\
    , .{img.session});
    if (img.users.len > 0) try s.appendSlice(arena, "echo '==> users'\n");
    for (img.users) |u| {
        // useradd from the build machine, working on the image's /etc (-R).
        try w.add(arena, &s, "useradd -R /target -m -s '{s}'", .{u.shell});
        if (u.groups.len > 0) try w.add(arena, &s, " -G '{s}'", .{try std.mem.join(arena, ",", u.groups)});
        try w.add(arena, &s, " '{s}'\n", .{u.name});
        if (std.mem.eql(u8, u.password, "empty")) {
            try w.add(arena, &s, "usermod -R /target -p '' '{s}'\n", .{u.name});
        } else if (!std.mem.eql(u8, u.password, "locked")) {
            try w.add(arena, &s, "usermod -R /target -p '{s}' '{s}'\n", .{ u.password, u.name });
        }
    }

    if (std.mem.eql(u8, img.console, "dkconsole")) {
        // tty1-tty5 run dkconsole (tty1 stays agetty when it logs a user in at boot);
        // tty6 and ttyS0 keep agetty as the independent way in
        try s.appendSlice(arena, "echo '==> console (dkconsole)'\n[ -x /target/usr/bin/dkconsole ] || { echo \"error: no /usr/bin/dkconsole (the package did not install it)\" >&2; exit 1; }\n");
        // (greetd's autologin does not use tty1)
        var n: u8 = if (img.autologin.len > 0 and !greetd) 2 else 1;
        while (n <= 5) : (n += 1) try w.add(arena, &s,
            \\[ -f /target/etc/dinit.d/tty{0d} ] || {{ echo "error: no /etc/dinit.d/tty{0d} to run dkconsole on (add dinit-services)" >&2; exit 1; }}
            \\sed -i 's|^command = .*|command = /usr/bin/dkconsole --vt {0d}|' /target/etc/dinit.d/tty{0d}
            \\
        , .{n});
    }
    if (img.issue.len > 0) try w.add(arena, &s,
        \\echo '==> issue'
        \\cat > /target/etc/issue <<'DKISSUE_EOF'
        \\{s}
        \\DKISSUE_EOF
        \\
    , .{std.mem.trimEnd(u8, img.issue, "\n")});
    if (greetd) {
        try s.appendSlice(arena,
            \\echo '==> login (greetd)'
            \\[ -f /target/etc/greetd/config.toml ] || { echo "error: no /etc/greetd/config.toml (add the greetd package)" >&2; exit 1; }
            \\
        );
        // the greeter asks for a password: an empty one (the live user) must be accepted
        for (img.users) |u| if (std.mem.eql(u8, u.password, "empty")) {
            try s.appendSlice(arena,
                \\mkdir -p /target/etc/pam.d
                \\sed 's/^\(auth[[:space:]].*pam_unix\.so.*\)$/\1 nullok/' /target/usr/lib/pam.d/greetd > /target/etc/pam.d/greetd
                \\grep -q nullok /target/etc/pam.d/greetd || { echo "error: /usr/lib/pam.d/greetd has no pam_unix auth line to give nullok" >&2; exit 1; }
                \\
            );
            break;
        };
        if (std.mem.eql(u8, img.seat, "elogind")) try s.appendSlice(arena,
            \\[ -f /target/usr/lib/security/pam_elogind.so ] || { echo "error: seat = \"elogind\" but no pam_elogind.so (add the elogind package)" >&2; exit 1; }
            \\[ -f /target/etc/pam.d/greetd ] || { mkdir -p /target/etc/pam.d; cp /target/usr/lib/pam.d/greetd /target/etc/pam.d/greetd; }
            \\echo 'session  optional pam_elogind.so' >> /target/etc/pam.d/greetd
            \\sed -i 's/^depends-on: seatd$/depends-on: elogind/' /target/etc/dinit.d/greetd
            \\grep -q '^depends-on: elogind$' /target/etc/dinit.d/greetd || { echo "error: /etc/dinit.d/greetd has no 'depends-on: seatd' line to point at elogind" >&2; exit 1; }
            \\
        );
        if (img.autologin.len > 0) try w.add(arena, &s,
            \\cat >> /target/etc/greetd/config.toml <<'EOF'
            \\
            \\# The first session after boot starts without a login (dkbuild image: autologin).
            \\[initial_session]
            \\command = "{s}"
            \\user = "{s}"
            \\EOF
            \\
        , .{ try tomlEscaped(arena, img.session), img.autologin });
    }
    if (img.autologin.len > 0 and !greetd) try w.add(arena, &s,
        \\echo '==> autologin'
        \\[ -f /target/etc/dinit.d/tty1 ] || {{ echo "error: no /etc/dinit.d/tty1 to log in on (add dinit-services)" >&2; exit 1; }}
        \\sed -i 's|^command = /sbin/agetty |command = /sbin/agetty --autologin {s} |' /target/etc/dinit.d/tty1
        \\
    , .{img.autologin});
    for (img.output) |o| {
        if (std.mem.eql(u8, o, "tar")) {
            try w.add(arena, &s, "echo '==> tar'\ntar -C /target --numeric-owner --xattrs -cf - . | zstd -T0 -19 -q -o /out/{s}.tar.zst\n", .{img.name});
        } else if (std.mem.eql(u8, o, "squashfs")) {
            try w.add(arena, &s, "echo '==> squashfs'\nmksquashfs /target /out/{s}.sfs -comp zstd -noappend -quiet\n", .{img.name});
        } else if (std.mem.eql(u8, o, "iso")) {
            // A hybrid BIOS + UEFI ISO booted by dklilo (its README's recipe):
            // the kernel and initramfs in the ISO 9660 part, the root as a
            // squashfs the live init mounts under a RAM overlay.
            try w.add(arena, &s,
                \\echo '==> iso'
                \\t=/out/.iso-tree; img=/out/.iso-img
                \\rm -rf "$t" "$img"; mkdir -p "$t/boot/dklilo" "$t/live" "$img"
                \\k=$(ls /target/boot/vmlinuz-* 2>/dev/null | sort | tail -n1)
                \\[ -n "$k" ] || {{ echo "error: no kernel in /boot (add 'linux' to packages)" >&2; exit 1; }}
                \\cp "$k" "$t/boot/vmlinuz"
                \\cp /target/usr/lib/live/initrd.img "$t/boot/initrd.img"
                \\# The installer's minimum disk size: what the root takes, unpacked.
                \\du -sb /target | cut -f1 > "$t/live/rootfs.size"
                \\# This ISO's own ID, on the disc and on every boot menu entry: the initramfs boots only the system
                \\# image that came with its kernel, never another ISO's that happens to be on some drive.
                \\buildid=$(cat /proc/sys/kernel/random/uuid)
                \\echo "$buildid" > "$t/live/build.id"
                \\# Which image this is, in the system (/etc/fenriros-image) and on the disc, so that a report of a
                \\# problem can name the exact ISO, whatever the file or USB stick is called.
                \\printf 'IMAGE={0s}\nBUILT=%s\nBUILD_ID=%s\n' "$DKIMAGE_STAMP" "$buildid" > /target/etc/fenriros-image
                \\cp /target/etc/fenriros-image "$t/live/image.info"
                \\mksquashfs /target "$t/live/rootfs.sfs" -comp zstd -noappend -quiet
                \\# The image's own dklilo: its boot loader goes onto the disc. The build machine's is
                \\# whatever its image was made with (DKRescue's 0.0.1 had no keyboard at a BIOS menu).
                \\dklilo=/target/usr/sbin/dklilo
                \\[ -x "$dklilo" ] || {{ echo "error: no /usr/sbin/dklilo in the image (add 'dklilo' to packages)" >&2; exit 1; }}
                \\"$dklilo" mkiso-images "$img"
                \\cp "$img/eltorito.bin" "$img/efiboot.img" "$t/boot/dklilo/"
                \\cat > "$t/boot/dklilo.conf" <<'EOF'
                \\timeout = 50
                \\default = {0s}
                \\serial  = 0,115200
                \\
                \\image   = /boot/vmlinuz
                \\    label  = {0s}
                \\    append = "root=live:LABEL={1s} quiet fenriros.build=@BUILDID@"
                \\    initrd = /boot/initrd.img
                \\
                \\image   = /boot/vmlinuz
                \\    label  = {0s}-safe
                \\    append = "root=live:LABEL={1s} nomodeset fenriros.build=@BUILDID@"
                \\    initrd = /boot/initrd.img
                \\
                \\image   = /boot/vmlinuz
                \\    label  = {0s}-toram
                \\    append = "root=live:LABEL={1s} toram fenriros.build=@BUILDID@"
                \\    initrd = /boot/initrd.img
                \\
                \\image   = /boot/vmlinuz
                \\    label  = {0s}-serial
                \\    append = "root=live:LABEL={1s} console=tty0 console=ttyS0,115200 fenriros.build=@BUILDID@"
                \\    initrd = /boot/initrd.img
                \\EOF
                \\sed -i "s/@BUILDID@/$buildid/g" "$t/boot/dklilo.conf"
                \\xorriso -as mkisofs -R -V {1s} -o /out/{0s}.iso \
                \\    --grub2-mbr "$img/mbr.bin" \
                \\    -b boot/dklilo/eltorito.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
                \\    -eltorito-alt-boot -e boot/dklilo/efiboot.img -no-emul-boot \
                \\    -append_partition 2 0xEF "$img/efiboot.img" -appended_part_as_gpt \
                \\    "$t"
                \\"$dklilo" isohybrid /out/{0s}.iso
                \\rm -rf "$t" "$img"
                \\
            , .{ img.name, img.label });
        }
    }
    // Only a rootfs output keeps the root on disk.
    if (!contains(img.output, "rootfs")) try s.appendSlice(arena, "find /target -mindepth 1 -delete\n");
    return s.items;
}

pub const Options = struct {
    /// Project root (holds repo/, keys/, rootfs/, work/).
    root: []const u8,
    /// Show the image script's output (apk's "Installing <package>" lines,
    /// services, users, outputs) while it runs, not only in the log.
    verbose: bool = false,
    /// Also keep the ISO under a dated name in out/archive/ (see `keepDated`).
    dated: bool = false,
};

/// The time an image is made, YYYYMMDD-HHMM in the build machine's time zone: in the ISO (/etc/fenriros-image,
/// live/image.info) and, with `--date`, in the kept copy's name.
fn timeStamp(arena: Allocator, io: std.Io) ![]const u8 {
    const r = std.process.run(arena, io, .{ .argv = &.{ "date", "+%Y%m%d-%H%M" } }) catch return error.PrepareFailed;
    const s = std.mem.trim(u8, r.stdout, " \n");
    if (r.term != .exited or r.term.exited != 0 or s.len != 13 or !safeWord(s)) return error.PrepareFailed;
    return s;
}

/// Keeps out/<name>/<name>.iso as out/archive/<name>-<stamp>.iso, with its .sha256 and the image's log beside it,
/// so that one exact ISO can still be named after later builds have replaced out/<name>/. A hard link, so it costs
/// no space while out/<name>/ holds the same ISO (a copy where links do not work). Nothing is ever written over: a
/// second ISO of the same minute gets "-2". Returns the kept ISO's path.
fn keepDated(arena: Allocator, io: std.Io, root: []const u8, name: []const u8, stamp: []const u8) ![]const u8 {
    const dir = try std.fs.path.join(arena, &.{ root, "out", "archive" });
    Dir.cwd().createDirPath(io, dir) catch return error.ArchiveFailed;
    const made = try std.fmt.allocPrint(arena, "{s}/out/{s}/{s}.iso", .{ root, name, name });
    var n: u8 = 1;
    const base, const iso = while (n < 100) : (n += 1) {
        const base = if (n == 1) try std.fmt.allocPrint(arena, "{s}-{s}", .{ name, stamp }) else try std.fmt.allocPrint(arena, "{s}-{s}-{d}", .{ name, stamp, n });
        const iso = try std.fmt.allocPrint(arena, "{s}/{s}.iso", .{ dir, base });
        _ = Dir.cwd().statFile(io, iso, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => break .{ base, iso },
            else => return error.ArchiveFailed,
        };
    } else return error.ArchiveFailed;
    if (!runs(arena, io, &.{ "ln", "--", made, iso }) and !runs(arena, io, &.{ "cp", "--", made, iso })) return error.ArchiveFailed;
    const sum = std.process.run(arena, io, .{ .argv = &.{ "sha256sum", "--", iso } }) catch return error.ArchiveFailed;
    if (sum.term != .exited or sum.term.exited != 0 or sum.stdout.len < 64) return error.ArchiveFailed;
    // the line `sha256sum -c` reads, naming the file without its directory
    Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}.sha256", .{iso}),
        .data = try std.fmt.allocPrint(arena, "{s}  {s}.iso\n", .{ sum.stdout[0..64], base }),
    }) catch return error.ArchiveFailed;
    if (!runs(arena, io, &.{ "cp", "--", try std.fmt.allocPrint(arena, "{s}/out/{s}/image.log", .{ root, name }), try std.fmt.allocPrint(arena, "{s}/{s}.log", .{ dir, base }) })) return error.ArchiveFailed;
    return iso;
}

fn runs(arena: Allocator, io: std.Io, argv: []const []const u8) bool {
    const r = std.process.run(arena, io, .{ .argv = argv }) catch return false;
    return r.term == .exited and r.term.exited == 0;
}

/// Deletes an image's directory and says whether it is gone. In a `rootfs` output, users' homes and service
/// accounts' files belong to the caller's sub-ids, which the caller cannot remove: what is left after an ordinary
/// delete is emptied by a sandbox with the same ids mapped, given that one directory.
fn removeImageDir(arena: Allocator, io: std.Io, root: []const u8, path: []const u8, ids: ?sandbox.Ids) bool {
    const st = Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return true;
    if (st.kind != .directory) { // a link here is removed, never followed
        Dir.cwd().deleteFile(io, path) catch return false;
        return true;
    }
    _ = std.process.run(arena, io, .{ .argv = &.{ "chmod", "-R", "u+rwX", "--", path } }) catch {};
    Dir.cwd().deleteTree(io, path) catch {};
    _ = Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return true;
    const map = ids orelse return false;
    const lower = Dir.cwd().realPathFileAlloc(io, std.fs.path.join(arena, &.{ root, "rootfs", "dkrescue" }) catch return false, arena) catch return false;
    const victim = Dir.cwd().realPathFileAlloc(io, path, arena) catch return false;
    const scratch = std.fs.path.join(arena, &.{ root, "work", "image-remove" }) catch return false;
    var sb: [3][]const u8 = undefined;
    for ([_][]const u8{ "upper", "work", "merged" }, &sb) |name, *d| {
        const rel = std.fs.path.join(arena, &.{ scratch, name }) catch return false;
        Dir.cwd().createDirPath(io, rel) catch return false;
        d.* = Dir.cwd().realPathFileAlloc(io, rel, arena) catch return false;
    }
    var log: std.ArrayList(u8) = .empty;
    _ = sandbox.run(arena, io, .{
        .lower = lower,
        .upper = sb[0],
        .work = sb[1],
        .merged = sb[2],
        .binds = &.{.{ .src = victim, .dst = "/victim" }},
        .env = &.{"PATH=/usr/bin:/bin"},
        .argv = &.{ "/usr/bin/find", "/victim", "-mindepth", "1", "-delete" },
        .ids = map,
    }, &log) catch {};
    sandbox.makeRemovable(io, sb[1]);
    Dir.cwd().deleteTree(io, scratch) catch {};
    Dir.cwd().deleteTree(io, path) catch {};
    _ = Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return true;
    return false;
}

pub fn build(arena: Allocator, io: std.Io, img: Image, opts: Options) !void {
    // The image is made in out/.<name>.new and replaces out/<name> only when it
    // succeeds: a failed run leaves the last good ISO where it was.
    const final_rel = try std.fs.path.join(arena, &.{ opts.root, "out", img.name });
    const out_rel = try std.fs.path.join(arena, &.{ opts.root, "out", try std.fmt.allocPrint(arena, ".{s}.new", .{img.name}) });
    const target_rel = try std.fs.path.join(arena, &.{ out_rel, "rootfs" });
    const work = try std.fs.path.join(arena, &.{ opts.root, "work", try std.fmt.allocPrint(arena, "image-{s}", .{img.name}) });
    // the previous image, once the new one has taken its place
    const old_rel = try std.fs.path.join(arena, &.{ opts.root, "out", try std.fmt.allocPrint(arena, ".{s}.old", .{img.name}) });
    const may_own = sandbox.subIds(arena, io);
    // Start from nothing: an unfinished earlier attempt is removed.
    for ([_][]const u8{ out_rel, work, old_rel }) |d| if (!removeImageDir(arena, io, opts.root, d, may_own)) {
        std.debug.print("error: cannot remove {s}, left by an earlier run\n", .{d});
        return error.PrepareFailed;
    };
    Dir.cwd().createDirPath(io, target_rel) catch return error.PrepareFailed;
    var abs: [6][]const u8 = undefined;
    const rels = [_][]const u8{
        target_rel,
        out_rel,
        try std.fs.path.join(arena, &.{ opts.root, "repo", img.arch }),
        try std.fs.path.join(arena, &.{ opts.root, "keys" }),
        try std.fs.path.join(arena, &.{ opts.root, "rootfs", "dkrescue" }),
        work,
    };
    Dir.cwd().createDirPath(io, work) catch return error.PrepareFailed;
    for (rels, &abs) |r, *a| a.* = Dir.cwd().realPathFileAlloc(io, r, arena) catch {
        std.debug.print("error: {s} is missing\n", .{r});
        return error.PrepareFailed;
    };
    var sb: [3][]const u8 = undefined;
    for ([_][]const u8{ "upper", "work", "merged" }, &sb) |sub, *p| {
        const rel = try std.fs.path.join(arena, &.{ work, sub });
        Dir.cwd().createDirPath(io, rel) catch return error.PrepareFailed;
        p.* = Dir.cwd().realPathFileAlloc(io, rel, arena) catch return error.PrepareFailed;
    }
    if (opts.dated and !contains(img.output, "iso")) {
        std.debug.print("error: --date is for an ISO, and image {s} makes none\n", .{img.name});
        return error.PrepareFailed;
    }
    const stamp = timeStamp(arena, io) catch {
        std.debug.print("error: cannot read the time with `date`\n", .{});
        return error.PrepareFailed;
    };
    const text = try script(arena, img);
    const script_path = try std.fs.path.join(arena, &.{ abs[5], "image.sh" });
    Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = text }) catch return error.PrepareFailed;

    // Files owned by users other than root (a user's home, a package's
    // service account) need the caller's sub-ids mapped too.
    const ids = sandbox.subIds(arena, io);
    if (ids == null and img.users.len > 0) {
        std.debug.print("error: image {s} makes users, whose files need sub-ids: give your user a range in /etc/subuid and /etc/subgid and install newuidmap/newgidmap (Ubuntu: uidmap)\n", .{img.name});
        return error.PrepareFailed;
    }
    std.debug.print("==> image {s} ({d} package(s) asked for)\n", .{ img.name, img.packages.len });
    if (opts.verbose) for (img.packages) |p| std.debug.print("    {s}\n", .{p});
    var log: std.ArrayList(u8) = .empty;
    const ok = sandbox.run(arena, io, .{
        .lower = abs[4],
        .upper = sb[0],
        .work = sb[1],
        .merged = sb[2],
        .binds = &.{
            .{ .src = abs[0], .dst = "/target" },
            .{ .src = abs[1], .dst = "/out" },
            .{ .src = abs[2], .dst = "/dkrepo", .read_only = true },
            .{ .src = abs[3], .dst = "/dkkeys", .read_only = true },
            .{ .src = script_path, .dst = "/image.sh", .read_only = true },
        },
        .env = &.{ "PATH=/usr/bin:/usr/sbin:/bin:/sbin", "HOME=/root", try std.fmt.allocPrint(arena, "DKIMAGE_STAMP={s}", .{stamp}) },
        .argv = &.{ "/usr/bin/sh", "/image.sh" },
        .ids = ids,
        .echo = opts.verbose,
    }, &log) catch false;
    sandbox.makeRemovable(io, sb[1]);
    Dir.cwd().deleteTree(io, work) catch {};
    if (!ok) {
        // The log goes beside the old image, which stays.
        const logpath = try std.fmt.allocPrint(arena, "{s}-failed.log", .{final_rel});
        Dir.cwd().writeFile(io, .{ .sub_path = logpath, .data = log.items }) catch {};
        _ = removeImageDir(arena, io, opts.root, out_rel, ids);
        const tail_start = if (log.items.len > 2000) log.items.len - 2000 else 0;
        std.debug.print("{s}\nerror: image {s} failed; log: {s} (out/{s}/ is unchanged)\n", .{ log.items[tail_start..], img.name, logpath, img.name });
        return error.BuildFailed;
    }
    const logpath = try std.fmt.allocPrint(arena, "{s}/image.log", .{out_rel});
    Dir.cwd().writeFile(io, .{ .sub_path = logpath, .data = log.items }) catch {};
    if (!contains(img.output, "rootfs")) _ = removeImageDir(arena, io, opts.root, target_rel, ids);
    // Succeeded: the new image replaces the old one. The old one is moved aside first and removed afterwards, so
    // that nothing of it is lost unless the new one is in place.
    const had_one = if (Dir.cwd().rename(final_rel, Dir.cwd(), old_rel, io)) |_| true else |err| switch (err) {
        error.FileNotFound => false,
        else => {
            std.debug.print("error: cannot move the old {s} aside: {s}\n", .{ final_rel, @errorName(err) });
            return error.BuildFailed;
        },
    };
    Dir.cwd().rename(out_rel, Dir.cwd(), final_rel, io) catch |err| {
        if (had_one) Dir.cwd().rename(old_rel, Dir.cwd(), final_rel, io) catch {};
        std.debug.print("error: cannot move {s} to {s}: {s}\n", .{ out_rel, final_rel, @errorName(err) });
        return error.BuildFailed;
    };
    if (had_one and !removeImageDir(arena, io, opts.root, old_rel, ids)) std.debug.print("warning: the previous image is left at {s}\n", .{old_rel});
    Dir.cwd().deleteFile(io, try std.fmt.allocPrint(arena, "{s}-failed.log", .{final_rel})) catch {};
    std.debug.print("    made", .{});
    for (img.output) |o| {
        if (std.mem.eql(u8, o, "rootfs")) std.debug.print(" {s}/rootfs/", .{final_rel});
        if (std.mem.eql(u8, o, "tar")) std.debug.print(" {s}/{s}.tar.zst", .{ final_rel, img.name });
        if (std.mem.eql(u8, o, "squashfs")) std.debug.print(" {s}/{s}.sfs", .{ final_rel, img.name });
        if (std.mem.eql(u8, o, "iso")) std.debug.print(" {s}/{s}.iso", .{ final_rel, img.name });
    }
    std.debug.print("; log: {s}/image.log\n", .{final_rel});
    if (opts.dated) {
        const kept = keepDated(arena, io, opts.root, img.name, stamp) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                std.debug.print("error: the image was made, but its dated copy could not be kept in {s}/out/archive/\n", .{opts.root});
                return error.BuildFailed;
            },
        };
        std.debug.print("    kept as {s}\n", .{kept});
    }
}

fn contains(hay: []const []const u8, needle: []const u8) bool {
    for (hay) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

/// `s` as the inside of a TOML basic string.
fn tomlEscaped(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c == '"' or c == '\\') try out.append(arena, '\\');
        try out.append(arena, c);
    }
    return out.items;
}

/// A word that is given to a command as an argument: never read as an option (a "package" `--allow-untrusted`
/// would turn signature checking off).
fn plainWord(s: []const u8) bool {
    return safeWord(s) and s[0] != '-';
}

fn safeWord(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '+' => {},
        else => return false,
    };
    return true;
}

/// `*` matches any run of characters.
fn glob(pat: []const u8, s: []const u8) bool {
    if (pat.len == 0) return s.len == 0;
    if (pat[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) if (glob(pat[1..], s[i..])) return true;
        return false;
    }
    return s.len > 0 and s[0] == pat[0] and glob(pat[1..], s[1..]);
}

test "image files parse; bad outputs, excluded packages and odd names are refused" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var diag: Diagnostic = .{};
    const img = try parse(a,
        \\name = "fenriros"
        \\packages = ["base", "hyprland"]
        \\exclude = ["*-devel"]
        \\services = ["udevd", "seatd"]
        \\output = ["rootfs", "tar"]
        \\[[users]]
        \\name = "fenrir"
        \\groups = ["wheel", "video"]
        \\
    , &diag);
    try std.testing.expectEqualStrings("x86_64", img.arch);
    try std.testing.expectEqualStrings("wheel", img.users[0].groups[0]);
    try std.testing.expectEqualStrings("locked", img.users[0].password);
    try std.testing.expectError(error.InvalidImage, parse(a, "name = \"x\"\npackages = [\"a\"]\noutput = [\"img\"]\n", &diag));
    try std.testing.expectEqualStrings("unknown output 'img'; give any of rootfs, tar, squashfs, iso", diag.message);
    try std.testing.expectError(error.InvalidImage, parse(a, "name = \"x\"\npackages = [\"a\"]\noutput = [\"iso\"]\n", &diag));
    try std.testing.expectEqualStrings("the iso output needs 'live-initramfs' in packages (the live system's initramfs)", diag.message);
    const live = try parse(a, "name = \"base\"\npackages = [\"linux\", \"live-initramfs\"]\noutput = [\"iso\"]\n", &diag);
    try std.testing.expectEqualStrings("BASE", live.label);
    const ls = try script(a, live);
    try std.testing.expect(std.mem.indexOf(u8, ls, "root=live:LABEL=BASE quiet") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls, "-V BASE -o /out/base.iso") != null);
    // the boot loader written to the disc is the image's, never the build machine's (a bare `dklilo`)
    try std.testing.expect(std.mem.indexOf(u8, ls, "\ndklilo=/target/usr/sbin/dklilo\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls, "\n\"$dklilo\" mkiso-images ") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls, "\n\"$dklilo\" isohybrid /out/base.iso\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls, "\ndklilo ") == null);
    // the optional entry that copies the system into RAM (live-initramfs' init reads `toram`); never the default
    try std.testing.expect(std.mem.indexOf(u8, ls, "label  = base-toram\n    append = \"root=live:LABEL=BASE toram fenriros.build=@BUILDID@\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls, "default = base\n") != null);
    // the disc and every menu entry carry the same new ID
    try std.testing.expect(std.mem.indexOf(u8, ls, "\necho \"$buildid\" > \"$t/live/build.id\"\n") != null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, ls, " fenriros.build=@BUILDID@\"\n"));
    try std.testing.expect(std.mem.indexOf(u8, ls, "\nsed -i \"s/@BUILDID@/$buildid/g\" \"$t/boot/dklilo.conf\"\n") != null);
    // the system and the disc say which build they are, with the same ID as the boot entries
    try std.testing.expect(std.mem.indexOf(u8, ls, "\nprintf 'IMAGE=base\\nBUILT=%s\\nBUILD_ID=%s\\n' \"$DKIMAGE_STAMP\" \"$buildid\" > /target/etc/fenriros-image\ncp /target/etc/fenriros-image \"$t/live/image.info\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls, "> /target/etc/fenriros-image\n").? < std.mem.indexOf(u8, ls, "\nmksquashfs /target \"$t/live/rootfs.sfs\"").?);
    try std.testing.expectError(error.InvalidImage, parse(a, "name = \"x\"\npackages = [\"a-devel\"]\nexclude = [\"*-devel\"]\noutput = [\"tar\"]\n", &diag));
    try std.testing.expectError(error.InvalidImage, parse(a, "name = \"x\"\npackages = [\"a;rm\"]\noutput = [\"tar\"]\n", &diag));
    const s = try script(a, img);
    try std.testing.expect(std.mem.indexOf(u8, s, "--initdb --arch x86_64") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, " base hyprland\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "useradd -R /target -m -s '/bin/bash' -G 'wheel,video' 'fenrir'") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "fenriros.tar.zst") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "mksquashfs") == null);
}

test "a dated ISO is kept in out/archive/, is never written over and outlives its out/<name>/" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "out/x");
    try tmp.dir.writeFile(io, .{ .sub_path = "out/x/x.iso", .data = "first" });
    try tmp.dir.writeFile(io, .{ .sub_path = "out/x/image.log", .data = "log" });
    const first = try keepDated(a, io, root, "x", "20261127-1530");
    try std.testing.expect(std.mem.endsWith(u8, first, "/out/archive/x-20261127-1530.iso"));
    // what a later image run does: the old directory goes, a new ISO takes its place, here in the same minute
    try tmp.dir.deleteTree(io, "out/x");
    try tmp.dir.createDirPath(io, "out/x");
    try tmp.dir.writeFile(io, .{ .sub_path = "out/x/x.iso", .data = "second" });
    try tmp.dir.writeFile(io, .{ .sub_path = "out/x/image.log", .data = "log" });
    const second = try keepDated(a, io, root, "x", "20261127-1530");
    try std.testing.expect(std.mem.endsWith(u8, second, "/out/archive/x-20261127-1530-2.iso"));
    try std.testing.expectEqualStrings("first", try Dir.cwd().readFileAlloc(io, first, a, .limited(64)));
    try std.testing.expectEqualStrings("second", try Dir.cwd().readFileAlloc(io, second, a, .limited(64)));
    // sha256 of "first", in the form `sha256sum -c` reads
    try std.testing.expectEqualStrings("a7937b64b8caa58f03721bb6bacf5c78cb235febe0e70b1b84cd99541461a08e  x-20261127-1530.iso\n", try tmp.dir.readFileAlloc(io, "out/archive/x-20261127-1530.iso.sha256", a, .limited(256)));
    try std.testing.expectEqualStrings("log", try tmp.dir.readFileAlloc(io, "out/archive/x-20261127-1530.log", a, .limited(64)));
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidImage, parse(a, "name = \"archive\"\npackages = [\"a\"]\noutput = [\"tar\"]\n", &diag));
}

test "an image name that would name another directory is refused (ID-03)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const a = arena_state.allocator();
    // out/<name> is deleted when an image succeeds: ".." is the build tree itself
    for ([_][]const u8{ "..", ".", ".hidden", "-rf" }) |bad|
        try std.testing.expectError(error.InvalidImage, parse(a, try std.fmt.allocPrint(a, "name = \"{s}\"\npackages = [\"a\"]\noutput = [\"tar\"]\n", .{bad}), &diag));
    try std.testing.expectError(error.InvalidImage, parse(a, "name = \"x\"\narch = \"../..\"\npackages = [\"a\"]\noutput = [\"tar\"]\n", &diag));
    _ = try parse(a, "name = \"dkde-devel.2\"\npackages = [\"a\"]\noutput = [\"tar\"]\n", &diag);
}

test "image values that reach a command or a config file are checked or escaped (ID-14, ID-15, ID-16)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const a = arena_state.allocator();
    const head = "name = \"x\"\noutput = [\"tar\"]\n";
    // a name that is an option: apk would read '--allow-untrusted' and stop checking signatures
    for ([_][]const u8{ "packages = [\"--allow-untrusted\", \"base\"]", "packages = [\"a\"]\nunwanted = [\"-x\"]", "packages = [\"a\"]\nservices = [\"-q\"]", "packages = [\"a\"]\nhostname = \"-F\"", "packages = [\"a\"]\n[[users]]\nname = \"-o\"", "packages = [\"a\"]\n[[users]]\nname = \"u\"\ngroups = [\"-p\"]", "packages = [\"a\"]\narch = \"x86_64; rm -rf /\"" }) |bad|
        try std.testing.expectError(error.InvalidImage, parse(a, try std.fmt.allocPrint(a, "{s}{s}\n", .{ head, bad }), &diag));
    // a session command with quotes stays a valid greetd string
    const base = head ++ "packages = [\"a\"]\nautologin = \"u\"\nlogin = \"greetd\"\nconsole = \"dkconsole\"\n";
    const img = try parse(a, base ++ "session = \"sh -c \\\"dkde-session\\\"\"\n[[users]]\nname = \"u\"\n", &diag);
    const s = try script(a, img);
    try std.testing.expect(std.mem.indexOf(u8, s, "command = \"sh -c \\\"dkde-session\\\"\"\n") != null);
    // greetd's autologin does not use tty1, so dkconsole gets it
    try std.testing.expect(std.mem.indexOf(u8, s, "dkconsole --vt 1|' /target/etc/dinit.d/tty1") != null);
}

test "an image's issue text is written to /etc/issue" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    const img = try parse(a, "name = \"x\"\npackages = [\"a\"]\noutput = [\"tar\"]\nissue = \"\"\"\nFenrirOS \\\\r (\\\\l)\nLog in as rescue\n\"\"\"\n", &diag);
    const s = try script(a, img);
    try std.testing.expect(std.mem.indexOf(u8, s, "cat > /target/etc/issue <<'DKISSUE_EOF'\nFenrirOS \\r (\\l)\nLog in as rescue\nDKISSUE_EOF\n") != null);
    try std.testing.expectError(error.InvalidImage, parse(a, "name = \"x\"\npackages = [\"a\"]\noutput = [\"tar\"]\nissue = \"DKISSUE_EOF\"\n", &diag));
}

test "console = dkconsole adds the package and moves tty1-tty5 off agetty, keeping tty6" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    const img = try parse(a, "name = \"x\"\npackages = [\"a\"]\noutput = [\"tar\"]\nconsole = \"dkconsole\"\n", &diag);
    const s = try script(a, img);
    try std.testing.expect(std.mem.indexOf(u8, s, " dkconsole") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "dkconsole --vt 1|' /target/etc/dinit.d/tty1") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "dkconsole --vt 5|' /target/etc/dinit.d/tty5") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "dinit.d/tty6") == null);
    const auto = try parse(a, "name = \"x\"\npackages = [\"a\"]\noutput = [\"tar\"]\nconsole = \"dkconsole\"\nautologin = \"u\"\n[[users]]\nname = \"u\"\n", &diag);
    const s2 = try script(a, auto);
    try std.testing.expect(std.mem.indexOf(u8, s2, "dkconsole --vt 1|' /target/etc/dinit.d/tty1") == null);
    try std.testing.expectError(error.InvalidImage, parse(a, "name = \"x\"\npackages = [\"a\"]\noutput = [\"tar\"]\nconsole = \"mingetty\"\n", &diag));
}

test "login = greetd writes initial_session and a nullok PAM file instead of the tty1 autologin" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    const base = "name = \"x\"\npackages = [\"a\"]\noutput = [\"tar\"]\nautologin = \"u\"\nsession = \"dkde-session\"\n";
    const img = try parse(a, base ++ "login = \"greetd\"\n[[users]]\nname = \"u\"\npassword = \"empty\"\n", &diag);
    const s = try script(a, img);
    try std.testing.expect(std.mem.indexOf(u8, s, "[initial_session]\ncommand = \"dkde-session\"\nuser = \"u\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "> /target/etc/pam.d/greetd") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "agetty --autologin") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, ".profile") == null);
    // a locked user: no nullok file; the console login keeps working as before
    const locked = try script(a, try parse(a, base ++ "login = \"greetd\"\n[[users]]\nname = \"u\"\n", &diag));
    try std.testing.expect(std.mem.indexOf(u8, locked, "/target/etc/pam.d/greetd") == null);
    const con = try script(a, try parse(a, base ++ "[[users]]\nname = \"u\"\n", &diag));
    try std.testing.expect(std.mem.indexOf(u8, con, "agetty --autologin u") != null);
    try std.testing.expect(std.mem.indexOf(u8, con, "greetd") == null);
    try std.testing.expectError(error.InvalidImage, parse(a, "name = \"x\"\npackages = [\"a\"]\noutput = [\"tar\"]\nlogin = \"gdm\"\n", &diag));
    try std.testing.expectError(error.InvalidImage, parse(a, "name = \"x\"\npackages = [\"a\"]\noutput = [\"tar\"]\nlogin = \"greetd\"\nautologin = \"u\"\n[[users]]\nname = \"u\"\n", &diag));
}

test "seat = elogind: greetd waits for elogind and its PAM file registers the session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    const base = "name = \"x\"\npackages = [\"a\"]\noutput = [\"tar\"]\nlogin = \"greetd\"\n";
    const el = try script(a, try parse(a, base ++ "seat = \"elogind\"\n", &diag));
    try std.testing.expect(std.mem.indexOf(u8, el, "pam_elogind.so' >> /target/etc/pam.d/greetd") != null);
    try std.testing.expect(std.mem.indexOf(u8, el, "s/^depends-on: seatd$/depends-on: elogind/") != null);
    const sd = try script(a, try parse(a, base, &diag));
    try std.testing.expect(std.mem.indexOf(u8, sd, "pam_elogind") == null);
    try std.testing.expectError(error.InvalidImage, parse(a, base ++ "seat = \"x\"\n", &diag));
}

test "unwanted packages are passed to apk as !name and may not also be asked for" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    const img = try parse(a, "name = \"x\"\npackages = [\"a\"]\nunwanted = [\"dhcpcd\"]\noutput = [\"tar\"]\n", &diag);
    const s = try script(a, img);
    try std.testing.expect(std.mem.indexOf(u8, s, " a '!dhcpcd'\n") != null);
    try std.testing.expectError(error.InvalidImage, parse(a, "name = \"x\"\npackages = [\"a\"]\nunwanted = [\"a\"]\noutput = [\"tar\"]\n", &diag));
}

test "the image writes /etc/apk/repositories with the repository disc commented out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    const img = try parse(a, "name = \"x\"\npackages = [\"a\"]\nrepositories = [\"https://example.org/x86_64/Packages.adb\"]\noutput = [\"tar\"]\n", &diag);
    const s = try script(a, img);
    try std.testing.expect(std.mem.indexOf(u8, s, "cat > /target/etc/apk/repositories <<'DKREPO_EOF'\nhttps://example.org/x86_64/Packages.adb\n# apk package repositories") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\n#@cdrom /mnt/cdrom/data/apks/x86_64/Packages.adb\nDKREPO_EOF\n") != null);
    try std.testing.expectError(error.InvalidImage, parse(a, "name = \"x\"\npackages = [\"a\"]\nrepositories = [\"a\\nb\"]\noutput = [\"tar\"]\n", &diag));
}
