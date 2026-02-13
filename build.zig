const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const macos_min_version = b.option(
        []const u8,
        "macos-min-version",
        "Minimum macOS deployment target used by default when -Dtarget is not provided",
    ) orelse "15.0";

    var default_target: std.Target.Query = .{};
    if (builtin.os.tag == .macos) {
        const min_semver = min_semver: {
            const parsed = std.Target.Query.parseVersion(macos_min_version) catch {
                @panic("invalid -Dmacos-min-version (expected semantic version like 15.0)");
            };
            break :min_semver parsed;
        };
        default_target = .{
            .os_tag = .macos,
            .os_version_min = .{ .semver = min_semver },
        };
    }

    const target = b.standardTargetOptions(.{
        .default_target = default_target,
    });
    const optimize = b.standardOptimizeOption(.{});

    const linkage = b.option(std.builtin.LinkMode, "linkage", "static or dynamic") orelse .static;

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const c_api_module = b.createModule(.{
        .root_source_file = b.path("src/c-api.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = linkage,
        .name = "fst",
        .root_module = c_api_module,
    });
    lib.installHeader(b.path("include/fst.h"), "fst.h");
    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = root_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const diff_module = b.createModule(.{
        .root_source_file = b.path("tests/diff/diff-test.zig"),
        .target = target,
        .optimize = optimize,
    });
    diff_module.addImport("libfst", root_module);

    const diff_tests = b.addTest(.{
        .root_module = diff_module,
    });

    const run_diff_tests = b.addRunArtifact(diff_tests);
    const diff_step = b.step("diff", "Run differential tests against Pynini golden outputs");
    diff_step.dependOn(&run_diff_tests.step);

    const prop_module = b.createModule(.{
        .root_source_file = b.path("tests/prop/prop-test.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_module.addImport("libfst", root_module);

    const prop_tests = b.addTest(.{
        .root_module = prop_module,
    });

    const run_prop_tests = b.addRunArtifact(prop_tests);
    const prop_step = b.step("prop", "Run property-based tests");
    prop_step.dependOn(&run_prop_tests.step);

    const fuzz_module = b.createModule(.{
        .root_source_file = b.path("tests/fuzz/fuzz-harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_module.addImport("libfst", root_module);

    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_module,
    });

    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("fuzz", "Run fuzz test harness");
    fuzz_step.dependOn(&run_fuzz_tests.step);

    const att2lfst_module = b.createModule(.{
        .root_source_file = b.path("src/tools/att2lfst.zig"),
        .target = target,
        .optimize = optimize,
    });
    att2lfst_module.addImport("libfst", root_module);

    const att2lfst_exe = b.addExecutable(.{
        .name = "att2lfst",
        .root_module = att2lfst_module,
    });
    b.installArtifact(att2lfst_exe);

    const att2lfst_step = b.step("att2lfst", "Build att2lfst converter tool");
    att2lfst_step.dependOn(&att2lfst_exe.step);
}
