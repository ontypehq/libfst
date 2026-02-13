const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");
const compose_mod = @import("compose.zig");
const rm_epsilon_mod = @import("rm-epsilon.zig");
const union_mod = @import("union.zig");
const concat_mod = @import("concat.zig");
const closure_mod = @import("closure.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const epsilon = arc_mod.epsilon;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

/// Identity penalty weight for obligatory semantics.
///
/// Identity (pass-through) arcs carry this penalty so that shortestPath
/// prefers tau replacement wherever it matches. Works correctly when
/// tau's total path weight < tau_input_length * IDENTITY_PENALTY.
const IDENTITY_PENALTY: f64 = 1.0;

/// Context-dependent rewrite: cdrewrite(tau, lambda, rho, sigma_star).
///
/// Implements LEFT_TO_RIGHT OBLIGATORY rewrite semantics.
///
/// Current contract:
/// - `tau`, `lambda`, `rho` must be unit-weight FSTs (all arc/final weights = `W.one`).
/// - Weighted rewrite rules are rejected with `error.UnsupportedWeightedRewrite`.
///
/// Construction: `rule = (lambda · tau · rho | sigma_one_penalized)*`
///
/// The rule is a nondeterministic transducer. At each input position,
/// it nondeterministically tries the context-tau replacement (weight 0)
/// or single-symbol identity (weight IDENTITY_PENALTY). After composing
/// with an input string, shortestPath(1) selects the path that maximizes
/// tau applications — achieving obligatory semantics.
///
/// Usage:
///   var rule = try cdrewrite(W, alloc, &tau, &lambda, &rho, &sigma_star);
///   var composed = try compose(W, alloc, &input_fst, &rule);
///   project(W, &composed, .output);
///   var best = try shortestPath(W, alloc, &composed, 1);
///   var text = try printString(W, alloc, &best);
///
/// Handles multi-character tau, branching lambda/rho, and all FST shapes.
pub fn cdrewrite(
    comptime W: type,
    allocator: Allocator,
    tau: *const mutable_fst_mod.MutableFst(W),
    lambda: *const mutable_fst_mod.MutableFst(W),
    rho: *const mutable_fst_mod.MutableFst(W),
    sigma_star: *const mutable_fst_mod.MutableFst(W),
) !mutable_fst_mod.MutableFst(W) {
    if (sigma_star.start() == no_state or tau.start() == no_state) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }

    try ensureUnitWeightedRewriteInput(W, tau);
    try ensureUnitWeightedRewriteInput(W, lambda);
    try ensureUnitWeightedRewriteInput(W, rho);

    const sigma_labels = try collectLabels(W, allocator, sigma_star);
    defer allocator.free(sigma_labels);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const A = arc_mod.Arc(W);
    const penalty = W.init(IDENTITY_PENALTY);

    // 1. Build context_tau: lambda · tau · rho
    var ctx_tau = try buildContextTau(W, arena, tau, lambda, rho);

    // 2. Build penalized single-symbol identity: each sigma label → itself with penalty
    var sigma_one = mutable_fst_mod.MutableFst(W).init(arena);
    {
        const s0 = try sigma_one.addState();
        const s1 = try sigma_one.addState();
        sigma_one.setStart(s0);
        sigma_one.setFinal(s1, W.one);
        for (sigma_labels) |l| {
            try sigma_one.addArc(s0, A.init(l, l, penalty, s1));
        }
    }

    // 3. rule = (ctx_tau | sigma_one)*
    try union_mod.union_(W, &ctx_tau, &sigma_one);
    try closure_mod.closure(W, &ctx_tau, .star);

    // 4. rmEpsilon to clean up concat/union/closure epsilon chains.
    //    Keep nondeterminism — resolved by shortestPath after compose.
    return rm_epsilon_mod.rmEpsilon(W, allocator, &ctx_tau);
}

/// Build context_tau transducer: lambda · tau · rho.
///
/// Lambda and rho are identity acceptors (context conditions).
/// Tau is a transducer (the replacement rule).
/// Result reads lambda_in + tau_in + rho_in, outputs lambda_in + tau_out + rho_in.
fn buildContextTau(
    comptime W: type,
    arena: Allocator,
    tau: *const mutable_fst_mod.MutableFst(W),
    lambda: *const mutable_fst_mod.MutableFst(W),
    rho: *const mutable_fst_mod.MutableFst(W),
) !mutable_fst_mod.MutableFst(W) {
    const lambda_trivial = isTrivialEpsilon(W, lambda);
    const rho_trivial = isTrivialEpsilon(W, rho);

    if (lambda_trivial and rho_trivial) {
        return tau.clone(arena);
    }

    if (lambda_trivial) {
        // tau · rho
        var result = try tau.clone(arena);
        try concat_mod.concat(W, &result, rho);
        return result;
    }

    if (rho_trivial) {
        // lambda · tau
        var result = try lambda.clone(arena);
        try concat_mod.concat(W, &result, tau);
        return result;
    }

    // lambda · tau · rho
    var result = try lambda.clone(arena);
    try concat_mod.concat(W, &result, tau);
    try concat_mod.concat(W, &result, rho);
    return result;
}

