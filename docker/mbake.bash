#!/usr/bin/env bash
#
# Script Name: mbake
# Description: Runs the image's mbake, answering --version itself. mbake asks PyPI for a newer release whenever it
#              prints its version, which make lint does twice, and updates stay off in the image.
# Usage: mbake [arguments...]
#
set -euo pipefail

if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
  printf 'mbake version %s\n' "$(/opt/mbake/bin/python -c 'import importlib.metadata; print(importlib.metadata.version("mbake"))')"
  exit 0
fi
exec /opt/mbake/bin/mbake "$@"
