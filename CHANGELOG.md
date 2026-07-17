# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.1-alpha.6] - 2026-07-16

### Fixed

- `Illegal instruction` (SIGILL) crash on Linux CPUs older than the CI build
  machines: the `hatch` build hook now passes `-Dcpu=baseline` to `zig` on Linux,
  so wheels use the architecture's baseline instruction set instead of the
  build host's full feature set (`aarch64` wheels built on `Neoverse N2` runners
  contained SVE instructions, crashing on Apple Silicon under Docker and
  Graviton 1/2).

## [0.0.1-alpha.5] - 2026-07-06

### Added

- Python version trove classifiers so the PyPI pyversions badge resolves
  (it reads classifiers, not `requires-python`).

### Changed

- Build macOS wheels against `MACOSX_DEPLOYMENT_TARGET=11.0`: the hatch build
  hook now passes it to zig as the target's minimum macOS version instead of
  pinning wheels to the CI runner's OS (previously `15.7`/`14.8`), so wheels
  install on macOS 11+.
- Updated GitHub Actions pins to Node 24 releases: `ruff-action` `v4.1.0`,
  `upload-artifact` `v7.0.1`, `download-artifact` `v8.0.1`.

### Security

- Bumped `pytest` to `9.1.1` (CVE-2025-71176) and transitive `pygments` to
  `2.20.0` (CVE-2026-4539).

## [0.0.1-alpha.4] - 2026-07-05

### Added

- Support for Windows.

### Changed

- Removed the `ziggy-pydust` dependency
  ([#8](https://github.com/recipe/secretsweeper/pull/8)): the binding layer is
  now a plain C-ABI shared library driven by stdlib `ctypes`.
- Bumped zig version to 0.16.0.
- Started using Hatch for the build.

### Fixed

- Unbounded memory retention in streaming mode.
- Memory-unsafe concurrent use of one `StreamWrapper`.
- Trie memory amplification, using the Adaptive Radix Tree (ART) node-classing
  idea.

## [0.0.1-alpha.3] - 2026-05-24

### Changed

- Corrected README and project page on PyPI
  ([#7](https://github.com/recipe/secretsweeper/pull/7)).

## [0.0.1-alpha.1] - 2026-01-26

### Added

- Initial release: a lightweight tool for detecting sensitive values in large
  texts and files.
- Fast, low-level implementation based on the Aho–Corasick algorithm.
- Designed to integrate cleanly with Python workflows.
- Scan data directly from `BinaryIO` streams.
- Enables use with in-memory buffers, file-like objects, and streaming
  pipelines.

[unreleased]: https://github.com/recipe/secretsweeper/compare/0.0.1-alpha.6...HEAD
[0.0.1-alpha.5]: https://github.com/recipe/secretsweeper/compare/0.0.1-alpha.5...0.0.1-alpha.6
[0.0.1-alpha.5]: https://github.com/recipe/secretsweeper/compare/0.0.1-alpha.4...0.0.1-alpha.5
[0.0.1-alpha.4]: https://github.com/recipe/secretsweeper/compare/0.0.1-alpha.3...0.0.1-alpha.4
[0.0.1-alpha.3]: https://github.com/recipe/secretsweeper/compare/0.0.1-alpha.1...0.0.1-alpha.3
[0.0.1-alpha.1]: https://github.com/recipe/secretsweeper/releases/tag/0.0.1-alpha.1
