//! Recipe model, reader and validation (SPEC.md section 5).
//!
//! The TOML is parsed by toml-zig (`cfg.parse`); this file checks the types
//! and rejects everything section 5 does not define. Unknown keys are errors
//! (5.1).

const std = @import("std");
const toml = @import("toml");
const cfg = @import("cfg.zig");
const Allocator = std.mem.Allocator;

pub const Source = union(enum) {
    /// `{ url, sha256 }`, and `unpack = false` for an archive the build wants
    /// as a file (copied to /build/sources/<name>, like any non-tar source).
    tarball: struct { url: []const u8, sha256: []const u8, unpack: bool = true, name: ?[]const u8 = null },
    /// `{ git, tag }` or `{ git, commit }`; `ref` is whichever was given.
    git: struct { url: []const u8, ref: []const u8 },
};

pub const Subpackage = struct {
    name: []const u8,
    summary: []const u8,
    paths: []const []const u8,
    /// Packages this one needs, besides what the scan finds.
    depends: []const []const u8 = &.{},
    /// apk's install_if: installed automatically once all of these are.
    install_if: []const []const u8 = &.{},
    /// Made even when no file matches `paths` (a group that only depends).
    empty: bool = false,
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
    /// selfhost: what the build needs instead of its own earlier package when
    /// repo/ has none yet (the first, "stage 0" build: dotnet from Microsoft's
    /// SDK). Never used again once one build exists.
    stage0deps: []const []const u8 = &.{},
    /// Names the main package provides besides what the scan finds
    /// (`so:libgcc_s.so.1` for a link the scanner cannot see through).
    provides: []const []const u8 = &.{},
    /// Paths the dependency scan skips (globs from the package root, `*`
    /// inside one component, a trailing `/**` for a whole tree): files built
    /// for other systems that the package carries as data (metasploit's
    /// payloads), whose needs are not this system's.
    noscan: []const []const u8 = &.{},
    /// Packages whose files the main package may take over (apk `replaces`):
    /// for a package that supersedes another.
    replaces: []const []const u8 = &.{},
    /// Directories whose changes run the main package's `scripts/trigger`
    /// (apk triggers: sd-tools applies /usr/lib/sysusers.d and tmpfiles.d).
    triggers: []const []const u8 = &.{},
    options: []const []const u8 = &.{},
    environment: ?[]const u8 = null,
    /// nugetdeps: the commands that restore the source's NuGet packages. Run
    /// once per source with the network, to fill the shared store (SPEC.md 7.4).
    restore: ?[]const u8 = null,
    setup: ?[]const u8 = null,
    build: ?[]const u8 = null,
    check: ?[]const u8 = null,
    install: []const u8,
    subpackages: []const Subpackage = &.{},
};

/// What went wrong, in words a recipe author can act on.
pub const Diagnostic = cfg.Diagnostic;

pub const Error = error{InvalidRecipe} || Allocator.Error;

const known_keys = [_][]const u8{
    "name",      "version",   "release",     "summary",     "description", "license",
    "homepage",  "source",    "patches",     "archs",       "hostdeps",    "builddeps",
    "checkdeps", "rundeps",   "options",     "environment", "restore",     "setup",       "build",
    "check",     "install",   "subpackages", "provides",    "triggers",    "replaces",    "stage0deps",
    "noscan",
};

const known_options = [_][]const u8{ "check", "cross", "strip", "lto", "static", "bootstrap", "zigdeps", "godeps", "cargodeps", "npmdeps", "gradledeps", "nugetdeps", "gemdeps", "pubdeps", "hackagedeps", "pydeps", "meta", "rootlayout", "repo-iso", "selfhost" };
const known_archs = [_][]const u8{ "x86_64", "aarch64", "riscv64" };

/// Parse and validate `text`. All returned memory lives in `arena`.
/// The directory that holds a package's recipe, relative to the project root:
/// `packages/<first letter>/<name>`. The letter keeps `packages/` small enough
/// to browse once the tree has hundreds of recipes.
pub fn dirPath(arena: Allocator, root: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ root, "packages", name[0..1], name });
}

