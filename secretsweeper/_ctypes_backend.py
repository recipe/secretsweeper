"""ctypes backend: drives the C-ABI shared library compiled from src/export.zig.

A wheel ships this backend instead of the `secretsweeper._native` extension module
where that cannot be built: free-threaded CPython before 3.15 (no stable ABI),
non-CPython interpreters such as PyPy, and Windows source builds without the stable
ABI import library. It exposes the same five functions as `_native`, with the
automaton represented by the integer handle returned by `ss_new`.
"""

import ctypes
import pathlib
import sys
import typing

_LIBRARY_NAMES = {
    "win32": ("secretsweeper.dll",),
    "cygwin": ("secretsweeper.dll",),
    "darwin": ("libsecretsweeper.dylib",),
}


def _load_library() -> ctypes.CDLL:
    # Every directory on the package's search path (see __init__.py), not just this one.
    package_dirs = [pathlib.Path(p) for p in sys.modules[__name__.rpartition(".")[0]].__path__]
    names = _LIBRARY_NAMES.get(sys.platform, ("libsecretsweeper.so",))
    for package_dir in package_dirs:
        for name in names:
            path = package_dir / name
            if path.exists():
                return ctypes.CDLL(str(path))
    raise ImportError(f"cannot find the secretsweeper shared library in {package_dirs}")


_lib = _load_library()

_lib.ss_new.argtypes = ()
_lib.ss_new.restype = ctypes.c_void_p
_lib.ss_destroy.argtypes = (ctypes.c_void_p,)
_lib.ss_destroy.restype = None
_lib.ss_insert.argtypes = (ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t)
_lib.ss_insert.restype = ctypes.c_int32
_lib.ss_build.argtypes = (ctypes.c_void_p,)
_lib.ss_build.restype = ctypes.c_int32
_lib.ss_build_fallback.argtypes = (ctypes.c_void_p,)
_lib.ss_build_fallback.restype = ctypes.c_int32
_lib.ss_mask.argtypes = (
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_size_t,
    ctypes.c_uint64,
    ctypes.c_bool,
    ctypes.POINTER(ctypes.c_void_p),
    ctypes.POINTER(ctypes.c_size_t),
)
_lib.ss_mask.restype = ctypes.c_int32
_lib.ss_free.argtypes = (ctypes.c_void_p, ctypes.c_size_t)
_lib.ss_free.restype = None
_lib.ss_get_reminder.argtypes = (ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t))
_lib.ss_get_reminder.restype = ctypes.c_void_p
_lib.ss_reset_reminder.argtypes = (ctypes.c_void_p,)
_lib.ss_reset_reminder.restype = None


def new(patterns: typing.Iterable[bytes], use_dfa: bool) -> int:
    """Create an automaton, insert all patterns and build it. Returns the handle."""
    automaton = _lib.ss_new()
    if not automaton:
        raise MemoryError("failed to create the automaton")
    try:
        for pattern in patterns:
            if not isinstance(pattern, bytes):
                raise TypeError(f"expected bytes, found {type(pattern)}")
            if _lib.ss_insert(automaton, pattern, len(pattern)) != 0:
                raise MemoryError("failed to insert a pattern")
        build_fn = _lib.ss_build if use_dfa else _lib.ss_build_fallback
        if build_fn(automaton) != 0:
            raise MemoryError("failed to build the automaton")
    except BaseException:
        _lib.ss_destroy(automaton)
        raise
    return automaton


def mask(automaton: int, data: bytes | bytearray | memoryview, limit: int, is_streaming: bool) -> bytes:
    """Mask all patterns in the data using the given automaton handle."""
    if not isinstance(data, bytes):
        data = bytes(data)
    out_ptr = ctypes.c_void_p()
    out_len = ctypes.c_size_t()
    status = _lib.ss_mask(automaton, data, len(data), limit, is_streaming, ctypes.byref(out_ptr), ctypes.byref(out_len))
    if status != 0:
        raise MemoryError("failed to mask the input")
    ptr = out_ptr.value
    if not ptr:
        return b""
    try:
        return ctypes.string_at(ptr, out_len.value)
    finally:
        _lib.ss_free(ptr, out_len.value)


def get_reminder(automaton: int) -> bytes:
    """The streaming-mode reminder, empty if there is none."""
    out_len = ctypes.c_size_t()
    ptr = _lib.ss_get_reminder(automaton, ctypes.byref(out_len))
    if not ptr:
        return b""
    return ctypes.string_at(ptr, out_len.value)


def reset_reminder(automaton: int) -> None:
    """Drop the streaming-mode reminder."""
    _lib.ss_reset_reminder(automaton)


def destroy(automaton: int) -> None:
    """Free the automaton. The handle must not be used afterwards."""
    _lib.ss_destroy(automaton)
