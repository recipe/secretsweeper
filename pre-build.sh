#!/usr/bin/env sh

set -e

pip install poetry
ln -sf `python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])'`/pydust pydust
poetry install
