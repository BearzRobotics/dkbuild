//! Running the builds of `pkg` and `world` (SPEC.md 10): up to `parallel`
//! at once, each starting as soon as everything its build root needs is built.
//!
//! main.zig makes the list, in dependency order, and settles what it can
//! upfront: a package never built, built as another version, or edited
//! (`certain`). The rest are decided here, once everything their build root
//! needs is done: rebuilt only if the outputs of those packages differ from
//! what the package was last built with (inputs.buildRootHash; early cutoff).
//! A build only waits for builds earlier in the list, so it never waits in a
//! circle, and with `parallel` = 1 it runs exactly as the list says.
//!
//! - A build waits for the in-tree packages it unpacks from repo/
//!   (`tree.needs`). When one of them fails, it is skipped.
//! - A heavy build (`build.isHeavy`: a recipe with `jobs:N`, such as LLVM) runs
//!   alone: it waits until the others end, and nothing starts beside it.
//! - Every other build gets the full `-j`. Small builds spend much of their
//!   time in single-threaded configure scripts, so they share the machine well.
//! - With more than one build at a time, each build's console output is held
//!   and printed whole when it ends; with one, it streams as before.

const term = @import("term.zig");
const std = @import("std");
const recipe = @import("recipe.zig");
const tree = @import("tree.zig");
const build = @import("build.zig");
const inputs = @import("inputs.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Job = struct {
    /// Index into the tree's recipes.
    idx: usize,
    /// `name-version-rN`.
    id: []const u8,
    /// Where the rebuild record goes once the build succeeds.
    rec_path: []const u8,
    /// `<version>-r<release>` and the recipe's own inputs, for that record.
    version: []const u8,
    own: inputs.Hex,
    /// Build it whatever its build root holds (new, new version, --force).
    certain: bool,
    /// The build-root hash it was last built with (from its record).
    old_root: ?inputs.Hex = null,
    /// Its build script now (build.scriptHash), and whether that differs from
    /// the record's: a changed macro rebuilds it like a changed build root.
    script: inputs.Hex,
    script_changed: bool = false,
};

pub const Result = struct {
    failed: []const []const u8,
    skipped: []const []const u8,
};

const State = enum { pending, running, ok, failed, skipped };

const Shared = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// Jobs whose thread has finished its build; capacity for every job.
    done: std.ArrayList(usize) = .empty,
};

const Worker = struct {
    shared: *Shared,
    io: Io,
    job: usize,
    r: recipe.Recipe,
    opts: build.Options,
    buffered: bool,
    console: std.ArrayList(u8) = .empty,
    err: ?anyerror = null,
    result: build.Built = undefined,
    /// Set for a rebuild only because the build root changed.
    rebuild: ?build.Rebuild = null,
    bump: Bump = undefined,
    thread: std.Thread = undefined,
};

/// What `build.Rebuild.bump` needs: the recipe to bump, in the tree and on disk.
const Bump = struct {
    t: tree.Tree,
    idx: usize,
    root: []const u8,
    io: Io,

    fn call(ctx: *anyopaque) anyerror!u32 {
        const b: *Bump = @ptrCast(@alignCast(ctx));
        return bumpRelease(b.io, b.t, b.idx, b.root);
    }
};

fn workerMain(w: *Worker) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    if (w.buffered) build.console = &w.console;
    defer build.console = null;
    if (build.buildOne(arena_state.allocator(), w.io, w.r, w.opts, w.rebuild)) |res| {
        w.result = res;
    } else |err| {
        w.err = err;
    }
    w.shared.mutex.lockUncancelable(w.io);
    defer w.shared.mutex.unlock(w.io);
    w.shared.done.appendAssumeCapacity(w.job);
    w.shared.cond.signal(w.io);
}

/// The jobs (by position in `jobs`) that job `j` waits for: the ones earlier
/// in the list whose packages its build root needs.
fn waitLists(arena: Allocator, t: tree.Tree, jobs: []const Job) Allocator.Error![]const []const usize {
    const job_of = try arena.alloc(?usize, t.recipes.len);
    @memset(job_of, null);
    for (jobs, 0..) |jb, j| job_of[jb.idx] = j;
    const waits = try arena.alloc([]const usize, jobs.len);
    for (jobs, 0..) |jb, j| {
        var list: std.ArrayList(usize) = .empty;
        for (try t.needs(arena, jb.idx)) |p| if (job_of[p]) |pj| {
            if (pj < j) try list.append(arena, pj);
        };
        waits[j] = list.items;
    }
    return waits;
}

