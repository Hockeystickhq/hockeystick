#!/bin/bash
# render.sh <html> <w> <h> <out> [scale]
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HTML="$1"; W="$2"; H="$3"; OUT="$4"; S="${5:-1}"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor="$S" \
  --window-size="$W,$H" \
  --virtual-time-budget=4000 \
  --screenshot="$OUT" "file://$PWD/$HTML" 2>/dev/null
ls -la "$OUT"
