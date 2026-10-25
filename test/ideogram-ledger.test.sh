#!/bin/bash
# Tests for ideogram-ledger and ideogram-hook.sh against a throwaway ledger dir.
# Run: bash test/ideogram-ledger.test.sh
cd "$(dirname "$0")/.." || exit 1
CLI="$PWD/ideogram-ledger"
HOOK="$PWD/ideogram-hook.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
export TZ=America/New_York IDEOGRAM_LEDGER_DIR="$TMP/ig"
NOW=$(date -d "2026-10-25 12:00" +%s)
export CLAUDE_WATCH_NOW=$NOW

check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; [ -n "$3" ] && echo "  got: $3"; fi; }
led() { sh "$CLI" "$@"; }
left() { led status | jq -r .credits_left; }
reset() { rm -rf "$TMP/ig"; }

# --- empty: the full plan, resetting Nov 1 local ---
out=$(led status)
check "empty is 2400"       '[ "$(printf "%s" "$out" | jq .credits_left)" = 2400 ]' "$out"
check "resets Nov 1 local"  '[ "$(printf "%s" "$out" | jq .resets_at)" = "$(date -d "2026-11-01 00:00" +%s)" ]' "$out"
check "since Oct 1 local"   '[ "$(printf "%s" "$out" | jq .since)" = "$(date -d "2026-10-01 00:00" +%s)" ]' "$out"

# --- add: credits or usd, exact or estimated ---
led add --credits 24 --app posterize --what "4 versions" --id g1
led add --usd 0.06 --app redline
check "credits + usd"       '[ "$(left)" = 2370 ]' "$(left)"
check "line format"         'tail -1 "$TMP/ig/ledger.jsonl" | jq -e ".v == 1 and .t == $NOW and .credits == 6 and .app == \"redline\" and .id == null and .estimated == false" > /dev/null'
led add --credits x 2> /dev/null; rc=$?
check "bad credits rejected" '[ "$rc" -eq 2 ] && [ "$(wc -l < "$TMP/ig/ledger.jsonl")" -eq 2 ]'
led add --credits -5 2> /dev/null
check "negative rejected"   '[ "$(wc -l < "$TMP/ig/ledger.jsonl")" -eq 2 ]'
led add --credits 6 --what 'quote " and \ slash' --app t
check "what is json-escaped" 'tail -1 "$TMP/ig/ledger.jsonl" | jq -e ".what == \"quote \\\" and \\\\ slash\"" > /dev/null'

# --- a repeated id counts once: exact beats estimate, whatever the order ---
reset
led add --credits 48 --id up1 --estimated
led add --credits 48.17 --id up1
check "exact replaces estimate" '[ "$(left)" = 2351.8 ]' "$(left)"
led add --credits 50 --id up1 --estimated
check "late estimate ignored"   '[ "$(left)" = 2351.8 ]' "$(left)"
led add --credits 12 --id r2 --estimated
led add --credits 12 --id r2 --estimated
check "repeated estimate once"  '[ "$(left)" = 2339.8 ]' "$(left)"

# --- set-left anchors the count; an anchor from last month is ignored ---
reset
led add --credits 999
led set-left 5.2
check "anchor replaces count"   '[ "$(left)" = 5.2 ]' "$(left)"
check "plan keeps monthly"      'jq -e ".monthly_credits == 2400 and .credits_left == 5.2 and .credits_set_at == $NOW" "$TMP/ig/plan.json" > /dev/null'
CLAUDE_WATCH_NOW=$((NOW+60)) led add --credits 3
check "spend after anchor"      '[ "$(CLAUDE_WATCH_NOW=$((NOW+60)) led status | jq .credits_left)" = 2.2 ]'
led set-left abc 2> /dev/null; rc=$?
check "bad set-left rejected"   '[ "$rc" -eq 2 ] && jq -e ".credits_left == 5.2" "$TMP/ig/plan.json" > /dev/null'
jq '.monthly_credits = 1000' "$TMP/ig/plan.json" > "$TMP/p" && mv "$TMP/p" "$TMP/ig/plan.json"
led set-left 7
check "set-left keeps custom monthly" 'jq -e ".monthly_credits == 1000" "$TMP/ig/plan.json" > /dev/null'
out=$(CLAUDE_WATCH_NOW=$(date -d "2026-11-02 09:00" +%s) led status)
check "next month resets"       '[ "$(printf "%s" "$out" | jq .credits_left)" = 1000 ]' "$out"
out=$(CLAUDE_WATCH_NOW=$(date -d "2026-12-31 23:00" +%s) led status)
check "december wraps to jan 1" '[ "$(printf "%s" "$out" | jq .resets_at)" = "$(date -d "2027-01-01 00:00" +%s)" ]' "$out"

# --- corrupt input never breaks the read ---
reset; mkdir -p "$TMP/ig"
printf '%s\n' '{"t":'$NOW',"credits":10}' 'garbage' '[1,2]' '{"credits":5}' '{"t":'$NOW',"usd":0.5}' > "$TMP/ig/ledger.jsonl"
check "bad lines skipped"   '[ "$(left)" = 2340 ]' "$(left)"
echo 'not json' > "$TMP/ig/plan.json"
check "bad plan = defaults" '[ "$(left)" = 2340 ]' "$(left)"

