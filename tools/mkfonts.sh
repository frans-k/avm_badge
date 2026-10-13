#!/usr/bin/env bash
# Rebuild priv/fonts/*.uf from the licensed sources in assets/src/fonts.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

python3 tools/fontconvert.py assets/src/fonts/dogica/TTF/dogica.ttf 16 \
  priv/fonts/dogica.uf --mode mono
python3 tools/fontconvert.py assets/src/fonts/pixel_operator/PixelOperator.ttf 16 \
  priv/fonts/pixel_operator.uf --mode mono
python3 tools/fontconvert.py assets/src/fonts/w95fa/W95F.otf 38 \
  priv/fonts/w95fa.uf --mode mono

ls -l priv/fonts/
