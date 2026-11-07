//! The build sandbox (SPEC.md 7.1), written against the Linux system calls
//! directly: no bubblewrap, no util-linux, no PATH lookups.
//!
//! A sandboxed command sees:
//!   - a root that is an overlay: `lower` (read-only, e.g. the DKRescue root)
//!     under a writable `upper` directory. Whatever the command writes lands in
//!     `upper`; `lower` is never touched, so one unpacked root serves every build.
//!   - its own user (the caller is uid 0 inside, nothing outside), mount, PID,
//!     UTS, IPC and, unless asked otherwise, network namespaces. No network
//!     means only a down loopback interface.
//!   - /proc for its own PID namespace, a small tmpfs /dev (null, zero, full,
//!     random, urandom, tty), and tmpfs /tmp and /run.
//!   - the directories it was given with `binds`, and nothing else of the host.
//!
//! The work is done by a re-executed copy of this program (`sandbox-child`),
//! because it must `fork` after `unshare`, and the main program may have
//! threads. When the parent dies the sandbox is killed (PR_SET_PDEATHSIG), and
//! the PID namespace takes every process in it along when its first one ends.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const Bind = struct {
    /// Absolute path on the host (a directory or a file).
    src: []const u8,
    /// Absolute path inside the sandbox.
    dst: []const u8,
    read_only: bool = false,
};

pub const Spec = struct {
    /// Absolute paths. `upper` and `work` must be empty directories on the same
    /// file system; `merged` is a directory used as the mount point. None of
    /// the four may contain ',' or ':' (they go into the overlay's options).
    lower: []const u8,
    upper: []const u8,
    work: []const u8,
    merged: []const u8,
    binds: []const Bind = &.{},
    net: bool = false,
    cwd: []const u8 = "/",
    /// `NAME=value` entries. Nothing else is inherited from the host.
    env: []const []const u8 = &.{},
    /// argv[0] is an absolute path inside the sandbox.
    argv: []const []const u8,
};

pub const subcommand = "sandbox-child";

pub const Error = error{BadSpec} || Allocator.Error || std.process.RunError;

fn badChar(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, ",:\n") != null;
}

/// Runs the sandboxed command to completion; its output is appended to `log`.
/// Returns whether it exited with status 0.
pub fn run(arena: Allocator, io: std.Io, spec: Spec, log: *std.ArrayList(u8)) Error!bool {
    if (spec.argv.len == 0 or spec.argv[0].len == 0 or spec.argv[0][0] != '/') return error.BadSpec;
    for ([_][]const u8{ spec.lower, spec.upper, spec.work, spec.merged }) |p| {
        if (p.len == 0 or p[0] != '/' or badChar(p)) return error.BadSpec;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        "/proc/self/exe", subcommand,
        "--lower",        spec.lower,
        "--upper",        spec.upper,
        "--work",         spec.work,
        "--merged",       spec.merged,
        "--cwd",          spec.cwd,
    });
    if (spec.net) try argv.append(arena, "--net");
    for (spec.binds) |b| try argv.appendSlice(arena, &.{ if (b.read_only) "--robind" else "--bind", b.src, b.dst });
    for (spec.env) |e| try argv.appendSlice(arena, &.{ "--env", e });
    try argv.append(arena, "--");
    try argv.appendSlice(arena, spec.argv);

    const res = try std.process.run(arena, io, .{ .argv = argv.items });
    try log.appendSlice(arena, res.stdout);
    try log.appendSlice(arena, res.stderr);
    return switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// Makes a finished sandbox's directories removable. The kernel creates the
/// overlay's `work/work` with mode 000 and a recursive delete cannot enter it,
/// which would leave the whole writable layer behind after every build. Call
/// this with the `work` directory that was in the `Spec`, then delete the tree.
pub fn makeRemovable(io: std.Io, work: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const inner = std.fmt.bufPrint(&buf, "{s}/work", .{work}) catch return;
    std.Io.Dir.cwd().setFilePermissions(io, inner, .fromMode(0o700), .{}) catch {};
}

// ---- the child --------------------------------------------------------------
//
// Everything below runs in the re-executed process, between the first system
// call and `execve`. It does not return to the caller and prints one line to
// stderr, prefixed `sandbox:`, when something fails.

const page = std.heap.page_allocator;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("sandbox: " ++ fmt ++ "\n", args);
    linux.exit_group(125);
}

fn sys(rc: usize, what: []const u8, path: []const u8) void {
    const e = linux.errno(rc);
    if (e != .SUCCESS) die("{s} {s}: {s}", .{ what, path, @tagName(e) });
}

