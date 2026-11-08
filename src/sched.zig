//! Running the builds of `pkg` and `world` (SPEC.md 10): up to `parallel`
//! at once, each starting as soon as everything its build root needs is built.
//!
//! What to build is decided before anything starts (main.zig); this runs that
//! list. The list is in dependency order, and a build only waits for builds
//! earlier in it, so it never waits in a circle, and with `parallel` = 1 it
//! runs exactly as the list says.
//!
//! - A build waits for the in-tree packages it unpacks from repo/
//!   (`tree.needs`). When one of them fails, it is skipped.
//! - A heavy build (`build.isHeavy`: a recipe with `jobs:N`, such as LLVM) runs
//!   alone: it waits until the others end, and nothing starts beside it.
//! - Every other build gets the full `-j`. Small builds spend much of their
//!   time in single-threaded configure scripts, so they share the machine well.
//! - With more than one build at a time, each build's console output is held
//!   and printed whole when it ends; with one, it streams as before.

const std = @import("std");
const recipe = @import("recipe.zig");
const tree = @import("tree.zig");
const build = @import("build.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Job = struct {
    /// Index into the tree's recipes.
    idx: usize,
    /// `name-version-rN`.
    id: []const u8,
    /// Where the rebuild record goes, and what it says, once the build succeeds.
    rec_path: []const u8,
    record: []const u8,
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
    thread: std.Thread = undefined,
};

fn workerMain(w: *Worker) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    if (w.buffered) build.console = &w.console;
    defer build.console = null;
    build.buildOne(arena_state.allocator(), w.io, w.r, w.opts) catch |err| {
        w.err = err;
    };
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

pub fn run(arena: Allocator, io: Io, t: tree.Tree, jobs: []const Job, opts: build.Options, parallel: usize, keep_going: bool) !Result {
    const n = jobs.len;
    const waits = try waitLists(arena, t, jobs);
    const state = try arena.alloc(State, n);
    @memset(state, .pending);
    const workers = try arena.alloc(Worker, n);
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
                    std.debug.print("==> {s}: skipped, a package it needs failed\n", .{r.name});
                    continue;
                }
                if (!ready or hold or running >= parallel) continue;
                const heavy = build.isHeavy(r);
                if (heavy and running > 0) {
                    hold = true;
                    continue;
                }
                workers[j] = .{ .shared = &shared, .io = io, .job = j, .r = r, .opts = opts, .buffered = buffered };
                workers[j].thread = std.Thread.spawn(.{}, workerMain, .{&workers[j]}) catch |err| {
                    std.debug.print("error: cannot start a thread for {s}: {s}\n", .{ r.name, @errorName(err) });
                    std.process.exit(1);
                };
                state[j] = .running;
                running += 1;
                if (buffered) std.debug.print("--> {s}: started{s} ({d} running)\n", .{ jobs[j].id, if (heavy) ", alone" else "", running });
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
            if (w.console.items.len > 0) std.debug.print("{s}", .{w.console.items});
            w.console.deinit(std.heap.smp_allocator);
            if (w.err) |err| {
                std.debug.print("{s}: {s}\n", .{ w.r.name, @errorName(err) });
                state[j] = .failed;
                try failed.append(arena, w.r.name);
                if (!keep_going and !stop) {
                    stop = true;
                    if (running > 0) std.debug.print("stopping: waiting for {d} running build(s) to end\n", .{running});
                }
                continue;
            }
            state[j] = .ok;
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = jobs[j].rec_path, .data = jobs[j].record }) catch |err| {
                std.debug.print("warning: cannot write {s}: {s}\n", .{ jobs[j].rec_path, @errorName(err) });
            };
        }
    }
    return .{ .failed = failed.items, .skipped = skipped.items };
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
        .{ .idx = 1, .id = "lib", .rec_path = "", .record = "" },
        .{ .idx = 2, .id = "other", .rec_path = "", .record = "" },
        .{ .idx = 0, .id = "app", .rec_path = "", .record = "" },
    };
    const w = try waitLists(a, t, &jobs);
    try std.testing.expectEqual(@as(usize, 0), w[0].len);
    try std.testing.expectEqual(@as(usize, 0), w[1].len);
    try std.testing.expectEqualSlices(usize, &.{0}, w[2]);
}
