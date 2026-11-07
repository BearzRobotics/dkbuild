//! `dkbuild doctor`: checks that this machine can run dkbuild, and says how to
//! fix what it cannot (SPEC.md 3 "Host requirements"). Nothing is changed.
//!
//! The first host is Ubuntu, so the fixes are `apt` packages and the one kernel
//! setting Ubuntu 23.10+ changes: AppArmor refuses unprivileged user
//! namespaces unless `kernel.apparmor_restrict_unprivileged_userns` is 0.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

/// A program dkbuild runs on the host, and the Ubuntu package that has it.
pub const Tool = struct {
    name: []const u8,
    apt: []const u8,
    why: []const u8,
    required: bool = true,
};

pub const tools = [_]Tool{
    .{ .name = "curl", .apt = "curl", .why = "downloads sources (dkbuild fetch, pkg)" },
    .{ .name = "tar", .apt = "tar", .why = "unpacks source tarballs and root tarballs" },
    .{ .name = "xz", .apt = "xz-utils", .why = "most source tarballs are .tar.xz" },
    .{ .name = "xorriso", .apt = "xorriso", .why = "reads the DKRescue ISO (bootstrap-root)" },
    .{ .name = "unsquashfs", .apt = "squashfs-tools", .why = "unpacks the DKRescue root (bootstrap-root)" },
    .{ .name = "unshare", .apt = "util-linux", .why = "bootstrap-root checks the root runs in a user namespace" },
    .{ .name = "openssl", .apt = "openssl", .why = "makes the signing key for the repository", .required = false },
    .{ .name = "git", .apt = "git", .why = "recipes whose source is a git repository", .required = false },
    .{ .name = "bwrap", .apt = "bubblewrap", .why = "only the old Chimera prototype base (--base chimera)", .required = false },
};

/// The one command that installs every tool above that is missing, for a person to run.
pub fn aptCommand(arena: Allocator, missing: []const Tool) Allocator.Error![]const u8 {
    var pkgs: std.ArrayList([]const u8) = .empty;
    // ca-certificates too: curl needs it for https, and it is cheap.
    try pkgs.append(arena, "ca-certificates");
    for (missing) |t| {
        var seen = false;
        for (pkgs.items) |p| {
            if (std.mem.eql(u8, p, t.apt)) seen = true;
        }
        if (!seen) try pkgs.append(arena, t.apt);
    }
    return std.mem.join(arena, " ", pkgs.items);
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn onPath(arena: Allocator, io: std.Io, path_var: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, path_var, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const p = std.fs.path.join(arena, &.{ dir, name }) catch return false;
        if (Dir.cwd().access(io, p, .{ .execute = true })) |_| return true else |_| {}
    }
    return false;
}

