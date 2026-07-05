"""Hatchling build hook: compiles the Zig shared library and bundles it into the wheel."""

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


class ZigBuildHook(BuildHookInterface):
    def initialize(self, version: str, build_data: dict) -> None:
        subprocess.run([*zig_command(), "build", "-Doptimize=ReleaseFast"], check=True, cwd=self.root)
        for out_dir in ("lib", "bin"):
            for name in LIBRARY_NAMES:
                artifact = Path(self.root) / "zig-out" / out_dir / name
                if artifact.exists():
                    build_data["force_include"][str(artifact)] = f"secretsweeper/{name}"
                    build_data["pure_python"] = False
                    build_data["infer_tag"] = True
                    return
        raise RuntimeError("zig build did not produce a shared library in zig-out")
