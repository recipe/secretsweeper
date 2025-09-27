# Secretsweeper

Secretsweeper is a fast, in-memory secret-sanitizing Python module written in Zig, designed for speed.

```shell 
» python          
Python 3.13.7 (main, Aug 14 2025, 11:12:11) [Clang 17.0.0 (clang-1700.0.13.3)] on darwin
Type "help", "copyright", "credits" or "license" for more information.
>>> import secretsweeper
>>> print(secretsweeper.mask(b"Hello, Secret Sweeper!", (b'Secret', b'Sweeper'])))
>>>  b'Hello, ****** *******!' 
```
