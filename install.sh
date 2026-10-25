#!/bin/sh
# Installs the statusline into ~/.claude (or $CLAUDE_CONFIG_DIR) and merges
# its statusLine block into settings.json. Safe to re-run: settings are only
# rewritten (with a timestamped backup) when something actually changes.
# Registers the PostToolUse hook that meters Ideogram MCP calls, links
# ideogram-ledger into ~/.local/bin, and strips the PreToolUse/Stop hooks left
# by the old fetch-usage.sh setup; any other hooks are kept.
set -e

repo=$(cd "$(dirname "$0")" && pwd)
dest=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
settings="$dest/settings.json"

if ! command -v jq > /dev/null 2>&1; then
  echo "install.sh: jq is required (the statusline needs it too)" >&2
  exit 1
fi

mkdir -p "$dest"
for f in statusline-command.sh usage-fetch.sh ideogram-ledger ideogram-hook.sh; do
  cp "$repo/$f" "$dest/$f"
  chmod +x "$dest/$f"
  echo "installed $dest/$f"
done

bin=${CLAUDE_WATCH_BIN_DIR:-$HOME/.local/bin}
mkdir -p "$bin"
ln -sf "$dest/ideogram-ledger" "$bin/ideogram-ledger"
echo "linked $bin/ideogram-ledger"

hook_cmd="sh $dest/ideogram-hook.sh"
[ -f "$settings" ] || echo '{}' > "$settings.new"

tmp=$(mktemp "$settings.XXXXXX")
trap 'rm -f "$tmp"' EXIT
src="$settings"; [ -f "$settings" ] || src="$settings.new"
jq --slurpfile repo "$repo/settings.json" --arg hook "$hook_cmd" '
  .statusLine = $repo[0].statusLine
  | .hooks.PostToolUse = ([.hooks.PostToolUse[]? | select(
        [.hooks[]?.command // "" | contains("ideogram-hook.sh")] | any | not)]
      + [{matcher: "mcp__ideogram__.*", hooks: [{type: "command", command: $hook, timeout: 10}]}])
  | if .hooks then
      .hooks |= (
        with_entries(.value |= map(select(
          [.hooks[]?.command // "" | contains("fetch-usage.sh")] | any | not
        )))
        | with_entries(select(.value | length > 0))
      )
      | if .hooks == {} then del(.hooks) else . end
    else . end
' "$src" > "$tmp"
rm -f "$settings.new"

if [ ! -f "$settings" ]; then
  mv "$tmp" "$settings"
  echo "created $settings"
elif jq -e --slurpfile new "$tmp" '. == $new[0]' "$settings" > /dev/null; then
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
