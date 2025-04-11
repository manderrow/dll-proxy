const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .windows },
        // .whitelist = &.{.{ .os_tag = .windows }},
    });

    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Forces stripping on all optimization modes") orelse switch (optimize) {
        .Debug => false,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => true,
    };

    const lib_mod = b.addModule("dll_proxy", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = false,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "dll_proxy",
        .root_module = lib_mod,
    });

    lib_mod.addIncludePath(b.path("src"));

    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
