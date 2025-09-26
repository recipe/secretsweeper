import pytest

import secretsweeper

@pytest.mark.parametrize(
    ("input", "words", "expected"),
    [
        ("first", (), "first"), # no patterns
        ("second", ("",), "second"), # empty pattern
        ("teststring", ("string",), "test******"),
        ("notebook", ("note", "book"), "********"),
        ("news(paper)man", ("man", "news"), "****(paper)***"),
        ("aballsong", ("ball", "on"), "a****s**g"),
        ("son sings a song", ("son",), "*** sings a ***g"),
        ("[multi\nline]secret", ("multi\nline", "secret"), "[**********]******"),
        ("new\nline\n", ("line", "new"), "***\n****\n"),
        ("-dash-\n", ("-",), "*dash*\n"),
        ("repeatingpeat", ("peat", "peat"), "re****ing****"),
        # Overlapping patterns
        ("asher", ("ash", "her", "she"), "*****"),
        ("qqwerty", ("qwerty",), "q******"),
        ("cbcbccb", ("cbccb",), "cb*****"),
        ("bcbcbccb", ("cbccb", "bcbcb",), "********"),
        ("sinto", ("sin", "into"), "*****"),
        ("smasher", ("ash", "masher",), "s******"),
        ("friendship", ("end", "ship", "friend"), "**********"),
    ],
)
def test_mask(input: str, words: tuple[str, ...], expected: str) -> None:
    assert secretsweeper.mask(input.encode(), tuple(w.encode() for w in words)) == expected.encode()

@pytest.mark.parametrize(
    ("input", "words", "limit", "expected"),
    [
        ("basketball", ("ball",), 2, "basket**"),
        ("smallhou\nse\n", ("hou\nse",), 2, "small**\n"),
        ("hellob\nunny", ("b\nunny\n",), 2, "hellob\nunny"),
        ("thiswasfunny\n", ("funny",), 6, "thiswas*****\n"),
        ("fivesix\n", ("six\n",), 0, "five"),
        ("seveneleven\n", ("eleven",), 6, "seven******\n"),
    ],
)
def test_mask_limit(input: str, words: tuple[str, ...], limit: int, expected: str) -> None:
    assert secretsweeper.mask(input.encode(), tuple(w.encode() for w in words), limit=limit) == expected.encode()

@pytest.mark.parametrize(
    ("input", "words", "expected"),
    [
        ("", ("",), ""),
        ("this is a [secret]", ("secret",), "this is a []"),
        ("fetch fresh fishes", ("sh",), "fetch fre fies"),
    ],
)
def test_sanitize(input: str, words: tuple[str, ...], expected: str) -> None:
    assert secretsweeper.mask(input.encode(), tuple(w.encode() for w in words), limit=0) == expected.encode()

@pytest.mark.parametrize(
    ("input", "words", "expected"),
    [
        # Multi-byte characters are replaced with 2-4 asterisks.
        ("давай", ("да",), "****вай"),
        ("тримай", ("май", "три"), "************"),
    ],
)
def test_mask_utf8(input: str, words: tuple[str, ...], expected: str) -> None:
    assert secretsweeper.mask(input.encode(), tuple(w.encode("utf8") for w in words)) == expected.encode()
