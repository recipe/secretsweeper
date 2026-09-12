"""Compare native and ctypes streaming calls using the installed wheel.

Run with: python -I /path/to/benchmarks/bench_streaming.py
"""

import argparse
import platform
import statistics
import sys
import timeit

from secretsweeper import _core


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=100_000)
    parser.add_argument("--rounds", type=int, default=7)
    args = parser.parse_args()
    if args.iterations < 1 or args.rounds < 1:
        parser.error("iterations and rounds must be positive")

    native = _core._native
    if native is None:
        parser.error("the installed package has no native streaming extension")
    print(f"Python {sys.version.split()[0]}, {platform.platform()}")
    print(f"GIL enabled: {getattr(sys, '_is_gil_enabled', lambda: True)()}")
    print(f"Extension: {native.__file__}")
    print(f"Median of {args.rounds} alternating rounds, {args.iterations} calls per round")
    print("bytes | native ns/call | ctypes ns/call | speedup")
    try:
        for size in (32, 128, 1024):
            data = b"x" * (size - 8) + b" secret\n"
            expected = b"x" * (size - 8) + b" ******\n"
            timings: dict[str, list[float]] = {"native": [], "ctypes": []}
            for round_index in range(args.rounds):
                order = ("native", "ctypes") if round_index % 2 == 0 else ("ctypes", "native")
                for name in order:
                    _core._native = native if name == "native" else None
                    wrapper = _core._StreamWrapper((b"secret",))
                    assert wrapper.masking_read(data) == expected
                    elapsed = timeit.timeit(lambda: wrapper.masking_read(data), number=args.iterations)
                    timings[name].append(elapsed * 1e9 / args.iterations)
            fast = statistics.median(timings["native"])
            fallback = statistics.median(timings["ctypes"])
            print(f"{size:5} | {fast:14.0f} | {fallback:14.0f} | {fallback / fast:.2f}x")
    finally:
        _core._native = native


if __name__ == "__main__":
    main()