fn runOk(arena: Allocator, io: std.Io, argv: []const []const u8) bool {
    const res = std.process.run(arena, io, .{ .argv = argv }) catch return false;
    return switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

fn readFirstLine(arena: Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    const text = Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return null;
    return std.mem.trim(u8, text, " \n\r\t");
}

/// Returns true if everything required is fine.
pub fn run(arena: Allocator, io: std.Io, root: []const u8, path_var: []const u8, home: ?[]const u8) Allocator.Error!bool {
    var problems: usize = 0;

    say("Programs\n", .{});
    var missing: std.ArrayList(Tool) = .empty;
    for (tools) |t| {
        const found = onPath(arena, io, path_var, t.name);
        say("  {s:<11} {s}", .{ t.name, if (found) "ok" else if (t.required) "MISSING" else "absent" });
        if (!found) say("   ({s})", .{t.why});
        say("\n", .{});
        if (!found and (t.required or std.mem.eql(u8, t.name, "openssl") or std.mem.eql(u8, t.name, "git"))) {
            try missing.append(arena, t);
            if (t.required) problems += 1;
        }
    }

    say("Kernel\n", .{});
    // Unprivileged user + mount + PID + network namespaces, as every build uses.
    const userns = runOk(arena, io, &.{ "unshare", "--user", "--map-root-user", "--mount", "--pid", "--net", "--fork", "true" });
    say("  user, mount, PID and network namespaces   {s}\n", .{if (userns) "ok" else "BLOCKED"});
    if (!userns) {
        problems += 1;
        const restrict = readFirstLine(arena, io, "/proc/sys/kernel/apparmor_restrict_unprivileged_userns");
        if (restrict) |v| if (std.mem.eql(u8, v, "1")) {
            say("      Ubuntu's AppArmor blocks unprivileged user namespaces. To allow them now and after reboot:\n", .{});
            say("        sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0\n", .{});
            say("        echo 'kernel.apparmor_restrict_unprivileged_userns = 0' | sudo tee /etc/sysctl.d/60-dkbuild.conf\n", .{});
        };
        if (readFirstLine(arena, io, "/proc/sys/kernel/unprivileged_userns_clone")) |v| if (std.mem.eql(u8, v, "0")) {
            say("      Enable with: sudo sysctl -w kernel.unprivileged_userns_clone=1\n", .{});
        };
        if (readFirstLine(arena, io, "/proc/sys/user/max_user_namespaces")) |v| if (std.mem.eql(u8, v, "0")) {
            say("      Enable with: sudo sysctl -w user.max_user_namespaces=15000\n", .{});
        };
    }
    // The build root is an overlay mounted inside a user namespace.
    if (userns) {
        const work = try std.fmt.allocPrint(arena, "{s}/work/doctor", .{root});
        Dir.cwd().deleteTree(io, work) catch {};
        for ([_][]const u8{ "lower", "upper", "work", "merged" }) |d| {
            const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ work, d });
            Dir.cwd().createDirPath(io, p) catch {};
        }
        const abs = Dir.cwd().realPathFileAlloc(io, work, arena) catch work;
        const script = try std.fmt.allocPrint(arena, "mount -t overlay overlay -o lowerdir={0s}/lower,upperdir={0s}/upper,workdir={0s}/work,userxattr {0s}/merged", .{abs});
        const overlay = runOk(arena, io, &.{ "unshare", "--user", "--map-root-user", "--mount", "sh", "-c", script });
        Dir.cwd().deleteTree(io, work) catch {};
        say("  overlay file system in a user namespace   {s}\n", .{if (overlay) "ok" else "FAILED"});
        if (!overlay) {
            problems += 1;
            say("      Needs Linux 5.11 or newer with CONFIG_OVERLAY_FS. Try: sudo modprobe overlay\n", .{});
        }
    }

    say("Disk\n", .{});
    {
        // 4.2 GB for the unpacked DKRescue root, plus sources and build trees.
        const res = std.process.run(arena, io, .{ .argv = &.{ "df", "-Pk", root } }) catch null;
        var free_gb: ?u64 = null;
        if (res) |r| {
            var lines = std.mem.splitScalar(u8, r.stdout, '\n');
            _ = lines.next();
            if (lines.next()) |l| {
                var cols = std.mem.tokenizeAny(u8, l, " \t");
                var k: usize = 0;
                while (cols.next()) |c| : (k += 1) {
                    if (k == 3) free_gb = (std.fmt.parseInt(u64, c, 10) catch 0) / (1024 * 1024);
                }
            }
        }
        if (free_gb) |g| {
            const enough = g >= 20;
            say("  {d} GB free where the project lives   {s}\n", .{ g, if (enough) "ok" else "LOW (about 20 GB is needed)" });
            if (!enough) problems += 1;
        } else say("  free space   unknown\n", .{});
    }

    say("Signing key\n", .{});
    {
        const key = if (home) |h| try std.fs.path.join(arena, &.{ h, ".config", "dkbuild", "signing.rsa" }) else null;
        const have = if (key) |k| (if (Dir.cwd().access(io, k, .{})) |_| true else |_| false) else false;
        say("  ~/.config/dkbuild/signing.rsa   {s}\n", .{if (have) "ok" else "absent"});
        if (!have) {
            say("      Create one (keep it private and backed up), and publish its public half in keys/:\n", .{});
            say("        mkdir -p ~/.config/dkbuild && openssl genrsa -out ~/.config/dkbuild/signing.rsa 4096\n", .{});
            say("        openssl rsa -in ~/.config/dkbuild/signing.rsa -pubout -out keys/dkbuild-signing.rsa.pub\n", .{});
            say("      Or copy your existing signing.rsa there; keys/ must hold its matching .pub.\n", .{});
        }
    }

    say("Build machine\n", .{});
    {
        const p = try std.fmt.allocPrint(arena, "{s}/rootfs/dkrescue/usr/bin/apk", .{root});
        const have = if (Dir.cwd().statFile(io, p, .{ .follow_symlinks = false })) |_| true else |_| false;
        say("  rootfs/dkrescue   {s}\n", .{if (have) "ok" else "absent"});
        if (!have) say("      Unpack the DKRescue image: dkbuild bootstrap-root /path/to/dkrescue-fixed.iso\n", .{});
    }

    if (missing.items.len > 0) {
        say("\nInstall what is missing (Ubuntu / Debian):\n  sudo apt install {s}\n", .{try aptCommand(arena, missing.items)});
    }
    if (problems == 0) {
        say("\nok: this machine can run dkbuild\n", .{});
        return true;
    }
    say("\n{d} problem(s) above need fixing.\n", .{problems});
    return false;
}

test "aptCommand lists each package once, with ca-certificates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = try aptCommand(arena.allocator(), &.{ tools[0], tools[2], tools[2], tools[4] });
    try std.testing.expectEqualStrings("ca-certificates curl xz-utils squashfs-tools", cmd);
}