# --- concurrent writers don't lose or tear lines ---
reset
for i in $(seq 1 40); do led add --credits 1 --id "c$i" --what "$(printf 'x%.0s' $(seq 1 200))" & done; wait
check "40 parallel appends"  '[ "$(jq -c . "$TMP/ig/ledger.jsonl" 2> /dev/null | wc -l)" -eq 40 ] && [ "$(left)" = 2360 ]' "$(left)"

# --- hook: MCP calls -> ledger entries ---
reset
hook() { sh "$HOOK"; }
resp() { jq -nc --arg r "$1" '[{type: "text", text: $r}]'; }
call() { jq -nc --arg t "mcp__ideogram__$1" --argjson i "$2" --argjson r "$3" '{tool_name: $t, tool_input: $i, tool_response: $r}'; }
gen='{"request":{"operation":"ideogram_4_5","body":{"prompt":"x","quality":"medium","num_images":2}}}'
call generate_images "$gen" "$(resp '{"status":"running","request_id":"R1","num_images_requested":2}')" | hook
check "4.5 medium x2 = 12"   'tail -1 "$TMP/ig/ledger.jsonl" | jq -e ".credits == 12 and .id == \"R1\" and .estimated and .app == \"claude-mcp\"" > /dev/null'
# the same result in other envelopes Claude Code may hand the hook
call generate_images "$gen" '{"content":[{"type":"text","text":"{\"request_id\":\"R1\",\"num_images_requested\":2}"}]}' | hook
call generate_images "$gen" '"{\"request_id\":\"R1\",\"num_images_requested\":2}"' | hook
call generate_images "$gen" '{"request_id":"R1","num_images_requested":2}' | hook
check "every envelope parsed" '[ "$(wc -l < "$TMP/ig/ledger.jsonl")" -eq 4 ]'
check "repeats count once"    '[ "$(left)" = 2388 ]' "$(left)"

call generate_images '{"request":{"operation":"ideogram_4_5","body":{"quality":"high","images":[{}]}}}' \
  '{"request_id":"R2","num_images_requested":1}' | hook
check "high with images = 22" 'tail -1 "$TMP/ig/ledger.jsonl" | jq -e ".credits == 22" > /dev/null'
call generate_images '{"request":{"operation":"ideogram_3","body":{"rendering_speed":"QUALITY"}}}' \
  '{"request_id":"R3","num_images_requested":2}' | hook
check "unknown quality falls back to 6/image" 'tail -1 "$TMP/ig/ledger.jsonl" | jq -e ".credits == 12" > /dev/null'
call edit_images '{"request":{"operation":"precise_edit_ideogram_4_5","body":{"quality":"high"}}}' \
  '{"request_id":"E1","num_images_requested":1}' | hook
check "high edit = 22"        'tail -1 "$TMP/ig/ledger.jsonl" | jq -e ".credits == 22" > /dev/null'
call edit_images '{"request":{"operation":"remove_background","body":{}}}' '{"request_id":"B1","num_images_requested":1}' | hook
check "remove background = 6" 'tail -1 "$TMP/ig/ledger.jsonl" | jq -e ".credits == 6" > /dev/null'

# upscale: estimate, then the exact cost from get_generation_status replaces it
reset
call edit_images '{"request":{"operation":"upscale_auto","body":{"upscale_factor":"x2"}}}' \
  '{"request_id":"U1","num_images_requested":1}' | hook
check "upscale x2 estimate 48" '[ "$(left)" = 2352 ]' "$(left)"
call get_generation_status '{"generation_id":"U1"}' \
  "$(resp '{"generation_id":"U1","status":"completed","usage_cost_usd_micros":481690,"data":[{"resolution":"3584x4480"}]}')" | hook
check "exact cost replaces it" '[ "$(left)" = 2351.8 ]' "$(left)"
check "exact entry recorded"   'tail -1 "$TMP/ig/ledger.jsonl" | jq -e ".estimated == false and .id == \"U1\"" > /dev/null'

# not billed: errors, browsing, status without a cost, junk
n=$(wc -l < "$TMP/ig/ledger.jsonl")
call generate_images "$gen" '{"error":"433 insufficient credits"}' | hook
call manage_collections '{}' '{"collections":[]}' | hook
call get_generation_status '{"request_id":"R1"}' "$(resp '{"rows":[{"request_id":"R1","status":"done"}]}')" | hook
echo 'not json' | hook; rc=$?
check "unbilled calls skipped" '[ "$(wc -l < "$TMP/ig/ledger.jsonl")" -eq "$n" ]'
check "hook always exits 0"    '[ "$rc" -eq 0 ]'
out=$(call generate_images "$gen" '{"request_id":"R9","num_images_requested":1}' | hook)
check "hook prints nothing"    '[ -z "$out" ]'
chmod 500 "$TMP/ig"
call generate_images "$gen" '{"request_id":"R10","num_images_requested":1}' | hook; rc=$?
chmod 700 "$TMP/ig"
check "unwritable ledger still exits 0" '[ "$rc" -eq 0 ]'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
