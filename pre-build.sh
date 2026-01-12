#!/usr/bin/env sh

set -e


echo "Installing uv..."
curl -LsSf https://astral.sh/uv/0.8.22/install.sh | sh

echo "Installing dependencies..."
uv sync --no-install-project

echo "Creating a symlink to the pydust library..."
PYDUST_PATH=`python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])'`/pydust
ln -sf $PYDUST_PATH ./pydust
ls -al ./pydust

#echo "Installing poetry..."
#pip install poetry
#
#echo "Installing dependencies..."
#poetry install --no-root
#
#pip freeze
#
#echo "Creating a symlink to the pydust library..."
#PYDUST_PATH=`python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])'`/pydust
#ls -al $PYDUST_PATH
#
#ln -sf $PYDUST_PATH pydust
#ls -al pydust
