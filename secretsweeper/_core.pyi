def mask(input: bytes, words: tuple[bytes, ...], /, *, limit: int = 15) -> bytes:
    """
    Masks the specific words in the input.

    :param input: An input bytes.
    :param words: A tuple of secrets that have to be masked with the `*` asterisk character.
    :param limit: A max number of consecutive asterisks.
    :return Rreturns the input string with masked secrets.
    """
    ...

