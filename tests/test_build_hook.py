"""Build selection checks; require the Hatchling backend used by wheel builds."""

import importlib.util
from pathlib import Path
from types import SimpleNamespace

import pytest

pytest.importorskip("hatchling")
from hatchling.builders.wheel import WheelBuilder


@pytest.fixture
def hook_module():
    path = Path(__file__).resolve().parents[1] / "hatch_build.py"
    spec = importlib.util.spec_from_file_location("secretsweeper_build_hook", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize(
    ("version", "free_threaded", "implementation", "library", "expected"),
    [
        ((3, 14), False, "cpython", None, ()),
        ((3, 15), True, "cpython", None, ()),
        ((3, 14), False, "cpython", "python3.lib", ("_native.pyd",)),
        ((3, 15), True, "cpython", "python3t.lib", ("_native.pyd",)),
        ((3, 15), True, "cpython", "python3.lib", ()),
        ((3, 14), True, "cpython", "python3t.lib", ()),
        ((3, 11), False, "pypy", "python3.lib", ()),
    ],
)
def test_windows_extension_selection(
    hook_module, monkeypatch, tmp_path, version, free_threaded, implementation, library, expected
):
    prefix = tmp_path / "Python with spaces"
    (prefix / "libs").mkdir(parents=True)
    if library:
        (prefix / "libs" / library).touch()
    monkeypatch.setattr(
        hook_module,
        "sys",
        SimpleNamespace(
            platform="win32",
            version_info=version,
            implementation=SimpleNamespace(name=implementation),
            base_prefix=str(prefix),
            base_exec_prefix=str(prefix),
            prefix=str(prefix),
        ),
    )
    monkeypatch.setattr(hook_module, "sysconfig", SimpleNamespace(get_config_var=lambda _: free_threaded))
    assert hook_module.extension_names() == expected
    assert (hook_module.windows_import_library() is not None) == bool(expected)


@pytest.mark.parametrize("native", [False, True])
@pytest.mark.parametrize("fallback", [False, True])
def test_windows_build_packages_only_selected_extension(hook_module, monkeypatch, tmp_path, native, fallback):
    # An old .pyd must not leak into a source build without an import library.
    out = tmp_path / "zig-out" / "lib"
    out.mkdir(parents=True)
    (out / "_native.pyd").write_bytes(b"stale")
    library = tmp_path / "python3t.lib" if native else None
    monkeypatch.setattr(hook_module, "windows_target", lambda: "aarch64-windows-gnu")
    monkeypatch.setattr(hook_module, "windows_import_library", lambda: library)
    monkeypatch.setattr(hook_module, "extension_names", lambda: ("_native.pyd",) if native else ())
    monkeypatch.setattr(hook_module, "library_names", lambda: ("secretsweeper.dll",))
    monkeypatch.setattr(hook_module, "uses_abi3t", lambda: True)
    calls = []

    def run_zig(args, cwd):
        calls.append(args)
        if args[0] == "build" and fallback:
            raise RuntimeError("build runner failed")
        if args[0] == "build":
            (out / "secretsweeper.dll").write_bytes(b"new core")
            if native:
                (out / "_native.pyd").write_bytes(b"new native")
        else:
            destination = next(arg.split("=", 1)[1] for arg in args if arg.startswith("-femit-bin="))
            (tmp_path / destination).write_bytes(b"new direct build")

    monkeypatch.setattr(hook_module, "run_zig", run_zig)
    (tmp_path / "pyproject.toml").write_text('[project]\nname="test-package"\nversion="1.0"\n')
    builder = WheelBuilder(str(tmp_path))
    hook = hook_module.ZigBuildHook(str(tmp_path), {}, builder.config, builder.metadata, str(tmp_path), "wheel")
    data = builder.get_default_build_data()
    data["force_include"] = {}
    hook.initialize("standard", data)
    assert set(data["force_include"].values()) == (
        {"secretsweeper/secretsweeper.dll", "secretsweeper/_native.pyd"}
        if native
        else {"secretsweeper/secretsweeper.dll"}
    )
    assert data["pure_python"] is False
    if native:
        assert data["tag"] == "cp315-abi3t-" + builder.get_best_matching_tag().rsplit("-", 1)[1]
        assert data["infer_tag"] is False
        assert (out / "_native.pyd").read_bytes() != b"stale"
    else:
        assert not data.get("tag")
        assert data["infer_tag"] is True
        assert not any("python-import-lib" in arg for args in calls for arg in args)
    assert len(calls) == (1 if not fallback else 3 if native else 2)
