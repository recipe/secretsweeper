#!/usr/bin/env sh

set -e


echo "Installing poetry"
pip install poetry==2.2.1 ziggy-pydust==0.26.0

echo "Creating a symlink to the pydust library..."
PYDUST_PATH=`python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])'`/pydust
ln -sf $PYDUST_PATH ./pydust
ls -al ./pydust

#echo "Installing uv..."
#curl -LsSf https://astral.sh/uv/0.8.22/install.sh | sh
#source $HOME/.local/bin/env
#
#echo "Installing dependencies..."
#uv sync --no-install-project
#. .venv/bin/activate
#
#echo "Creating a symlink to the pydust library..."
#PYDUST_PATH=`python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])'`/pydust
#ln -sf $PYDUST_PATH ./pydust
#ls -al ./pydust
#
#echo "Building the package..."
#poetry build
#ls -al ./dist
#
#echo "Running tests..."
#WHEEL=$(find ./dist -maxdepth 1 -type f -name 'secretsweeper-*.whl' | head -n 1)
#pip install "$WHEEL"
#pytest test -v -k "not pydust-test-build"