fn z(comptime fmt: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.allocPrintSentinel(page, fmt, args, 0) catch die("out of memory", .{});
}

fn dupeZ(s: []const u8) [:0]const u8 {
    return page.dupeSentinel(u8, s, 0) catch die("out of memory", .{});
}

fn writeFile(path: [:0]const u8, data: []const u8) void {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY }, 0);
    sys(rc, "open", path);
    const fd: i32 = @intCast(rc);
    sys(linux.write(fd, data.ptr, data.len), "write", path);
    _ = linux.close(fd);
}

/// `mkdir -p`.
fn mkdirAll(path: []const u8) void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const part = dupeZ(path[0..i]);
            const e = linux.errno(linux.mkdir(part, 0o755));
            if (e != .SUCCESS and e != .EXIST) die("mkdir {s}: {s}", .{ part, @tagName(e) });
        }
    }
}

fn touch(path: [:0]const u8) void {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    sys(rc, "create", path);
    _ = linux.close(@intCast(rc));
}

fn isDir(path: [:0]const u8) bool {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    _ = linux.close(@intCast(rc));
    return true;
}

fn mountFs(source: [:0]const u8, target: [:0]const u8, fstype: [:0]const u8, flags: u32, data: [:0]const u8) void {
    sys(linux.mount(source, target, fstype, flags, @intFromPtr(data.ptr)), "mount", target);
}

fn bindMount(src: []const u8, dst_inside: []const u8, merged: []const u8, read_only: bool) void {
    const s = dupeZ(src);
    const dst_path = z("{s}{s}", .{ merged, dst_inside });
    if (isDir(s)) {
        mkdirAll(dst_path);
    } else {
        if (std.fs.path.dirname(dst_path)) |parent| mkdirAll(parent);
        touch(dst_path);
    }
    sys(linux.mount(s, dst_path, null, linux.MS.BIND | linux.MS.REC, 0), "bind", dst_path);
    if (read_only) {
        // A read-only bind needs a remount. In a user namespace the remount must
        // repeat the flags the source mount has locked in, so try plain first.
        const base = linux.MS.BIND | linux.MS.REMOUNT | linux.MS.RDONLY;
        var rc = linux.mount(null, dst_path, null, base, 0);
        if (linux.errno(rc) == .PERM) rc = linux.mount(null, dst_path, null, base | linux.MS.NOSUID | linux.MS.NODEV, 0);
        sys(rc, "remount read-only", dst_path);
    }
}

const dev_nodes = [_][]const u8{ "null", "zero", "full", "random", "urandom", "tty" };

