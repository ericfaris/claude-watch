#!/bin/bash
# Tests for install.sh against a throwaway CLAUDE_CONFIG_DIR. Run: bash test/install.test.sh
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
install() { CLAUDE_CONFIG_DIR="$1" sh "$REPO/install.sh"; }

# --- fresh install: no settings.json yet ---
d="$TMP/fresh"
out=$(install "$d")
check "script copied"      '[ -x "$d/statusline-command.sh" ]'
check "script identical"   'cmp -s "$d/statusline-command.sh" "$REPO/statusline-command.sh"'
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

# --- hooks object made empty is dropped entirely ---
d="$TMP/onlyfetch"; mkdir -p "$d"
echo '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash ~/.claude/fetch-usage.sh &"}]}]}}' > "$d/settings.json"
install "$d" > /dev/null
check "empty hooks removed" 'jq -e "has(\"hooks\") | not" "$d/settings.json" > /dev/null'

# --- invalid settings.json: fail without clobbering it ---
d="$TMP/broken"; mkdir -p "$d"
echo '{not json' > "$d/settings.json"
install "$d" > /dev/null 2>&1; rc=$?
check "fails on invalid json"   '[ "$rc" -ne 0 ]'
check "invalid json untouched"  '[ "$(cat "$d/settings.json")" = "{not json" ]'
check "no temp file left"       '[ "$(ls "$d" | grep -c "settings.json.")" -eq 0 ]'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
