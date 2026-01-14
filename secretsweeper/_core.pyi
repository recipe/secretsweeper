import typing
from collections.abc import Buffer

MAX_NUMBER_OF_STARS = 15

class _StreamWrapper:
    """
    An internal _StreamWrapper class representation written in Zig language.
    """
    def __init__(self, patterns: typing.Iterable[bytes], /, *, limit: int = MAX_NUMBER_OF_STARS):
        """
        The _StreamWrapper class constructor.

        :param patterns: Any iterable of patterns that have to be masked with the `*` asterisk character.
        :param limit: The max number of consecutive stars.
        """
    ...

    def masking_read(self, carry: bytes) -> bytes:
        """
        Read data from the carry buffer and apply pattern masking.

        :param carry: A chunk buffer that needs to be masked with the `*` asterisk character.
        :return: Returns the input string with masked patterns.
        """
        ...

    def consume_reminder(self) -> bytes:
        """
        :return: Consumes the reminder or return empty bytes if there is no reminder. Then reset its value.
        """
        ...

    def get_reminder(self) -> bytes:
        """
        :return: Get the reminder or return empty bytes if it's empty.
        """
        ...

    def _id(self) -> int:
        """
        :return: Return the identity of this object.
        """
        ...

def mask(input: Buffer, patterns: typing.Iterable[bytes], /, *, limit: int = MAX_NUMBER_OF_STARS) -> bytes:
    """
    Masks the specific patterns in the input.

    :param input: An input bytes, bytearray or memoryview.
    :param patterns: Any iterable of patterns that have to be masked with the `*` asterisk character.
    :param limit: The max number of consecutive stars.
    :return Returns the input string with masked patterns.
    """
    ...
