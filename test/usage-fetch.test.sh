#!/bin/bash
# Tests for usage-fetch.sh with a fake curl and throwaway ledger/plan/keys.
# Run: bash test/usage-fetch.test.sh
cd "$(dirname "$0")/.." || exit 1
SCRIPT="$PWD/usage-fetch.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
export TZ=America/New_York
NOW=$(date -d "2026-10-25 12:00" +%s)

check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; [ -n "$3" ] && echo "  got: $3"; fi; }

# fake curl: answers from $TMP/ideogram.json / $TMP/elevenlabs.json and logs
# its argv and stdin (where the key header must arrive).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/curl.argv"
cat >> "$TMP/curl.stdin"
case "\$*" in
  *account/usage*) cat "$TMP/ideogram.json" 2> /dev/null ;;
  *user/subscription*) cat "$TMP/elevenlabs.json" 2> /dev/null ;;
esac
EOF
chmod +x "$TMP/bin/curl"
echo "ig-secret-key" > "$TMP/ig.key"
echo "el-secret-key" > "$TMP/el.key"

fetch() {
  rm -f "$TMP/cache/services.json"
  env -u IDEOGRAM_API_KEY -u ELEVENLABS_API_KEY PATH="$TMP/bin:$PATH" \
    CLAUDE_WATCH_NOW="${at:-$NOW}" CLAUDE_WATCH_CACHE_DIR="$TMP/cache" \
    CLAUDE_WATCH_IDEOGRAM_LEDGER="$TMP/ledger.jsonl" CLAUDE_WATCH_IDEOGRAM_PLAN="$TMP/plan.json" \
    CLAUDE_WATCH_IDEOGRAM_KEY_FILE="$TMP/ig.key" CLAUDE_WATCH_ELEVENLABS_KEY_FILE="$TMP/el.key" \
    "$@" sh "$SCRIPT"
  cat "$TMP/cache/services.json" 2> /dev/null
}
q() { printf '%s' "$out" | jq -r "$1"; }

echo '{"buckets":[{"line_items":[]}]}' > "$TMP/ideogram.json"
echo '{"character_count":12345,"character_limit":100000,"next_character_count_reset_unix":1793000000}' > "$TMP/elevenlabs.json"

# --- no ledger or plan yet ---
out=$(fetch)
check "no ledger error"      '[ "$(q .ideogram.error)" = "no ledger" ]' "$out"
check "fetched_at written"   '[ "$(q .fetched_at)" = "$NOW" ]'

# --- counts down from the person's "credits left" anchor ---
echo '{"monthly_credits":2400,"credits_left":500,"credits_set_at":'$((NOW-1000))'}' > "$TMP/plan.json"
cat > "$TMP/ledger.jsonl" <<EOF
{"t":$((NOW-2000)),"credits":999,"app":"posterize","what":"before the anchor"}
{"t":$((NOW-500)),"credits":24,"app":"posterize","what":"4 versions"}
{"t":$((NOW-100)),"usd":0.06,"app":"redline","what":"usd only"}
EOF
out=$(fetch)
check "anchor minus ledger"  '[ "$(q .ideogram.credits_left)" = 470 ]' "$out"
check "ledger is the source" '[ "$(q .ideogram.source)" = ledger ]'
check "monthly passed on"    '[ "$(q .ideogram.monthly_credits)" = 2400 ]'
check "resets Nov 1 local"   '[ "$(q .ideogram.resets_at)" = "$(date -d "2026-11-01 00:00" +%s)" ]' "$out"
check "usage API asked from the anchor" \
  'grep -q "start_time=$(date -u -d "@$((NOW-1000))" +%Y-%m-%dT%H:%M:%SZ)" "$TMP/curl.argv"'

# --- usage API wins when it reports more spend than the ledger ---
echo '{"buckets":[{"line_items":[{"usd_micros":600000}]},{"line_items":[{"credits":40}]}]}' > "$TMP/ideogram.json"
out=$(fetch)
check "api spend used"       '[ "$(q .ideogram.credits_left)" = 400 ]' "$out"
check "api is the source"    '[ "$(q .ideogram.source)" = api ]'
echo 'gateway timeout' > "$TMP/ideogram.json"
out=$(fetch)
check "api down falls back"  '[ "$(q .ideogram.credits_left)" = 470 ]' "$out"

# --- an anchor from last month is ignored: full plan minus this cycle's spend ---
echo '{"buckets":[]}' > "$TMP/ideogram.json"
echo '{"credits_left":10,"credits_set_at":'$(date -d "2026-09-20" +%s)'}' > "$TMP/plan.json"
out=$(fetch)
check "new cycle resets to 2400" '[ "$(q .ideogram.credits_left)" = $((2400-999-24-6)) ]' "$out"
check "monthly defaults to 2400" '[ "$(q .ideogram.monthly_credits)" = 2400 ]'
rm "$TMP/plan.json"
out=$(fetch)
check "ledger alone works"   '[ "$(q .ideogram.credits_left)" = $((2400-999-24-6)) ]' "$out"

# --- December wraps to January 1st ---
out=$(at=$(date -d "2026-12-31 23:00" +%s) fetch)
check "december resets jan 1" '[ "$(q .ideogram.resets_at)" = "$(date -d "2027-01-01 00:00" +%s)" ]' "$out"
check "ledger outside cycle ignored" '[ "$(q .ideogram.credits_left)" = 2400 ]'

# --- elevenlabs ---
out=$(fetch)
check "elevenlabs used"      '[ "$(q .elevenlabs.used)" = 12345 ]' "$out"
check "elevenlabs limit"     '[ "$(q .elevenlabs.limit)" = 100000 ]'
check "elevenlabs reset"     '[ "$(q .elevenlabs.resets_at)" = 1793000000 ]'
echo '{"detail":{"status":"missing_permissions","message":"The API key you used is missing the permission user_read to execute this operation."}}' > "$TMP/elevenlabs.json"
out=$(fetch)
check "missing user_read"    '[ "$(q .elevenlabs.error)" = "key needs user_read" ]' "$out"
echo '{"detail":{"status":"invalid_api_key"}}' > "$TMP/elevenlabs.json"
out=$(fetch)
check "bad key"              '[ "$(q .elevenlabs.error)" = auth ]' "$out"
rm "$TMP/elevenlabs.json"
out=$(fetch)
check "offline"              '[ "$(q .elevenlabs.error)" = offline ]' "$out"
out=$(fetch CLAUDE_WATCH_ELEVENLABS_KEY_FILE="$TMP/missing")
check "no key"               '[ "$(q .elevenlabs.error)" = "no key" ]' "$out"

# --- keys travel on stdin, never argv ---
check "keys not in argv"     '! grep -q secret-key "$TMP/curl.argv"'
check "keys sent as headers" 'grep -q "Api-Key: ig-secret-key" "$TMP/curl.stdin" && grep -q "xi-api-key: el-secret-key" "$TMP/curl.stdin"'

# --- one fetch at a time; a stale lock is taken over ---
mkdir -p "$TMP/cache/.fetch.lock"
out=$(fetch)
check "fresh lock skips fetch" '[ -z "$out" ]' "$out"
touch -d "2 minutes ago" "$TMP/cache/.fetch.lock"
out=$(fetch)
check "stale lock taken over"  '[ -n "$out" ]'
check "lock released"          '[ ! -e "$TMP/cache/.fetch.lock" ]'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
