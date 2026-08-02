"""Generates a synthetic ~100 MiB corpus with embedded secrets and fake PEM blocks.

Deterministic (fixed seed): every run produces byte-identical output, so repeat
benchmark passes (e.g. after a masking-path optimization) compare like-for-like.
Output goes to `benchmarks/data/` (gitignored - regenerate it instead of
committing a 100 MiB binary): `corpus.bin`, `patterns.pkl` (a pickled
`list[bytes]`), and `manifest.json` (human-readable summary of what got
embedded, consumed by `report.py`).
"""

import base64
import json
import pathlib
import pickle
import random
import string

SEED = 20260731
TARGET_SIZE = 100 * 1024 * 1024
DATA_DIR = pathlib.Path(__file__).parent / "data"
rng = random.Random(SEED)

# Filler text: synthetic log lines / terraform-plan-ish / config dump lines.

SERVICES = ["checkout", "billing", "auth", "worker", "gateway", "scheduler", "ingest", "notifier"]
LEVELS = ["INFO", "DEBUG", "WARN", "ERROR"]
WORDS = (
    "job request response cache miss hit retry timeout connection pool lease "
    "renew lease expired queue depth backlog flush commit rollback shard "
    "replica leader follower heartbeat metric latency p99 p50 throughput"
).split()
RESOURCES = ["aws_subnet", "aws_instance", "aws_security_group", "aws_iam_role", "aws_s3_bucket", "aws_lambda_function"]
ENVS = ["dev", "staging", "production"]


def _rand_hex(n: int) -> str:
    return "".join(rng.choice("0123456789abcdef") for _ in range(n))


def _log_line() -> str:
    ts = f"2026-07-{rng.randint(1, 31):02d}T{rng.randint(0, 23):02d}:{rng.randint(0, 59):02d}:{rng.randint(0, 59):02d}Z"
    svc = rng.choice(SERVICES)
    lvl = rng.choice(LEVELS)
    words = " ".join(rng.choice(WORDS) for _ in range(rng.randint(3, 8)))
    reqid = _rand_hex(16)
    ms = rng.randint(1, 4000)
    return f"{ts} {lvl:5s} {svc}: {words} request_id={reqid} duration_ms={ms}\n"


def _tf_line() -> str:
    res = rng.choice(RESOURCES)
    env = rng.choice(ENVS)
    idx = rng.randint(0, 9)
    rid = _rand_hex(17)
    return f'module.{env}.{res}[{idx}]: Modifying... [id={rid}]\n  + tags = {{"env" = "{env}"}}\n'


def build_filler_lines(target_size: int) -> list[bytes]:
    lines: list[bytes] = []
    size = 0
    while size < target_size:
        line = (_log_line() if rng.random() < 0.7 else _tf_line()).encode()
        lines.append(line)
        size += len(line)
    return lines


# Secrets: realistic-looking, random length (<=1KB), various "kinds".

SECRET_TEMPLATES = [
    ("AKIA", string.ascii_uppercase + string.digits, "export AWS_ACCESS_KEY_ID={}\n"),
    ("", string.ascii_letters + string.digits + "/+", "export AWS_SECRET_ACCESS_KEY={}\n"),
    ("ghp_", string.ascii_letters + string.digits, "git remote set-url origin https://{}@github.com/acme/repo.git\n"),
    ("xoxb-", string.digits, "SLACK_BOT_TOKEN={}\n"),
    ("sk_live_", string.ascii_letters + string.digits, "STRIPE_SECRET_KEY={}\n"),
    (
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.",
        string.ascii_letters + string.digits + "._-",
        "Authorization: Bearer {}\n",
    ),
    ("", string.ascii_letters + string.digits + "!@#%", "DATABASE_URL=postgres://admin:{}@db.internal:5432/app\n"),
    ("", "0123456789abcdef", "api_key={}\n"),
    ("client_secret_", string.ascii_letters + string.digits, "OAUTH_CLIENT_SECRET={}\n"),
    ("ya29.", string.ascii_letters + string.digits + "-_", "GOOGLE_OAUTH_TOKEN={}\n"),
]

PEM_KINDS = ["RSA PRIVATE KEY", "CERTIFICATE", "OPENSSH PRIVATE KEY", "EC PRIVATE KEY"]


def make_secret() -> tuple[bytes, bytes]:
    """Return (embedded_line_bytes, secret_value_bytes)."""
    prefix, charset, line_tpl = rng.choice(SECRET_TEMPLATES)
    total_len = rng.randint(24, 1024)
    suffix_len = max(8, total_len - len(prefix))
    suffix = "".join(rng.choice(charset) for _ in range(suffix_len))
    value = (prefix + suffix).encode()
    return line_tpl.format(value.decode()).encode(), value


def make_pem_block(kind: str) -> bytes:
    raw_len = rng.randint(600, 1400)
    raw = bytes(rng.getrandbits(8) for _ in range(raw_len))
    body = base64.encodebytes(raw)  # wraps at 76 cols, realistic PEM look
    return f"-----BEGIN {kind}-----\n".encode() + body + f"-----END {kind}-----\n".encode()


def generate() -> dict:
    """Writes corpus.bin/patterns.pkl/manifest.json to DATA_DIR and returns the manifest."""
    lines = build_filler_lines(TARGET_SIZE)

    n_secrets = rng.randint(10, 20)
    secret_lines_and_values = [make_secret() for _ in range(n_secrets)]

    n_pem = rng.randint(3, 4)
    pem_kinds = rng.sample(PEM_KINDS, k=n_pem)
    pem_blocks = [make_pem_block(k) for k in pem_kinds]

    patterns: list[bytes] = [v for _, v in secret_lines_and_values] + pem_blocks

    # Insert each secret line / PEM block at a random line boundary.
    inserts: list[bytes] = [line for line, _ in secret_lines_and_values]
    for kind, block in zip(pem_kinds, pem_blocks):
        inserts.append(f"Loading TLS material ({kind}):\n".encode() + block)

    rng.shuffle(inserts)
    for chunk in inserts:
        pos = rng.randint(0, len(lines))
        lines.insert(pos, chunk)

    corpus = b"".join(lines)

    for p in patterns:
        assert corpus.count(p) == 1, f"pattern not embedded exactly once: {p[:40]!r}..."

    DATA_DIR.mkdir(exist_ok=True)
    (DATA_DIR / "corpus.bin").write_bytes(corpus)
    with (DATA_DIR / "patterns.pkl").open("wb") as f:
        pickle.dump(patterns, f)

    manifest = {
        "seed": SEED,
        "corpus_size": len(corpus),
        "n_secrets": n_secrets,
        "n_pem": n_pem,
        "pem_kinds": pem_kinds,
        "secret_lengths": sorted(len(v) for _, v in secret_lines_and_values),
        "pem_lengths": sorted(len(b) for b in pem_blocks),
    }
    with (DATA_DIR / "manifest.json").open("w") as f:
        json.dump(manifest, f, indent=2)
    return manifest


def main() -> None:
    print("Generating filler text and embedding secrets/PEM blocks...")
    manifest = generate()
    print(f"Corpus: {manifest['corpus_size'] / 1024 / 1024:.2f} MiB")
    pem_kinds = ", ".join(manifest["pem_kinds"])
    print(f"Embedded {manifest['n_secrets']} secrets + {manifest['n_pem']} PEM blocks ({pem_kinds})")
    print(f"Written to {DATA_DIR}")


if __name__ == "__main__":
    main()
