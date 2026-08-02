"""Renders benchmarks/data/results.json (from bench.py) into a GitHub-flavored
Markdown report at benchmarks/RESULTS.md, stamped with the machine/CPU/software
versions the run used - numbers move between machines, so a report without
that context can't be trusted or reproduced.

Usage: uv run --group benchmark python benchmarks/report.py
"""

import importlib.metadata
import json
import os
import pathlib
import platform
import re
import subprocess

REPO_ROOT = pathlib.Path(__file__).parent.parent
DATA_DIR = pathlib.Path(__file__).parent / "data"
OUT_PATH = pathlib.Path(__file__).parent / "RESULTS.md"


def _run(cmd: list[str]) -> str | None:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return out.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def _cpu_brand() -> str:
    system = platform.system()
    if system == "Darwin":
        brand = _run(["sysctl", "-n", "machdep.cpu.brand_string"])
        if brand:
            return brand
        model = _run(["sysctl", "-n", "hw.model"])
        return model or platform.processor() or "unknown"
    if system == "Linux":
        try:
            with open("/proc/cpuinfo") as f:
                for line in f:
                    if line.lower().startswith("model name"):
                        return line.split(":", 1)[1].strip()
        except OSError:
            pass
        return platform.processor() or platform.machine() or "unknown"
    return platform.processor() or platform.machine() or "unknown"


def _physical_cores() -> int | None:
    system = platform.system()
    if system == "Darwin":
        out = _run(["sysctl", "-n", "hw.physicalcpu"])
        return int(out) if out and out.isdigit() else None
    if system == "Linux":
        try:
            with open("/proc/cpuinfo") as f:
                ids = {line.split(":", 1)[1].strip() for line in f if line.lower().startswith("core id")}
            return len(ids) or None
        except OSError:
            return None
    return None


def _total_memory_gib() -> float | None:
    system = platform.system()
    if system == "Darwin":
        out = _run(["sysctl", "-n", "hw.memsize"])
        return int(out) / 1024**3 if out and out.isdigit() else None
    if system == "Linux":
        try:
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        kib = int(line.split()[1])
                        return kib / 1024**2
        except (OSError, ValueError, IndexError):
            return None
    return None


def _pinned_zig_version() -> str:
    text = (REPO_ROOT / "pyproject.toml").read_text()
    m = re.search(r"ziglang==([\d.]+)", text)
    return m.group(1) if m else "unknown"


def _dfa_memory_cap_mib() -> str:
    """Reads Aho.DFA_MEMORY_CAP straight out of src/aho.zig - there's no runtime
    accessor for it (it's a compile-time const with no Python-facing knob), and
    hardcoding a second copy of the number here would drift the moment someone
    changes the source without remembering this string."""
    text = (REPO_ROOT / "src" / "aho.zig").read_text()
    m = re.search(r"DFA_MEMORY_CAP:\s*usize\s*=\s*(\d+)\s*\*\s*1024\s*\*\s*1024", text)
    return f"{m.group(1)} MiB" if m else "unknown (see src/aho.zig)"


def collect_system_info() -> dict:
    cores_logical = os.cpu_count()
    cores_physical = _physical_cores()
    return {
        "os": f"{platform.system()} {platform.release()}",
        "platform": platform.platform(),
        "machine": platform.machine(),
        "cpu": _cpu_brand(),
        "cores_physical": cores_physical,
        "cores_logical": cores_logical,
        "memory_gib": _total_memory_gib(),
        "python_implementation": platform.python_implementation(),
        "python_version": platform.python_version(),
        "secretsweeper_version": _try_version("secretsweeper"),
        "zig_version": _pinned_zig_version(),
    }


def _try_version(dist_name: str) -> str | None:
    try:
        return importlib.metadata.version(dist_name)
    except importlib.metadata.PackageNotFoundError:
        return None


def _mermaid_label(name: str) -> str:
    """Quotes a category label for mermaid xychart-beta's x-axis list, escaping
    the one character (`"`) that would otherwise break out of the quotes."""
    return '"' + name.replace('"', "'") + '"'


