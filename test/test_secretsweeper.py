import io
import pathlib
import typing
import unittest

import pytest

import secretsweeper


def _generator() -> typing.Generator[bytes, None, None]:
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
    with open(pathlib.Path(__file__).parent / "fixtures" / "file.txt", "rb") as f:
        stream = secretsweeper.StreamWrapper(f, (b"line",))
        for line in stream:
            chunk.append(line)
    assert b"".join(chunk) == b"first ****\nsecond ****\nthird ****\n"


def test_stream_wrapper_readall() -> None:
    with open(pathlib.Path(__file__).parent / "fixtures" / "file.txt", "rb") as f:
        stream = secretsweeper.StreamWrapper(f, (b"line",))
        result = stream.readall()
    assert result == b"first ****\nsecond ****\nthird ****\n"


def test_stream_wrapper_bytes_io() -> None:
    s = io.BytesIO(initial_bytes=b"funny")
    stream = secretsweeper.StreamWrapper(s, (b"fun",), limit=0)
    result = stream.readall()
    assert result == b"ny"


@pytest.mark.parametrize(
    ("fixture_file", "patterns", "limit", "expected"),
    [
        ("file", (b"line\nthird",), None, b"first line\nsecond ********** line\n"),
        # overlapping multiline pattern.
        ("file", (b"ne\nse", b"second"), 3, b"first li*** line\nthird line\n"),
        # the first pattern is near the limit and next overlapping pattern is less than the limit.
        ("file-cr-lf", (b"ne\r\nse", b"second"), 4, b"first li**** line\r\nthird line\r\n"),
        # multiline pattern for more than two lines.
        ("file", (b"st line\nsecond line\nthird ",), 1, b"fir*line\n"),
        # FIXME multiline pattern for more than two lines up to the end of the input
        # ("file", (b"st line\nsecond line\nthird line\n",), 1, b"fir*"),
    ],
)
def test_stream_wrapper(
    fixture_file: str, patterns: typing.Iterable[bytes], expected: bytes, limit: None | int
) -> None:
    if limit is None:
        limit = secretsweeper.MAX_NUMBER_OF_STARS
    chunk = []
    with open(pathlib.Path(__file__).parent / "fixtures" / f"{fixture_file}.txt", "rb") as f:
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