pub fn parse(arena: Allocator, text: []const u8, diag: *Diagnostic) Error!Recipe {
    return parseChecked(arena, text, diag) catch |err| switch (err) {
        error.Invalid => error.InvalidRecipe,
        error.OutOfMemory => |e| e,
    };
}

fn parseChecked(arena: Allocator, text: []const u8, diag: *Diagnostic) cfg.Error!Recipe {
    const root = try cfg.parse(arena, text, diag);
    try cfg.onlyKeys(arena, diag, root, &known_keys, "");

    var r: Recipe = undefined;
    r.name = try cfg.reqString(arena, diag, root, "name");
    if (!validName(r.name)) return cfg.fail(arena, diag, "name '{s}': only lowercase letters, digits, '-', '+', '.'", .{r.name});
    r.version = try cfg.reqString(arena, diag, root, "version");
    r.release = try cfg.reqPositive(arena, diag, root, "release", u32);
    r.summary = try cfg.reqString(arena, diag, root, "summary");
    r.license = try cfg.reqString(arena, diag, root, "license");
    r.description = try cfg.optString(arena, diag, root, "description");
    r.homepage = try cfg.optString(arena, diag, root, "homepage");
    r.environment = try cfg.optString(arena, diag, root, "environment");
    r.restore = try cfg.optString(arena, diag, root, "restore");
    r.setup = try cfg.optString(arena, diag, root, "setup");
    r.build = try cfg.optString(arena, diag, root, "build");
    r.check = try cfg.optString(arena, diag, root, "check");
    r.install = (try cfg.optString(arena, diag, root, "install")) orelse "";
    r.patches = try cfg.optStrings(arena, diag, root, "patches");
    r.archs = try cfg.optStrings(arena, diag, root, "archs");
    r.hostdeps = try cfg.optStrings(arena, diag, root, "hostdeps");
    r.builddeps = try cfg.optStrings(arena, diag, root, "builddeps");
    r.checkdeps = try cfg.optStrings(arena, diag, root, "checkdeps");
    r.rundeps = try cfg.optStrings(arena, diag, root, "rundeps");
    r.stage0deps = try cfg.optStrings(arena, diag, root, "stage0deps");
    r.provides = try cfg.optStrings(arena, diag, root, "provides");
    r.noscan = try cfg.optStrings(arena, diag, root, "noscan");
    r.replaces = try cfg.optStrings(arena, diag, root, "replaces");
    r.triggers = try cfg.optStrings(arena, diag, root, "triggers");
    r.options = try cfg.optStrings(arena, diag, root, "options");

    for (r.archs) |a| {
        const bare = if (a.len > 0 and a[0] == '!') a[1..] else a;
        if (!contains(&known_archs, bare)) return cfg.fail(arena, diag, "unknown arch '{s}'", .{a});
    }
    for (r.options) |o| {
        const bare = if (o.len > 0 and o[0] == '!') o[1..] else o;
        const key = if (std.mem.startsWith(u8, bare, "jobs:")) "jobs" else bare;
        // cargolock=<dir>: a Cargo.lock in files/ for the Rust project at <dir>
        if (std.mem.startsWith(u8, bare, "cargolock=")) {
            if (bare.len == "cargolock=".len or !contains(r.options, "cargodeps"))
                return cfg.fail(arena, diag, "option '{s}': cargolock=<dir> needs a directory and the cargodeps option", .{o});
            continue;
        }
        if (!std.mem.eql(u8, key, "jobs") and !contains(&known_options, key))
            return cfg.fail(arena, diag, "unknown option '{s}'", .{o});
        if (std.mem.eql(u8, key, "jobs") and
            (std.fmt.parseInt(u32, bare["jobs:".len..], 10) catch 0) == 0)
            return cfg.fail(arena, diag, "option '{s}': jobs:N needs a positive number", .{o});
    }

    // A meta-package (`meta`) only depends on others: no source, no steps.
    if (r.stage0deps.len > 0 and !contains(r.options, "selfhost"))
        return cfg.fail(arena, diag, "'stage0deps' is only for a 'selfhost' recipe", .{});
    const meta = contains(r.options, "meta");
    if (meta) {
        if (root.get("source") != null or r.setup != null or r.build != null or r.install.len > 0)
            return cfg.fail(arena, diag, "a 'meta' package has no source, setup, build or install", .{});
        r.source = &.{};
    } else {
        if (root.get("install") == null) return cfg.fail(arena, diag, "missing required key 'install'", .{});
        r.source = try parseSources(arena, diag, root);
    }
    r.subpackages = try parseSubpackages(arena, diag, root);
    // gradledeps (SPEC.md 7.4): the Gradle used is a source of the recipe, kept
    // as a file, and unzip unpacks it (the build image has none).
    if (contains(r.options, "gradledeps")) {
        var dist = false;
        for (r.source) |src| if (src == .tarball) {
            const base = std.fs.path.basename(src.tarball.url);
            if (std.mem.startsWith(u8, base, "gradle-") and std.mem.endsWith(u8, base, "-bin.zip")) dist = true;
        };
        if (!dist) return cfg.fail(arena, diag, "option 'gradledeps' needs a Gradle distribution (gradle-<version>-bin.zip) among the sources", .{});
        if (!contains(r.hostdeps, "unzip")) return cfg.fail(arena, diag, "option 'gradledeps' needs 'unzip' in hostdeps", .{});
    }
    if (contains(r.options, "nugetdeps") and r.restore == null)
        return cfg.fail(arena, diag, "option 'nugetdeps' needs a 'restore' step (the dotnet restore commands)", .{});
    return r;
}

