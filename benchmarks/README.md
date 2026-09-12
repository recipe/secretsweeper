# Benchmarks

Reusable scripts that compare `secretsweeper.mask()` against stdlib `re` and
several Aho-Corasick libraries (`pyahocorasick`, `ahocorasick_rs`, `acora`,
`ahocorapy`). The current results live in [RESULTS.md](RESULTS.md), linked
from the main [README](../README.md).

## Running it

Comparison libraries are an optional dependency group (`benchmark`), kept out
of the main install:

```bash
uv run --group benchmark python benchmarks/gen_corpus.py   
uv run --group benchmark python benchmarks/bench.py --rounds 5
uv run --group benchmark python benchmarks/report.py        
```

`bench.py` regenerates the corpus automatically on first run if
`benchmarks/data/` doesn't exist yet (or pass `--generate` to force it).

## Files

- `gen_corpus.py` - deterministic corpus + pattern generator. Every run with
  the same seed produces byte-identical output, so results are comparable
  across time and across machines.
- `bench.py` - the actual benchmark: interleaved rounds (engine order rotates
  each round to spread out system noise), one total wall-clock call per
  engine per round, byte-identical output verified against secretsweeper's
  own result. Writes `data/results.json`.
- `report.py` - turns `results.json` into `RESULTS.md`, stamped with the CPU/
  OS/Python/Zig versions the run used.
- `data/` - generated corpus, patterns, and results.

## Native streaming calls

`bench_streaming.py` compares the native streaming fast path against the ctypes
fallback within the same installed wheel. It checks output equality, alternates
measurement order, and reports the median call cost for 32, 128, and 1024-byte
chunks. Run it in the environment where the wheel is installed:

```bash
python -I /path/to/secretsweeper/benchmarks/bench_streaming.py
```

For Python 3.15t, check that the output names `_native.abi3t.so` and reports
`GIL enabled: False`. These measurements cover streaming-call overhead, not
end-to-end application throughput or parallel scaling.

## Why re-run this instead of trusting old numbers

Numbers in `RESULTS.md` are only valid for the machine and versions listed at
its top. Re-run the three commands above after any change to the masking path
(or before/after upgrading a comparison library) rather than trusting a stale
report - that's the whole reason this lives in the repo instead of a
scratchpad.
