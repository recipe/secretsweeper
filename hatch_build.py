"""Hatchling build hook: compiles the Zig shared library and bundles it into the wheel."""

import platform
import shutil
import subprocess
import sys
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

LIBRARY_NAMES = ("libsecretsweeper.so", "libsecretsweeper.dylib", "secretsweeper.dll")


def zig_command() -> list[str]:
    """Prefer the `ziglang` wheel from build requirements, fall back to a system zig."""
    try:
        import ziglang  # noqa: F401
    except ImportError:
        if shutil.which("zig") is None:
            raise RuntimeError("zig is required to build secretsweeper: pip install ziglang")
        return ["zig"]
    return [sys.executable, "-m", "ziglang"]


def zig_target_options() -> list[str]:
    """On Windows, target the GNU ABI explicitly: it uses Zig's bundled mingw instead of
    relying on MSVC and Windows SDK detection, which the native default ABI requires."""
    if sys.platform != "win32":
        return []
    arch = {"AMD64": "x86_64", "ARM64": "aarch64"}.get(platform.machine().upper())
    if arch is None:
        raise RuntimeError(f"unsupported Windows architecture: {platform.machine()}")
    return [f"-Dtarget={arch}-windows-gnu"]


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
        run_zig(["version"], cwd=self.root)
        run_zig(["build", "-Doptimize=ReleaseFast", *zig_target_options()], cwd=self.root)
        for out_dir in ("lib", "bin"):
            for name in LIBRARY_NAMES:
                artifact = Path(self.root) / "zig-out" / out_dir / name
                if artifact.exists():
                    build_data["force_include"][str(artifact)] = f"secretsweeper/{name}"
                    build_data["pure_python"] = False
                    build_data["infer_tag"] = True
                    return
        raise RuntimeError("zig build did not produce a shared library in zig-out")
