const std = @import("std");
const libfst = @import("libfst");

const W = libfst.TropicalWeight;
const FrozenFst = libfst.Fst(W);
const epsilon = libfst.epsilon;

const CliError = error{
    InvalidArguments,
};

fn printUsage() void {
    std.debug.print(
        "Usage: att2lfst --input <att.txt> --output <libfst.fst>\n",
        .{},
    );
}

fn parseArgs(args: []const [:0]const u8) !struct { input: []const u8, output: []const u8 } {
    if (args.len != 5) return CliError.InvalidArguments;
    if (!std.mem.eql(u8, args[1], "--input")) return CliError.InvalidArguments;
    if (!std.mem.eql(u8, args[3], "--output")) return CliError.InvalidArguments;
    return .{
        .input = args[2],
        .output = args[4],
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const parsed = parseArgs(args) catch {
        printUsage();
        return CliError.InvalidArguments;
    };

    const input_data = try std.Io.Dir.cwd().readFileAlloc(
        io,
        parsed.input,
        allocator,
        .limited(256 * 1024 * 1024),
    );
    defer allocator.free(input_data);

    var mutable = try libfst.io_text.readText(W, allocator, input_data);
    defer mutable.deinit();

    // OpenFst byte-tokenized ATT uses labels in [0..255] with 0 as epsilon.
    // libfst's string helpers and rewrite ops reserve 0 for epsilon and use
    // byte+1 for concrete byte labels. Normalize imported arcs here so converted
    // assets are interoperable with `fst_compile_string` / `fst_print_string`.
    for (0..mutable.numStates()) |sid| {
        const state: u32 = @intCast(sid);
        for (mutable.arcsMut(state)) |*arc| {
            if (arc.ilabel != epsilon) arc.ilabel += 1;
            if (arc.olabel != epsilon) arc.olabel += 1;
        }
    }

    var frozen = try FrozenFst.fromMutable(allocator, &mutable);
    defer frozen.deinit();

    try libfst.io_binary.writeBinary(W, &frozen, io, parsed.output);

    var total_arcs: u64 = 0;
    for (0..frozen.numStates()) |i| {
        total_arcs += frozen.numArcs(@intCast(i));
    }
    std.debug.print(
        "Converted {s} -> {s} (states={d}, arcs={d})\n",
        .{ parsed.input, parsed.output, frozen.numStates(), total_arcs },
    );
}
