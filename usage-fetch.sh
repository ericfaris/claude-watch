#!/bin/sh
# Refreshes the Ideogram / ElevenLabs usage cache that statusline-command.sh
# renders as its third line. The statusline runs this in the background when
# the cache is stale, so nothing here ever blocks a render.
#
# - Ideogram has no balance API. Apps that spend credits append to a shared
#   ledger (~/.local/share/ideogram/ledger.jsonl, one {"t","credits"|"usd",
#   "app","what"} per line); ~/.config/ideogram/plan.json holds the plan
#   ({"monthly_credits","renew_day","credits_left","credits_set_at"}).
# - ElevenLabs: GET /v1/user/subscription with the machine-wide key
#   (~/.config/elevenlabs/api-key, or $ELEVENLABS_API_KEY). The key needs the
#   user_read permission.
#
# Writes {"fetched_at", "ideogram": {...}, "elevenlabs": {...}} atomically;
# a service that can't be reached gets {"error": "<short reason>"}.

cache_dir=${CLAUDE_WATCH_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-watch}
cache="$cache_dir/services.json"
lock="$cache_dir/.fetch.lock"
mkdir -p "$cache_dir" || exit 1

# One fetch at a time; a lock older than 60s is from a fetch that died.
if ! mkdir "$lock" 2> /dev/null; then
  [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2> /dev/null)" ] || exit 0
  rm -rf "$lock" && mkdir "$lock" 2> /dev/null || exit 0
fi
trap 'rmdir "$lock" 2> /dev/null' EXIT

now=${CLAUDE_WATCH_NOW:-$(date -u "+%s")}

# --- ideogram: the shared ledger (ideogram-ledger), cross-checked with /v2/account/usage ---
# If the usage API ever reports more spend since the ledger's start than the
# ledger has, trust the API for the difference. So far it returns empty line
# items, so their shape is a best guess: credits, else usd micros.
ledger_cmd=${CLAUDE_WATCH_LEDGER_CMD:-$(dirname "$0")/ideogram-ledger}
ig_key=${IDEOGRAM_API_KEY:-$(cat "${CLAUDE_WATCH_IDEOGRAM_KEY_FILE:-$HOME/.config/ideogram/api-key}" 2> /dev/null)}
status=$(CLAUDE_WATCH_NOW=$now sh "$ledger_cmd" status 2> /dev/null)
if printf '%s' "$status" | jq -e '.credits_left' > /dev/null 2>&1; then
  api_spent=""
  if [ -n "$ig_key" ]; then
    since=$(printf '%s' "$status" | jq -r '.since | floor')
    iso=$(date -u -d "@$since" +%Y-%m-%dT%H:%M:%SZ 2> /dev/null || date -u -r "$since" +%Y-%m-%dT%H:%M:%SZ)
    api_spent=$(printf 'Api-Key: %s\n' "$ig_key" | curl -s -m 10 -H @- \
      "${CLAUDE_WATCH_IDEOGRAM_API:-https://api.ideogram.ai}/v2/account/usage?start_time=$iso&bucket_width=1d" 2> /dev/null \
      | jq 'if .buckets then [.buckets[].line_items[]?
              | .credits // ((.usd_micros // .cost_usd_micros // .usage_cost_usd_micros // 0) / 10000)]
              | add // 0 else empty end' 2> /dev/null)
  fi
  ideogram=$(printf '%s' "$status" | jq -c --argjson a "${api_spent:-null}" '
    (if $a != null and $a > .spent then $a - .spent else 0 end) as $extra
    | {credits_left: (.credits_left - $extra), monthly_credits, resets_at,
       source: (if $extra > 0 then "api" else "ledger" end)}')
fi
[ -n "$ideogram" ] || ideogram='{"error":"no ledger"}'

# --- elevenlabs: subscription quota ---
key=${ELEVENLABS_API_KEY:-$(cat "${CLAUDE_WATCH_ELEVENLABS_KEY_FILE:-$HOME/.config/elevenlabs/api-key}" 2> /dev/null)}
if [ -z "$key" ]; then
  elevenlabs='{"error":"no key"}'
else
  # The key goes in via stdin (-H @-) so it never shows up in `ps`.
  body=$(printf 'xi-api-key: %s\n' "$key" | curl -s -m 10 -H @- \
    "${CLAUDE_WATCH_ELEVENLABS_API:-https://api.elevenlabs.io}/v1/user/subscription" 2> /dev/null)
  elevenlabs=$(printf '%s' "$body" | jq -c '
    if .character_limit then
      {used: .character_count, limit: .character_limit, resets_at: .next_character_count_reset_unix}
    elif (.detail.message // "" | test("user_read")) then {error: "key needs user_read"}
    elif .detail then {error: "auth"}
    else {error: "offline"} end' 2> /dev/null)
  [ -n "$elevenlabs" ] || elevenlabs='{"error":"offline"}'
fi

tmp=$(mktemp "$cache.XXXXXX") || exit 1
if jq -n --argjson t "$now" --argjson i "$ideogram" --argjson e "$elevenlabs" \
  '{fetched_at: $t, ideogram: $i, elevenlabs: $e}' > "$tmp"; then
  mv "$tmp" "$cache"
else
  rm -f "$tmp"
fi
