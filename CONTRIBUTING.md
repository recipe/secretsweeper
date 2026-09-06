# Contributing

secretsweeper is a Python package whose core is a shared library written in Zig
(`src/`). Building it locally needs no system Zig: the pinned `ziglang`
wheel is installed automatically as a build requirement and as a dev dependency.

## Prerequisites

- `git`
- [uv](https://docs.astral.sh/uv/) — manages the virtualenv, Python, and all
  dependencies:

  ```bash
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ```

  uv downloads a suitable Python on its own if none is installed.

## Set up a fresh checkout

```bash
git clone https://github.com/recipe/secretsweeper.git
cd secretsweeper
uv sync
```

`uv sync` creates `.venv`, installs the `dev` dependency group (pytest, ruff, ty,
pre-commit, ziglang) and installs secretsweeper itself in editable mode. The
editable install runs the hatch build hook (`hatch_build.py`), which compiles the
Zig library into `zig-out/lib/` and bundles the shared library and extension
module into `.venv/.../site-packages/secretsweeper/`. The package finds them
there even though the editable install imports the Python sources from the
source tree.

uv caches the build: deleting `.venv` or `zig-out/` and running `uv sync` again
installs the cached wheel without recompiling, which is fine. Stale copies of
`libsecretsweeper.*`/`_native.abi3.so` inside `secretsweeper/` (from older
workflows) would shadow the fresh build, so delete them if present.

Optionally install the git hooks (ruff and ty run on every commit):

```bash
uv run pre-commit install
```

## Run the tests

```bash
uv run pytest                          # Python tests
uv run python -m ziglang build test    # Zig unit tests
```

`tests/conftest.py` runs every Python test twice: once against the DFA
automaton and once against the classic goto/fail-link fallback (ids `dfa` /
`fallback`). To force the fallback path outside the test suite set
`SECRET_SWEEPER_NO_DFA_AUTOMATON=1`.

## Lint and type check

The same checks CI runs (`.github/workflows/ci.yml`):

```bash
uv run ruff format --check .
uv run ruff check .
uv run ty check
```

## Rebuild after changing Zig sources

Nothing to do by hand. `[tool.uv].cache-keys` in `pyproject.toml` lists
`src/**/*.zig`, `build.zig`, `hatch_build.py` and `pyproject.toml`, so `uv run`
and `uv sync` notice when any of them changed and rebuild the editable install
(rerunning the Zig build) before your command runs:

```bash
uv run pytest      # rebuilds the library first if Zig sources changed
```

Note that `uv run python -m ziglang build test` only compiles and runs the Zig
test binary; it does not touch the library Python loads. To force a rebuild
regardless of timestamps:

```bash
uv sync --reinstall-package secretsweeper
```

Set `SECRET_SWEEPER_ZIG=/path/to/zig` to build with a specific Zig binary
instead of the bundled wheel.

## Build a wheel or sdist

```bash
uv build
```

Release wheels are produced by cibuildwheel in CI; see the `build` job in
`.github/workflows/ci.yml` for the per-platform flags.

## Releasing

Pushing a tag triggers the release pipeline in `.github/workflows/ci.yml`: it
builds wheels for every platform, runs the tests against them, builds the sdist
and publishes everything to PyPI via trusted publishing. CI refuses a tag that
does not name the version in `pyproject.toml` (compared as PEP 440 versions, so
the tag `0.0.1-alpha.9` matches `0.0.1a9`).

1. Bump the version. This updates `pyproject.toml` and `uv.lock` together and
   re-syncs `.venv`:

   ```bash
   uv version --bump alpha     # 0.0.1a8 -> 0.0.1a9; also: patch, minor, major, stable, rc
   uv version 0.1.0            # or set it explicitly
   ```

2. In `CHANGELOG.md`, rename the `[Unreleased]` heading to the new version and
   date, e.g. `## [0.0.1-alpha.9] - 2026-09-05`, and start a fresh empty
   `## [Unreleased]` above it.

3. Optional: if the change affects performance, regenerate
   `benchmarks/RESULTS.md` (see below) so it reports the new version.

4. Commit, tag and push:

   ```bash
   git commit -am "Release 0.0.1a9"
   git tag 0.0.1-alpha.9
   git push origin main 0.0.1-alpha.9
   ```

No local package build is needed; CI builds and publishes the artifacts.

## Benchmarks

```bash
uv sync --group benchmark
uv run --group benchmark python benchmarks/gen_corpus.py
uv run --group benchmark python benchmarks/bench.py --rounds 5
uv run --group benchmark python benchmarks/report.py
```

See `benchmarks/README.md` and `benchmarks/RESULTS.md`.
