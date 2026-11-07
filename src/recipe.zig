//! Recipe model, reader and validation (SPEC.md section 5).
//!
//! The YAML is parsed by zig-yaml; everything outside the subset of 5.1 is
//! rejected here, after parsing. Unknown keys are errors (5.1).

const std = @import("std");
const yaml = @import("yaml.zig");
const Value = yaml.Value;
const Map = yaml.Map;
const Allocator = std.mem.Allocator;

pub const Source = union(enum) {
    /// `URL : sha256`
    tarball: struct { url: []const u8, sha256: []const u8 },
    /// `git|URL : tag-or-commit`
    git: struct { url: []const u8, ref: []const u8 },
};

pub const Subpackage = struct {
    name: []const u8,
    summary: []const u8,
    paths: []const []const u8,
};

pub const Recipe = struct {
    name: []const u8,
    version: []const u8,
    release: u32,
    summary: []const u8,
    description: ?[]const u8 = null,
    license: []const u8,
    homepage: ?[]const u8 = null,
    source: []const Source,
    patches: []const []const u8 = &.{},
    archs: []const []const u8 = &.{},
    hostdeps: []const []const u8 = &.{},
    builddeps: []const []const u8 = &.{},
    checkdeps: []const []const u8 = &.{},
    rundeps: []const []const u8 = &.{},
    options: []const []const u8 = &.{},
    environment: ?[]const u8 = null,
    setup: ?[]const u8 = null,
    build: ?[]const u8 = null,
    check: ?[]const u8 = null,
    install: []const u8,
    subpackages: []const Subpackage = &.{},
};

/// What went wrong, in words a recipe author can act on.
pub const Diagnostic = yaml.Diagnostic;

pub const Error = error{InvalidRecipe} || Allocator.Error;

const known_keys = [_][]const u8{
    "name",     "version",   "release",   "summary",     "description", "license",
    "homepage", "source",    "patches",   "archs",       "hostdeps",    "builddeps",
    "checkdeps", "rundeps",  "options",   "environment", "setup",       "build",
    "check",    "install",   "subpackages",
};

const known_options = [_][]const u8{ "check", "cross", "strip", "lto", "static", "bootstrap" };
const known_archs = [_][]const u8{ "x86_64", "aarch64", "riscv64" };

/// Parse and validate `text`. All returned memory lives in `arena`.
pub fn parse(arena: Allocator, text: []const u8, diag: *Diagnostic) Error!Recipe {
    const doc = yaml.parse(arena, text, diag) catch |err| switch (err) {
        error.Syntax => return error.InvalidRecipe,
        error.OutOfMemory => |e| return e,
    };
    const root = doc.asMap() orelse return fail(arena, diag, "top level must be a mapping", .{});

    for (root.keys) |k| {
        if (!contains(&known_keys, k)) return fail(arena, diag, "unknown key '{s}'", .{k});
    }

    var r: Recipe = undefined;
    r.name = try reqScalar(arena, diag, root, "name");
    if (!validName(r.name)) return fail(arena, diag, "name '{s}': only lowercase letters, digits, '-', '+', '.'", .{r.name});
    r.version = try reqScalar(arena, diag, root, "version");
    const rel = try reqScalar(arena, diag, root, "release");
    r.release = std.fmt.parseInt(u32, rel, 10) catch
        return fail(arena, diag, "release '{s}' is not a number", .{rel});
    if (r.release < 1) return fail(arena, diag, "release starts at 1", .{});
    r.summary = try reqScalar(arena, diag, root, "summary");
    r.license = try reqScalar(arena, diag, root, "license");
    r.description = try optScalar(arena, diag, root, "description");
    r.homepage = try optScalar(arena, diag, root, "homepage");
    r.environment = try optScalar(arena, diag, root, "environment");
    r.setup = try optScalar(arena, diag, root, "setup");
    r.build = try optScalar(arena, diag, root, "build");
    r.check = try optScalar(arena, diag, root, "check");
    r.install = try reqScalar(arena, diag, root, "install");
    r.patches = try optList(arena, diag, root, "patches");
    r.archs = try optList(arena, diag, root, "archs");
    r.hostdeps = try optList(arena, diag, root, "hostdeps");
    r.builddeps = try optList(arena, diag, root, "builddeps");
    r.checkdeps = try optList(arena, diag, root, "checkdeps");
    r.rundeps = try optList(arena, diag, root, "rundeps");
    r.options = try optList(arena, diag, root, "options");

    for (r.archs) |a| {
        const bare = if (a.len > 0 and a[0] == '!') a[1..] else a;
        if (!contains(&known_archs, bare)) return fail(arena, diag, "unknown arch '{s}'", .{a});
    }
    for (r.options) |o| {
        const bare = if (o.len > 0 and o[0] == '!') o[1..] else o;
        const key = if (std.mem.startsWith(u8, bare, "jobs:")) "jobs" else bare;
        if (!std.mem.eql(u8, key, "jobs") and !contains(&known_options, key))
            return fail(arena, diag, "unknown option '{s}'", .{o});
        if (std.mem.eql(u8, key, "jobs") and
            (std.fmt.parseInt(u32, bare["jobs:".len..], 10) catch 0) == 0)
            return fail(arena, diag, "option '{s}': jobs:N needs a positive number", .{o});
    }

    r.source = try parseSources(arena, diag, root);
    r.subpackages = try parseSubpackages(arena, diag, root);
    return r;
}

