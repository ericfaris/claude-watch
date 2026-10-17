#!/bin/bash
# Fixture-driven tests for statusline-command.sh. Run: bash test/statusline.test.sh
cd "$(dirname "$0")/.." || exit 1
SCRIPT="$PWD/statusline-command.sh"
NOW=1800000000
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# render <json> [env...]: runs the script with a fixed clock, ANSI stripped
render() {
  json=$1; shift
  printf '%s' "$json" | env -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -u CLAUDE_WATCH_CTX_WARN \
    -u REMOTE_CONTAINERS CLAUDE_WATCH_NOW=$NOW "$@" bash "$SCRIPT" \
    | sed 's/\x1b\[[0-9;]*m//g'
}
render_raw() {
  printf '%s' "$1" | env -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE CLAUDE_WATCH_NOW=$NOW bash "$SCRIPT"
}

has()  { if printf '%s' "$2" | grep -qF -- "$3"; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL: %s\n  expected to contain: %s\n  got: %s\n' "$1" "$3" "$2"; fi; }
lacks(){ if printf '%s' "$2" | grep -qF -- "$3"; then fail=$((fail+1)); printf 'FAIL: %s\n  expected NOT to contain: %s\n  got: %s\n' "$1" "$3" "$2"; else pass=$((pass+1)); fi; }

# fixture <5h_pct> <5h_reset_offset> <7d_pct> <7d_reset_offset> <ctx_pct> [dir]
fixture() {
  cat <<EOF
{"model":{"display_name":"Claude Opus 5.5"},"workspace":{"current_dir":"${6:-$TMP/nogit}"},
 "context_window":{"used_percentage":$5,"context_window_size":200000,
   "current_usage":{"input_tokens":1000,"output_tokens":1000,"cache_read_input_tokens":50000,"cache_creation_input_tokens":0}},
 "rate_limits":{"five_hour":{"used_percentage":$1,"resets_at":$((NOW+$2))},
                "seven_day":{"used_percentage":$3,"resets_at":$((NOW+$4))}}}
EOF
}
mkdir -p "$TMP/nogit"

# --- usage comes from piped .rate_limits, with countdowns ---
out=$(render "$(fixture 12.4 7200 30 172800 20)")
has   "5h pct rounded"        "$out" "5h 12%"
has   "5h countdown"          "$out" "(2h 0m)"
has   "7d pct"                "$out" "7d 30%"
has   "7d countdown"          "$out" "(2d 0h)"
has   "ctx pct + tokens"      "$out" "ctx 20% (52k/200k)"
has   "model prefix stripped" "$out" "Opus 5.5"
lacks "no warnings when calm" "$out" "⚠"

# --- missing rate_limits (API key / Bedrock): usage hidden, ctx still shown ---
out=$(render '{"model":{"display_name":"Claude Opus 5.5"},"workspace":{"current_dir":"'"$TMP/nogit"'"},"context_window":{"used_percentage":10}}')
lacks "no 5h without rate_limits" "$out" "5h"
lacks "no 7d without rate_limits" "$out" "7d"
has   "ctx without rate_limits"   "$out" "ctx 10%"

# --- burn-rate projection (5h window = 18000s) ---
# 2.5h elapsed at 60% -> 100% in ~1h40m, before the 2.5h reset
out=$(render "$(fixture 60 9000 10 500000 20)")
has   "5h on pace to hit limit" "$out" "⚠ limit in ~1h 40m"
# 2.5h elapsed at 40% -> 100% in 3h45m, after reset: no warning
out=$(render "$(fixture 40 9000 10 500000 20)")
lacks "5h under pace"           "$out" "limit in"
# only 20m into the window: too early to project
out=$(render "$(fixture 50 16800 10 500000 20)")
lacks "5h too early to project" "$out" "limit in"
# already at 100%: nothing to project
out=$(render "$(fixture 100 3600 10 500000 20)")
lacks "5h already maxed"        "$out" "limit in"
# reset already passed: no projection
out=$(render "$(fixture 80 -60 10 500000 20)")
has   "reset passed shows now"  "$out" "(now)"
lacks "reset passed no eta"     "$out" "limit in"
# 7d window: 3.5d elapsed at 70% -> 100% in 1.5d, before the 3.5d reset
out=$(render "$(fixture 5 9000 70 302400 20)")
has   "7d on pace to hit limit" "$out" "7d 70% (3d 12h) ⚠ limit in ~1d 12h"

# --- auto-compact warning ---
out=$(render "$(fixture 5 9000 5 500000 79)")
lacks "ctx below default warn" "$out" "compact soon"
out=$(render "$(fixture 5 9000 5 500000 80)")
has   "ctx at default warn"    "$out" "ctx 80% (52k/200k) ⚠ compact soon"
out=$(render "$(fixture 5 9000 5 500000 60)" CLAUDE_WATCH_CTX_WARN=60)
has   "custom warn threshold"  "$out" "compact soon"
out=$(render "$(fixture 5 9000 5 500000 46)" CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50)
has   "honors autocompact override" "$out" "compact soon"
out=$(render "$(fixture 5 9000 5 500000 44)" CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50)
lacks "below autocompact override"  "$out" "compact soon"

# --- burn-rate colors ---
raw=$(render_raw "$(fixture 92 9000 75 500000 20)")
has "5h red at 90%+"    "$raw" $'\033[38;2;224;108;117m5h 92%'
has "7d yellow at 70%+" "$raw" $'\033[38;2;229;192;123m7d 75%'

# --- git glyphs ---
repo="$TMP/repo"
git init -q -b main "$repo"
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo a > "$repo/staged"; git -C "$repo" add staged
echo b > "$repo/untracked"
out=$(render "$(fixture 5 9000 5 500000 20 "$repo")")
has   "branch shown"     "$out" "main"
has   "staged glyph"     "$out" "+1"
has   "untracked glyph"  "$out" "?1"
out=$(render "$(fixture 5 9000 5 500000 20)")
lacks "no branch outside git" "$(printf "%s" "$out" | head -1)" "•"

echo c > "$repo/tracked"; git -C "$repo" add tracked
git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m tracked
echo changed > "$repo/tracked"
out=$(render "$(fixture 5 9000 5 500000 20 "$repo")")
has "modified glyph" "$out" "~1"

# ahead/behind against an upstream
git init -q --bare "$TMP/remote.git"
git -C "$repo" remote add origin "$TMP/remote.git"
git -C "$repo" push -q -u origin main
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m ahead1
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m ahead2
out=$(render "$(fixture 5 9000 5 500000 20 "$repo")")
has   "ahead glyph"      "$out" "↑2"
lacks "no behind glyph"  "$out" "↓"
git -C "$repo" reset -q --hard HEAD~3
git -C "$repo" stash -q 2>/dev/null
out=$(render "$(fixture 5 9000 5 500000 20 "$repo")")
has   "behind glyph"     "$out" "↓1"

# slash in branch name, then detached HEAD shows the short sha
git -C "$repo" checkout -q -b feat/x-y
out=$(render "$(fixture 5 9000 5 500000 20 "$repo")")
has "branch with slash" "$out" "feat/x-y"
git -C "$repo" checkout -q --detach
sha=$(git -C "$repo" rev-parse --short=7 HEAD)
out=$(render "$(fixture 5 9000 5 500000 20 "$repo")")
has "detached shows sha" "$out" "• $sha"

# a hung git must not stall the statusline
mkdir -p "$TMP/slowbin"
printf '#!/bin/sh\nsleep 5\n' > "$TMP/slowbin/git"; chmod +x "$TMP/slowbin/git"
start=$(date +%s)
out=$(render "$(fixture 5 9000 5 500000 20 "$repo")" PATH="$TMP/slowbin:$PATH" CLAUDE_WATCH_GIT_TIMEOUT=1)
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -lt 4 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: slow git stalled render for ${elapsed}s"; fi
has "slow git still renders usage" "$out" "5h 5%"

# --- prompt cache countdown ---
cache() { fixture 5 9000 5 500000 20 | jq -c --argjson pc "$1" '. + {prompt_cache: $pc}'; }
out=$(render "$(cache '{"warm":true,"expires_at":'$((NOW+240))'}')")
has   "warm cache countdown" "$out" "| cache 4m"
raw=$(render_raw "$(cache '{"warm":true,"expires_at":'$((NOW+240))'}')")
has   "warm cache gray"      "$raw" $'\033[38;2;156;162;175mcache 4m'
raw=$(render_raw "$(cache '{"warm":true,"expires_at":'$((NOW+45))'}')")
has   "last minute yellow + seconds" "$raw" $'\033[38;2;229;192;123mcache 45s'
raw=$(render_raw "$(cache '{"warm":false,"expires_at":null}')")
has   "cold cache red"       "$raw" $'\033[38;2;224;108;117mcache cold'
out=$(render "$(cache '{"warm":true,"expires_at":'$((NOW-10))'}')")
has   "expired counts as cold" "$out" "cache cold"
out=$(render "$(fixture 5 9000 5 500000 20)")
lacks "no cache segment without data" "$out" "cache"

# --- robustness ---
printf 'not json' | CLAUDE_WATCH_NOW=$NOW bash "$SCRIPT" > /dev/null 2>&1
rc=$?; if [ "$rc" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: malformed payload exit $rc"; fi
printf '%s' "$(fixture 5 9000 5 500000 20)" | CLAUDE_WATCH_NOW=$NOW bash "$SCRIPT" > /dev/null
rc=$?; if [ "$rc" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: calm render exit $rc"; fi
out=$(render '{"model":{"display_name":"$(touch '"$TMP"'/pwned)"},"workspace":{"current_dir":"'"$TMP/nogit"'"}}')
if [ -e "$TMP/pwned" ]; then fail=$((fail+1)); echo "FAIL: payload executed as shell"; else pass=$((pass+1)); fi
has "payload rendered literally" "$out" '$(touch'

# --- container badge ---
out=$(render "$(fixture 5 9000 5 500000 20)" REMOTE_CONTAINERS=1)
has "container badge" "$out" "⬢ container"

# --- effort ---
out=$(render '{"model":{"display_name":"Claude Opus 5.5"},"effort":{"level":"high"},"workspace":{"current_dir":"'"$TMP/nogit"'"}}')
has "effort suffix" "$out" "Opus 5.5 (high)"

# --- regression: no reliance on the old fetch-usage.sh / OAuth cache ---
lacks "no fetch-usage.sh call" "$(cat "$SCRIPT")" "fetch-usage"
lacks "no /tmp usage cache"    "$(cat "$SCRIPT")" ".claude_usage_cache"
[ ! -e fetch-usage.sh ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: fetch-usage.sh still in repo"; }
if jq -e '.hooks' settings.json >/dev/null 2>&1; then fail=$((fail+1)); echo "FAIL: settings.json still has hooks"; else pass=$((pass+1)); fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
