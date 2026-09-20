# ruff: noqa: E402, F405
import io
import pathlib
import pkgutil
import typing

_BINARY_SUFFIXES = frozenset({".so", ".dylib", ".dll", ".pyd"})
if not any(entry.suffix in _BINARY_SUFFIXES for entry in pathlib.Path(__file__).parent.iterdir()):
    __path__ = pkgutil.extend_path(__path__, __name__)

from . import _core
from ._core import MAX_NUMBER_OF_STARS, mask

__all__ = ["MAX_NUMBER_OF_STARS", "StreamWrapper", "mask"]


class StreamWrapper(io.RawIOBase):
    """The StreamWrapper wraps an io.BytesIO stream to mask or remove secrets while reading from it."""

    def __init__(
        self, stream: typing.IO[bytes], patterns: typing.Iterable[bytes], /, *, limit: int = MAX_NUMBER_OF_STARS
    ):
        """
        The StreamWrapper class constructor.

        :param stream: An I/O stream (a file-like object) that works with binary data (sequences of bytes).
        :param patterns: Any iterable of patterns that have to be masked with the `*` asterisk character.
        :param limit: The max number of consecutive stars.
        """
        self._stream = stream
        self._wrapper = _core._StreamWrapper(patterns, limit=limit)

    def _masking_read(self, reader: typing.Callable[[int], bytes | None], size: int) -> bytes | None:
        """
        Pull chunks from `reader` until one yields masked output, EOF, or a would-block.

        Only b"" from the source means EOF; that is the one point where the held
        partial match is flushed. None (non-blocking source with no data ready) and
        a zero-size read must keep the automaton state, or a secret split across
        the boundary would be emitted unmasked.
        """
        if size == 0:
            return b""
        while True:
            carry = reader(size)
            if carry is None:
                return None
            if not carry:
                return self._wrapper.consume_reminder()
            if res := self._wrapper.masking_read(carry):
                return res

    def read(self, size: int = -1) -> bytes | None:
        """
        Read up to size bytes from the object and return them.

        All found patterns are masked. If a starting part of some multiline pattern appears at the end of line
        the method may move it to the beginning of the next line.

        :param size: A number of bytes to read. As a convenience, if size is unspecified or -1,
        all bytes until EOF are returned. Otherwise, only one system call is ever made.
        Fewer than size bytes may be returned if the operating system call returns fewer than size bytes.
        :return: If 0 bytes are returned, and size was not 0, this indicates end of file.
        If the object is in non-blocking mode and no bytes are available, None is returned.
        """
        return self._masking_read(self._stream.read, size)

    # typeshed types IOBase.readline() as bytes only, but a non-blocking source
    # with no data ready yields None, and that is passed through rather than
    # mistaken for EOF, exactly as read() does.
    def readline(self, size: int | None = -1, /) -> bytes | None:  # ty: ignore[invalid-method-override]
        """
        Read and return one line from the stream.

        All found patterns are masked. If a starting part of some multiline pattern appears at the end of line
        the method may move it to the beginning of the next line.

        :param size: If size is specified, at most size bytes will be read.
        :return: The line with masked patterns. The line terminator is always b'\n' for binary files.
        If the object is in non-blocking mode and no bytes are available, None is returned.
        """
        if size is None:
            size = -1
        return self._masking_read(self._stream.readline, size)

    def seekable(self):
        """This stream does not support seek operations."""
        return False

    def readable(self) -> bool:
        """This stream is readable."""
        return True

    def writable(self) -> bool:
        """This stream does not support writing."""
        return False