fn parseSources(arena: Allocator, diag: *Diagnostic, root: Map) Error![]const Source {
    const v = root.get("source") orelse return fail(arena, diag, "missing required key 'source'", .{});
    const list = v.asList() orelse return fail(arena, diag, "'source' must be a list", .{});
    if (list.len == 0) return fail(arena, diag, "'source' is empty", .{});
    const out = try arena.alloc(Source, list.len);
    for (list, out) |item, *dst| {
        const m = item.asMap() orelse
            return fail(arena, diag, "'source' entries must look like 'URL : sha256'", .{});
        if (m.count() != 1) return fail(arena, diag, "'source' entries must look like 'URL : sha256'", .{});
        const key = m.keys[0];
        const val = m.values[0].asScalar() orelse
            return fail(arena, diag, "source '{s}' has no checksum", .{key});
        if (std.mem.startsWith(u8, key, "git|")) {
            dst.* = .{ .git = .{ .url = try arena.dupe(u8, key["git|".len..]), .ref = try arena.dupe(u8, val) } };
        } else {
            if (!validSha256(val)) return fail(arena, diag, "source '{s}': checksum is not 64 hex digits", .{key});
            dst.* = .{ .tarball = .{ .url = try arena.dupe(u8, key), .sha256 = try arena.dupe(u8, val) } };
        }
    }
    return out;
}

fn parseSubpackages(arena: Allocator, diag: *Diagnostic, root: Map) Error![]const Subpackage {
    const v = root.get("subpackages") orelse return &.{};
    const m = v.asMap() orelse return fail(arena, diag, "'subpackages' must be a mapping", .{});
    const out = try arena.alloc(Subpackage, m.count());
    for (m.keys, m.values, out) |k, val, *dst| {
        const sm = val.asMap() orelse return fail(arena, diag, "subpackage '{s}' must be a mapping", .{k});
        for (sm.keys) |sk| {
            if (!std.mem.eql(u8, sk, "summary") and !std.mem.eql(u8, sk, "paths"))
                return fail(arena, diag, "subpackage '{s}': unknown key '{s}'", .{ k, sk });
        }
        dst.* = .{
            .name = try arena.dupe(u8, k),
            .summary = try reqScalar(arena, diag, sm, "summary"),
            .paths = try optList(arena, diag, sm, "paths"),
        };
    }
    return out;
}

fn reqScalar(arena: Allocator, diag: *Diagnostic, m: Map, key: []const u8) Error![]const u8 {
    return (try optScalar(arena, diag, m, key)) orelse
        fail(arena, diag, "missing required key '{s}'", .{key});
}

fn optScalar(arena: Allocator, diag: *Diagnostic, m: Map, key: []const u8) Error!?[]const u8 {
    const v = m.get(key) orelse return null;
    const s = v.asScalar() orelse return fail(arena, diag, "'{s}' must be a single value", .{key});
    return try arena.dupe(u8, s);
}

fn optList(arena: Allocator, diag: *Diagnostic, m: Map, key: []const u8) Error![]const []const u8 {
    const v = m.get(key) orelse return &.{};
    const list = v.asList() orelse return fail(arena, diag, "'{s}' must be a list", .{key});
    const out = try arena.alloc([]const u8, list.len);
    for (list, out) |item, *dst| {
        const s = item.asScalar() orelse return fail(arena, diag, "'{s}' entries must be plain values", .{key});
        dst.* = try arena.dupe(u8, s);
    }
    return out;
}

fn fail(arena: Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.message = try std.fmt.allocPrint(arena, fmt, args);
    return error.InvalidRecipe;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

fn validName(n: []const u8) bool {
    if (n.len == 0) return false;
    for (n) |c| switch (c) {
        'a'...'z', '0'...'9', '-', '+', '.' => {},
        else => return false,
    };
    return true;
}

fn validSha256(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

// ---- tests ----

const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "minimal recipe" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const r = try parse(arena_state.allocator(),
        "name: zstd\nversion: 1.5.7\nrelease: 1\nsummary: Compressor\nlicense: BSD-3-Clause\n" ++
            "source:\n  - https://example.org/zstd-1.5.7.tar.gz : " ++ sha ++ "\n" ++
            "install: |\n  %make_install\n", &diag);
    try std.testing.expectEqualStrings("zstd", r.name);
    try std.testing.expectEqual(@as(u32, 1), r.release);
    try std.testing.expectEqualStrings(sha, r.source[0].tarball.sha256);
}

test "unknown key is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidRecipe, parse(arena_state.allocator(),
        "name: a\nversoin: 1\n", &diag));
    try std.testing.expectEqualStrings("unknown key 'versoin'", diag.message);
}

test "bad checksum is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidRecipe, parse(arena_state.allocator(),
        "name: a\nversion: 1\nrelease: 1\nsummary: s\nlicense: MIT\n" ++
            "source:\n  - https://example.org/a.tar.gz : abc\ninstall: x\n", &diag));
}
