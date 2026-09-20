<div align="center">
  <img src="https://raw.githubusercontent.com/recipe/secretsweeper/main/secret-sweeper.png" alt="SecretSweeper" width="260"/>
  <p>&nbsp;</p>

[![CI](https://github.com/recipe/secretsweeper/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/recipe/secretsweeper/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/recipe/secretsweeper.svg)](https://github.com/recipe/secretsweeper/blob/main/LICENSE)
[![PyPI Version](https://img.shields.io/pypi/v/secretsweeper.svg)](https://pypi.org/project/secretsweeper/)
[![Compatible Python versions](https://img.shields.io/pypi/pyversions/secretsweeper.svg?style=flat-square)](https://pypi.python.org/pypi/secretsweeper/)

SecretSweeper is a ⚡ fast, in-memory secret-sanitizing Python module written in Zig, designed for 🚀 speed.
</div>

---

## About

> 💡 Need to scrub known secrets from a log, a build output or any large file before someone reads it? SecretSweeper is here to help!

SecretSweeper is a Python library that can mask or remove known secrets – API keys, 
tokens, credentials – from byte literals, files, or any file-like objects (`io.BinaryIO`). 

- Written in Zig with no third-party dependencies. 
- Ships as a CPython extension module built against the stable ABI, so one wheel per platform covers every supported Python version.
- Can wrap a file descriptor to read and sanitize data directly from the stream.
- Works well with multi-line secrets.

## Installation

```bash
pip install secretsweeper 
```

Free-threaded Python 3.15+ wheels use `abi3t` and require pip 26.1 or newer
(or a recent uv). Upgrade pip with `python -m pip install --upgrade pip` if an
older installer attempts a source build.

## Examples

✨ To mask secrets from the `bytes` literal:

```python          
import secretsweeper
print(secretsweeper.mask(b"Hello, Secret Sweeper!", (b'Secret', b'Sweeper')))
# b'Hello, ****** *******!' 
```

Secrets may be completely removed by providing a third argument, `limit=0`, which specifies the maximum number of masking characters:

```python          
import secretsweeper
print(secretsweeper.mask(b"Moby Dick!", [b" Dick"], limit=0))
# b'Moby!' 
```
To effectively mask all secrets in a large text:

```python 
import urllib.request
import secretsweeper

url = "https://raw.githubusercontent.com/annotation/mobydick/main/txt/plain.txt"

with urllib.request.urlopen(url) as src, open("sanitized.txt", "wb") as dest:
    stream = secretsweeper.StreamWrapper(
        src, (b"Dick", b"savage", b"cannibal", b"harpooner")
    )
    for line in stream:
        dest.write(line)
```

Matching is byte-exact. A secret is masked only where it appears in the input as exactly the bytes given as a pattern. A base64 or URL-encoded form, a JSON-escaped one (`\"`, `\n`, `\u00e9`) or a value split across wrapped lines are all different byte sequences, so if the data you scan can contain them, add each variant as its own pattern. Keep in mind that a very short pattern, such as a single digit or a common word, masks every occurrence in the input.

More examples are in [tests](https://github.com/recipe/secretsweeper/blob/main/tests/test_secretsweeper.py).

## Performance

SecretSweeper's Zig core is within a few percent of the fastest Rust-backed Aho-Corasick implementation available for Python, and multiple times faster than stdlib `re` or other pure-Python/C-extension alternatives. See [benchmarks/RESULTS.md](https://github.com/recipe/secretsweeper/blob/main/benchmarks/RESULTS.md) for the full, reproducible comparison (methodology, corpus, and machine specs included).

## Getting involved

🌱 Contributions are always welcome – whether it’s a bug report, a small fix, or a big idea. If something here sparks your curiosity, jump in and help shape it. Open an issue or a pull request – even small contributions make a difference. See [CONTRIBUTING.md](https://github.com/recipe/secretsweeper/blob/main/CONTRIBUTING.md) for how to set up a development environment and run the tests.

## License

🪪 This is free software: you can redistribute it and/or modify it under the terms of the MIT License. A copy of this license is provided in [LICENSE](https://github.com/recipe/secretsweeper/blob/main/LICENSE).


