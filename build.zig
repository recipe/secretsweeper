const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const python_abi3t = b.option(bool, "python-abi3t", "Build the Python 3.15+ free-threaded stable ABI extension") orelse false;
    const python_import_lib = b.option([]const u8, "python-import-lib", "Windows Python stable ABI import library path");

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
    // symbols resolve against the hosting interpreter. Windows requires its
    // stable ABI import library, supplied by the Python build hook.
    if (target.result.os.tag != .windows or python_import_lib != null) {
        const python_options = b.addOptions();
        python_options.addOption(bool, "abi3t", python_abi3t);
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
        ext.root_module.addOptions("python_options", python_options);
        if (python_import_lib) |path| {
            ext.root_module.addObjectFile(.{ .cwd_relative = path });
        } else {
            ext.linker_allow_shlib_undefined = true;
        }
        const ext_install = b.addInstallArtifact(
            ext,
            .{
                .dest_dir = .{ .override = .lib },
                .dest_sub_path = if (target.result.os.tag == .windows) "_native.pyd" else if (python_abi3t) "_native.abi3t.so" else "_native.abi3.so",
            },
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
