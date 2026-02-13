const std = @import("std");
const libfst = @import("libfst");

const W = libfst.TropicalWeight;
const FrozenFst = libfst.Fst(W);

const CliError = error{
    InvalidArguments,
};

fn printUsage() void {
    std.debug.print(
        "Usage: att2lfst --input <att.txt> --output <libfst.fst>\n",
        .{},
    );
}

fn parseArgs(args: []const []const u8) !struct { input: []const u8, output: []const u8 } {
    if (args.len != 5) return CliError.InvalidArguments;
    if (!std.mem.eql(u8, args[1], "--input")) return CliError.InvalidArguments;
    if (!std.mem.eql(u8, args[3], "--output")) return CliError.InvalidArguments;
    return .{
        .input = args[2],
        .output = args[4],
    };
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const parsed = parseArgs(args) catch {
        printUsage();
        return CliError.InvalidArguments;
    };

    const input_data = try std.fs.cwd().readFileAlloc(
        allocator,
        parsed.input,
        256 * 1024 * 1024,
    );
    defer allocator.free(input_data);

    var mutable = try libfst.io_text.readText(W, allocator, input_data);
    defer mutable.deinit();

    var frozen = try FrozenFst.fromMutable(allocator, &mutable);
    defer frozen.deinit();

    try libfst.io_binary.writeBinary(W, &frozen, parsed.output);

    var total_arcs: u64 = 0;
    for (0..frozen.numStates()) |i| {
        total_arcs += frozen.numArcs(@intCast(i));
    }
    std.debug.print(
        "Converted {s} -> {s} (states={d}, arcs={d})\n",
        .{ parsed.input, parsed.output, frozen.numStates(), total_arcs },
    );
}
