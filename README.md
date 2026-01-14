# Secretsweeper

[![CI](https://github.com/recipe/secretsweeper/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/recipe/secretsweeper/actions/workflows/ci.yml)

Secretsweeper is a fast, in-memory secret-sanitizing Python module written in Zig, designed for speed.

```shell 
» python          
>>> import secretsweeper
>>> print(secretsweeper.mask(b"Hello, Secret Sweeper!", (b'Secret', b'Sweeper'])))
>>>  b'Hello, ****** *******!' 
```
