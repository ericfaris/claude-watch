#!/bin/sh
# Fetches Claude API usage stats and writes them to /tmp/.claude_usage_cache.
# Line 1: five_hour.utilization (integer %)
# Line 2: seven_day.utilization (integer %)
# Line 3: five_hour.resets_at (raw ISO string, e.g. 2026-02-26T12:59:59.997656+00:00)
# Line 4: seven_day.resets_at (raw ISO string)
# All output is suppressed; meant to be run in background.

CACHE_FILE="/tmp/.claude_usage_cache"
TOKEN_CACHE="/tmp/.claude_token_cache"
TOKEN_TTL=900  # 15 minutes

# --- read a fresh access token from the keychain and refresh the cache ---
token_from_keychain() {
  creds_json=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  [ -z "$creds_json" ] && return
  tok=$(printf '%s' "$creds_json" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  [ -z "$tok" ] && return
  printf '%s' "$tok" > "$TOKEN_CACHE"
  printf '%s' "$tok"
}

fetch_usage() {
  curl -s -m 3 \
    -H "accept: application/json" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "authorization: Bearer $1" \
    -H "user-agent: claude-code/2.1.11" \
    "https://api.anthropic.com/oauth/usage" 2>/dev/null
}

# --- get token (with 15-min cache to avoid repeated credential reads) ---
token=""
if [ -f "$TOKEN_CACHE" ]; then
  cache_age=$(( $(date -u +%s) - $(stat -c %Y "$TOKEN_CACHE" 2>/dev/null || echo 0) ))
  if [ "$cache_age" -lt "$TOKEN_TTL" ]; then
    token=$(cat "$TOKEN_CACHE" 2>/dev/null)
  fi
fi

[ -z "$token" ] && token=$(token_from_keychain)
[ -z "$token" ] && exit 0

usage_json=$(fetch_usage "$token")

# The cached token may be stale (Claude Code rotates the OAuth token in the
# keychain). If it was rejected, drop the cache, re-read from the keychain and
# retry once with a fresh token.
case "$usage_json" in
  *authentication_error*|*"Invalid authentication"*)
    rm -f "$TOKEN_CACHE"
    token=$(token_from_keychain)
    [ -z "$token" ] && exit 0
    usage_json=$(fetch_usage "$token")
    ;;
esac

if [ -z "$usage_json" ]; then
  exit 0
fi

five_h_raw=$(printf '%s' "$usage_json" | jq -r '.five_hour.utilization // empty' 2>/dev/null)
seven_d_raw=$(printf '%s' "$usage_json" | jq -r '.seven_day.utilization // empty' 2>/dev/null)
five_h_reset=$(printf '%s' "$usage_json" | jq -r '.five_hour.resets_at // ""' 2>/dev/null)
seven_d_reset=$(printf '%s' "$usage_json" | jq -r '.seven_day.resets_at // ""' 2>/dev/null)

if [ -n "$five_h_raw" ] && [ -n "$seven_d_raw" ]; then
  five_h=$(printf "%.0f" "$five_h_raw")
  seven_d=$(printf "%.0f" "$seven_d_raw")
  printf '%s\n%s\n%s\n%s\n' "$five_h" "$seven_d" "$five_h_reset" "$seven_d_reset" > "$CACHE_FILE"
fi