/// Check if FST accepts only the empty string (single final start state, no arcs).
fn isTrivialEpsilon(comptime W: type, fst: *const mutable_fst_mod.MutableFst(W)) bool {
    if (fst.start() == no_state) return true;
    return fst.numStates() == 1 and fst.isFinal(fst.start()) and fst.numArcs(fst.start()) == 0;
}

/// Collect all unique non-epsilon labels from sigma_star.
fn collectLabels(comptime W: type, allocator: Allocator, sigma_star: *const mutable_fst_mod.MutableFst(W)) ![]Label {
    var set = std.AutoHashMap(Label, void).init(allocator);
    defer set.deinit();

    if (sigma_star.start() != no_state) {
        for (0..sigma_star.numStates()) |i| {
            const s: StateId = @intCast(i);
            for (sigma_star.arcs(s)) |a| {
                if (a.ilabel != epsilon) {
                    try set.put(a.ilabel, {});
                }
            }
        }
    }

    const labels = try allocator.alloc(Label, set.count());
    var idx: usize = 0;
    var it = set.keyIterator();
    while (it.next()) |k| {
        labels[idx] = k.*;
        idx += 1;
    }
    std.mem.sort(Label, labels, {}, std.sort.asc(Label));
    return labels;
}

/// Ensure every arc/final weight in an input grammar is `W.one`.
///
/// Rationale: obligatory selection is currently encoded via fixed identity
/// penalties; non-unit rule weights can invert rewrite preference and produce
/// silent wrong outputs.
fn ensureUnitWeightedRewriteInput(comptime W: type, fst: *const mutable_fst_mod.MutableFst(W)) !void {
    if (fst.start() == no_state) return;

    for (0..fst.numStates()) |i| {
        const s: StateId = @intCast(i);
        const fw = fst.finalWeight(s);
        if (!fw.isZero() and !W.eql(fw, W.one)) {
            return error.UnsupportedWeightedRewrite;
        }
        for (fst.arcs(s)) |a| {
            if (!W.eql(a.weight, W.one)) {
                return error.UnsupportedWeightedRewrite;
            }
        }
    }
}

/// Helper: compose input with rule, project output, shortestPath, printString.
/// Returns the output string or error if no accepting path.
fn applyRule(
    comptime W: type,
    allocator: Allocator,
    input: []const u8,
    rule: *const mutable_fst_mod.MutableFst(W),
) ![]u8 {
    const string = @import("../string.zig");
    const project_mod = @import("project.zig");
    const sp_mod = @import("shortest-path.zig");

    var input_fst = try string.compileString(W, allocator, input);
    defer input_fst.deinit();

    var composed = try compose_mod.compose(W, allocator, &input_fst, rule);
    defer composed.deinit();

    project_mod.project(W, &composed, .output);

    var sp = try sp_mod.shortestPath(W, allocator, &composed, 1);
    defer sp.deinit();

    return (try string.printString(W, allocator, &sp)) orelse return error.NoAcceptingPath;
}

// ── Tests ──

fn buildSigmaStar(comptime W: type, allocator: Allocator) !mutable_fst_mod.MutableFst(W) {
    const A = arc_mod.Arc(W);
    var sigma_star = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer sigma_star.deinit();
    _ = try sigma_star.addState();
    sigma_star.setStart(0);
    sigma_star.setFinal(0, W.one);
    // a-z in byte+1 encoding (labels 98-123)
    for ('a'..'z' + 1) |ch| {
        const l: Label = @as(Label, @intCast(ch)) + 1;
        try sigma_star.addArc(0, A.init(l, l, W.one, 0));
    }
    return sigma_star;
}

fn buildEpsilonFst(comptime W: type, allocator: Allocator) !mutable_fst_mod.MutableFst(W) {
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer fst.deinit();
    _ = try fst.addState();
    fst.setStart(0);
    fst.setFinal(0, W.one);
    return fst;
}

