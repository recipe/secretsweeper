#!/usr/bin/env sh

set -e

echo "Installing poetry..."
pip install poetry

echo "Creating a symlink to the pydust library..."
PYDUST_PATH=`python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])'`/pydust
ls -al $PYDUST_PATH

ln -sf $PYDUST_PATH pydust
ls -al pydust

echo "Installing dependencies..."
poetry install

pip freze
