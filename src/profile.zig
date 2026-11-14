//! Target profiles and the files generated from them (SPEC.md 6.1).

const std = @import("std");
const cfg = @import("cfg.zig");
const Allocator = std.mem.Allocator;

pub const Diagnostic = cfg.Diagnostic;

pub const Profile = struct {
    arch: []const u8,
    triple: []const u8,
    cpu: []const u8,
    zig_target: []const u8,
    zig_cpu: []const u8,
    kernel_arch: []const u8,

    /// Where the target sysroot lives inside a cross build root (6.2).
    pub const sysroot = "/sysroot";
    /// Where the generated cross files are placed inside the build root.
    pub const cross_dir = "/dkbuild/cross";

    pub fn isCross(p: Profile, host: Profile) bool {
        return !std.mem.eql(u8, p.arch, host.arch);
    }

    /// Meson's `cpu_family` for this architecture.
    pub fn mesonCpuFamily(p: Profile) []const u8 {
        return p.arch; // x86_64, aarch64 and riscv64 match Meson's names
    }

    pub fn mesonCross(p: Profile, arena: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena,
            \\[binaries]
            \\c = ['clang', '--target={[t]s}', '--sysroot={[s]s}']
            \\cpp = ['clang++', '--target={[t]s}', '--sysroot={[s]s}']
            \\ar = 'llvm-ar'
            \\nm = 'llvm-nm'
            \\ranlib = 'llvm-ranlib'
            \\strip = 'llvm-strip'
            \\pkg-config = 'pkg-config'
            \\
            \\[host_machine]
            \\system = 'linux'
            \\cpu_family = '{[f]s}'
            \\cpu = '{[f]s}'
            \\endian = 'little'
            \\
            \\[built-in options]
            \\c_args = ['-march={[c]s}']
            \\cpp_args = ['-march={[c]s}']
            \\c_link_args = ['-fuse-ld=lld', '-Wl,--undefined-version']
            \\cpp_link_args = ['-fuse-ld=lld', '-Wl,--undefined-version']
            \\
            \\[properties]
            \\needs_exe_wrapper = true
            \\sys_root = '{[s]s}'
            \\
        , .{ .t = p.triple, .s = sysroot, .f = p.mesonCpuFamily(), .c = p.cpu });
    }

    pub fn cmakeToolchain(p: Profile, arena: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena,
            \\set(CMAKE_SYSTEM_NAME Linux)
            \\set(CMAKE_SYSTEM_PROCESSOR {[a]s})
            \\set(CMAKE_C_COMPILER clang)
            \\set(CMAKE_CXX_COMPILER clang++)
            \\set(CMAKE_C_COMPILER_TARGET {[t]s})
            \\set(CMAKE_CXX_COMPILER_TARGET {[t]s})
            \\set(CMAKE_AR llvm-ar)
            \\set(CMAKE_RANLIB llvm-ranlib)
            \\set(CMAKE_NM llvm-nm)
            \\set(CMAKE_SYSROOT {[s]s})
            \\set(CMAKE_C_FLAGS_INIT "-march={[c]s}")
            \\set(CMAKE_CXX_FLAGS_INIT "-march={[c]s}")
            \\set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld -Wl,--undefined-version")
            \\set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld -Wl,--undefined-version")
            \\set(CMAKE_FIND_ROOT_PATH {[s]s})
            \\set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
            \\set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
            \\set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
            \\set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
            \\
        , .{ .a = p.arch, .t = p.triple, .s = sysroot, .c = p.cpu });
    }

    /// The `export` lines run before every step (5.5 "Default flags").
    /// `cross` selects `--sysroot`; `static` adds `-static`.
    pub fn buildEnv(p: Profile, arena: Allocator, cross: bool, static: bool) Allocator.Error![]const u8 {
        const sys: []const u8 = if (cross) " --sysroot=" ++ sysroot else "";
        const st: []const u8 = if (static) " -static" else "";
        return std.fmt.allocPrint(arena,
            \\export CC="clang --target={[t]s}{[sys]s}"
            \\export CXX="clang++ --target={[t]s}{[sys]s}"
            \\export FORCE_UNSAFE_CONFIGURE=1
            \\export CFLAGS="-O2 -march={[c]s}"
            \\export CXXFLAGS="-O2 -march={[c]s}"
            \\export LDFLAGS="-fuse-ld=lld -Wl,--undefined-version{[st]s}"
            \\
        , .{ .t = p.triple, .sys = sys, .c = p.cpu, .st = st });
    }
};

