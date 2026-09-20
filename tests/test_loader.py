"""How the package locates its compiled backend: the `_native` extension module or
the ctypes shared library.

Each test runs Python in a subprocess against a temporary package layout, so the
tests hold both in the editable checkout (Python sources in the source tree, binary in
site-packages) and against an installed wheel (binary next to __init__.py).
"""

import os
import pathlib
import shutil
import subprocess
import sys
import sysconfig

import pytest

import secretsweeper

_BINARY_SUFFIXES = {".so", ".dylib", ".dll", ".pyd"}


def _package_binaries() -> list[pathlib.Path]:
    return [p for d in secretsweeper.__path__ for p in pathlib.Path(d).iterdir() if p.suffix in _BINARY_SUFFIXES]


def _copy_package(dst: pathlib.Path, *, with_binary: bool) -> None:
    dst.mkdir(parents=True)
    for source in pathlib.Path(secretsweeper.__file__).parent.glob("*.py"):
        shutil.copy(source, dst / source.name)
    if with_binary:
        for binary in _package_binaries():
            shutil.copy(binary, dst / binary.name)


def _run_isolated(sys_path: list[pathlib.Path], code: str) -> subprocess.CompletedProcess:
    # -S -P: no site-packages and no script directory, so sys.path is exactly PYTHONPATH.
    env = {**os.environ, "PYTHONPATH": os.pathsep.join(str(p) for p in sys_path)}
    return subprocess.run([sys.executable, "-S", "-P", "-c", code], env=env, capture_output=True, text=True, timeout=30)


def test_wheel_layout_searches_only_its_own_directory(tmp_path: pathlib.Path) -> None:
    # A stray `secretsweeper/` directory earlier on sys.path (e.g. next to a script) must
    # not become part of the package: a wheel has its binary next to __init__.py.
    site = tmp_path / "site"
    _copy_package(site / "secretsweeper", with_binary=True)
    planted = tmp_path / "planted" / "secretsweeper"
    planted.mkdir(parents=True)
    (planted / "_native.py").write_text("raise AssertionError('planted _native imported')\n")
    for name in ("libsecretsweeper.so", "libsecretsweeper.dylib", "secretsweeper.dll"):
        (planted / name).write_bytes(b"not a library")
    result = _run_isolated(
        [planted.parent, site],
        "import os, secretsweeper; "
        f"assert [os.path.abspath(p) for p in secretsweeper.__path__] == [{str(site / 'secretsweeper')!r}], "
        "list(secretsweeper.__path__); "
        "assert secretsweeper.mask(b'a secret', [b'secret']) == b'a ******'",
    )
    assert result.returncode == 0, result.stderr


def test_source_layout_finds_binary_elsewhere_on_sys_path(tmp_path: pathlib.Path) -> None:
    # The editable install: Python sources without a binary, binary in another
    # `secretsweeper` directory on sys.path.
    src = tmp_path / "src"
    _copy_package(src / "secretsweeper", with_binary=False)
    site = tmp_path / "site" / "secretsweeper"
    site.mkdir(parents=True)
    for binary in _package_binaries():
        shutil.copy(binary, site / binary.name)
    result = _run_isolated(
        [src, site.parent],
        "import os, secretsweeper; "
        "assert [os.path.abspath(p) for p in secretsweeper.__path__] == "
        f"[{str(src / 'secretsweeper')!r}, {str(site)!r}], list(secretsweeper.__path__); "
        "assert secretsweeper.mask(b'a secret', [b'secret']) == b'a ******'",
    )
    assert result.returncode == 0, result.stderr


def test_broken_native_extension_is_not_masked_by_ctypes_fallback(tmp_path: pathlib.Path) -> None:
    if sysconfig.get_config_var("Py_GIL_DISABLED") and sys.version_info < (3, 15):
        pytest.skip("free-threaded CPython before 3.15 never imports the extension")
    # Only a missing extension falls back to ctypes. One that exists but fails to import
    # reports its own error rather than a misleading "cannot find the shared library".
    site = tmp_path / "site"
    _copy_package(site / "secretsweeper", with_binary=True)
    for binary in (site / "secretsweeper").glob("_native.*"):
        binary.unlink()
    (site / "secretsweeper" / "_native.py").write_text("import secretsweeper_missing_dependency\n")
    result = _run_isolated([site], "import secretsweeper")
    assert result.returncode != 0
    assert "No module named 'secretsweeper_missing_dependency'" in result.stderr


def test_ctypes_wheel_layout_loads_library_from_its_own_directory(tmp_path: pathlib.Path) -> None:
    # A wheel without the extension: the missing `_native` falls back to the ctypes
    # backend, which finds the shared library next to __init__.py and nowhere else.
    libraries = [p for p in _package_binaries() if not p.name.startswith("_native")]
    if not libraries:
        pytest.skip("this install ships the extension module, not the ctypes library")
    site = tmp_path / "site"
    _copy_package(site / "secretsweeper", with_binary=False)
    for library in libraries:
        shutil.copy(library, site / "secretsweeper" / library.name)
    result = _run_isolated(
        [site],
        "import os, secretsweeper; "
        "assert secretsweeper._core._native is None; "
        "assert secretsweeper._core._backend.__name__ == 'secretsweeper._ctypes_backend'; "
        f"assert [os.path.abspath(p) for p in secretsweeper.__path__] == [{str(site / 'secretsweeper')!r}]; "
        "assert secretsweeper.mask(b'a secret', [b'secret']) == b'a ******'",
    )
    assert result.returncode == 0, result.stderr
