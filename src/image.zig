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
    shell: []const u8 = "/bin/sh",
};

pub const Image = struct {
    name: []const u8,
    arch: []const u8 = "x86_64",
    packages: []const []const u8,
    /// Patterns (`*` within a name) no package named in `packages` may match.
    exclude: []const []const u8 = &.{},
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
    try cfg.onlyKeys(arena, diag, root, &.{ "name", "arch", "packages", "exclude", "services", "users", "hostname", "label", "autologin", "session", "output" }, "");
    var img: Image = .{
        .name = try cfg.reqString(arena, diag, root, "name"),
        .packages = try cfg.optStrings(arena, diag, root, "packages"),
        .exclude = try cfg.optStrings(arena, diag, root, "exclude"),
        .services = try cfg.optStrings(arena, diag, root, "services"),
        .output = try cfg.optStrings(arena, diag, root, "output"),
    };
    if (try cfg.optString(arena, diag, root, "arch")) |a| img.arch = a;
    if (try cfg.optString(arena, diag, root, "hostname")) |h| img.hostname = h;
    if (try cfg.optString(arena, diag, root, "autologin")) |u| img.autologin = u;
    if (try cfg.optString(arena, diag, root, "session")) |c| img.session = c;
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
    if (img.label.len > 32) return cfg.fail(arena, diag, "label '{s}' is longer than an ISO volume label (32)", .{img.label});
    for (img.packages) |p| for (img.exclude) |x| if (glob(x, p))
        return cfg.fail(arena, diag, "package '{s}' matches exclude pattern '{s}'", .{ p, x });
    for ([_][]const []const u8{ img.packages, img.services, &.{ img.name, img.hostname, img.label } }) |list| for (list) |s| if (!safeWord(s))
        return cfg.fail(arena, diag, "'{s}': only letters, digits, '-', '_', '.', '+'", .{s});

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
            for ([_][]const []const u8{ &.{u.name}, u.groups }) |list| for (list) |s| if (!safeWord(s))
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
    try s.appendSlice(arena, "\n");
    try w.add(arena, &s, "echo '{s}' > /target/etc/hostname\n", .{img.hostname});

    try s.appendSlice(arena, "echo '==> services'\nmkdir -p /target/etc/dinit.d/boot.d\n");
    for (img.services) |sv| try w.add(arena, &s,
        \\if [ -e /target/etc/dinit.d/{0s} ]; then ln -sfn ../{0s} /target/etc/dinit.d/boot.d/{0s}
        \\elif [ -e /target/usr/lib/dinit.d/{0s} ]; then ln -sfn /usr/lib/dinit.d/{0s} /target/etc/dinit.d/boot.d/{0s}
        \\else echo "error: service '{0s}' is in no installed package" >&2; exit 1; fi
        \\
    , .{sv});

    if (img.session.len > 0) try w.add(arena, &s,
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

    if (img.autologin.len > 0) try w.add(arena, &s,
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
                \\mksquashfs /target "$t/live/rootfs.sfs" -comp zstd -noappend -quiet
                \\dklilo mkiso-images "$img"
                \\cp "$img/eltorito.bin" "$img/efiboot.img" "$t/boot/dklilo/"
                \\cat > "$t/boot/dklilo.conf" <<'EOF'
                \\timeout = 50
                \\default = {0s}
                \\serial  = 0,115200
                \\
                \\image   = /boot/vmlinuz
                \\    label  = {0s}
                \\    append = "root=live:LABEL={1s} quiet"
                \\    initrd = /boot/initrd.img
                \\
                \\image   = /boot/vmlinuz
                \\    label  = {0s}-safe
                \\    append = "root=live:LABEL={1s} nomodeset"
                \\    initrd = /boot/initrd.img
                \\
                \\image   = /boot/vmlinuz
                \\    label  = {0s}-serial
                \\    append = "root=live:LABEL={1s} console=tty0 console=ttyS0,115200"
                \\    initrd = /boot/initrd.img
                \\EOF
                \\xorriso -as mkisofs -R -V {1s} -o /out/{0s}.iso \
                \\    --grub2-mbr "$img/mbr.bin" \
                \\    -b boot/dklilo/eltorito.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
                \\    -eltorito-alt-boot -e boot/dklilo/efiboot.img -no-emul-boot \
                \\    -append_partition 2 0xEF "$img/efiboot.img" -appended_part_as_gpt \
                \\    "$t"
                \\dklilo isohybrid /out/{0s}.iso
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
};

pub fn build(arena: Allocator, io: std.Io, img: Image, opts: Options) !void {
    const out_rel = try std.fs.path.join(arena, &.{ opts.root, "out", img.name });
    const target_rel = try std.fs.path.join(arena, &.{ out_rel, "rootfs" });
    const work = try std.fs.path.join(arena, &.{ opts.root, "work", try std.fmt.allocPrint(arena, "image-{s}", .{img.name}) });
    // Start from nothing: an old root, tarball or squashfs is replaced.
    for ([_][]const u8{ out_rel, work }) |d| {
        _ = std.process.run(arena, io, .{ .argv = &.{ "chmod", "-R", "u+rwX", d } }) catch {};
        Dir.cwd().deleteTree(io, d) catch {};
    }
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
        .env = &.{ "PATH=/usr/bin:/usr/sbin:/bin:/sbin", "HOME=/root" },
        .argv = &.{ "/usr/bin/sh", "/image.sh" },
        .ids = ids,
    }, &log) catch false;
    const logpath = try std.fmt.allocPrint(arena, "{s}/image.log", .{out_rel});
    Dir.cwd().writeFile(io, .{ .sub_path = logpath, .data = log.items }) catch {};
    sandbox.makeRemovable(io, sb[1]);
    Dir.cwd().deleteTree(io, work) catch {};
    if (!ok) {
        const tail_start = if (log.items.len > 2000) log.items.len - 2000 else 0;
        std.debug.print("{s}\nerror: image {s} failed; log: {s}\n", .{ log.items[tail_start..], img.name, logpath });
        return error.BuildFailed;
    }
    if (!contains(img.output, "rootfs")) {
        _ = std.process.run(arena, io, .{ .argv = &.{ "chmod", "-R", "u+rwX", target_rel } }) catch {};
        Dir.cwd().deleteTree(io, target_rel) catch {};
    }
    std.debug.print("    made", .{});
    for (img.output) |o| {
        if (std.mem.eql(u8, o, "rootfs")) std.debug.print(" {s}/rootfs/", .{out_rel});
        if (std.mem.eql(u8, o, "tar")) std.debug.print(" {s}/{s}.tar.zst", .{ out_rel, img.name });
        if (std.mem.eql(u8, o, "squashfs")) std.debug.print(" {s}/{s}.sfs", .{ out_rel, img.name });
        if (std.mem.eql(u8, o, "iso")) std.debug.print(" {s}/{s}.iso", .{ out_rel, img.name });
    }
    std.debug.print("; log: {s}\n", .{logpath});
}

fn contains(hay: []const []const u8, needle: []const u8) bool {
    for (hay) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
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
    try std.testing.expectError(error.InvalidImage, parse(a, "name = \"x\"\npackages = [\"a-devel\"]\nexclude = [\"*-devel\"]\noutput = [\"tar\"]\n", &diag));
    try std.testing.expectError(error.InvalidImage, parse(a, "name = \"x\"\npackages = [\"a;rm\"]\noutput = [\"tar\"]\n", &diag));
    const s = try script(a, img);
    try std.testing.expect(std.mem.indexOf(u8, s, "--initdb --arch x86_64") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, " base hyprland\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "useradd -R /target -m -s '/bin/sh' -G 'wheel,video' 'fenrir'") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "fenriros.tar.zst") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "mksquashfs") == null);
}
