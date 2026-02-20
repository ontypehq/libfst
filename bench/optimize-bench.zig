const std = @import("std");
const libfst = @import("libfst");

const W = libfst.TropicalWeight;
const A = libfst.Arc(W);
const Label = libfst.Label;
const StateId = libfst.StateId;
const MutableFst = libfst.MutableFst(W);
const FrozenFst = libfst.Fst(W);
const Allocator = std.mem.Allocator;

const Scenario = enum {
    clone_acceptor,
    optimize_acceptor,
    optimize_transducer,
    compose_acceptor,
    compose_frozen_transducer,
    compose_frozen_shortest_path,
    rm_epsilon_acceptor,
    shortest_path_acceptor,
};

const OutputFormat = enum {
    text,
    json,
};

const Options = struct {
    scenario: Scenario = .optimize_acceptor,
    len: usize = 4096,
    transducer_len: usize = 0, // 0 => derive from len
    branches: usize = 3,
    iterations: usize = 80,
    warmup: usize = 5,
    per_iter: bool = false,
    format: OutputFormat = .text,
};

const Inputs = struct {
    acceptor: MutableFst,
    acceptor_branch: MutableFst,
    transducer: MutableFst,
    transducer_frozen: FrozenFst,

    fn deinit(self: *Inputs) void {
        self.acceptor.deinit();
        self.acceptor_branch.deinit();
        self.transducer.deinit();
        self.transducer_frozen.deinit();
    }
};

const BenchStats = struct {
    total_ns: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    total_states: usize = 0,
};

fn parseScenario(arg: []const u8) ?Scenario {
    if (std.mem.eql(u8, arg, "clone_acceptor")) return .clone_acceptor;
    if (std.mem.eql(u8, arg, "optimize_acceptor")) return .optimize_acceptor;
    if (std.mem.eql(u8, arg, "optimize_transducer")) return .optimize_transducer;
    if (std.mem.eql(u8, arg, "compose_acceptor")) return .compose_acceptor;
    if (std.mem.eql(u8, arg, "compose_frozen_transducer")) return .compose_frozen_transducer;
    if (std.mem.eql(u8, arg, "compose_frozen_shortest_path")) return .compose_frozen_shortest_path;
    if (std.mem.eql(u8, arg, "rm_epsilon_acceptor")) return .rm_epsilon_acceptor;
    if (std.mem.eql(u8, arg, "shortest_path_acceptor")) return .shortest_path_acceptor;
    return null;
}

fn parseFormat(arg: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, arg, "text")) return .text;
    if (std.mem.eql(u8, arg, "json")) return .json;
    return null;
}

fn parseBool(arg: []const u8) ?bool {
    if (std.mem.eql(u8, arg, "true")) return true;
    if (std.mem.eql(u8, arg, "false")) return false;
    return null;
}

fn printUsage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\Usage: optimize-bench [options]
        \\  --scenario <name>         clone_acceptor|optimize_acceptor|optimize_transducer|compose_acceptor|compose_frozen_transducer|compose_frozen_shortest_path|rm_epsilon_acceptor|shortest_path_acceptor
        \\  --len <n>                 graph length (default: 4096)
        \\  --transducer-len <n>      transducer length (default: len/4, min 1)
        \\  --branches <n>            branching factor for transducer (default: 3)
        \\  --iters <n>               timed iterations (default: 80)
        \\  --warmup <n>              warmup iterations (default: 5)
        \\  --format <text|json>      output format (default: text)
        \\  --per-iter <true|false>   emit per-iteration timings (default: false)
        \\  --help                    show this help
        \\
        \\Example (profile-friendly):
        \\  zig build bench -Doptimize=ReleaseFast -- --scenario optimize_transducer --len 16384 --branches 4 --iters 300 --warmup 20 --format json
        \\
    );
}

fn parseOptions(allocator: Allocator) !Options {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            return error.ShowUsage;
        }
        if (i + 1 >= args.len) return error.InvalidArgument;
        const value = args[i + 1];

        if (std.mem.eql(u8, arg, "--scenario")) {
            opts.scenario = parseScenario(value) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--len")) {
            opts.len = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--transducer-len")) {
            opts.transducer_len = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--branches")) {
            opts.branches = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--iters")) {
            opts.iterations = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            opts.warmup = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--format")) {
            opts.format = parseFormat(value) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--per-iter")) {
            opts.per_iter = parseBool(value) orelse return error.InvalidArgument;
        } else {
            return error.InvalidArgument;
        }
        i += 2;
    }
    if (opts.len == 0 or opts.iterations == 0) return error.InvalidArgument;
    if (opts.branches == 0) opts.branches = 1;
    return opts;
}

