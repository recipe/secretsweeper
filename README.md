
```zig
▞▀▖            ▐  ▞▀▖                   
▚▄ ▞▀▖▞▀▖▙▀▖▞▀▖▜▀ ▚▄ ▌  ▌▞▀▖▞▀▖▛▀▖▞▀▖▙▀▖
▖ ▌▛▀ ▌ ▖▌  ▛▀ ▐ ▖▖ ▌▐▐▐ ▛▀ ▛▀ ▙▄▘▛▀ ▌  
▝▀ ▝▀▘▝▀ ▘  ▝▀▘ ▀ ▝▀  ▘▘ ▝▀▘▝▀▘▌  ▝▀▘▘  
```

[![CI](https://github.com/recipe/secretsweeper/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/recipe/secretsweeper/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/recipe/secretsweeper.svg)](https://github.com/recipe/secretsweeper/blob/main/LICENSE)
[![PyPI Version](https://img.shields.io/pypi/v/secretsweeper.svg)](https://pypi.org/project/secretsweeper/)
[![Compatiable Python versions](https://img.shields.io/pypi/pyversions/secretsweeper.svg?style=flat-square)](https://pypi.python.org/pypi/secretsweeper/)

SecretSweeper is a fast, in-memory secret-sanitizing Python module written in Zig, designed for speed.

---

## About

> Just want to remove all secret variables from the terraform plan output or any large file? SecretSweeper is here to help!
 
SecretSweeper as a Python library that can mask or remove known secrets from the byte literals, files, or any file-like objects (`io.BinaryIO`).

- Written in Zig and has no third party dependencies. It leverages the stability of the Python Limited C API to create a single binary extension.
- Can wrap a file descriptor to read and sanitize data directly from the stream.
- Works well with multi-line secrets.

## Example

To mask secrets from the `bytes` literal:

```shell 
» python          
>>> import secretsweeper
>>> print(secretsweeper.mask(b"Hello, Secret Sweeper!", (b'Secret', b'Sweeper')))
>>>  b'Hello, ****** *******!' 
```
Secrets may be completely removed by providing a third argument, `limit=0`, which specifies the maximum number of masking characters:

```shell 
» python          
>>> import secretsweeper
>>> print(secretsweeper.mask(b"Moby Dick!", [b" Dick"], limit=0))
>>> b'Moby!' 
```
To effectively mask a large text:

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

More examples in [tests](tests/test_secretsweeper.py).

## Getting involved

🌱 Contributions are always welcome — whether it’s a bug report, a small fix, or a big idea.
If something here sparks your curiosity, jump in and help shape it. Open an issue or a pull request — even small contributions make a difference.

## License

This is free software: you can redistribute it and/or modify it under the terms of the MIT License. A copy of this license is provided in [LICENSE](LICENSE).


