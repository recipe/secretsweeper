"""Hatchling build hook: compiles the Zig shared library and bundles it into the wheel."""

import os
import platform
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


def library_names() -> tuple[str, ...]:
    if sys.platform in ("win32", "cygwin"):
        return ("secretsweeper.dll",)
    if sys.platform == "darwin":
        return ("libsecretsweeper.dylib",)
    return ("libsecretsweeper.so",)


# CPython extension for the hot calls; the ctypes fallback applies where it is absent.
# Free-threaded Python before 3.15 has no stable ABI and keeps the ctypes fallback.


def uses_abi3t() -> bool:
    return (
        sys.platform != "cygwin" and sys.version_info >= (3, 15) and bool(sysconfig.get_config_var("Py_GIL_DISABLED"))
    )


def extension_names() -> tuple[str, ...]:
    if sys.platform == "cygwin" or sys.implementation.name != "cpython":
        return ()
    if sysconfig.get_config_var("Py_GIL_DISABLED") and not uses_abi3t():
        return ()
    if sys.platform == "win32":
        return ("_native.pyd",) if windows_import_library() is not None else ()
    if uses_abi3t():
        return ("_native.abi3t.so",)
    return ("_native.abi3.so",)


def windows_import_library() -> Path | None:
    if sys.platform != "win32" or sys.implementation.name != "cpython":
        return None
    if sysconfig.get_config_var("Py_GIL_DISABLED") and not uses_abi3t():
        return None
    name = "python3t.lib" if uses_abi3t() else "python3.lib"
    for prefix in (sys.base_prefix, sys.base_exec_prefix, sys.prefix):
        path = Path(prefix) / "libs" / name
        if path.is_file():
            return path
    return None


def zig_command() -> list[str]:
    """Use the zig binary from SECRET_SWEEPER_ZIG if set, otherwise prefer the `ziglang`
    wheel from build requirements, and fall back to a system zig."""
    if zig := os.environ.get("SECRET_SWEEPER_ZIG"):
        return [zig]
    try:
        import ziglang  # noqa: F401
    except ImportError:
        if shutil.which("zig") is None:
            raise RuntimeError("zig is required to build secretsweeper: pip install ziglang")
        return ["zig"]
    return [sys.executable, "-m", "ziglang"]


def windows_target() -> str | None:
    """On Windows, target the GNU ABI explicitly: it uses Zig's bundled mingw instead of
    relying on MSVC and Windows SDK detection, which the native default ABI requires."""
    if sys.platform != "win32":
        return None
    arch = {"AMD64": "x86_64", "ARM64": "aarch64"}.get(platform.machine().upper())
    if arch is None:
        raise RuntimeError(f"unsupported Windows architecture: {platform.machine()}")
    return f"{arch}-windows-gnu"


def macos_target() -> str | None:
    """On macOS, honor MACOSX_DEPLOYMENT_TARGET: the native target stamps the dylib with
    the build host's OS version as its minimum, which would pin wheels to that macOS."""
    if sys.platform != "darwin":
        return None
    min_version = os.environ.get("MACOSX_DEPLOYMENT_TARGET")
    if not min_version:
        return None
    arch = {"arm64": "aarch64", "x86_64": "x86_64"}.get(platform.machine())
    if arch is None:
        raise RuntimeError(f"unsupported macOS architecture: {platform.machine()}")
    return f"{arch}-macos.{min_version}"


def linux_cpu() -> list[str]:
    """On Linux, compile for the architecture's baseline CPU: the native target enables
    every feature of the build machine's CPU (like -mcpu=native), so wheels built on
    newer CI hardware (e.g. Neoverse N2 with SVE) crash with SIGILL on CPUs lacking
    those instructions, such as Apple Silicon under Docker or Graviton 1/2."""
    if not sys.platform.startswith("linux"):
        return []
    return ["-Dcpu=baseline"]


def run_zig(args: list[str], cwd: str) -> None:
    command = [*zig_command(), *args]
    result = subprocess.run(command, capture_output=True, text=True, cwd=cwd)
    if result.returncode != 0:
        raise RuntimeError(
            f"{' '.join(command)} failed with exit code {result.returncode}\n"
            f"--- stdout ---\n{result.stdout}\n--- stderr ---\n{result.stderr}"
        )


class ZigBuildHook(BuildHookInterface):
    def initialize(self, version: str, build_data: dict) -> None:
        # windows_target() and macos_target() are mutually exclusive; `windows` is kept
        # separate from `target` because the fallback below applies only to Windows.
        windows = windows_target()
        target = windows or macos_target()
        import_library = windows_import_library()
        extensions = extension_names()
        try:
            target_options = [f"-Dtarget={target}"] if target else []
            if uses_abi3t():
                target_options.append("-Dpython-abi3t=true")
            if import_library is not None:
                target_options.append(f"-Dpython-import-lib={import_library}")
            run_zig(["build", "-Doptimize=ReleaseFast", *target_options, *linux_cpu()], cwd=self.root)
        except RuntimeError:
            # On any host other than Windows a build failure is fatal: the `build-lib`
            # fallback is a workaround for the Windows ARM64 crash below and would
            # emit a .dll regardless of the host.
            if windows is None:
                raise
            # `zig build` crashes silently on Windows ARM64 (zig support for aarch64-windows
            # is partial: ziglang/zig#16665). Unlike `zig build`, compiling the library
            # directly involves neither building nor running a build-runner executable.
            Path(self.root, "zig-out", "bin").mkdir(parents=True, exist_ok=True)
            run_zig(
                [
                    "build-lib",
                    "src/export.zig",
                    "--name",
                    "secretsweeper",
                    "-dynamic",
                    "-OReleaseFast",
                    "-lc",
                    "-target",
                    windows,
                    "-femit-bin=zig-out/bin/secretsweeper.dll",
                ],
                cwd=self.root,
            )
            if import_library is not None:
                options = Path(self.root, "zig-out", "python_options.zig")
                options.write_text(f"pub const abi3t = {str(uses_abi3t()).lower()};\n")
                Path(self.root, "zig-out", "lib").mkdir(parents=True, exist_ok=True)
                run_zig(
                    [
                        "build-lib",
                        "--name",
                        "_native",
                        "-dynamic",
                        "-OReleaseFast",
                        "-lc",
                        "-target",
                        windows,
                        str(import_library),
                        "--dep",
                        "python_options",
                        "-Mroot=src/python.zig",
                        f"-Mpython_options={options}",
                        "-femit-bin=zig-out/lib/_native.pyd",
                    ],
                    cwd=self.root,
                )
        found_library = False
        for out_dir in ("lib", "bin"):
            for name in library_names() + extensions:
                artifact = Path(self.root) / "zig-out" / out_dir / name
                if artifact.exists():
                    build_data["force_include"][str(artifact)] = f"secretsweeper/{name}"
                    found_library = found_library or name in library_names()
        if not found_library:
            raise RuntimeError("zig build did not produce a shared library in zig-out")
        for name in extensions:
            if not Path(self.root, "zig-out", "lib", name).is_file():
                raise RuntimeError(f"zig build did not produce the native extension {name}")
        build_data["pure_python"] = False
        if extensions and uses_abi3t() and version != "editable":
            platform_tag = self.build_config.builder.get_best_matching_tag().rsplit("-", 1)[1]
            build_data["tag"] = f"cp315-abi3t-{platform_tag}"
        else:
            build_data["infer_tag"] = True
