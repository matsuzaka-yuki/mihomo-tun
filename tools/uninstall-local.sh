#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="LyraVoid/mihomo-tun"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
DEST="$DATA_HOME/noctalia/plugins/mihomo-tun"

if command -v noctalia >/dev/null 2>&1; then
  noctalia msg plugins disable "$PLUGIN_ID" >/dev/null 2>&1 || true
fi

rm -rf "$DEST"
printf 'Removed %s from %s\n' "$PLUGIN_ID" "$DEST"
