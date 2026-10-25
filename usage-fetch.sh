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

# --- ideogram: shared ledger + plan, cross-checked with /v2/account/usage ---
# Spend is whichever is higher since the cycle start (or since the person last
# said how many credits were left): the ledger the apps append to, or the
# usage API (which has lagged, or come back empty, for subscription credits).
ig_data=${CLAUDE_WATCH_IDEOGRAM_LEDGER:-${XDG_DATA_HOME:-$HOME/.local/share}/ideogram/ledger.jsonl}
ig_plan=${CLAUDE_WATCH_IDEOGRAM_PLAN:-$HOME/.config/ideogram/plan.json}
ig_key=${IDEOGRAM_API_KEY:-$(cat "${CLAUDE_WATCH_IDEOGRAM_KEY_FILE:-$HOME/.config/ideogram/api-key}" 2> /dev/null)}

# local midnight of <yyyy-mm-dd>, GNU or BSD date
midnight() { date -d "$1 00:00" +%s 2> /dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$1 00:00:00" +%s 2> /dev/null; }

if [ -f "$ig_plan" ] || [ -f "$ig_data" ]; then
  # The plan resets to monthly_credits (2400) at local midnight on the 1st.
  plan=$(jq -c '{monthly_credits: (.monthly_credits // 2400), credits_left, credits_set_at}' "$ig_plan" 2> /dev/null) \
    || plan='{"monthly_credits":2400}'
  ym=$(date -d "@$now" +%Y-%m 2> /dev/null || date -r "$now" +%Y-%m)
  y=${ym%-*}; m=${ym#*-}; m=${m#0}
  cycle=$(midnight "$ym-01")
  if [ "$m" -eq 12 ]; then next=$(midnight "$((y + 1))-01-01"); else next=$(midnight "$(printf '%d-%02d-01' "$y" $((m + 1)))"); fi

  # count from the person's "credits left" if they set it this cycle
  since=$(printf '%s' "$plan" | jq -r --argjson c "$cycle" \
    'if .credits_left != null and (.credits_set_at // 0) >= $c then .credits_set_at | floor else $c end')

  ledger_spent=$(jq -s --argjson s "$since" \
    '[.[] | select(.t >= $s) | .credits // ((.usd // 0) * 100)] | add // 0' "$ig_data" 2> /dev/null)
  ledger_spent=${ledger_spent:-0}

  # line_items have come back empty so far, so their shape is a best guess:
  # credits if given, else usd micros (1 credit = $0.01).
  api_spent=""
  if [ -n "$ig_key" ]; then
    iso=$(date -u -d "@$since" +%Y-%m-%dT%H:%M:%SZ 2> /dev/null || date -u -r "$since" +%Y-%m-%dT%H:%M:%SZ)
    api_spent=$(printf 'Api-Key: %s\n' "$ig_key" | curl -s -m 10 -H @- \
      "${CLAUDE_WATCH_IDEOGRAM_API:-https://api.ideogram.ai}/v2/account/usage?start_time=$iso&bucket_width=1d" 2> /dev/null \
      | jq 'if .buckets then [.buckets[].line_items[]?
              | .credits // ((.usd_micros // .cost_usd_micros // .usage_cost_usd_micros // 0) / 10000)]
              | add // 0 else empty end' 2> /dev/null)
  fi

  ideogram=$(printf '%s' "$plan" | jq -c --argjson s "$since" --argjson c "$cycle" --argjson n "$next" \
    --argjson l "$ledger_spent" --argjson a "${api_spent:-null}" '
    ([$l, ($a // 0)] | max) as $spent
    | {credits_left: ((if $s > $c then .credits_left else .monthly_credits end) - $spent | round),
       monthly_credits, resets_at: $n, source: (if $a != null and $a > $l then "api" else "ledger" end)}')
  [ -n "$ideogram" ] || ideogram='{"error":"bad ledger"}'
else
  ideogram='{"error":"no ledger"}'
fi

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
