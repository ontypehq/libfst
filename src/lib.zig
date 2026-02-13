pub const weight = @import("weight.zig");
pub const arc = @import("arc.zig");
pub const sym = @import("sym.zig");
pub const mutable_fst = @import("mutable-fst.zig");
pub const fst = @import("fst.zig");
pub const string = @import("string.zig");
pub const char_class = @import("char-class.zig");
pub const io_text = @import("io/text.zig");
pub const io_binary = @import("io/binary.zig");
pub const c_api = @import("c-api.zig");

// Operations
pub const ops = struct {
    pub const union_ = @import("ops/union.zig");
    pub const concat = @import("ops/concat.zig");
    pub const closure = @import("ops/closure.zig");
    pub const invert = @import("ops/invert.zig");
    pub const project = @import("ops/project.zig");
    pub const rm_epsilon = @import("ops/rm-epsilon.zig");
    pub const determinize = @import("ops/determinize.zig");
    pub const minimize = @import("ops/minimize.zig");
    pub const compose = @import("ops/compose.zig");
    pub const shortest_path = @import("ops/shortest-path.zig");
    pub const optimize = @import("ops/optimize.zig");
    pub const difference = @import("ops/difference.zig");
    pub const replace = @import("ops/replace.zig");
    pub const reverse = @import("ops/reverse.zig");
    pub const rewrite = @import("ops/rewrite.zig");
    pub const connect = @import("ops/connect.zig");
};

// Re-export common types
pub const TropicalWeight = weight.TropicalWeight;
pub const LogWeight = weight.LogWeight;
pub const Arc = arc.Arc;
pub const StdArc = arc.StdArc;
pub const LogArc = arc.LogArc;
pub const Label = arc.Label;
pub const StateId = arc.StateId;
pub const epsilon = arc.epsilon;
pub const no_state = arc.no_state;
pub const MutableFst = mutable_fst.MutableFst;
pub const StdMutableFst = mutable_fst.StdMutableFst;
pub const Fst = fst.Fst;
pub const StdFst = fst.StdFst;
pub const SymbolTable = sym.SymbolTable;

test {
    _ = weight;
    _ = arc;
    _ = sym;
    _ = mutable_fst;
    _ = fst;
    _ = string;
    _ = char_class;
    _ = io_text;
    _ = io_binary;
    _ = ops.union_;
    _ = ops.concat;
    _ = ops.closure;
    _ = ops.invert;
    _ = ops.project;
    _ = ops.rm_epsilon;
    _ = ops.determinize;
    _ = ops.minimize;
    _ = ops.compose;
    _ = ops.shortest_path;
    _ = ops.optimize;
    _ = ops.difference;
    _ = ops.replace;
    _ = ops.reverse;
    _ = ops.rewrite;
    _ = ops.connect;
}
