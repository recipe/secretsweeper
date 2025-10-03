import typing

class StreamWrapper:
    """
    The StreamWrapper wraps an io.BytesIO stream to mask or remove secrets while reading from it.
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