fn buildLinearAcceptor(allocator: Allocator, len: usize) !MutableFst {
    return buildLinearAcceptorWithAlphabet(allocator, len, 255);
}

fn buildLinearAcceptorWithAlphabet(allocator: Allocator, len: usize, alphabet: usize) !MutableFst {
    var fst = MutableFst.init(allocator);
    errdefer fst.deinit();

    try fst.addStates(len + 1);
    fst.setStart(0);
    fst.setFinal(@intCast(len), W.one);

    const alpha = @max(@as(usize, 1), alphabet);
    for (0..len) |i| {
        const label: Label = @intCast((i % alpha) + 1);
        const src: StateId = @intCast(i);
        const dst: StateId = @intCast(i + 1);
        try fst.addArc(src, A.init(label, label, W.one, dst));
    }
    return fst;
}

fn buildBranchingTransducer(allocator: Allocator, len: usize, branches: usize) !MutableFst {
    var fst = MutableFst.init(allocator);
    errdefer fst.deinit();

    try fst.addStates(len + 1);
    fst.setStart(0);
    fst.setFinal(@intCast(len), W.one);

    for (0..len) |i| {
        const src: StateId = @intCast(i);
        const dst: StateId = @intCast(i + 1);
        const ilabel: Label = @intCast((i % 255) + 1);
        for (0..branches) |b| {
            const olabel: Label = @intCast(((i + b) % 255) + 1);
            const weight = W.init(@floatFromInt(b));
            try fst.addArc(src, A.init(ilabel, olabel, weight, dst));
        }
    }
    return fst;
}

fn initInputs(allocator: Allocator, len: usize, transducer_len: usize, branches: usize) !Inputs {
    var acceptor = try buildLinearAcceptor(allocator, len);
    errdefer acceptor.deinit();
    var acceptor_branch = try buildLinearAcceptorWithAlphabet(allocator, len, branches);
    errdefer acceptor_branch.deinit();

    var transducer = try buildBranchingTransducer(allocator, transducer_len, branches);
    errdefer transducer.deinit();

    var transducer_for_freeze = MutableFst.init(allocator);
    errdefer transducer_for_freeze.deinit();
    try transducer_for_freeze.addStates(transducer_len);
    if (transducer_len == 0) return error.InvalidArgument;
    transducer_for_freeze.setStart(0);
    for (0..transducer_len) |i| {
        const s: StateId = @intCast(i);
        transducer_for_freeze.setFinal(s, W.one);
        for (0..branches) |b| {
            const ilabel: Label = @intCast((b % 255) + 1);
            const olabel: Label = @intCast(((i + b) % 255) + 1);
            const next: StateId = @intCast((i + b + 1) % transducer_len);
            try transducer_for_freeze.addArc(s, A.init(ilabel, olabel, W.init(@floatFromInt(b)), next));
        }
    }
    defer transducer_for_freeze.deinit();
    var transducer_frozen = try FrozenFst.fromMutable(allocator, &transducer_for_freeze);
    errdefer transducer_frozen.deinit();

    return .{
        .acceptor = acceptor,
        .acceptor_branch = acceptor_branch,
        .transducer = transducer,
        .transducer_frozen = transducer_frozen,
    };
}

fn runScenarioOnce(scenario: Scenario, allocator: Allocator, inputs: *const Inputs) !usize {
    switch (scenario) {
        .clone_acceptor => {
            var clone = try inputs.acceptor.clone(allocator);
            defer clone.deinit();
            return clone.numStates();
        },
        .optimize_acceptor => {
            var out = try libfst.ops.optimize.optimize(W, allocator, &inputs.acceptor);
            defer out.deinit();
            return out.numStates();
        },
        .optimize_transducer => {
            var out = try libfst.ops.optimize.optimize(W, allocator, &inputs.transducer);
            defer out.deinit();
            return out.numStates();
        },
        .compose_acceptor => {
            var out = try libfst.ops.compose.compose(W, allocator, &inputs.acceptor, &inputs.acceptor);
            defer out.deinit();
            return out.numStates();
        },
        .compose_frozen_transducer => {
            var out = try libfst.ops.compose.compose(W, allocator, &inputs.acceptor_branch, &inputs.transducer_frozen);
            defer out.deinit();
            return out.numStates();
        },
        .compose_frozen_shortest_path => {
            var lattice = try libfst.ops.compose.compose(W, allocator, &inputs.acceptor_branch, &inputs.transducer_frozen);
            defer lattice.deinit();
            var best = try libfst.ops.shortest_path.shortestPath(W, allocator, &lattice, 1);
            defer best.deinit();
            return best.numStates();
        },
        .rm_epsilon_acceptor => {
            var out = try libfst.ops.rm_epsilon.rmEpsilon(W, allocator, &inputs.acceptor);
            defer out.deinit();
            return out.numStates();
        },
        .shortest_path_acceptor => {
            var out = try libfst.ops.shortest_path.shortestPath(W, allocator, &inputs.acceptor, 1);
            defer out.deinit();
            return out.numStates();
        },
    }
}

