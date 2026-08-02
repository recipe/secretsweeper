import unittest

import pytest

from secretsweeper import _core


@pytest.fixture(autouse=True)
def _build_variant(request, monkeypatch):
    """Runs every (non-unittest) test twice: once against the DFA build path,
    once against the classic goto/fail-link fallback. Both are supposed to be
    behaviorally identical — this is what catches a regression in either one."""
    if getattr(request, "param", False):
        monkeypatch.setenv(_core._FORCE_NO_DFA_AUTOMATON_ENV, "true")


def pytest_generate_tests(metafunc):
    # unittest.TestCase methods can't take a parametrized autouse fixture (pytest
    # errors at collection: "does not support fixtures"), so those run once,
    # under the default DFA path only - fine here since InvalidInputTest only
    # covers input-validation errors raised before/independent of which
    # automaton representation gets built.
    is_unittest_case = metafunc.cls and issubclass(metafunc.cls, unittest.TestCase)
    if "_build_variant" in metafunc.fixturenames and not is_unittest_case:
        metafunc.parametrize("_build_variant", [False, True], ids=["dfa", "fallback"], indirect=True)