const source_shape = "'source' entries must look like { url = \"...\", sha256 = \"...\" } or { git = \"...\", tag = \"...\" }";

fn parseSources(arena: Allocator, diag: *Diagnostic, root: *const toml.Table) cfg.Error![]const Source {
    // No `source` at all: the recipe's own files/ are everything (base-files).
    const v = root.get("source") orelse return &.{};
    const list = switch (v) {
        .array => |a| a.items.items,
        else => return cfg.fail(arena, diag, "'source' must be a list", .{}),
    };
    if (list.len == 0) return cfg.fail(arena, diag, "'source' is empty", .{});
    const out = try arena.alloc(Source, list.len);
    for (list, out) |item, *dst| {
        const t = switch (item) {
            .table => |t| t,
            else => return cfg.fail(arena, diag, "{s}", .{source_shape}),
        };
        try cfg.onlyKeys(arena, diag, t, &.{ "url", "sha256", "unpack", "name", "git", "tag", "commit" }, "source");
        if (t.get("url") != null) {
            // A tarball: url + sha256, nothing for git.
            if (t.get("git") != null or t.get("tag") != null or t.get("commit") != null)
                return cfg.fail(arena, diag, "{s}", .{source_shape});
            const url = try cfg.reqString(arena, diag, t, "url");
            const checksum = (try cfg.optString(arena, diag, t, "sha256")) orelse
                return cfg.fail(arena, diag, "source '{s}' has no checksum", .{url});
            if (!validSha256(checksum)) return cfg.fail(arena, diag, "source '{s}': checksum is not 64 hex digits", .{url});
            const unpack = if (t.get("unpack")) |uv| switch (uv) {
                .boolean => |b| b,
                else => return cfg.fail(arena, diag, "source '{s}': unpack must be true or false", .{url}),
            } else true;
            // `name`: the file name the source is copied as (crates.io URLs all end in /download).
            const fname = try cfg.optString(arena, diag, t, "name");
            if (fname) |f| if (f.len == 0 or std.mem.indexOfScalar(u8, f, '/') != null)
                return cfg.fail(arena, diag, "source '{s}': name must be a plain file name", .{url});
            dst.* = .{ .tarball = .{ .url = url, .sha256 = checksum, .unpack = unpack, .name = fname } };
        } else if (t.get("git") != null) {
            if (t.get("sha256") != null) return cfg.fail(arena, diag, "{s}", .{source_shape});
            const url = try cfg.reqString(arena, diag, t, "git");
            const tag = try cfg.optString(arena, diag, t, "tag");
            const commit = try cfg.optString(arena, diag, t, "commit");
            if ((tag == null) == (commit == null))
                return cfg.fail(arena, diag, "git source '{s}': give exactly one of 'tag' and 'commit'", .{url});
            dst.* = .{ .git = .{ .url = url, .ref = tag orelse commit.? } };
        } else {
            return cfg.fail(arena, diag, "{s}", .{source_shape});
        }
    }
    return out;
}