fn benchmark(
    out: *std.Io.Writer,
    allocator: Allocator,
    opts: Options,
    inputs: *const Inputs,
) !BenchStats {
    for (0..opts.warmup) |_| {
        _ = try runScenarioOnce(opts.scenario, allocator, inputs);
    }

    var stats = BenchStats{};
    for (0..opts.iterations) |iter| {
        var timer = try std.time.Timer.start();
        const states = try runScenarioOnce(opts.scenario, allocator, inputs);
        const ns = timer.read();

        stats.total_ns += ns;
        stats.min_ns = @min(stats.min_ns, ns);
        stats.max_ns = @max(stats.max_ns, ns);
        stats.total_states += states;

        if (opts.per_iter) {
            switch (opts.format) {
                .text => {
                    try out.print("iter={d} ns={d} states={d}\n", .{ iter, ns, states });
                },
                .json => {
                    try out.print(
                        "{{\"iter\":{d},\"ns\":{d},\"states\":{d}}}\n",
                        .{ iter, ns, states },
                    );
                },
            }
        }
    }
    return stats;
}

fn scenarioName(scenario: Scenario) []const u8 {
    return switch (scenario) {
        .clone_acceptor => "clone_acceptor",
        .optimize_acceptor => "optimize_acceptor",
        .optimize_transducer => "optimize_transducer",
        .compose_acceptor => "compose_acceptor",
        .compose_frozen_transducer => "compose_frozen_transducer",
        .compose_frozen_shortest_path => "compose_frozen_shortest_path",
        .rm_epsilon_acceptor => "rm_epsilon_acceptor",
        .shortest_path_acceptor => "shortest_path_acceptor",
    };
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&out_buf);
    const out = &stdout_writer.interface;

    const opts = parseOptions(allocator) catch |err| switch (err) {
        error.ShowUsage => {
            try printUsage(out);
            try out.flush();
            return;
        },
        else => {
            try out.writeAll("invalid arguments\n\n");
            try printUsage(out);
            try out.flush();
            return err;
        },
    };

    const transducer_len = @max(@as(usize, 1), if (opts.transducer_len == 0) opts.len / 4 else opts.transducer_len);
    var inputs = try initInputs(allocator, opts.len, transducer_len, opts.branches);
    defer inputs.deinit();

    const stats = try benchmark(out, allocator, opts, &inputs);
    const avg_ns = stats.total_ns / opts.iterations;
    const avg_us = @as(f64, @floatFromInt(avg_ns)) / @as(f64, std.time.ns_per_us);
    const avg_states = stats.total_states / opts.iterations;

    switch (opts.format) {
        .text => {
            try out.print(
                "scenario={s} len={d} transducer_len={d} branches={d} warmup={d} iters={d}\n",
                .{
                    scenarioName(opts.scenario),
                    opts.len,
                    transducer_len,
                    opts.branches,
                    opts.warmup,
                    opts.iterations,
                },
            );
            try out.print(
                "total_ns={d} avg_us={d:.3} min_ns={d} max_ns={d} avg_states={d}\n",
                .{ stats.total_ns, avg_us, stats.min_ns, stats.max_ns, avg_states },
            );
        },
        .json => {
            try out.print(
                "{{\"scenario\":\"{s}\",\"len\":{d},\"transducer_len\":{d},\"branches\":{d},\"warmup\":{d},\"iters\":{d},\"total_ns\":{d},\"avg_ns\":{d},\"min_ns\":{d},\"max_ns\":{d},\"avg_states\":{d}}}\n",
                .{
                    scenarioName(opts.scenario),
                    opts.len,
                    transducer_len,
                    opts.branches,
                    opts.warmup,
                    opts.iterations,
                    stats.total_ns,
                    avg_ns,
                    stats.min_ns,
                    stats.max_ns,
                    avg_states,
                },
            );
        },
    }
    try out.flush();
}
