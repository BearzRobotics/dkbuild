//! Macro expansion (SPEC.md 5.5). Macros hold the toolchain decisions so a
//! recipe never repeats them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Profile = @import("profile.zig").Profile;

pub const Context = struct {
    target: Profile,
    /// The build machine's profile; differs from `target` for cross builds.
    host: Profile,
    /// The recipe has the `static` option.
    static: bool = false,
};

pub const Error = error{UnknownMacro} || Allocator.Error;

/// Expands every `%name` in `text`. `%%` is a literal `%`. A `%` followed by
/// anything else is left alone (printf formats, shell `%` suffix removal).
/// `bad_macro` receives the offending name on `error.UnknownMacro`.
pub fn expand(arena: Allocator, ctx: Context, text: []const u8, bad_macro: *[]const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c != '%') {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        if (i + 1 < text.len and text[i + 1] == '%') {
            try out.append(arena, '%');
            i += 2;
            continue;
        }
        var j = i + 1;
        while (j < text.len and (std.ascii.isLower(text[j]) or text[j] == '_')) j += 1;
        if (j == i + 1) {
            try out.append(arena, '%');
            i += 1;
            continue;
        }
        const name = text[i + 1 .. j];
        const body = try lookup(arena, ctx, name) orelse {
            bad_macro.* = name;
            return error.UnknownMacro;
        };
        try out.appendSlice(arena, body);
        i = j;
    }
    return out.toOwnedSlice(arena);
}

fn lookup(arena: Allocator, ctx: Context, name: []const u8) Allocator.Error!?[]const u8 {
    const t = ctx.target;
    const cross = t.isCross(ctx.host);
    const eql = std.mem.eql;
    const cross_dir = Profile.cross_dir;

    if (eql(u8, name, "configure")) {
        // Shared and static libraries both: the static ones go to <name>-static
        // (5.7), for fully static programs on musl.
        return try std.fmt.allocPrint(arena, "./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var{s}", .{
            if (cross) try std.fmt.allocPrint(arena, " --build={s} --host={s}", .{ ctx.host.triple, t.triple }) else "",
        });
    }
    if (eql(u8, name, "make"))
        return "make -j$jobs CC=\"$CC\" CXX=\"$CXX\" AR=llvm-ar NM=llvm-nm RANLIB=llvm-ranlib";
    if (eql(u8, name, "make_install")) return "make DESTDIR=$pkgdir install";
    if (eql(u8, name, "meson")) {
        return try std.fmt.allocPrint(arena, "meson setup build --prefix=/usr --buildtype=release --wrap-mode=nodownload -Dwerror=false -Ddefault_library=both{s}", .{
            if (cross) " --cross-file " ++ cross_dir ++ "/meson.ini" else "",
        });
    }
    if (eql(u8, name, "meson_build")) return "ninja -C build";
    if (eql(u8, name, "meson_install")) return "DESTDIR=$pkgdir ninja -C build install";
    if (eql(u8, name, "cmake")) {
        return try std.fmt.allocPrint(arena, "cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release{s}", .{
            if (cross) " -DCMAKE_TOOLCHAIN_FILE=" ++ cross_dir ++ "/toolchain.cmake" else "",
        });
    }
    if (eql(u8, name, "cmake_build")) return "cmake --build build";
    if (eql(u8, name, "cmake_install")) return "DESTDIR=$pkgdir cmake --install build --strip";
    if (eql(u8, name, "zig_build")) {
        // A native build leaves out -Dtarget: with an explicit target zig treats the
        // build as a cross build and does not ask pkg-config for system libraries.
        return try std.fmt.allocPrint(arena, "DESTDIR=$pkgdir zig build --release=safe --prefix /usr{s}{s} -Dcpu={s} --system zig-pkg -j$jobs", .{
            if (cross) " -Dtarget=" else "",
            if (cross) t.zig_target else "",
            t.zig_cpu,
        });
    }
    if (eql(u8, name, "kernel_make")) return try std.fmt.allocPrint(arena, "make LLVM=1 ARCH={s}", .{t.kernel_arch});
    return null;
}

// ---- tests ----

const profile = @import("profile.zig");

fn testProfile(arena: Allocator, arch: []const u8, triple: []const u8, cpu: []const u8, zt: []const u8, zc: []const u8, ka: []const u8) !Profile {
    _ = arena;
    return .{ .arch = arch, .triple = triple, .cpu = cpu, .zig_target = zt, .zig_cpu = zc, .kernel_arch = ka };
}

test "macros expand per target" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const x86 = try testProfile(a, "x86_64", "x86_64-fenriros-linux-musl", "x86-64", "x86_64-linux-musl", "baseline", "x86");
    const arm = try testProfile(a, "aarch64", "aarch64-fenriros-linux-musl", "armv8-a", "aarch64-linux-musl", "baseline", "arm64");
    var bad: []const u8 = "";

    const native = try expand(a, .{ .target = x86, .host = x86 }, "%configure\n%make\n%make_install\n%kernel_make", &bad);
    try std.testing.expectEqualStrings(
        "./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var\n" ++
            "make -j$jobs CC=\"$CC\" CXX=\"$CXX\" AR=llvm-ar NM=llvm-nm RANLIB=llvm-ranlib\n" ++
            "make DESTDIR=$pkgdir install\nmake LLVM=1 ARCH=x86",
        native,
    );

    const cross = try expand(a, .{ .target = arm, .host = x86, .static = true }, "%configure", &bad);
    try std.testing.expectEqualStrings(
        "./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --build=x86_64-fenriros-linux-musl --host=aarch64-fenriros-linux-musl",
        cross,
    );

    const zig = try expand(a, .{ .target = arm, .host = x86 }, "%zig_build", &bad);
    try std.testing.expect(std.mem.indexOf(u8, zig, "-Dtarget=aarch64-linux-musl -Dcpu=baseline") != null);

    const meson = try expand(a, .{ .target = arm, .host = x86 }, "%meson -Dfoo=1\n%meson_build", &bad);
    try std.testing.expect(std.mem.indexOf(u8, meson, "--cross-file /dkbuild/cross/meson.ini -Dfoo=1\nninja -C build") != null);
}

test "longest macro name wins, %% and stray % are kept, unknown fails" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const x86 = try testProfile(a, "x86_64", "x86_64-fenriros-linux-musl", "x86-64", "x86_64-linux-musl", "baseline", "x86");
    var bad: []const u8 = "";
    const ctx: Context = .{ .target = x86, .host = x86 };
    try std.testing.expectEqualStrings("make DESTDIR=$pkgdir install", try expand(a, ctx, "%make_install", &bad));
    try std.testing.expectEqualStrings("100% done, ${v%.*} %%", try expand(a, ctx, "100% done, ${v%.*} %%%%", &bad));
    try std.testing.expectError(error.UnknownMacro, expand(a, ctx, "%nonsense", &bad));
    try std.testing.expectEqualStrings("nonsense", bad);
}
