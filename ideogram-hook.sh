#!/bin/sh
# Claude Code PostToolUse hook for mcp__ideogram__*: records the credits each
# MCP call spends in the shared ledger (see ideogram-ledger), since the MCP
# server bills the subscription but doesn't report a cost.
#
# - generate/edit calls: an estimate from Ideogram's price list (2026-10-17),
#   keyed by request_id, times num_images_requested.
# - get_generation_status with usage_cost_usd_micros (upscales report it): the
#   exact cost under the same id, which replaces the estimate.
# Never blocks or fails the tool call: no output, always exit 0.

input=$(cat)
ledger_cmd=${CLAUDE_WATCH_LEDGER_CMD:-$(dirname "$0")/ideogram-ledger}

# -> "<credits>\t<id>\t<estimated>\t<what>" or nothing when the call isn't billed
entry=$(printf '%s' "$input" | jq -r '
  def parsed: if type == "string" then (fromjson? // {})
    elif type == "array" then (map(select(.type? == "text") | .text | fromjson?) | first // {})
    elif type == "object" and (.content | type) == "array" then (.content | parsed)
    elif type == "object" then . else {} end;
  def per_image($op; $q; $with_images):
    if ($op | test("upscale")) then null
    elif ($op | test("remove_background|remove_object|erase")) then 6
    elif ($op | test("4_5")) then
      ({"low": 3, "turbo": 3, "medium": 6, "default": 6, "balanced": 6,
        "high": (if $with_images then 22 else 10 end),
        "quality": (if $with_images then 22 else 10 end)}[$q // "medium"] // 6)
    else ({"low": 3, "turbo": 3, "medium": 6, "default": 6, "balanced": 6, "high": 9, "quality": 9}[$q // "default"] // 6)
    end;
  (.tool_name // "" | sub("^mcp__ideogram__"; "")) as $tool
  | (.tool_input.request // {}) as $req | ($req.body // {}) as $body
  | (.tool_response | parsed) as $r
  | if $tool == "get_generation_status" then
      if ($r.usage_cost_usd_micros | type) == "number" and $r.generation_id then
        [($r.usage_cost_usd_micros / 10000 | . * 1000 | round / 1000), $r.generation_id, "false",
         "mcp: \($r.data[0].resolution // "generation") (exact)"]
      else empty end
    elif ($tool | test("^(generate|edit)_(images|video)$")) and $r.request_id then
      ($req.operation // $r.operation_label // "") as $op
      | ($body.quality // $body.rendering_speed) as $q
      | ($r.num_images_requested // $r.job_size // $body.num_images // 1) as $n
      | (if ($op | test("upscale")) then
           ({"x4": 192, "x8": 768}[$body.upscale_factor // "x2"] // 48)
         elif ($tool | test("video")) then 0
         else per_image($op; $q; ($op | test("edit")) or ($body.images // [] | length) > 0) * $n end) as $c
      | [$c, $r.request_id, "true",
         "mcp: \($op)\(if $q then " " + $q else "" end) x\($n)\(if ($tool | test("video")) then " (video, unpriced)" else "" end)"]
    elif $tool == "describe_image" then [1, "", "true", "mcp: describe_image"]
    else empty end
  | map(tostring) | join("\t")' 2> /dev/null)

[ -n "$entry" ] || exit 0
credits=$(printf '%s' "$entry" | cut -f1)
id=$(printf '%s' "$entry" | cut -f2)
estimated=$(printf '%s' "$entry" | cut -f3)
what=$(printf '%s' "$entry" | cut -f4)
set -- add --credits "$credits" --app claude-mcp --what "$what"
[ -n "$id" ] && set -- "$@" --id "$id"
[ "$estimated" = "true" ] && set -- "$@" --estimated
sh "$ledger_cmd" "$@" > /dev/null 2>&1
exit 0
