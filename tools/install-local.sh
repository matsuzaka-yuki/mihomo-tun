#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="LyraVoid/mihomo-tun"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
SOURCE_DIR="$DATA_HOME/noctalia/plugins"
DEST="$SOURCE_DIR/mihomo-tun"
BACKUP_DIR="$STATE_HOME/noctalia/plugin-backups"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

if ! command -v noctalia >/dev/null 2>&1; then
  printf 'noctalia command not found\n' >&2
  exit 1
fi

mkdir -p "$SOURCE_DIR" "$BACKUP_DIR"

if [ -e "$DEST" ]; then
  mv "$DEST" "$BACKUP_DIR/mihomo-tun.$TIMESTAMP"
  printf 'Backed up existing plugin to %s\n' "$BACKUP_DIR/mihomo-tun.$TIMESTAMP"
fi

mkdir -p "$DEST/scripts" "$DEST/translations"
cp "$ROOT/plugin.toml" "$DEST/plugin.toml"
cp "$ROOT/panel.luau" "$DEST/panel.luau"
cp "$ROOT/widget.luau" "$DEST/widget.luau"
cp "$ROOT/service.luau" "$DEST/service.luau"
cp "$ROOT/shortcut.luau" "$DEST/shortcut.luau"
cp "$ROOT/scripts/mihomo-ctl.py" "$DEST/scripts/mihomo-ctl.py"
cp "$ROOT/scripts/configure-direct-rules.py" "$DEST/scripts/configure-direct-rules.py"
cp "$ROOT/scripts/apply-subscription-change.py" "$DEST/scripts/apply-subscription-change.py"
cp "$ROOT/translations/en.json" "$DEST/translations/en.json"
cp "$ROOT/translations/zh-Hans.json" "$DEST/translations/zh-Hans.json"
chmod 755 "$DEST/scripts/mihomo-ctl.py"
chmod 755 "$DEST/scripts/configure-direct-rules.py"
chmod 755 "$DEST/scripts/apply-subscription-change.py"

if ! noctalia msg plugins source list 2>/dev/null | grep -q '^localdev '; then
  noctalia msg plugins source add localdev path "$SOURCE_DIR"
fi

noctalia msg plugins enable "$PLUGIN_ID"
noctalia msg config-reload

printf 'Installed %s to %s\n' "$PLUGIN_ID" "$DEST"
printf 'Restart Noctalia if the Luau entries are not reloaded immediately.\n'