fn parseSubpackages(arena: Allocator, diag: *Diagnostic, root: *const toml.Table) cfg.Error![]const Subpackage {
    const v = root.get("subpackages") orelse return &.{};
    const m = switch (v) {
        .table => |t| t,
        else => return cfg.fail(arena, diag, "'subpackages' must be a table", .{}),
    };
    const out = try arena.alloc(Subpackage, m.count());
    for (m.entries.keys(), m.entries.values(), out) |k, val, *dst| {
        const sm = switch (val) {
            .table => |t| t,
            else => return cfg.fail(arena, diag, "subpackage '{s}' must be a table", .{k}),
        };
        try cfg.onlyKeys(arena, diag, sm, &.{ "summary", "paths", "depends", "install_if", "empty" }, try std.fmt.allocPrint(arena, "subpackage '{s}'", .{k}));
        const empty = if (sm.get("empty")) |e| switch (e) {
            .boolean => |b| b,
            else => return cfg.fail(arena, diag, "subpackage '{s}': 'empty' must be true or false", .{k}),
        } else false;
        dst.* = .{
            .name = try arena.dupe(u8, k),
            .summary = try cfg.reqString(arena, diag, sm, "summary"),
            .paths = try cfg.optStrings(arena, diag, sm, "paths"),
            .depends = try cfg.optStrings(arena, diag, sm, "depends"),
            .install_if = try cfg.optStrings(arena, diag, sm, "install_if"),
            .empty = empty,
        };
    }
    return out;
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

const minimal = "name = \"zstd\"\nversion = \"1.5.7\"\nrelease = 1\nsummary = \"Compressor\"\nlicense = \"BSD-3-Clause\"\n" ++
    "install = \'\'\'\n%make_install\n\'\'\'\n" ++
    "source = [{ url = \"https://example.org/zstd-1.5.7.tar.gz\", sha256 = \"" ++ sha ++ "\" }]\n";

fn expectInvalid(text: []const u8, message: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidRecipe, parse(arena_state.allocator(), text, &diag));
    try std.testing.expectEqualStrings(message, diag.message);
}

test "minimal recipe" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const r = try parse(arena_state.allocator(), minimal, &diag);
    try std.testing.expectEqualStrings("zstd", r.name);
    try std.testing.expectEqual(@as(u32, 1), r.release);
    try std.testing.expectEqualStrings(sha, r.source[0].tarball.sha256);
    try std.testing.expectEqualStrings("%make_install\n", r.install);
}

test "shell steps are literal: backslashes and dollars survive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const r = try parse(arena_state.allocator(), minimal ++
        "build = \'\'\'\n%configure --a \\\n    --b=$pkgdir\n\'\'\'\n", &diag);
    try std.testing.expectEqualStrings("%configure --a \\\n    --b=$pkgdir\n", r.build.?);
}

test "git sources, lists, subpackages and [[source]] tables" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const r = try parse(arena_state.allocator(),
        "name = \"a\"\nversion = \"1\"\nrelease = 2\nsummary = \"s\"\nlicense = \"MIT\"\n" ++
            "install = \"x\"\noptions = [\"static\", \"!check\", \"jobs:2\"]\nbuilddeps = [\"zlib\", \"xz\"]\n" ++
            "[[source]]\ngit = \"https://example.org/a.git\"\ntag = \"v1\"\n" ++
            "[[source]]\nurl = \"https://example.org/b.tgz\"\nsha256 = \"" ++ sha ++ "\"\n" ++
            "[subpackages.tools]\nsummary = \"Tools\"\npaths = [\"/usr/bin\"]\n", &diag);
    try std.testing.expectEqual(@as(u32, 2), r.release);
    try std.testing.expectEqualStrings("v1", r.source[0].git.ref);
    try std.testing.expectEqualStrings("https://example.org/b.tgz", r.source[1].tarball.url);
    try std.testing.expectEqual(@as(usize, 3), r.options.len);
    try std.testing.expectEqualStrings("xz", r.builddeps[1]);
    try std.testing.expectEqualStrings("tools", r.subpackages[0].name);
    try std.testing.expectEqualStrings("/usr/bin", r.subpackages[0].paths[0]);
}