test "cdrewrite: basic a->b everywhere" {
    const TW = @import("../weight.zig").TropicalWeight;
    const TA = arc_mod.Arc(TW);
    const allocator = std.testing.allocator;

    // tau: a -> b (byte+1 encoding)
    var tau = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer tau.deinit();
    _ = try tau.addState();
    _ = try tau.addState();
    tau.setStart(0);
    tau.setFinal(1, TW.one);
    try tau.addArc(0, TA.init('a' + 1, 'b' + 1, TW.one, 1));

    var lambda = try buildEpsilonFst(TW, allocator);
    defer lambda.deinit();
    var rho = try buildEpsilonFst(TW, allocator);
    defer rho.deinit();
    var sigma_star = try buildSigmaStar(TW, allocator);
    defer sigma_star.deinit();

    var rule = try cdrewrite(TW, allocator, &tau, &lambda, &rho, &sigma_star);
    defer rule.deinit();

    // "a" → "b"
    {
        const s = try applyRule(TW, allocator, "a", &rule);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("b", s);
    }
    // "hello" → "hello" (no 'a')
    {
        const s = try applyRule(TW, allocator, "hello", &rule);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("hello", s);
    }
}

test "cdrewrite: multi-char tau ab->xy no context" {
    const TW = @import("../weight.zig").TropicalWeight;
    const TA = arc_mod.Arc(TW);
    const allocator = std.testing.allocator;

    // tau: ab -> xy (byte+1 encoding)
    var tau = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer tau.deinit();
    try tau.addStates(3);
    tau.setStart(0);
    tau.setFinal(2, TW.one);
    try tau.addArc(0, TA.init('a' + 1, 'x' + 1, TW.one, 1));
    try tau.addArc(1, TA.init('b' + 1, 'y' + 1, TW.one, 2));

    var lambda = try buildEpsilonFst(TW, allocator);
    defer lambda.deinit();
    var rho = try buildEpsilonFst(TW, allocator);
    defer rho.deinit();
    var sigma_star = try buildSigmaStar(TW, allocator);
    defer sigma_star.deinit();

    var rule = try cdrewrite(TW, allocator, &tau, &lambda, &rho, &sigma_star);
    defer rule.deinit();

    // "ab" → "xy" (full match)
    {
        const s = try applyRule(TW, allocator, "ab", &rule);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("xy", s);
    }
    // "ac" → "ac" (partial match fails, should NOT reject)
    {
        const s = try applyRule(TW, allocator, "ac", &rule);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("ac", s);
    }
    // "cab" → "cxy" (match at position 1)
    {
        const s = try applyRule(TW, allocator, "cab", &rule);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("cxy", s);
    }
    // "aab" → "axy" (match at position 1, not 0)
    {
        const s = try applyRule(TW, allocator, "aab", &rule);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("axy", s);
    }
}

test "cdrewrite: context c_d" {
    const TW = @import("../weight.zig").TropicalWeight;
    const TA = arc_mod.Arc(TW);
    const allocator = std.testing.allocator;

    // tau: a -> b (byte+1 encoding)
    var tau = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer tau.deinit();
    _ = try tau.addState();
    _ = try tau.addState();
    tau.setStart(0);
    tau.setFinal(1, TW.one);
    try tau.addArc(0, TA.init('a' + 1, 'b' + 1, TW.one, 1));

    // lambda: "c" (byte+1 encoding)
    var lambda = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer lambda.deinit();
    _ = try lambda.addState();
    _ = try lambda.addState();
    lambda.setStart(0);
    lambda.setFinal(1, TW.one);
    try lambda.addArc(0, TA.init('c' + 1, 'c' + 1, TW.one, 1));

    // rho: "d" (byte+1 encoding)
    var rho = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer rho.deinit();
    _ = try rho.addState();
    _ = try rho.addState();
    rho.setStart(0);
    rho.setFinal(1, TW.one);
    try rho.addArc(0, TA.init('d' + 1, 'd' + 1, TW.one, 1));

    var sigma_star = try buildSigmaStar(TW, allocator);
    defer sigma_star.deinit();

    var rule = try cdrewrite(TW, allocator, &tau, &lambda, &rho, &sigma_star);
    defer rule.deinit();

    // "cad" → "cbd" (context matches)
    {
        const s = try applyRule(TW, allocator, "cad", &rule);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("cbd", s);
    }
    // "cab" → "cab" (rho doesn't match)
    {
        const s = try applyRule(TW, allocator, "cab", &rule);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("cab", s);
    }
    // "xad" → "xad" (lambda doesn't match)
    {
        const s = try applyRule(TW, allocator, "xad", &rule);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("xad", s);
    }
}