def render_bar_chart(available: list[tuple[str, dict]]) -> list[str]:
    """Renders a `mermaid xychart-beta` bar chart of min throughput (MB/s,
    higher is better) - GitHub renders mermaid diagrams natively in Markdown,
    so this shows up as an actual chart, not just a code block, wherever this
    file is viewed on GitHub."""
    if not available:
        return []
    labels = ", ".join(_mermaid_label(name) for name, _ in available)
    values = ", ".join(f"{r['min_mb_s']:.1f}" for _, r in available)
    y_max = max(r["min_mb_s"] for _, r in available) * 1.1
    return [
        "```mermaid",
        "xychart-beta",
        '    title "Masking throughput - min MB/s across interleaved rounds (higher is better)"',
        f"    x-axis [{labels}]",
        f'    y-axis "MB/s" 0 --> {y_max:.0f}',
        f"    bar [{values}]",
        "```",
        "",
    ]


def render_markdown(data: dict, sysinfo: dict) -> str:
    manifest = data["manifest"]
    results = data["results"]
    corpus_mib = data["corpus_bytes"] / 1024 / 1024

    available = [(name, r) for name, r in results.items() if r["available"]]
    available.sort(key=lambda kv: kv[1]["min_ms"])

    fastest_min = available[0][1]["min_ms"] if available else None

    lines: list[str] = []
    a = lines.append

    a("# secretsweeper masking benchmark")
    a("")
    a(
        "Compares `secretsweeper.mask()` against stdlib `re` and several Aho-Corasick "
        "libraries on a synthetic corpus containing sparse, realistic secrets. "
        "Generated by [`bench.py`](bench.py) + [`report.py`](report.py) - "
        "re-run with:"
    )
    a("")
    a("```bash")
    a("uv run --group benchmark python benchmarks/gen_corpus.py")
    a("uv run --group benchmark python benchmarks/bench.py --rounds 5")
    a("uv run --group benchmark python benchmarks/report.py")
    a("```")
    a("")

    a("## Machine")
    a("")
    a("| | |")
    a("|---|---|")
    a(f"| CPU | {sysinfo['cpu']} |")
    cores = sysinfo["cores_physical"]
    cores_str = (
        f"{cores} physical / {sysinfo['cores_logical']} logical" if cores else f"{sysinfo['cores_logical']} logical"
    )
    a(f"| Cores | {cores_str} |")
    if sysinfo["memory_gib"]:
        a(f"| Memory | {sysinfo['memory_gib']:.1f} GiB |")
    a(f"| OS | {sysinfo['os']} ({sysinfo['machine']}) |")
    a(f"| Python | {sysinfo['python_implementation']} {sysinfo['python_version']} |")
    a(f"| Zig | {sysinfo['zig_version']} |")
    if sysinfo["secretsweeper_version"]:
        a(f"| secretsweeper | {sysinfo['secretsweeper_version']} |")
    a("")

    a("## Corpus")
    a("")
    a(
        f"~{corpus_mib:.2f} MiB of synthetic log lines / Terraform-plan-style noise, seeded "
        f"with {manifest['n_secrets']} realistic secrets (AWS/GitHub/Slack/Stripe/JWT/DB-URL/"
        f"OAuth-style, {min(manifest['secret_lengths'])}-{max(manifest['secret_lengths'])} bytes) "
        f"and {manifest['n_pem']} fake PEM blocks ({', '.join(manifest['pem_kinds'])}, "
        f"{min(manifest['pem_lengths'])}-{max(manifest['pem_lengths'])} bytes) at random positions - "
        f"same absolute secret count regardless of corpus size, so secrets stay sparse "
        f"(closer to real-world rarity than scaling secret count with file size). Fixed seed "
        f"({manifest['seed']}): every regeneration is byte-identical."
    )
    a("")

    a("## Results")
    a("")
    a(
        f"Each engine measured as a single total wall-clock call (build/compile + search + mask "
        f"fused, no separate breakdown) over {data['n_rounds']} interleaved "
        f"round{'s' if data['n_rounds'] != 1 else ''} (engine order rotates each round to spread "
        f"out system noise). Non-native engines only find match "
        f"spans, so each gets the same handwritten pure-Python reconstruction (merge overlapping "
        f"spans, cap at 15 stars) counted in its total; secretsweeper's Zig core fuses search+mask "
        f"natively. `correct` checks byte-identical output against secretsweeper's own result."
    )
    a("")
    lines.extend(render_bar_chart(available))
    a("| Engine | min | avg | min throughput | vs. fastest | correct |")
    a("|---|---:|---:|---:|---:|:---:|")
    for name, r in available:
        vs_fastest = f"{r['min_ms'] / fastest_min:.2f}x" if fastest_min else "-"
        correct_mark = "✅" if r["correct"] else "❌"
        version = f" `{r['version']}`" if r.get("version") else ""
        a(
            f"| {name}{version} | {r['min_ms']:.1f} ms | {r['avg_ms']:.1f} ms | "
            f"{r['min_mb_s']:.1f} MB/s | {vs_fastest} | {correct_mark} |"
        )
    a("")

    total_pattern_bytes = sum(manifest["secret_lengths"]) + sum(manifest["pem_lengths"])
    dfa_cap = _dfa_memory_cap_mib()
    a("## Notes")
    a("")
    a(
        f"- **Pattern set size vs. the DFA path.** secretsweeper dispatches through a "
        f"byte-class-compressed DFA when the pattern set fits `Aho.DFA_MEMORY_CAP` "
        f"(currently **{dfa_cap}**, `src/aho.zig`), falling back to a classic "
        f"trie/fail-link walk otherwise - both are correct, but the DFA is usually "
        f"faster for small-to-moderate pattern sets. This run's {data['n_patterns']} "
        f"patterns (~{total_pattern_bytes / 1024:.1f} KiB total) comfortably fit under "
        f"the cap, so this benchmark exercises the DFA path specifically. A much larger "
        f"or more numerous pattern set can exceed the cap and fall back - re-run against "
        f"your own patterns if that distinction matters for your use case."
    )
    a(
        "- **This corpus is a best case for the bigram gate.** The DFA dispatch skips a "
        "byte entirely (no `dfa_table`/`dfa_match` lookup at all) whenever it's at the "
        "root and the next two bytes provably can't start any pattern - a large win when "
        "matches are sparse (this corpus: real matches roughly every ~370 bytes), since "
        "most of the file never leaves the root state. Corpora with frequent or "
        "back-to-back matches spend less time at the root and benefit less (verified: no "
        "regression on an all-matching synthetic corpus, only reduced upside)."
    )
    a(
        "- **Rebuild before re-running after a source change.** An editable install "
        "(`pip install -e .`) can leave a stale compiled library sitting in the "
        "`secretsweeper/` source directory that shadows a freshly rebuilt one in "
        "site-packages. After changing anything under `src/`, run `uv pip install -e . "
        "--reinstall` and, if in doubt, copy `zig-out/lib/{libsecretsweeper.dylib or "
        ".so,_native.abi3.so}` into `secretsweeper/` directly before benchmarking - "
        "otherwise you may be measuring an old build without realizing it."
    )
    a(
        "- **Single-machine, single-run numbers.** These are wall-clock measurements on "
        "one machine at one point in time (see **Machine**, above) - thermal "
        "throttling, background load, and machine-to-machine variance are all real. "
        "Treat cross-run deltas smaller than ~10-15% as noise unless reproduced across "
        "multiple separate invocations."
    )
    a("")

    unavailable = [(name, r) for name, r in results.items() if not r["available"]]
    if unavailable:
        a("<details><summary>Unavailable on this run</summary>")
        a("")
        for name, r in unavailable:
            a(f"- **{name}**: {r['note']}")
        a("")
        a("</details>")
        a("")

    return "\n".join(lines) + "\n"


def main() -> None:
    with (DATA_DIR / "results.json").open() as f:
        data = json.load(f)
    sysinfo = collect_system_info()
    markdown = render_markdown(data, sysinfo)
    OUT_PATH.write_text(markdown)
    print(f"Wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
