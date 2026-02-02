import contextlib
import os
import shutil
import sys
import sysconfig
import typing
from pathlib import Path


def _ensure_ld_library() -> None:
    """
    Pydust assumes LDLIBRARY is always set, but on Windows (especially in PEP 517 isolated builds) it may be None.
    Provide a correct fallback.
    """
    if sys.platform != "win32":
        return

    if sysconfig.get_config_var("LDLIBRARY") is None:
        sysconfig._CONFIG_VARS["LDLIBRARY"] = f"python{sys.version_info.major}{sys.version_info.minor}.lib"


_ensure_ld_library()  # MUST happen before importing pydust


import pydust  # noqa: E402
from pydust import buildzig  # noqa: E402
from pydust import config as pydust_config  # noqa: E402
from pydust.build import build  # noqa: E402

# Patch Windows path pydust bug in build.zig
if sys.platform == "win32":
    # Save the original function
    original_addPythonModule = pydust.buildzig.addPythonModule

    def _addPythonModule(mod):
        # Force absolute path for root_source_file
        mod["root_source_file"] = os.path.abspath(mod["root_source_file"]).replace("\\", "/")
        return original_addPythonModule(mod)

    pydust.buildzig.addPythonModule = _addPythonModule

    def _generate_build_zig(fileobj: typing.TextIO, conf=pydust_config):
        b = buildzig.Writer(fileobj)

        b.writeln('const std = @import("std");')
        b.writeln('const py = @import("./pydust.build.zig");')
        b.writeln()

        with b.block("pub fn build(b: *std.Build) void"):
            b.write(
                """
                const target = b.standardTargetOptionsQueryOnly(.{});
                const optimize = b.standardOptimizeOption(.{});

                const test_step = b.step("test", "Run library tests");

                const pydust = py.addPydust(b, .{
                    .test_step = test_step,
                });
                """
            )

            for ext_module in conf.ext_modules:
                assert ext_module.limited_api, "Only limited_api is supported for now"
                ext_module_root = str(ext_module.root).replace("\\", "/")  # fix for windows
                b.write(
                    f"""
                    _ = pydust.addPythonModule(.{{
                        .name = "{ext_module.name}",
                        .root_source_file = b.path("{ext_module_root}"),
                        .limited_api = {str(ext_module.limited_api).lower()},
                        .target = target,
                        .optimize = optimize,
                    }});
                    """
                )

    buildzig.generate_build_zig = _generate_build_zig


@contextlib.contextmanager
def ensure_ffi_location() -> typing.Iterator[None]:
    """
    For some reason, `zig translate-c` is looking for `ffi.h` in the wrong location.
    """
    dst = Path("pydust/src/ffi.h")
    dst.parent.mkdir(parents=True, exist_ok=True)
    src = Path(pydust.__file__).parent / "src" / "ffi.h"
    shutil.copyfile(src, dst)
    yield
    shutil.rmtree(Path("pydust"))


with ensure_ffi_location():
    build()
