#!/bin/sh
# Installs the statusline into ~/.claude (or $CLAUDE_CONFIG_DIR) and merges
# its statusLine block into settings.json. Safe to re-run: settings are only
# rewritten (with a timestamped backup) when something actually changes.
# Also strips the PreToolUse/Stop hooks left by the old fetch-usage.sh setup;
# any other hooks are kept.
set -e

repo=$(cd "$(dirname "$0")" && pwd)
dest=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
settings="$dest/settings.json"

if ! command -v jq > /dev/null 2>&1; then
  echo "install.sh: jq is required (the statusline needs it too)" >&2
  exit 1
fi

mkdir -p "$dest"
for f in statusline-command.sh usage-fetch.sh; do
  cp "$repo/$f" "$dest/$f"
  chmod +x "$dest/$f"
  echo "installed $dest/$f"
done

if [ ! -f "$settings" ]; then
  cp "$repo/settings.json" "$settings"
  echo "created $settings"
  exit 0
fi

tmp=$(mktemp "$settings.XXXXXX")
trap 'rm -f "$tmp"' EXIT
jq --slurpfile repo "$repo/settings.json" '
  .statusLine = $repo[0].statusLine
  | if .hooks then
      .hooks |= (
        with_entries(.value |= map(select(
          [.hooks[]?.command // "" | contains("fetch-usage.sh")] | any | not
        )))
        | with_entries(select(.value | length > 0))
      )
      | if .hooks == {} then del(.hooks) else . end
    else . end
' "$settings" > "$tmp"

if jq -e --slurpfile new "$tmp" '. == $new[0]' "$settings" > /dev/null; then
  echo "$settings already up to date"
else
  backup="$settings.bak-$(date +%Y%m%d%H%M%S)"
  cp "$settings" "$backup"
  mv "$tmp" "$settings"
  echo "updated $settings (backup: $backup)"
fi

if [ -f "$dest/fetch-usage.sh" ]; then
  echo "note: $dest/fetch-usage.sh is no longer used and can be deleted"
fi