/// The prefix GCC is installed under (packages/g/gcc).
pub const gcc_prefix = "/usr/lib/gcc15";

/// The `export` lines for a recipe with `options = ["gcc"]`, after `buildEnv`
/// (SPEC 3): GCC from its own prefix instead of clang, and GNU binutils under
/// their plain names in a directory first on PATH (they install as gas, gar, ...
/// so as not to shadow LLVM's; ld is ld.bfd). The flags are GCC's: clang's
/// `--target` and `-fuse-ld=lld` do not exist in it. Programs built this way may
/// need GCC's runtime, so they find it through an rpath. A recipe's own
/// `environment` runs after this and can change any of it.
pub fn gccEnv(p: Profile, arena: Allocator) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena,
        \\mkdir -p /tmp/gnu-bin
        \\for t in as ar nm ranlib objcopy objdump strip readelf; do if [ -e /usr/bin/g$t ]; then ln -sf /usr/bin/g$t /tmp/gnu-bin/$t; fi; done
        \\if [ -e /usr/bin/ld.bfd ]; then ln -sf /usr/bin/ld.bfd /tmp/gnu-bin/ld; fi
        \\export PATH="/tmp/gnu-bin:{[g]s}/bin:$PATH"
        \\export CC={[g]s}/bin/gcc CXX={[g]s}/bin/g++ CPP={[g]s}/bin/cpp AR=ar RANLIB=ranlib NM=nm
        \\export CFLAGS="-O2 -march={[c]s}" CXXFLAGS="-O2 -march={[c]s}" LDFLAGS="-Wl,-rpath,{[g]s}/lib"
        \\
    , .{ .g = gcc_prefix, .c = p.cpu });
}

pub fn parse(arena: Allocator, text: []const u8, diag: *Diagnostic) (error{InvalidProfile} || Allocator.Error)!Profile {
    return parseChecked(arena, text, diag) catch |err| switch (err) {
        error.Invalid => error.InvalidProfile,
        error.OutOfMemory => |e| e,
    };
}

fn parseChecked(arena: Allocator, text: []const u8, diag: *Diagnostic) cfg.Error!Profile {
    const root = try cfg.parse(arena, text, diag);
    const fields = [_][]const u8{ "arch", "triple", "cpu", "zig_target", "zig_cpu", "kernel_arch" };
    try cfg.onlyKeys(arena, diag, root, &fields, "");
    var p: Profile = undefined;
    inline for (fields) |f| {
        @field(p, f) = try cfg.reqString(arena, diag, root, f);
    }
    // the triple must name the same architecture and use musl
    if (!std.mem.startsWith(u8, p.triple, p.arch) or !std.mem.endsWith(u8, p.triple, "-musl"))
        return cfg.fail(arena, diag, "triple '{s}' does not match arch '{s}' with musl", .{ p.triple, p.arch });
    return p;
}

// ---- tests ----

const aarch64_src =
    \\arch = "aarch64"
    \\triple = "aarch64-fenriros-linux-musl"
    \\cpu = "armv8-a"
    \\zig_target = "aarch64-linux-musl"
    \\zig_cpu = "baseline"
    \\kernel_arch = "arm64"
    \\
;

