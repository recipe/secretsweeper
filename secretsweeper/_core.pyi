import typing

class _StreamWrapper:
    """
    An internal _StreamWrapper class representation written in Zig language.
    """
    def __init__(self, patterns: typing.Iterable[bytes], /, *, limit: int = 15):
        """
        The _StreamWrapper class constructor.

        :param patterns: Any iterable of patterns that have to be masked with the `*` asterisk character.
        :param limit: The max number of consecutive stars.
        """
    ...

    def _wrapped_read(self, carry: bytes) -> bytes:
        """
        Read data from the carry buffer and apply pattern masking.

        :param carry: A chunk buffer that needs to be masked with the `*` asterisk character.
        :return: Returns the input string with masked patterns.
        """
        ...

    def _id(self) -> int:
        """
        :return: Return the identity of this object.
        """
        ...


def mask(input: bytes, patterns: typing.Iterable[bytes], /, *, limit: int = 15) -> bytes:
    """
    Masks the specific patterns in the input.

    :param input: An input.
    :param patterns: Any iterable of patterns that have to be masked with the `*` asterisk character.
    :param limit: The max number of consecutive stars.
    :return Returns the input string with masked patterns.
    """
    ...
