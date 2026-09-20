"""Public API over the automaton backend.

- `secretsweeper._native`: the CPython extension module (src/python.zig) using the
  stable ABI - `abi3` on regular CPython 3.11+, `abi3t` on free-threaded CPython
  3.15+. Calls cost about as much as a builtin function.
- `secretsweeper._ctypes_backend`: the C-ABI shared library (src/export.zig) driven
  through the standard library `ctypes` module. Used where the extension cannot be
  built: free-threaded CPython before 3.15, which has no stable ABI; non-CPython
  interpreters; Windows source builds without the stable ABI import library.
"""

import io
import os
import sys
import sysconfig
import threading
import typing

if sysconfig.get_config_var("Py_GIL_DISABLED") and sys.version_info < (3, 15):
    # No stable ABI before 3.15 on free-threaded CPython: never load a leftover
    # abi3 extension, whose object layouts would not match the interpreter's.
    _native = None
else:
    try:
        import secretsweeper._native as _native
    except ModuleNotFoundError as e:
        # Only a wheel built without the extension falls back to ctypes.
        if e.name != "secretsweeper._native":
            raise
        _native = None

if _native is not None:
    _backend = _native
else:
    from secretsweeper import _ctypes_backend as _backend

MAX_NUMBER_OF_STARS = 15

_FORCE_NO_DFA_AUTOMATON_ENV = "SECRET_SWEEPER_NO_DFA_AUTOMATON"
"""
Normally builds whichever representation the backend picks (the DFA, unless
the pattern set exceeds its memory cap). Setting the
`SECRET_SWEEPER_NO_DFA_AUTOMATON` environment variable to a truthy value
(`1`/`true`, case-insensitive) forces the classic goto/fail-link build
instead, for tests that need to exercise both code paths without a pattern
set large enough to defeat the DFA naturally. Any other value (including
unset, `0`, `false`) keeps the default behavior. Checked on every call (not
cached at import time) so tests can toggle it per-test via
`monkeypatch.setenv`.
"""

_TRUTHY_ENV_VALUES = frozenset({"1", "true"})


def _is_env_flag_set(name: str) -> bool:
    """True if the environment variable `name` is set to a truthy value
    (`1`/`true`, case-insensitive, surrounding whitespace ignored). Everything
    else - unset, `0`, `false`/`False`, empty, or any other value - is not."""
    return os.environ.get(name, "").strip().lower() in _TRUTHY_ENV_VALUES


def _build_automaton(patterns: typing.Iterable[bytes]) -> typing.Any:
    """Create an automaton, insert all patterns and build it. Returns the backend's handle."""
    return _backend.new(patterns, not _is_env_flag_set(_FORCE_NO_DFA_AUTOMATON_ENV))


class _StreamWrapper:
    """
    An internal _StreamWrapper class that owns a persistent automaton.

    The automaton state is mutated by the native code, so all calls into it are
    serialized with a lock to keep concurrent use memory-safe.

    This is also gevent-safe: `threading.Lock` is resolved when the wrapper is created,
    honoring monkey-patching, and even an unpatched lock is only ever held around
    native calls that contain no greenlet switch points.
    """

    def __init__(self, patterns: typing.Iterable[bytes], /, *, limit: int = MAX_NUMBER_OF_STARS):
        """
        The _StreamWrapper class constructor.

        :param patterns: Any iterable of patterns that have to be masked with the `*` asterisk character.
        :param limit: The max number of consecutive stars.
        """
        if limit < 0:
            raise ValueError("limit must be non-negative")
        self._limit = limit
        self._lock = threading.Lock()
        self._automaton: typing.Any = _build_automaton(patterns)

    def __del__(self, _destroy=_backend.destroy):
        if (automaton := getattr(self, "_automaton", None)) is not None:
            self._automaton = None
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
        with self._lock:
            return _backend.mask(self._automaton, carry, self._limit, True)

    def consume_reminder(self) -> bytes:
        """
        :return: Consumes the reminder or return empty bytes if there is no reminder. Then reset its value.
        """
        with self._lock:
            try:
                return _backend.get_reminder(self._automaton)
            finally:
                _backend.reset_reminder(self._automaton)

    def get_reminder(self) -> bytes:
        """
        :return: Get the reminder or return empty bytes if it's empty.
        """
        with self._lock:
            return _backend.get_reminder(self._automaton)


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
    if limit < 0:
        raise ValueError("limit must be non-negative")
    if isinstance(input, memoryview) and not input.c_contiguous:
        # The backends read the input as one contiguous buffer.
        input = input.tobytes()
    automaton = _build_automaton(patterns)
    try:
        return _backend.mask(automaton, input, limit, False)
    finally:
        _backend.destroy(automaton)