test "unknown key is an error" {
    try expectInvalid("name = \"a\"\nversoin = 1\n", "unknown key 'versoin'");
}

test "types are checked" {
    try expectInvalid(minimal ++ "check = 5\n", "'check' must be a string, not integer");
    try expectInvalid(minimal ++ "builddeps = \"zlib\"\n", "'builddeps' must be a list, not string");
    try expectInvalid(minimal ++ "patches = [1]\n", "'patches' entries must be strings, not integer");
}

test "release is an integer starting at 1" {
    const head = "name = \"a\"\nversion = \"1\"\nsummary = \"s\"\nlicense = \"MIT\"\ninstall = \"x\"\n" ++
        "source = [{ url = \"u\", sha256 = \"" ++ sha ++ "\" }]\n";
    try expectInvalid(head ++ "release = \"1\"\n", "'release' must be an integer, not string");
    try expectInvalid(head ++ "release = 0\n", "'release' starts at 1");
    try expectInvalid(head, "missing required key 'release'");
}

test "version must be a string" {
    try expectInvalid("name = \"a\"\nversion = 1.5\n", "'version' must be a string, not float");
}

test "bad checksum and bad source shapes are errors" {
    const head = "name = \"a\"\nversion = \"1\"\nrelease = 1\nsummary = \"s\"\nlicense = \"MIT\"\ninstall = \"x\"\n";
    try expectInvalid(head ++ "source = [{ url = \"https://example.org/a.tar.gz\", sha256 = \"abc\" }]\n", "source 'https://example.org/a.tar.gz': checksum is not 64 hex digits");
    try expectInvalid(head ++ "source = [{ url = \"u\" }]\n", "source 'u' has no checksum");
    try expectInvalid(head ++ "source = [{ git = \"g\" }]\n", "git source 'g': give exactly one of 'tag' and 'commit'");
    try expectInvalid(head ++ "source = [{ git = \"g\", tag = \"t\", commit = \"c\" }]\n", "git source 'g': give exactly one of 'tag' and 'commit'");
    try expectInvalid(head ++ "source = [{ url = \"u\", sha256 = \"" ++ sha ++ "\", tag = \"t\" }]\n", source_shape);
    try expectInvalid(head ++ "source = [{ urll = \"u\" }]\n", "source: unknown key 'urll'");
    try expectInvalid(head ++ "source = []\n", "'source' is empty");
    try expectInvalid(head ++ "source = [\"u\"]\n", source_shape);
}

test "a TOML syntax error reports line and column" {
    try expectInvalid("name = \"a\"\nversion = \n", "line 2, column 11: expected value");
}

test "meta packages have no source or steps; subpackages take depends, install_if, empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    const head = "name = \"a\"\nversion = \"1\"\nrelease = 1\nsummary = \"s\"\nlicense = \"MIT\"\n";
    const m = try parse(arena_state.allocator(), head ++ "options = [\"meta\"]\nrundeps = [\"b\", \"c\"]\n", &diag);
    try std.testing.expectEqual(@as(usize, 0), m.source.len);
    try std.testing.expectEqualStrings("", m.install);
    try expectInvalid(head ++ "options = [\"meta\"]\ninstall = \"x\"\n", "a 'meta' package has no source, setup, build or install");
    try expectInvalid(head ++ "source = []\n", "missing required key 'install'");
    const f = try parse(arena_state.allocator(), head ++ "options = [\"meta\"]\n" ++
        "[subpackages.gpu]\nsummary = \"GPU\"\nempty = true\ndepends = [\"a-amdgpu\"]\n" ++
        "[subpackages.amdgpu]\nsummary = \"AMD\"\npaths = [\"/usr/lib/firmware/amdgpu\"]\ninstall_if = [\"a-gpu\"]\n", &diag);
    try std.testing.expect(f.subpackages[0].empty);
    try std.testing.expectEqualStrings("a-amdgpu", f.subpackages[0].depends[0]);
    try std.testing.expectEqualStrings("a-gpu", f.subpackages[1].install_if[0]);
    try std.testing.expect(!f.subpackages[1].empty);
}
