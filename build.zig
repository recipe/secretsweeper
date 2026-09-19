const std = @import("std");

/// Which binary a wheel ships. `secretsweeper._core` uses exactly one of them,
/// so the Python build hook (hatch_build.py) requests exactly one; `both` is
/// the default for development builds and tests.
const Artifact = enum { library, extension, both };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const artifact = b.option(Artifact, "artifact", "Binary to build: the ctypes shared library, the CPython extension module, or both (default)") orelse .both;
    const python_abi3t = b.option(bool, "python-abi3t", "Build the Python 3.15+ free-threaded stable ABI extension") orelse false;
    const python_import_lib = b.option([]const u8, "python-import-lib", "Windows Python stable ABI import library path");

    // C-ABI shared library (see src/export.zig), driven through ctypes by
    // secretsweeper._ctypes_backend where the extension module is unavailable.
    if (artifact != .extension) {
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
    }

    // CPython extension module (see src/python.zig). Python C API symbols
    // resolve against the hosting interpreter. Windows requires its stable ABI
    // import library, supplied by the Python build hook.
    if (artifact != .library and (target.result.os.tag != .windows or python_import_lib != null)) {
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
