import pytest

import secretsweeper

@pytest.mark.parametrize(
    ("input", "words", "expected"),
    [
        ("test", (), "test"),
        ("test", ("",), "test"),
        ("teststring", ("string",), "test******"),
        ("testingstring", ("string", "testing"), "*************"),
        ("testing(val)string", ("string", "testing"), "*******(val)******"),
        ("1ttestingsstringg", ("string", "testing"), "1t*******s******g"),
        ("string and other things", ("string", ), "****** and other things"),
        ("1ttes\ntingss\ntringg", ("string", "testing"), "1t***\n****s*\n*****g"),
        ("testing\nstring\n", ("string", "testing"), "*******\n******\n"),
        ("testing\n", ("testing",), "*******\n"),
        ("testingothertesting\n", ("testing",), "*******other*******\n"),
        # overlapping values
        ("12foobarbaz", ("12foobarbaz", "other121"), "***********"),
        ("qquerty", ("querty",), "q******"),
        ("cbcbccb", ("cbccb",), "cb*****"),
        ("bcbcbccb", ("cbccb", "bcbcb",), "********"),
        ("4RIPUG5YE", ("RIPUG", "4I3CT",), "4*****5YE"),
        ("TXXXXICHTAX", ("XXICH",), "TXX*****TAX"),
        ("TX\n\n\nX\n\nX\nX\n\nICHTAX", ("XXICH",), "TX\n\n\nX\n\n*\n*\n\n***TAX"),
        ("TX\n\n\nX\n\nX\nX\n\nICHTAX", ("X\nX\nICH",), "TX\n\n\nX\n\n*\n*\n\n***TAX"),
        ("S7SUUUUZPE", ("S7SUU", "UUZPE",), "**********"),
        ("all-removed\nnot-removed\n", ("removed", "all-removed",), "***********\nnot-*******\n"),
    ],
)
def test_mask(input: str, words: tuple[str, ...], expected: str) -> None:
    assert secretsweeper.mask(input.encode(), tuple(w.encode() for w in words)) == expected.encode()

@pytest.mark.parametrize(
    ("input", "words", "limit", "expected"),
    [
        ("teststring", ("string",), 2, "test**"),
        ("smallhou\nse\n", ("house",), 2, "small**\n**\n"),
        ("hellob\nunny", ("bu\nnny\n",), 2, "hello*\n**"),
        ("thiswasfunny\n", ("funny",), 6, "thiswas*****\n"),
        ("fivesix\n", ("six\n",), 0, "five\n"),
        ("seveneleven\n", ("eleven",), 6, "seven******\n"),
        ("b\n\nart-stop\n", ("bar\nt","\nart", "op"), 2, "*\n\n**-st**\n"),
    ],
)
def test_mask_limit(input: str, words: tuple[str, ...], limit: int, expected: str) -> None:
    assert secretsweeper.mask(input.encode(), tuple(w.encode() for w in words), limit=limit) == expected.encode()
