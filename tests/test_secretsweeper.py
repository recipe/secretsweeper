import io
import pathlib
import typing
import unittest

import pytest

import secretsweeper

FIXTURES_DIR = pathlib.Path(__file__).parent / "fixtures"
# Git may check fixtures out with CRLF line endings (e.g. on Windows with core.autocrlf),
# so tests reading fixture files build patterns and expected values from the actual newline.
NL = b"\r\n" if b"\r\n" in (FIXTURES_DIR / "file.txt").read_bytes() else b"\n"


def _generator() -> typing.Iterator[bytes]:
    yield b"a"


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
    assert secretsweeper.mask(input.encode(), (w.encode() for w in patterns)) == expected.encode()


@pytest.mark.parametrize(
    ("input", "patterns", "limit", "expected"),
    [
        ("basketball", ("ball",), 2, "basket**"),
        ("smallhou\nse\n", ("hou\nse",), 2, "small**\n"),
        ("hellob\nunny", ("b\nunny\n",), 2, "hellob\nunny"),
        ("thiswasfunny\n", ("funny",), 6, "thiswas*****\n"),
        ("fivesix\n", ("six\n",), 0, "five"),
        ("seveneleven\n", ("eleven",), 6, "seven******\n"),
        ("line\nsecond line\n", ("ne\nsec", "second"), 6, "li****** line\n"),  # overlapping patterns + max size
    ],
)
def test_mask_limit(input: str, patterns: typing.Iterable[str], limit: int, expected: str) -> None:
    assert secretsweeper.mask(input.encode(), (w.encode() for w in patterns), limit=limit) == expected.encode()


@pytest.mark.parametrize(
    ("input", "patterns", "expected"),
    [
        ("", ("",), ""),
        ("this is a [secret]", ("secret",), "this is a []"),
        ("fetch fresh fishes", ("sh",), "fetch fre fies"),
    ],
)
def test_sanitize(input: str, patterns: typing.Iterable[str], expected: str) -> None:
    assert secretsweeper.mask(input.encode(), (w.encode() for w in patterns), limit=0) == expected.encode()


@pytest.mark.parametrize(
    ("input", "patterns", "expected"),
    [
        # Multibyte characters are replaced with 2-4 asterisks.
        ("давай", ("да",), "****вай"),
        ("тримай", ("май", "три"), "************"),
    ],
)
def test_mask_utf8(input: str, patterns: typing.Iterable[str], expected: str) -> None:
    assert secretsweeper.mask(input.encode(), (w.encode() for w in patterns)) == expected.encode()


@pytest.mark.parametrize(
    ("patterns"),
    [
        (b"a",),  # it can be a tuple
        [b"a"],  # it can be a list
        {b"a"},  # it can be a set
        {b"a": typing.Any},  # it can be a dict
        (b"a" for i in range(0, 1)),  # it can be a generator expression
        _generator(),
    ],
)
def test_mask_pattern_type(patterns: typing.Iterable[bytes]) -> None:
    assert secretsweeper.mask(b"a", patterns) == b"*"


def test_mask_max_number_of_stars_default() -> None:
    inp = b"a" * (secretsweeper.MAX_NUMBER_OF_STARS + 1)
    assert secretsweeper.mask(inp, (inp,)) == b"*" * secretsweeper.MAX_NUMBER_OF_STARS


def test_can_mask_bytearray() -> None:
    assert secretsweeper.mask(bytearray(b"funny"), (b"fun",)) == b"***ny"


def test_can_mask_memory_view() -> None:
    assert secretsweeper.mask(memoryview(b"funny"), (b"fun",)) == b"***ny"


def test_stream_wrapper_init_and_del() -> None:
    wrapper = secretsweeper._core._StreamWrapper((b"a", b"b"))
    wrapper2 = secretsweeper._core._StreamWrapper((b"a", b"b"))
    assert isinstance(wrapper, secretsweeper._core._StreamWrapper)
    assert isinstance(wrapper2, secretsweeper._core._StreamWrapper)
    assert id(wrapper) == wrapper._id()
    assert id(wrapper2) == wrapper2._id()
    assert id(wrapper) != id(wrapper2)
    del wrapper
    del wrapper2


def test_stream_wrapper_iter() -> None:
    chunk = []
    with open(FIXTURES_DIR / "file.txt", "rb") as f:
        stream = secretsweeper.StreamWrapper(f, (b"line",))
        for line in stream:
            chunk.append(line)
    assert b"".join(chunk) == b"first ****" + NL + b"second ****" + NL + b"third ****" + NL