test "cdrewrite: multi-char tau with context" {
    const TW = @import("../weight.zig").TropicalWeight;
    const TA = arc_mod.Arc(TW);
    const allocator = std.testing.allocator;

    // tau: ab -> xy (byte+1)
    var tau = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer tau.deinit();
    try tau.addStates(3);
    tau.setStart(0);
    tau.setFinal(2, TW.one);
    try tau.addArc(0, TA.init('a' + 1, 'x' + 1, TW.one, 1));
    try tau.addArc(1, TA.init('b' + 1, 'y' + 1, TW.one, 2));

    // lambda: "c", rho: "d" (byte+1)
    var lambda = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer lambda.deinit();
    _ = try lambda.addState();
    _ = try lambda.addState();
    lambda.setStart(0);
    lambda.setFinal(1, TW.one);
    try lambda.addArc(0, TA.init('c' + 1, 'c' + 1, TW.one, 1));

    var rho = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer rho.deinit();
    _ = try rho.addState();
    _ = try rho.addState();
    rho.setStart(0);
    rho.setFinal(1, TW.one);
    try rho.addArc(0, TA.init('d' + 1, 'd' + 1, TW.one, 1));

    var sigma_star = try buildSigmaStar(TW, allocator);
    defer sigma_star.deinit();

    var rule = try cdrewrite(TW, allocator, &tau, &lambda, &rho, &sigma_star);
    defer rule.deinit();

    // "cabd" → "cxyd" (full context match)
    {
        const s = try applyRule(TW, allocator, "cabd", &rule);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("cxyd", s);
    }
    // "cacd" → "cacd" (tau doesn't match: ac ≠ ab)
    {
        const s = try applyRule(TW, allocator, "cacd", &rule);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("cacd", s);
    }
}

test "cdrewrite: branching lambda" {
    const TW = @import("../weight.zig").TropicalWeight;
    const TA = arc_mod.Arc(TW);
    const allocator = std.testing.allocator;

    // tau: a -> b (byte+1)
    var tau = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer tau.deinit();
    _ = try tau.addState();
    _ = try tau.addState();
    tau.setStart(0);
    tau.setFinal(1, TW.one);
    try tau.addArc(0, TA.init('a' + 1, 'b' + 1, TW.one, 1));

    // lambda: (c|x) — branching acceptor
    var lambda = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer lambda.deinit();
    _ = try lambda.addState();
    _ = try lambda.addState();
    lambda.setStart(0);
    lambda.setFinal(1, TW.one);
    try lambda.addArc(0, TA.init('c' + 1, 'c' + 1, TW.one, 1));
    try lambda.addArc(0, TA.init('x' + 1, 'x' + 1, TW.one, 1));

    // rho: "d"
    var rho = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer rho.deinit();
    _ = try rho.addState();
    _ = try rho.addState();
    rho.setStart(0);
    rho.setFinal(1, TW.one);
    try rho.addArc(0, TA.init('d' + 1, 'd' + 1, TW.one, 1));

    var sigma_star = try buildSigmaStar(TW, allocator);
    defer sigma_star.deinit();

    var rule = try cdrewrite(TW, allocator, &tau, &lambda, &rho, &sigma_star);
    defer rule.deinit();

    // "cad" → "cbd" (lambda=c matches)
    {
        const s = try applyRule(TW, allocator, "cad", &rule);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("cbd", s);
    }
    // "xad" → "xbd" (lambda=x matches — branching!)
    {
        const s = try applyRule(TW, allocator, "xad", &rule);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("xbd", s);
    }
    // "yad" → "yad" (lambda doesn't match y)
    {
        const s = try applyRule(TW, allocator, "yad", &rule);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("yad", s);
    }
}

test "cdrewrite: empty tau" {
    const TW = @import("../weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    var tau = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer tau.deinit();

    var lambda = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer lambda.deinit();

    var rho = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer rho.deinit();

    var sigma_star = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer sigma_star.deinit();
    _ = try sigma_star.addState();
    sigma_star.setStart(0);
    sigma_star.setFinal(0, TW.one);

    var result = try cdrewrite(TW, allocator, &tau, &lambda, &rho, &sigma_star);
    defer result.deinit();

    try std.testing.expectEqual(no_state, result.start());
}

test "cdrewrite: weighted tau is rejected" {
    const TW = @import("../weight.zig").TropicalWeight;
    const TA = arc_mod.Arc(TW);
    const allocator = std.testing.allocator;

    var tau = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer tau.deinit();
    _ = try tau.addState();
    _ = try tau.addState();
    tau.setStart(0);
    tau.setFinal(1, TW.one);
    try tau.addArc(0, TA.init('a' + 1, 'b' + 1, TW.init(2.0), 1)); // non-unit

    var lambda = try buildEpsilonFst(TW, allocator);
    defer lambda.deinit();
    var rho = try buildEpsilonFst(TW, allocator);
    defer rho.deinit();
    var sigma_star = try buildSigmaStar(TW, allocator);
    defer sigma_star.deinit();

    const result = cdrewrite(TW, allocator, &tau, &lambda, &rho, &sigma_star);
    try std.testing.expectError(error.UnsupportedWeightedRewrite, result);
}
