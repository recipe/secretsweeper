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

> 💡 Just want to remove all secret variables from the terraform plan output or any large file? SecretSweeper is here to help! In a shared Terraform workspace, anyone who can edit a module can add `output "x" { value = var.db_password }` – and suddenly everyone who can run plan can read a secret they were never granted access to. SecretSweeper wraps your plan/apply output stream so known secrets get redacted no matter how they end up in it, even from output blocks you didn't write.

SecretSweeper is a Python library that can mask or remove known secrets – API keys, 
tokens, credentials – from byte literals, files, or any file-like objects (`io.BinaryIO`). 

- Written in Zig with no third-party dependencies. The core is a plain C-ABI shared library driven through the standard library `ctypes` module, so a single binary works across Python versions.
- Can wrap a file descriptor to read and sanitize data directly from the stream.
- Works well with multi-line secrets.

## Installation

```bash
pip install secretsweeper 
```

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

A more realistic scenario: any multi-tenant Terraform/OpenTofu setup, where someone with plan access shouldn't see secrets they weren't granted:

```python
import json, subprocess, secretsweeper

# Plan as the trusted process. OpenTofu does NOT redact sensitive
# values in JSON output, unlike its human-readable plan text.
subprocess.run(["tofu", "plan", "-out=tfplan"], check=True)
plan = json.loads(subprocess.run(
    ["tofu", "show", "-json", "tfplan"], capture_output=True, check=True
).stdout)

# Collect every value OpenTofu marked sensitive - variables,
# resource attributes, outputs - however it got there.
known_secrets = {
    str(v["value"]).encode()
    for v in plan.get("variables", {}).values() if v.get("sensitive")
}

# Only now render the plan a human will see - wrapped, so a leak
# via output blocks (e.g. a stray nonsensitive() call) still gets caught.
proc = subprocess.Popen(["tofu", "show", "tfplan"], stdout=subprocess.PIPE)
for line in secretsweeper.StreamWrapper(proc.stdout, tuple(known_secrets)):
    print(line)
```

The example above only walks top-level variables. Sensitive values nested inside maps, lists, or objects need a recursive walk of `after_sensitive`, since it mirrors the shape of `after`:

```python 
def collect_sensitive(value, marker):
    """Recursively collect leaf values OpenTofu marked sensitive.

    `marker` mirrors the shape of `value` (dict/list of bools) per
    the plan JSON format's after_sensitive/before_sensitive convention.
    """
    found = set()
    if isinstance(marker, dict) and isinstance(value, dict):
        for key, sub_marker in marker.items():
            if key in value:
                found |= collect_sensitive(value[key], sub_marker)
    elif isinstance(marker, list) and isinstance(value, list):
        for i, sub_marker in enumerate(marker):
            if i < len(value):
                found |= collect_sensitive(value[i], sub_marker)
    elif marker is True:
        found.add(str(value).encode())
    return found

known_secrets = set()

for var in plan.get("variables", {}).values():
    if var.get("sensitive"):
        known_secrets.add(str(var["value"]).encode())

for change in plan.get("resource_changes", []):
    after = change["change"].get("after") or {}
    after_sensitive = change["change"].get("after_sensitive") or {}
    known_secrets |= collect_sensitive(after, after_sensitive)

for out in plan.get("output_changes", {}).values():
    known_secrets |= collect_sensitive(out.get("after"), out.get("after_sensitive")) 
```

More examples are in [tests](tests/test_secretsweeper.py).

## Performance

SecretSweeper's Zig core is within a few percent of the fastest Rust-backed Aho-Corasick implementation available for Python, and multiple times faster than stdlib `re` or other pure-Python/C-extension alternatives. See [benchmarks/RESULTS.md](benchmarks/RESULTS.md) for the full, reproducible comparison (methodology, corpus, and machine specs included).

## Getting involved

🌱 Contributions are always welcome – whether it’s a bug report, a small fix, or a big idea. If something here sparks your curiosity, jump in and help shape it. Open an issue or a pull request – even small contributions make a difference.

## License

🪪 This is free software: you can redistribute it and/or modify it under the terms of the MIT License. A copy of this license is provided in [LICENSE](LICENSE).