/// `outputs` holds, per recipe, the hash of what it last produced (from the
/// records); builds that succeed here update it.
/// A package rebuilt because what it builds against changed is published as
/// the next release, written into its recipe, if it comes out different (apk
/// upgrades only when the version goes up); if it comes out identical, its
/// package stays as it is (SPEC.md 7.2). The tree's copy of the recipe is
/// updated with any bump, so what builds against it looks for the new files;
/// nothing that needs it is running yet (it waits for this build).
pub fn run(arena: Allocator, io: Io, t: tree.Tree, jobs: []Job, outputs: []?inputs.Produced, opts: build.Options, parallel: usize, keep_going: bool) !Result {
    const n = jobs.len;
    const waits = try waitLists(arena, t, jobs);
    const state = try arena.alloc(State, n);
    @memset(state, .pending);
    const workers = try arena.alloc(Worker, n);
    // The build-root hash each job starts with, for its record.
    const roots = try arena.alloc(inputs.Hex, n);
    const announced = try arena.alloc(bool, n);
    @memset(announced, false);
    var shared: Shared = .{};
    try shared.done.ensureTotalCapacity(arena, n);
    const buffered = parallel > 1;

    var failed: std.ArrayList([]const u8) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    var running: usize = 0;
    var heavy_running = false;
    var stop = false;

    while (true) {
        if (!stop) {
            // Nothing starts beside a heavy build, nor past one waiting for the others to end.
            var hold = heavy_running;
            for (0..n) |j| {
                if (state[j] != .pending) continue;
                var ready = true;
                var blocked = false;
                for (waits[j]) |w| switch (state[w]) {
                    .failed, .skipped => blocked = true,
                    .pending, .running => ready = false,
                    .ok => {},
                };
                const r = t.recipes[jobs[j].idx];
                if (blocked) {
                    state[j] = .skipped;
                    try skipped.append(arena, r.name);
                    term.print("==> {s}: skipped, a package it needs failed\n", .{r.name});
                    continue;
                }
                if (!ready) continue;
                // Everything in its build root is settled: compare.
                roots[j] = try inputs.buildRootHash(arena, t, outputs, jobs[j].idx);
                if (!jobs[j].certain) {
                    if (jobs[j].old_root) |old| if (!jobs[j].script_changed and std.mem.eql(u8, &old, &roots[j])) {
                        state[j] = .ok;
                        term.print("==> {s}: up to date\n", .{jobs[j].id});
                        continue;
                    };
                    if (!announced[j]) {
                        announced[j] = true;
                        term.print("==> {s}: {s}; rebuilding\n", .{ jobs[j].id, if (jobs[j].script_changed) "dkbuild's macros changed its build script" else "packages it builds against changed" });
                    }
                }
                if (hold or running >= parallel) continue;
                const heavy = build.isHeavy(r);
                if (heavy and running > 0) {
                    hold = true;
                    continue;
                }
                workers[j] = .{ .shared = &shared, .io = io, .job = j, .r = t.recipes[jobs[j].idx], .opts = opts, .buffered = buffered };
                if (!jobs[j].certain) if (outputs[jobs[j].idx]) |prev| {
                    workers[j].bump = .{ .t = t, .idx = jobs[j].idx, .root = opts.root, .io = io };
                    workers[j].rebuild = .{ .previous = prev, .bump = Bump.call, .ctx = &workers[j].bump };
                };
                workers[j].thread = std.Thread.spawn(.{}, workerMain, .{&workers[j]}) catch |err| {
                    term.print("error: cannot start a thread for {s}: {s}\n", .{ r.name, @errorName(err) });
                    std.process.exit(1);
                };
                state[j] = .running;
                running += 1;
                if (buffered) term.print("--> {s}: started{s} ({d} running)\n", .{ jobs[j].id, if (heavy) ", alone" else "", running });
                if (heavy) {
                    heavy_running = true;
                    hold = true;
                }
            }
        }
        if (running == 0) break;

        shared.mutex.lockUncancelable(io);
        while (shared.done.items.len == 0) shared.cond.waitUncancelable(io, &shared.mutex);
        const finished = try arena.dupe(usize, shared.done.items);
        shared.done.clearRetainingCapacity();
        shared.mutex.unlock(io);

        for (finished) |j| {
            const w = &workers[j];
            w.thread.join();
            running -= 1;
            if (build.isHeavy(w.r)) heavy_running = false;
            if (w.console.items.len > 0) term.emit(w.console.items);
            w.console.deinit(std.heap.smp_allocator);
            if (w.err) |err| {
                term.print("{s}: {s}\n", .{ w.r.name, @errorName(err) });
                state[j] = .failed;
                try failed.append(arena, w.r.name);
                if (!keep_going and !stop) {
                    stop = true;
                    if (running > 0) term.print("stopping: waiting for {d} running build(s) to end\n", .{running});
                }
                continue;
            }
            state[j] = .ok;
            outputs[jobs[j].idx] = w.result.produced;
            const r_now = t.recipes[jobs[j].idx];
            if (w.result.release != w.r.release) {
                // Bumped: the record is for the new release and the edited recipe.
                jobs[j].version = try std.fmt.allocPrint(arena, "{s}-r{d}", .{ r_now.version, w.result.release });
                jobs[j].id = try std.fmt.allocPrint(arena, "{s}-{s}", .{ r_now.name, jobs[j].version });
                jobs[j].own = try inputs.ownHash(arena, io, opts.root, r_now.name, opts.arch);
            }
            const record = try inputs.format(arena, .{ .version = jobs[j].version, .inputs = jobs[j].own, .deps = roots[j], .output = w.result.produced.output, .interface = w.result.produced.interface, .script = jobs[j].script });
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = jobs[j].rec_path, .data = record }) catch |err| {
                term.print("warning: cannot write {s}: {s}\n", .{ jobs[j].rec_path, @errorName(err) });
            };
        }
    }
    return .{ .failed = failed.items, .skipped = skipped.items };
}

