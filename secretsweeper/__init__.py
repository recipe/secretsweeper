import io
import typing

from ._core import *  # noqa: F403

MAX_NUMBER_OF_STARS = 15


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
        self._wrapper = _core._StreamWrapper(patterns, limit=limit)  # noqa: F405

    def read(self, size: int = -1) -> bytes:
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
        carry = self._stream.read(size)
        if not carry:
            return self._wrapper.consume_reminder()
        return self._wrapper.masking_read(carry)

    def readline(self, size: int | None = -1, /) -> bytes:
        """
        Read and return one line from the stream.

        All found patterns are masked. If a starting part of some multiline pattern appears at the end of line
        the method may move it to the beginning of the next line.

        :param size: If size is specified, at most size bytes will be read.
        :return: The line terminator is always b'\n' for binary files.
        """
        carry = self._stream.readline(size)
        if not carry:
            return self._wrapper.consume_reminder()
        return self._wrapper.masking_read(carry)

    def seekable(self):
        """This stream does not support seek operations."""
        return False

    def readable(self) -> bool:
        """This stream is readable."""
        return True

    def writable(self) -> bool:
        """This stream does not support writing."""
        return False