def test_stream_wrapper_readall() -> None:
    with open(FIXTURES_DIR / "file.txt", "rb") as f:
        stream = secretsweeper.StreamWrapper(f, (b"line",))
        result = stream.readall()
    assert result == b"first ****" + NL + b"second ****" + NL + b"third ****" + NL


def test_stream_wrapper_reminder_is_bounded() -> None:
    # A stream of b"a" against the pattern b"ab" keeps the automaton away from its
    # starting state; the wrapper must still emit data promptly and retain at most
    # a longest-pattern-prefix tail instead of buffering the whole stream.
    stream = secretsweeper.StreamWrapper(io.BytesIO(b"a" * 1000), (b"ab",))
    first = stream.read(100)
    assert first == b"a" * 99
    assert stream._wrapper.get_reminder() == b"a"
    assert first + stream.readall() == b"a" * 1000


def test_stream_wrapper_bytes_io() -> None:
    s = io.BytesIO(initial_bytes=b"funny")
    stream = secretsweeper.StreamWrapper(s, (b"fun",), limit=0)
    result = stream.readall()
    assert result == b"ny"


def test_stream_wrapper_read_limited_size() -> None:
    def _iter() -> typing.Iterator[bytes]:
        with open(FIXTURES_DIR / "file.txt", "rb") as f:
            stream = secretsweeper.StreamWrapper(
                f, (b"st line" + NL + b"second line" + NL + b"third line" + NL,), limit=5
            )
            # Note: We don't guarantee that the buffer won't exceed the provided size.
            while buf := stream.read(size=3):
                yield buf

    assert b"".join(_iter()) == b"fir*****"


@pytest.mark.parametrize(
    ("fixture_file", "patterns", "limit", "expected"),
    [
        # the mask length equals the pattern length, which depends on the newline width.
        (
            "file",
            (b"line" + NL + b"third",),
            None,
            b"first line" + NL + b"second " + b"*" * len(b"line" + NL + b"third") + b" line" + NL,
        ),
        # overlapping multiline pattern.
        ("file", (b"ne" + NL + b"se", b"second"), 3, b"first li*** line" + NL + b"third line" + NL),
        # the first pattern is near the limit and next overlapping pattern is less than the limit.
        ("file", (b"ne" + NL + b"se", b"second"), 4, b"first li**** line" + NL + b"third line" + NL),
        # multiline pattern for more than two lines.
        ("file", (b"st line" + NL + b"second line" + NL + b"third ",), 1, b"fir*line" + NL),
        # multiline pattern for more than two lines up to the end of the input.
        ("file", (b"st line" + NL + b"second line" + NL + b"third line" + NL,), 1, b"fir*"),
        # removing overlapping patterns.
        (
            "file",
            (b"third", b"ne" + NL, b"e" + NL, b" line" + NL, b"st line" + NL + b"second line" + NL + b"th"),
            0,
            b"fir",
        ),
        # non overlapping - 1 asterisks for every pattern.
        ("file", (b"first line" + NL, b"second line" + NL, b"third line" + NL), 1, b"***"),
        # overlapping - 1 asterisks in total for all patterns.
        ("file", (b"first line" + NL + b"s", b"second line" + NL + b"t", b"third line" + NL), 1, b"*"),
    ],
)
def test_stream_wrapper(
    fixture_file: str, patterns: typing.Iterable[bytes], expected: bytes, limit: None | int
) -> None:
    if limit is None:
        limit = secretsweeper.MAX_NUMBER_OF_STARS
    chunk = []
    with open(FIXTURES_DIR / f"{fixture_file}.txt", "rb") as f:
        stream = secretsweeper.StreamWrapper(f, patterns, limit=limit)
        for line in stream:
            chunk.append(line)
    assert b"".join(chunk) == expected


class InvalidInputTest(unittest.TestCase):
    def test_mask_error_input(self) -> None:
        with self.assertRaises(TypeError) as ex:
            secretsweeper.mask(0, ())  # type: ignore
        self.assertIn("expected bytes, memoryview or bytearray, found <class 'int'>", str(ex.exception))

    def test_mask_error_patterns(self) -> None:
        with self.assertRaises(TypeError) as ex:
            secretsweeper.mask(b"", -1)  # type: ignore
        self.assertIn("'int' object is not iterable", str(ex.exception))

    def test_mask_bytes_io_input(self) -> None:
        with self.assertRaises(TypeError) as ex:
            secretsweeper.mask(io.BytesIO(initial_bytes=b""), ())  # type: ignore
        self.assertIn("You can use the StreamWrapper class for such purposes.", str(ex.exception))
