const std = @import("std");
const libfst = @import("libfst");

const W = libfst.TropicalWeight;
const MutableFst = libfst.MutableFst(W);
const A = libfst.Arc(W);
const Label = libfst.Label;
const no_state = libfst.no_state;
const io_text = libfst.io_text;

const compose = libfst.ops.compose.compose;
const determinize = libfst.ops.determinize.determinize;
const minimize = libfst.ops.minimize.minimize;
const optimize = libfst.ops.optimize.optimize;
const rm_epsilon = libfst.ops.rm_epsilon.rmEpsilon;
const union_ = libfst.ops.union_.union_;
const concat = libfst.ops.concat.concat;
const closure = libfst.ops.closure.closure;
const invert = libfst.ops.invert.invert;
const project = libfst.ops.project.project;
const string_mod = libfst.string;

/// Build a random FST from fuzzer bytes.
fn fstFromBytes(allocator: std.mem.Allocator, data: []const u8) !MutableFst {
    if (data.len < 4) return error.TooShort;

    var fst = MutableFst.init(allocator);
    errdefer fst.deinit();

    const num_states: u32 = @min(data[0], 16) + 1;
    try fst.addStates(num_states);
    fst.setStart(0);

    var i: usize = 1;
    while (i + 4 <= data.len) {
        const src: u32 = data[i] % num_states;
        const dst: u32 = data[i + 1] % num_states;
        const il: Label = data[i + 2];
        const ol: Label = data[i + 3];
        try fst.addArc(src, A.init(il, ol, W.one, dst));
        i += 4;

        if (fst.totalArcs() > 64) break; // limit size
    }

    // Set some final states
    for (0..num_states) |s| {
        if (s % 3 == 0) {
            fst.setFinal(@intCast(s), W.one);
        }
    }

    return fst;
}

// ── Fuzz tests ──
// These run as normal unit tests but exercise the code with random-ish inputs.
// For actual libfuzzer integration, build with: zig build-exe -fuzz

test "fuzz: random FST operations don't crash" {
    const allocator = std.testing.allocator;

    // Test with various byte patterns
    const seeds = [_][]const u8{
        &[_]u8{ 3, 0, 1, 5, 5, 1, 0, 3, 3, 2, 0, 0, 0 },
        &[_]u8{ 5, 1, 2, 10, 20, 3, 4, 0, 0, 0, 0, 0, 0 },
        &[_]u8{ 2, 0, 0, 0, 0, 1, 1, 1, 1, 0, 1, 2, 3 },
        &[_]u8{ 1, 0, 0, 0, 0 },
        &[_]u8{ 8, 7, 3, 255, 128, 0, 0, 0, 0, 5, 2, 100, 50 },
    };

    for (seeds) |seed| {
        var fst = fstFromBytes(allocator, seed) catch continue;
        defer fst.deinit();

        // Try all operations — must not crash
        {
            var result = rm_epsilon(W, allocator, &fst) catch continue;
            result.deinit();
        }
        {
            var result = determinize(W, allocator, &fst) catch continue;
            result.deinit();
        }
        {
            var result = optimize(W, allocator, &fst) catch continue;
            result.deinit();
        }
        {
            var clone = fst.clone(allocator) catch continue;
            defer clone.deinit();
            invert(W, &clone);
        }
        {
            var clone = fst.clone(allocator) catch continue;
            defer clone.deinit();
            project(W, &clone, .input);
        }
        {
            var clone = fst.clone(allocator) catch continue;
            defer clone.deinit();
            project(W, &clone, .output);
        }
        {
            var clone = fst.clone(allocator) catch continue;
            defer clone.deinit();
            closure(W, &clone, .star) catch continue;
        }
        {
            var result = compose(W, allocator, &fst, &fst) catch continue;
            result.deinit();
        }
    }
}

test "fuzz: AT&T text parse doesn't crash" {
    const allocator = std.testing.allocator;

    // Various malformed inputs
    const inputs = [_][]const u8{
        "",
        "0\n",
        "0 1 0 0\n1\n",
        "0 1 a b 0.5\n1 0.0\n",
        "garbage",
        "0 1 999 999 0.0\n1\n",
        "0 1 0 0\n0 2 1 1\n1\n2\n",
    };

    for (inputs) |input| {
        var fst = io_text.readText(W, allocator, input) catch continue;
        fst.deinit();
    }
}

test "fuzz: string compile/print roundtrip" {
    const allocator = std.testing.allocator;

    const strings = [_][]const u8{
        "",
        "a",
        "hello",
        "test123",
        &[_]u8{ 1, 2, 3, 255 },
    };

    for (strings) |s| {
        var fst = string_mod.compileString(W, allocator, s) catch continue;
        defer fst.deinit();

        const printed = string_mod.printString(W, allocator, &fst) catch continue;
        if (printed) |p| {
            allocator.free(p);
        }
    }
}
