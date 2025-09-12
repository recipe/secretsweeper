import pytest

import secretsweeper

@pytest.mark.parametrize(
    ("data", "values", "expected"),
    [
        ("teststring", ["string"], "test******"),
        ("testingstring", ["string", "testing"], "*************"),
        ("testing(val)string", ["string", "testing"], "*******(val)******"),
        ("1ttestingsstringg", ["string", "testing"], "1t*******s******g"),
        ("string and other things", ["string"], "****** and other things"),
        ("1ttes\ntingss\ntringg", ["string", "testing"], "1t***\n****s*\n*****g"),
        ("testing\nstring\n", ["string", "testing"], "*******\n******\n"),
        ("testing\n", ["testing"], "*******\n"),
        ("testingothertesting\n", ["testing"], "*******other*******\n"),
        # overlapping values
        ("12foobarbaz", ["12foobarbaz", "other121"], "***********"),
        ("qquerty", ["querty"], "q******"),
        ("cbcbccb", ["cbccb"], "cb*****"),
        ("bcbcbccb", ["cbccb", "bcbcb"], "*" * len("bcbcbccb")),
        ("4RIPUG5YE", ["RIPUG", "4I3CT"], "4*****5YE"),
        ("TXXXXICHTAX", ["XXICH"], "TXX*****TAX"),
        ("TX\n\n\nX\n\nX\nX\n\nICHTAX", ["XXICH"], "TX\n\n\nX\n\n*\n*\n\n***TAX"),
        ("TX\n\n\nX\n\nX\nX\n\nICHTAX", ["X\nX\nICH"], "TX\n\n\nX\n\n*\n*\n\n***TAX"),
        ("S7SUUUUZPE", ["S7SUU", "UUZPE"], "**********"),
        ("all-removed\nnot-removed\n", ["removed", "all-removed"], "***********\nnot-*******\n"),
        # ("terraform\n", ["terra\nform"], "terraform\n"),  # reserved word must remain intact
    ],
)
def test_mask(data: str, values: list[str], expected: str) -> None:
    assert secretsweeper.mask(data.encode(), tuple(v.encode() for v in values)) == expected.encode()
