#!/usr/bin/env sh

set -e

echo "Installing uv..."
curl -LsSf https://astral.sh/uv/0.8.22/install.sh | sh
source $HOME/.local/bin/env

echo "Installing dependencies..."
uv sync --no-install-project
. .venv/bin/activate

echo "Creating a symlink to the pydust library..."
PYDUST_PATH=`python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])'`/pydust
ln -sf $PYDUST_PATH ./pydust
ls -al ./pydust

echo "Building the package..."
poetry build

echo "Running tests..."
pytest test -v