/// `release = N` becomes `N + 1` in the recipe's package.toml and in the
/// tree's copy of the recipe. Runs in the worker that built it.
fn bumpRelease(io: Io, t: tree.Tree, idx: usize, root: []const u8) !u32 {
    var st = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer st.deinit();
    const arena = st.allocator();
    const recipes = @constCast(t.recipes);
    const r = &recipes[idx];
    const path = try std.fs.path.join(arena, &.{ try recipe.dirPath(arena, root, r.name), "package.toml" });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
    const span = releaseValue(text) orelse return error.NoReleaseLine;
    const next = r.release + 1;
    const new_text = try std.fmt.allocPrint(arena, "{s}{d}{s}", .{ text[0..span[0]], next, text[span[1]..] });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = new_text });
    r.release = next;
    return next;
}

/// Where the number of the top-level `release = N` line is: [start, end).
fn releaseValue(text: []const u8) ?[2]usize {
    var start: usize = 0;
    while (start < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const line = text[start..end];
        // Subpackage tables come after every top-level key (SPEC.md 5.1).
        if (line.len > 0 and line[0] == '[') return null;
        if (std.mem.startsWith(u8, line, "release")) {
            var i: usize = "release".len;
            while (i < line.len and line[i] == ' ') i += 1;
            if (i < line.len and line[i] == '=') {
                i += 1;
                while (i < line.len and line[i] == ' ') i += 1;
                const d0 = i;
                while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
                if (i > d0) return .{ start + d0, start + i };
            }
        }
        start = end + 1;
    }
    return null;
}

test "releaseValue finds the top-level release, however it is spaced" {
    const t1 = "name = \"a\"\nrelease = 12\nsummary = \"s\"\n";
    const s1 = releaseValue(t1).?;
    try std.testing.expectEqualStrings("12", t1[s1[0]..s1[1]]);
    const t2 = "name      = \"a\"\nrelease   = 3\n";
    const s2 = releaseValue(t2).?;
    try std.testing.expectEqualStrings("3", t2[s2[0]..s2[1]]);
    try std.testing.expect(releaseValue("name = \"a\"\n[subpackages.x]\nrelease = 1\n") == null);
    try std.testing.expect(releaseValue("# release = 4\nreleases = 2\n") == null);
}

fn rc(name: []const u8, build_deps: []const []const u8) recipe.Recipe {
    return .{
        .name = name, .version = "1", .release = 1, .summary = "s", .license = "MIT",
        .source = &.{}, .install = "x", .builddeps = build_deps,
    };
}

test "a job waits only for earlier jobs it needs; up-to-date packages are not waited for" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const t: tree.Tree = .{ .recipes = &.{
        rc("app", &.{ "lib-devel", "zlib-devel" }),
        rc("lib", &.{"zlib-devel"}),
        rc("other", &.{}),
        rc("zlib", &.{}),
    } };
    // zlib is up to date (not in the list); lib, other, app are built in that order.
    const jobs = [_]Job{
        .{ .idx = 1, .id = "lib", .rec_path = "", .version = "1-r1", .own = undefined, .certain = true, .script = undefined },
        .{ .idx = 2, .id = "other", .rec_path = "", .version = "1-r1", .own = undefined, .certain = true, .script = undefined },
        .{ .idx = 0, .id = "app", .rec_path = "", .version = "1-r1", .own = undefined, .certain = true, .script = undefined },
    };
    const w = try waitLists(a, t, &jobs);
    try std.testing.expectEqual(@as(usize, 0), w[0].len);
    try std.testing.expectEqual(@as(usize, 0), w[1].len);
    try std.testing.expectEqualSlices(usize, &.{0}, w[2]);
}