test "profile parses and generates cross files" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var d: Diagnostic = .{};
    const p = try parse(a, aarch64_src, &d);
    try std.testing.expectEqualStrings("arm64", p.kernel_arch);

    const meson = try p.mesonCross(a);
    try std.testing.expect(std.mem.indexOf(u8, meson, "--target=aarch64-fenriros-linux-musl") != null);
    try std.testing.expect(std.mem.indexOf(u8, meson, "cpu_family = 'aarch64'") != null);
    try std.testing.expect(std.mem.indexOf(u8, meson, "-march=armv8-a") != null);

    const cmake = try p.cmakeToolchain(a);
    try std.testing.expect(std.mem.indexOf(u8, cmake, "CMAKE_SYSTEM_PROCESSOR aarch64") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmake, "CMAKE_SYSROOT /sysroot") != null);

    const env = try p.buildEnv(a, true, true);
    try std.testing.expect(std.mem.indexOf(u8, env, "--sysroot=/sysroot") != null);
    try std.testing.expect(std.mem.indexOf(u8, env, "-Wl,--undefined-version -static") != null);
    try std.testing.expect(std.mem.indexOf(u8, env, "native") == null);
}

test "profile rejects unknown keys and mismatched triples" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var d: Diagnostic = .{};
    try std.testing.expectError(error.InvalidProfile, parse(a, aarch64_src ++ "boot = \"x\"\n", &d));
    try std.testing.expectEqualStrings("unknown key 'boot'", d.message);
    var bad_src = try std.mem.replaceOwned(u8, a, aarch64_src, "aarch64-fenriros-linux-musl", "x86_64-fenriros-linux-musl");
    bad_src = bad_src;
    try std.testing.expectError(error.InvalidProfile, parse(a, bad_src, &d));
}

test "shipped profiles generate correct files for all three targets" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const Case = struct { src: []const u8, arch: []const u8, triple: []const u8, cpu: []const u8, kernel: []const u8 };
    const cases = [_]Case{
        .{ .src = @embedFile("profile_x86_64"), .arch = "x86_64", .triple = "x86_64-fenriros-linux-musl", .cpu = "x86-64", .kernel = "x86" },
        .{ .src = @embedFile("profile_aarch64"), .arch = "aarch64", .triple = "aarch64-fenriros-linux-musl", .cpu = "armv8-a", .kernel = "arm64" },
        .{ .src = @embedFile("profile_riscv64"), .arch = "riscv64", .triple = "riscv64-fenriros-linux-musl", .cpu = "rv64gc", .kernel = "riscv" },
    };
    for (cases) |c| {
        var d: Diagnostic = .{};
        const p = try parse(a, c.src, &d);
        try std.testing.expectEqualStrings(c.arch, p.arch);
        try std.testing.expectEqualStrings(c.kernel, p.kernel_arch);
        const meson = try p.mesonCross(a);
        try std.testing.expect(std.mem.indexOf(u8, meson, try std.fmt.allocPrint(a, "--target={s}", .{c.triple})) != null);
        try std.testing.expect(std.mem.indexOf(u8, meson, try std.fmt.allocPrint(a, "cpu_family = '{s}'", .{c.arch})) != null);
        try std.testing.expect(std.mem.indexOf(u8, meson, try std.fmt.allocPrint(a, "-march={s}", .{c.cpu})) != null);
        const cmake = try p.cmakeToolchain(a);
        try std.testing.expect(std.mem.indexOf(u8, cmake, try std.fmt.allocPrint(a, "CMAKE_SYSTEM_PROCESSOR {s}", .{c.arch})) != null);
        try std.testing.expect(std.mem.indexOf(u8, cmake, try std.fmt.allocPrint(a, "CMAKE_C_COMPILER_TARGET {s}", .{c.triple})) != null);
    }
}

test "gccEnv uses GCC's compilers and flags, not clang's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p: Profile = .{ .arch = "x86_64", .triple = "x86_64-fenriros-linux-musl", .cpu = "x86-64", .zig_target = "x86_64-linux-musl", .zig_cpu = "baseline", .kernel_arch = "x86" };
    const e = try gccEnv(p, a);
    try std.testing.expect(std.mem.indexOf(u8, e, "export CC=/usr/lib/gcc15/bin/gcc ") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "-march=x86-64") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "--target") == null);
    try std.testing.expect(std.mem.indexOf(u8, e, "fuse-ld=lld") == null);
}
