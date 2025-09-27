import pytest
import unittest
import typing

import secretsweeper


@pytest.mark.parametrize(
    ("input", "patterns", "expected"),
    [
        ("first", (), "first"),  # no patterns
        ("second", ("",), "second"),  # empty pattern
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
        (
            "bcbcbccb",
            (
                "cbccb",
                "bcbcb",
            ),
            "********",
        ),
        ("sinto", ("sin", "into"), "*****"),
        (
            "smasher",
            (
                "ash",
                "masher",
            ),
            "s******",
        ),
        ("friendship", ("end", "ship", "friend"), "**********"),
    ],
)
def test_mask(input: str, patterns: typing.Iterable[str], expected: str) -> None:
    assert (
        secretsweeper.mask(input.encode(), (w.encode() for w in patterns))
        == expected.encode()
    )


@pytest.mark.parametrize(
    ("input", "patterns", "limit", "expected"),
    [
        ("basketball", ("ball",), 2, "basket**"),
        ("smallhou\nse\n", ("hou\nse",), 2, "small**\n"),
        ("hellob\nunny", ("b\nunny\n",), 2, "hellob\nunny"),
        ("thiswasfunny\n", ("funny",), 6, "thiswas*****\n"),
        ("fivesix\n", ("six\n",), 0, "five"),
        ("seveneleven\n", ("eleven",), 6, "seven******\n"),
    ],
)
def test_mask_limit(
    input: str, patterns: typing.Iterable[str], limit: int, expected: str
) -> None:
    assert (
        secretsweeper.mask(input.encode(), (w.encode() for w in patterns), limit=limit)
        == expected.encode()
    )


@pytest.mark.parametrize(
    ("input", "patterns", "expected"),
    [
        ("", ("",), ""),
        ("this is a [secret]", ("secret",), "this is a []"),
        ("fetch fresh fishes", ("sh",), "fetch fre fies"),
    ],
)
def test_sanitize(input: str, patterns: typing.Iterable[str], expected: str) -> None:
    assert (
        secretsweeper.mask(input.encode(), (w.encode() for w in patterns), limit=0)
        == expected.encode()
    )


@pytest.mark.parametrize(
    ("input", "patterns", "expected"),
    [
        # Multi-byte characters are replaced with 2-4 asterisks.
        ("давай", ("да",), "****вай"),
        ("тримай", ("май", "три"), "************"),
    ],
)
def test_mask_utf8(input: str, patterns: typing.Iterable[str], expected: str) -> None:
    assert (
        secretsweeper.mask(input.encode(), (w.encode() for w in patterns))
        == expected.encode()
    )


def _generator():
    yield b"a"


@pytest.mark.parametrize(
    ("patterns"),
    [
        (b"a",),  # it can be a tuple
        [b"a"],  # it can be a list
        (b"a" for i in range(0, 1)),  # it can be a generator expression
        _generator(),
    ],
)
def test_mask_pattern_type(patterns: typing.Iterable[bytes]) -> None:
    assert secretsweeper.mask(b"a", patterns) == b"*"


class InvalidInputTest(unittest.TestCase):
    def test_mask_error_input(self) -> None:
        with self.assertRaises(TypeError) as ex:
            secretsweeper.mask(0, ())
        self.assertIn("expected bytes, found <class 'int'>", str(ex.exception))

    def test_mask_error_patterns(self) -> None:
        with self.assertRaises(TypeError) as ex:
            secretsweeper.mask(b"", -1)
        self.assertIn("'int' object is not iterable", str(ex.exception))