pub fn childMain(args: []const [:0]const u8) noreturn {
    var lower: []const u8 = "";
    var upper: []const u8 = "";
    var work: []const u8 = "";
    var merged: []const u8 = "";
    var cwd: []const u8 = "/";
    var net = false;
    var binds: std.ArrayList(Bind) = .empty;
    var env: std.ArrayList([]const u8) = .empty;
    var cmd: []const [:0]const u8 = &.{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--")) {
            cmd = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, a, "--net")) {
            net = true;
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--lower")) {
            i += 1;
            lower = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--upper")) {
            i += 1;
            upper = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--work")) {
            i += 1;
            work = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--merged")) {
            i += 1;
            merged = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--cwd")) {
            i += 1;
            cwd = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--env")) {
            i += 1;
            env.append(page, args[i]) catch die("out of memory", .{});
        } else if (i + 2 < args.len and (std.mem.eql(u8, a, "--bind") or std.mem.eql(u8, a, "--robind"))) {
            binds.append(page, .{ .src = args[i + 1], .dst = args[i + 2], .read_only = std.mem.eql(u8, a, "--robind") }) catch die("out of memory", .{});
            i += 2;
        } else die("bad argument '{s}'", .{a});
    }
    if (cmd.len == 0 or lower.len == 0 or upper.len == 0 or work.len == 0 or merged.len == 0) die("missing arguments", .{});

    const uid = linux.getuid();
    const gid = linux.getgid();

    // Die with our parent, so a stopped dkbuild leaves nothing running.
    _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(linux.SIG.KILL), 0, 0, 0);

    var flags: usize = linux.CLONE.NEWUSER | linux.CLONE.NEWNS | linux.CLONE.NEWPID | linux.CLONE.NEWUTS | linux.CLONE.NEWIPC;
    if (!net) flags |= linux.CLONE.NEWNET;
    sys(linux.unshare(flags), "unshare", "namespaces (are unprivileged user namespaces enabled?)");

    // Become root inside: map this user to uid/gid 0. setgroups must be denied
    // first, or the kernel refuses an unprivileged gid_map.
    writeFile("/proc/self/setgroups", "deny");
    writeFile("/proc/self/uid_map", z("0 {d} 1\n", .{uid}));
    writeFile("/proc/self/gid_map", z("0 {d} 1\n", .{gid}));

    // The first fork lands in the new PID namespace as its PID 1. This process
    // stays outside it and passes on the exit status.
    const pid_rc = linux.fork();
    sys(pid_rc, "fork", "");
    if (pid_rc != 0) {
        var status: i32 = 0;
        while (true) {
            const rc = linux.waitpid(@intCast(pid_rc), &status, 0);
            if (linux.errno(rc) == .INTR) continue;
            sys(rc, "waitpid", "");
            break;
        }
        const s: u32 = @bitCast(status);
        if (s & 0x7f == 0) linux.exit_group(@intCast((s >> 8) & 0xff));
        linux.exit_group(@intCast(128 + (s & 0x7f)));
    }

    // ---- PID 1 of the sandbox ----
    _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(linux.SIG.KILL), 0, 0, 0);

    // Nothing mounted from here on may reach the host's mount table.
    sys(linux.mount(null, "/", null, linux.MS.REC | linux.MS.PRIVATE, 0), "make private", "/");

    mkdirAll(merged);
    const opts = z("lowerdir={s},upperdir={s},workdir={s},userxattr", .{ lower, upper, work });
    mountFs("overlay", dupeZ(merged), "overlay", 0, opts);

    // /proc of the new PID namespace.
    {
        const p = z("{s}/proc", .{merged});
        mkdirAll(p);
        mountFs("proc", p, "proc", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, "");
    }
    // A small /dev: a tmpfs with the harmless device nodes bound from the host.
    {
        const d = z("{s}/dev", .{merged});
        mkdirAll(d);
        mountFs("tmpfs", d, "tmpfs", linux.MS.NOSUID, "mode=755,size=1m");
        for (dev_nodes) |n| {
            const dst = z("{s}/dev/{s}", .{ merged, n });
            touch(dst);
            sys(linux.mount(z("/dev/{s}", .{n}), dst, null, linux.MS.BIND, 0), "bind", dst);
        }
        mkdirAll(z("{s}/dev/shm", .{merged}));
        mountFs("tmpfs", z("{s}/dev/shm", .{merged}), "tmpfs", linux.MS.NOSUID | linux.MS.NODEV, "mode=1777");
        sys(linux.symlink("/proc/self/fd", z("{s}/dev/fd", .{merged})), "symlink", "/dev/fd");
        sys(linux.symlink("/proc/self/fd/0", z("{s}/dev/stdin", .{merged})), "symlink", "/dev/stdin");
        sys(linux.symlink("/proc/self/fd/1", z("{s}/dev/stdout", .{merged})), "symlink", "/dev/stdout");
        sys(linux.symlink("/proc/self/fd/2", z("{s}/dev/stderr", .{merged})), "symlink", "/dev/stderr");
    }
    for ([_][]const u8{ "tmp", "run" }) |name| {
        const p = z("{s}/{s}", .{ merged, name });
        mkdirAll(p);
        mountFs("tmpfs", p, "tmpfs", linux.MS.NOSUID | linux.MS.NODEV, "mode=1777");
    }
    for (binds.items) |b| bindMount(b.src, b.dst, merged, b.read_only);

    // Make the overlay the root and drop the host's tree.
    const old = z("{s}/.oldroot", .{merged});
    mkdirAll(old);
    sys(linux.pivot_root(dupeZ(merged), old), "pivot_root", merged);
    sys(linux.chdir("/"), "chdir", "/");
    sys(linux.umount2("/.oldroot", linux.MNT.DETACH), "umount", "/.oldroot");
    sys(linux.chdir(dupeZ(cwd)), "chdir", cwd);

    // Run the command with exactly the environment it was given.
    if (cmd[0][0] != '/') die("the command must be an absolute path: {s}", .{cmd[0]});
    const argv_c = page.alloc(?[*:0]const u8, cmd.len + 1) catch die("out of memory", .{});
    for (cmd, 0..) |c, k| argv_c[k] = c.ptr;
    argv_c[cmd.len] = null;
    const envp = page.alloc(?[*:0]const u8, env.items.len + 1) catch die("out of memory", .{});
    for (env.items, 0..) |e, k| envp[k] = dupeZ(e).ptr;
    envp[env.items.len] = null;
    const rc = linux.execve(cmd[0], @ptrCast(argv_c.ptr), @ptrCast(envp.ptr));
    die("exec {s}: {s}", .{ cmd[0], @tagName(linux.errno(rc)) });
}
