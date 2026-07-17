const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "secretsweeper",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/export.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(lib);

    // CPython extension module for the hot calls (see src/python.zig). Python C API
    // symbols stay undefined and resolve against the hosting interpreter at import
    // time; Windows cannot do that (extensions must link python3.lib there), so the
    // extension is skipped and secretsweeper falls back to the ctypes path.
    if (target.result.os.tag != .windows) {
        const ext = b.addLibrary(.{
            .name = "_native",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/python.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        ext.linker_allow_shlib_undefined = true;
        const ext_install = b.addInstallArtifact(
            ext,
            .{ .dest_dir = .{ .override = .lib }, .dest_sub_path = "_native.abi3.so" },
        );
        b.getInstallStep().dependOn(&ext_install.step);
    }

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/export.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);
}
