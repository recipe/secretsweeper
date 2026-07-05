"""ctypes bindings for the Aho-Corasick automaton shared library written in Zig."""

import ctypes
import io
import pathlib
import sys
import typing

MAX_NUMBER_OF_STARS = 15

_LIBRARY_NAMES = {
    "win32": ("secretsweeper.dll",),
    "cygwin": ("secretsweeper.dll",),
    "darwin": ("libsecretsweeper.dylib",),
}


def _load_library() -> ctypes.CDLL:
    package_dir = pathlib.Path(__file__).parent
    names = _LIBRARY_NAMES.get(sys.platform, ("libsecretsweeper.so",))
    for name in names:
        path = package_dir / name
        if path.exists():
            return ctypes.CDLL(str(path))
    raise ImportError(f"cannot find the secretsweeper shared library in {package_dir}")


_lib = _load_library()

_lib.ss_new.argtypes = ()
_lib.ss_new.restype = ctypes.c_void_p
_lib.ss_destroy.argtypes = (ctypes.c_void_p,)
_lib.ss_destroy.restype = None
_lib.ss_insert.argtypes = (ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t)
_lib.ss_insert.restype = ctypes.c_int32
_lib.ss_build.argtypes = (ctypes.c_void_p,)
_lib.ss_build.restype = ctypes.c_int32
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


def _build_automaton(patterns: typing.Iterable[bytes]) -> int:
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
        if _lib.ss_build(automaton) != 0:
            raise MemoryError("failed to build the automaton")
    except BaseException:
        _lib.ss_destroy(automaton)
        raise
    return automaton


def _mask(automaton: int, text: bytes, limit: int, *, is_streaming: bool) -> bytes:
    """Mask all patterns in the text using the given automaton handle."""
    if limit < 0:
        raise ValueError("limit must be non-negative")
    out_ptr = ctypes.c_void_p()
    out_len = ctypes.c_size_t()
    status = _lib.ss_mask(automaton, text, len(text), limit, is_streaming, ctypes.byref(out_ptr), ctypes.byref(out_len))
    if status != 0:
        raise MemoryError("failed to mask the input")
    ptr = out_ptr.value
    if not ptr:
        return b""
    try:
        return ctypes.string_at(ptr, out_len.value)
    finally:
        _lib.ss_free(ptr, out_len.value)


class _StreamWrapper:
    """An internal _StreamWrapper class that owns a persistent automaton handle."""

    def __init__(self, patterns: typing.Iterable[bytes], /, *, limit: int = MAX_NUMBER_OF_STARS):
        """
        The _StreamWrapper class constructor.

        :param patterns: Any iterable of patterns that have to be masked with the `*` asterisk character.
        :param limit: The max number of consecutive stars.
        """
        self._limit = limit
        self._automaton = _build_automaton(patterns)

    def __del__(self, _destroy=_lib.ss_destroy):
        if automaton := getattr(self, "_automaton", 0):
            self._automaton = 0
            _destroy(automaton)

    def _id(self) -> int:
        """Return the identity of this object."""
        return id(self)

    def masking_read(self, carry: bytes) -> bytes:
        """
        Read data from the carry buffer and apply pattern masking.

        :param carry: A chunk buffer that needs to be masked with the `*` asterisk character.
        :return: Returns the input string with masked patterns.
        """
        return _mask(self._automaton, carry, self._limit, is_streaming=True)

    def consume_reminder(self) -> bytes:
        """
        :return: Consumes the reminder or return empty bytes if there is no reminder. Then reset its value.
        """
        try:
            return self.get_reminder()
        finally:
            _lib.ss_reset_reminder(self._automaton)

    def get_reminder(self) -> bytes:
        """
        :return: Get the reminder or return empty bytes if it's empty.
        """
        out_len = ctypes.c_size_t()
        ptr = _lib.ss_get_reminder(self._automaton, ctypes.byref(out_len))
        if not ptr:
            return b""
        return ctypes.string_at(ptr, out_len.value)


def mask(
    input: bytes | bytearray | memoryview,
    patterns: typing.Iterable[bytes],
    /,
    *,
    limit: int = MAX_NUMBER_OF_STARS,
) -> bytes:
    """
    Masks the specific patterns in the input.

    :param input: An input bytes, bytearray or memoryview.
    :param patterns: Any iterable of patterns that have to be masked with the `*` asterisk character.
    :param limit: The max number of consecutive stars.
    :return: Returns the input string with masked patterns.
    """
    if not isinstance(input, (bytes, bytearray, memoryview)):
        help_note = ". You can use the StreamWrapper class for such purposes." if isinstance(input, io.BytesIO) else ""
        raise TypeError(f"expected bytes, memoryview or bytearray, found {type(input)}{help_note}")
    automaton = _build_automaton(patterns)
    try:
        return _mask(automaton, bytes(input), limit, is_streaming=False)
    finally:
        _lib.ss_destroy(automaton)
