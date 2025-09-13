def mask(input: bytes, words: tuple[bytes, ...], /, *, limit: int = 15) -> bytes:
    """
    Masks the specific words in the input.

    :param input: An input.
    :param words: A tuple of secrets that have to be masked with the `*` asterisk character.
    :param limit: The max number of consecutive stars.
    :return Rreturns the input string with masked secrets.
    """
    ...

