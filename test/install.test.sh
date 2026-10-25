#!/bin/bash
# Tests for install.sh against a throwaway CLAUDE_CONFIG_DIR. Run: bash test/install.test.sh
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
install() { CLAUDE_CONFIG_DIR="$1" CLAUDE_WATCH_BIN_DIR="$1/bin" sh "$REPO/install.sh"; }
ideo_hooks() { jq '[.hooks.PostToolUse[]? | select(.hooks[].command | contains("ideogram-hook.sh"))] | length' "$1"; }

# --- fresh install: no settings.json yet ---
d="$TMP/fresh"
out=$(install "$d")
check "script copied"      '[ -x "$d/statusline-command.sh" ]'
check "script identical"   'cmp -s "$d/statusline-command.sh" "$REPO/statusline-command.sh"'
check "fetcher copied"     '[ -x "$d/usage-fetch.sh" ] && cmp -s "$d/usage-fetch.sh" "$REPO/usage-fetch.sh"'
check "ledger cli copied"  '[ -x "$d/ideogram-ledger" ] && [ -x "$d/ideogram-hook.sh" ]'
check "ledger cli linked"  '[ "$(readlink "$d/bin/ideogram-ledger")" = "$d/ideogram-ledger" ]'
check "cli runs via link"  'IDEOGRAM_LEDGER_DIR="$d/ig" "$d/bin/ideogram-ledger" status | jq -e ".credits_left == 2400" > /dev/null'
check "mcp hook registered" 'jq -e ".hooks.PostToolUse[0] | .matcher == \"mcp__ideogram__.*\" and .hooks[0].command == \"sh $d/ideogram-hook.sh\"" "$d/settings.json" > /dev/null'
check "no backup on create" '! ls "$d"/settings.json.bak-* > /dev/null 2>&1'
check "settings created"   'jq -e ".statusLine.refreshInterval == 30" "$d/settings.json" > /dev/null'
check "reports creation"   '[[ "$out" == *"created"* ]]'

# --- upgrade from the fetch-usage.sh setup, keeping unrelated settings/hooks ---
d="$TMP/upgrade"; mkdir -p "$d"
touch "$d/fetch-usage.sh"
cat > "$d/settings.json" <<'EOF'
{
  "model": "opus",
  "statusLine": {"type": "command", "command": "bash ~/.claude/statusline-command.sh"},
  "hooks": {
    "PreToolUse": [
      {"matcher": "", "hooks": [{"type": "command", "command": "bash ~/.claude/fetch-usage.sh > /dev/null 2>&1 &"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "my-guard.sh"}]}
    ],
    "Stop": [
      {"matcher": "", "hooks": [{"type": "command", "command": "bash ~/.claude/fetch-usage.sh > /dev/null 2>&1 &"}]}
    ]
  }
}
EOF
out=$(install "$d")
s="$d/settings.json"
check "unrelated setting kept"   'jq -e ".model == \"opus\"" "$s" > /dev/null'
check "refreshInterval added"    'jq -e ".statusLine.refreshInterval == 30" "$s" > /dev/null'
check "fetch-usage hooks gone"   '! grep -q fetch-usage "$s"'
check "other hook kept"          'jq -e ".hooks.PreToolUse | length == 1 and .[0].hooks[0].command == \"my-guard.sh\"" "$s" > /dev/null'
check "mcp hook added once"      '[ "$(ideo_hooks "$s")" -eq 1 ]'
check "empty Stop event removed" 'jq -e ".hooks | has(\"Stop\") | not" "$s" > /dev/null'
check "backup written"           '[ "$(ls "$d"/settings.json.bak-* | wc -l)" -eq 1 ]'
check "backup has old hooks"     'grep -q fetch-usage "$d"/settings.json.bak-*'
check "fetch-usage.sh not deleted" '[ -e "$d/fetch-usage.sh" ]'
check "suggests deleting it"     '[[ "$out" == *"no longer used"* ]]'

# --- re-running is a no-op: no rewrite, no extra backup ---
before=$(cat "$s")
out=$(install "$d")
check "idempotent content"  '[ "$(cat "$s")" = "$before" ]'
check "no second backup"    '[ "$(ls "$d"/settings.json.bak-* | wc -l)" -eq 1 ]'
check "reports up to date"  '[[ "$out" == *"already up to date"* ]]'
check "still one mcp hook"  '[ "$(ideo_hooks "$s")" -eq 1 ]'

# --- a moved CLAUDE_CONFIG_DIR replaces the old hook path, keeps other PostToolUse hooks ---
d="$TMP/moved"; mkdir -p "$d"
echo '{"hooks":{"PostToolUse":[{"matcher":"mcp__ideogram__.*","hooks":[{"type":"command","command":"sh /old/ideogram-hook.sh"}]},{"matcher":"Edit","hooks":[{"type":"command","command":"fmt.sh"}]}]}}' > "$d/settings.json"
install "$d" > /dev/null
check "stale hook path replaced" '[ "$(ideo_hooks "$d/settings.json")" -eq 1 ] && ! grep -q /old/ "$d/settings.json"'
check "other PostToolUse kept"   'jq -e "[.hooks.PostToolUse[].hooks[].command] | index(\"fmt.sh\")" "$d/settings.json" > /dev/null'

# --- hooks object made empty is dropped entirely ---
d="$TMP/onlyfetch"; mkdir -p "$d"
echo '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash ~/.claude/fetch-usage.sh &"}]}]}}' > "$d/settings.json"
install "$d" > /dev/null
check "empty events removed" 'jq -e ".hooks | keys == [\"PostToolUse\"]" "$d/settings.json" > /dev/null'

# --- invalid settings.json: fail without clobbering it ---
d="$TMP/broken"; mkdir -p "$d"
echo '{not json' > "$d/settings.json"
install "$d" > /dev/null 2>&1; rc=$?
check "fails on invalid json"   '[ "$rc" -ne 0 ]'
check "invalid json untouched"  '[ "$(cat "$d/settings.json")" = "{not json" ]'
check "no temp file left"       '[ "$(ls "$d" | grep -c "settings.json.")" -eq 0 ]'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
