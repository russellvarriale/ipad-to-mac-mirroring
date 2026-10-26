#!/bin/zsh
# Copyright (c) 2026 Russell Varriale (https://github.com/russellvarriale/ipad-to-mac-mirroring)
# SPDX-License-Identifier: MIT
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
python3 "$PROJECT_ROOT/scripts/native/rebuild_backend.py"
mkdir -p "$PROJECT_ROOT/vendor"
if [[ -d "$PROJECT_ROOT/vendor/Wireless" ]]; then
  rm -rf "$PROJECT_ROOT/vendor/Wireless"
fi
cp -R -X "$PROJECT_ROOT/scripts/native/bundle/Wireless" "$PROJECT_ROOT/vendor/Wireless"
print -r -- "Wireless runtime built. Run ./build.sh from the project directory."
