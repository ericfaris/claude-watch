#!/bin/sh
input=$(cat)

in_container=""
if [ -f /.dockerenv ] || [ -n "$REMOTE_CONTAINERS" ]; then
  in_container="1"
fi

# --- parse the whole payload in one jq pass ---
# @sh quotes every value, so eval only ever assigns plain strings. Defaults
# keep the script rendering if jq is missing or the payload is malformed.
model="" effort="" dir="" five_h="" seven_d="" five_h_reset="" seven_d_reset=""
used="" ctx_used="" ctx_total="" cache_warm="" cache_expires=""
eval "$(printf '%s' "$input" | jq -r '
  def int: if . == null then "" else floor end;
  @sh "model=\(.model.display_name // "" | sub("^Claude "; ""))",
  @sh "effort=\(.effort.level // "")",
  @sh "dir=\(.workspace.current_dir // .cwd // "")",
  @sh "five_h=\(.rate_limits.five_hour.used_percentage | if . == null then "" else round end)",
  @sh "seven_d=\(.rate_limits.seven_day.used_percentage | if . == null then "" else round end)",
  @sh "five_h_reset=\(.rate_limits.five_hour.resets_at | int)",
  @sh "seven_d_reset=\(.rate_limits.seven_day.resets_at | int)",
  @sh "used=\(.context_window.used_percentage | if . == null then "" else round end)",
  @sh "ctx_used=\(.context_window.current_usage
      | if . == null then "" else (.cache_read_input_tokens + .cache_creation_input_tokens + .input_tokens + .output_tokens) end)",
  @sh "ctx_total=\(.context_window.context_window_size | int)",
  @sh "cache_warm=\(.prompt_cache.warm | if . == null then "" else tostring end)",
  @sh "cache_expires=\(.prompt_cache.expires_at | int)"
')"

# --- reasoning effort ---
# models with "1M context" -> "(1M - <effort>)", others -> "(<effort>)"
if [ -n "$effort" ]; then
  case "$model" in
    *"1M context"*)
      model=$(echo "$model" | sed "s/1M context/1M - ${effort}/")
      ;;
    *)
      model="${model} (${effort})"
      ;;
  esac
fi

# --- folder ---
dir_name=$(basename "$dir")

# --- git branch + remote URL + status glyphs ---
# One `git status --porcelain=v2 --branch` gives branch, ahead/behind and file
# states. --no-optional-locks avoids fighting Claude's own git commands for the
# index lock; the timeout keeps a huge repo from stalling every render.
branch=""
github_url=""
git_glyphs=""
git_timeout=""
command -v timeout > /dev/null 2>&1 && git_timeout="timeout ${CLAUDE_WATCH_GIT_TIMEOUT:-1}"
porcelain=$($git_timeout git --no-optional-locks -C "$dir" status --porcelain=v2 --branch 2>/dev/null)
if [ -n "$porcelain" ]; then
  staged=0 modified=0 untracked=0 ahead=0 behind=0
  eval "$(printf '%s\n' "$porcelain" | awk '
    /^# branch.oid /  { oid = substr($3, 1, 7) }
    /^# branch.head / { head = $3 }
    /^# branch.ab /   { ahead = substr($3, 2); behind = substr($4, 2) }
    /^[12u] /         { if (substr($2, 1, 1) != ".") s++; if (substr($2, 2, 1) != ".") m++ }
    /^\? /            { u++ }
    END {
      if (head == "(detached)") head = oid
      gsub(/'\''/, "", head)
      printf "branch='\''%s'\'' staged=%d modified=%d untracked=%d ahead=%d behind=%d\n", head, s, m, u, ahead, behind
    }')"
  remote_url=$(git -C "$dir" remote get-url origin 2>/dev/null)
  case "$remote_url" in
    *github.com*)
      github_url=$(echo "$remote_url" \
        | sed 's|git@github.com:|https://github.com/|' \
        | sed 's|\.git$||')
      ;;
  esac

  [ "$staged" -gt 0 ] && git_glyphs="${git_glyphs} +${staged}"
  [ "$modified" -gt 0 ] && git_glyphs="${git_glyphs} ~${modified}"
  [ "$untracked" -gt 0 ] && git_glyphs="${git_glyphs} ?${untracked}"
  [ "$ahead" -gt 0 ] && git_glyphs="${git_glyphs} \xe2\x86\x91${ahead}"
  [ "$behind" -gt 0 ] && git_glyphs="${git_glyphs} \xe2\x86\x93${behind}"
  git_glyphs=${git_glyphs# }
fi

# --- usage stats (5h / 7d), piped by Claude Code as .rate_limits ---
# resets_at is epoch seconds. CLAUDE_WATCH_NOW overrides the clock (tests).
now_epoch=${CLAUDE_WATCH_NOW:-$(date -u "+%s")}

# --- fmt_duration: seconds -> "2d 3h" / "3h 12m" / "12m" ---
fmt_duration() {
  diff=$1
  days=$(( diff / 86400 ))
  hours=$(( (diff % 86400) / 3600 ))
  minutes=$(( (diff % 3600) / 60 ))
  if [ "$days" -gt 0 ]; then
    echo "${days}d ${hours}h"
  elif [ "$hours" -gt 0 ]; then
    echo "${hours}h ${minutes}m"
  elif [ "$minutes" -gt 0 ]; then
    echo "${minutes}m"
  else
    echo "${diff}s"
  fi
}

# --- compute_delta: given a reset epoch, returns human-readable time until reset ---
compute_delta() {
  [ -z "$1" ] && return
  diff=$(( $1 - now_epoch ))
  if [ "$diff" -le 0 ]; then echo "now"; return; fi
  fmt_duration "$diff"
}

# --- burn_eta: <pct> <reset_epoch> <window_secs> -> time until 100% at the
# current pace, printed only when that lands before the window resets.
# Skips the first 10% of the window, where the projection is just noise.
burn_eta() {
  pct=$1; reset=$2; window=$3
  [ -z "$pct" ] || [ -z "$reset" ] && return
  [ "$pct" -le 0 ] || [ "$pct" -ge 100 ] && return
  remaining=$(( reset - now_epoch ))
  elapsed=$(( window - remaining ))
  [ "$remaining" -le 0 ] || [ "$elapsed" -lt $(( window / 10 )) ] && return
  eta=$(( elapsed * (100 - pct) / pct ))
  [ "$eta" -lt "$remaining" ] && fmt_duration "$eta"
}

# --- burn-rate color: sets $color; gray under 70%, yellow 70-89%, red 90%+ ---
GRAY="\033[38;2;156;162;175m"
YELLOW="\033[38;2;229;192;123m"
RED="\033[38;2;224;108;117m"
color_for_pct() {
  if [ "$1" -ge 90 ]; then
    color=$RED
  elif [ "$1" -ge 70 ]; then
    color=$YELLOW
  else
    color=$GRAY
  fi
}

# --- context window ---
ctx_tokens_str=""
if [ -n "$used" ] && [ -n "$ctx_used" ] && [ -n "$ctx_total" ]; then
  ctx_tokens_str="$(( ctx_used / 1000 ))k/$(( ctx_total / 1000 ))k"
fi

# --- prompt cache: time until the cache goes cold ---
# Sending before it expires reuses the cached prefix; after, the whole context
# is re-read at full price. Yellow in the last minute, red once cold.
cache_str=""
if [ -n "$cache_warm" ]; then
  cache_left=$(( ${cache_expires:-0} - now_epoch ))
  if [ "$cache_warm" = "true" ] && [ -n "$cache_expires" ] && [ "$cache_left" -gt 0 ]; then
    cache_str="cache $(fmt_duration "$cache_left")"
    if [ "$cache_left" -le 60 ]; then cache_color=$YELLOW; else cache_color=$GRAY; fi
  else
    cache_str="cache cold"
    cache_color=$RED
  fi
fi

# --- fmt_k: 12345 -> "12k", 2400 -> "2.4k", 999 -> "999" ---
fmt_k() {
  n=${1#-}; sign=${1%"$n"}
  if [ "$n" -ge 10000 ]; then echo "${sign}$(( n / 1000 ))k"
  elif [ "$n" -ge 1000 ]; then echo "${sign}$(( n / 1000 )).$(( n % 1000 / 100 ))k"
  else echo "$1"; fi
}

# --- ideogram / elevenlabs usage (line 3) ---
# Read from a cache that usage-fetch.sh refreshes in the background once it's
# older than CLAUDE_WATCH_SERVICES_TTL (300s), so a render never waits on the
# network. CLAUDE_WATCH_SERVICES=0 turns the line off.
ig_left="" ig_total="" ig_reset="" ig_err="" el_used="" el_limit="" el_reset="" el_err=""
if [ "${CLAUDE_WATCH_SERVICES:-1}" != "0" ]; then
  services_cache="${CLAUDE_WATCH_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-watch}/services.json"
  fetched_at=""
  if [ -f "$services_cache" ]; then
    eval "$(jq -r '
      def int: if . == null then "" else floor end;
      @sh "fetched_at=\(.fetched_at | int)",
      @sh "ig_left=\(.ideogram.credits_left | int)",
      @sh "ig_total=\(.ideogram.monthly_credits | int)",
      @sh "ig_reset=\(.ideogram.resets_at | int)",
      @sh "ig_err=\(.ideogram.error // "")",
      @sh "el_used=\(.elevenlabs.used | int)",
      @sh "el_limit=\(.elevenlabs.limit | int)",
      @sh "el_reset=\(.elevenlabs.resets_at | int)",
      @sh "el_err=\(.elevenlabs.error // "")"
    ' "$services_cache" 2> /dev/null)"
  fi
  if [ -z "$fetched_at" ] || [ $(( now_epoch - fetched_at )) -ge "${CLAUDE_WATCH_SERVICES_TTL:-300}" ]; then
    fetcher=${CLAUDE_WATCH_FETCHER:-$(dirname "$0")/usage-fetch.sh}
    [ -f "$fetcher" ] && (sh "$fetcher" > /dev/null 2>&1 &)
  fi
fi

# --- auto-compact warning ---
# Claude Code doesn't pipe its compaction threshold, so warn within 5 points of
# CLAUDE_AUTOCOMPACT_PCT_OVERRIDE when set, else at CLAUDE_WATCH_CTX_WARN (80).
compact_soon=""
if [ -n "$used" ]; then
  if [ -n "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" ]; then
    ctx_warn=$(( CLAUDE_AUTOCOMPACT_PCT_OVERRIDE - 5 ))
  else
    ctx_warn=${CLAUDE_WATCH_CTX_WARN:-80}
  fi
  [ "$used" -ge "$ctx_warn" ] 2>/dev/null && compact_soon="1"
fi

# --- assemble output ---
SEP="\033[90m • \033[0m"
WARN="\033[1m${RED}"

# line 1: model | folder • branch
if [ -n "$in_container" ]; then
  printf "\033[1m\033[38;2;97;175;239m⬢ container\033[22m\033[0m"
  printf "\033[90m | \033[0m"
fi
printf "\033[38;5;208m\033[1m%s\033[22m\033[0m" "$model"
printf "\033[90m | \033[0m"
printf "\033[1m\033[38;2;76;208;222m%s\033[22m\033[0m" "$dir_name"
if [ -n "$branch" ]; then
  printf "%b" "$SEP"
  printf "\033[1m\033[38;2;192;103;222m%s\033[22m\033[0m" "$branch"
  if [ -n "$git_glyphs" ]; then
    printf " \033[2m\033[38;2;156;162;175m%b\033[0m" "$git_glyphs"
  fi
fi
if [ -n "$github_url" ]; then
  printf "%b" "$SEP"
  printf "\033[38;2;156;162;175m%s\033[0m" "$github_url"
fi

# line 2: usage | ctx
printf "\n"
if [ -n "$five_h" ]; then
  color_for_pct "$five_h"; five_h_color=$color
  printf "%b5h %s%%\033[0m" "$five_h_color" "$five_h"
  if [ -n "$five_h_reset" ]; then
    delta=$(compute_delta "$five_h_reset")
    [ -n "$delta" ] && printf " \033[2m%b(%s)\033[0m" "$five_h_color" "$delta"
  fi
  eta=$(burn_eta "$five_h" "$five_h_reset" 18000)
  [ -n "$eta" ] && printf " %b\xe2\x9a\xa0 limit in ~%s\033[0m" "$WARN" "$eta"
fi
if [ -n "$seven_d" ]; then
  [ -n "$five_h" ] && printf "%b" "$SEP"
  color_for_pct "$seven_d"; seven_d_color=$color
  printf "%b7d %s%%\033[0m" "$seven_d_color" "$seven_d"
  if [ -n "$seven_d_reset" ]; then
    delta=$(compute_delta "$seven_d_reset")
    [ -n "$delta" ] && printf " \033[2m%b(%s)\033[0m" "$seven_d_color" "$delta"
  fi
  eta=$(burn_eta "$seven_d" "$seven_d_reset" 604800)
  [ -n "$eta" ] && printf " %b\xe2\x9a\xa0 limit in ~%s\033[0m" "$WARN" "$eta"
fi
if [ -n "$used" ]; then
  color_for_pct "$used"; ctx_color=$color
  printf "\033[90m | \033[0m"
  printf "%bctx %s%%\033[0m" "$ctx_color" "$used"
  [ -n "$ctx_tokens_str" ] && printf " \033[2m%b(%s)\033[0m" "$ctx_color" "$ctx_tokens_str"
  [ -n "$compact_soon" ] && printf " %b\xe2\x9a\xa0 compact soon\033[0m" "$WARN"
fi
if [ -n "$cache_str" ]; then
  printf "\033[90m | \033[0m"
  printf "%b%s\033[0m" "$cache_color" "$cache_str"
fi

# line 3: ideogram credits • elevenlabs characters, colored by share used
services_line=""
if [ -n "$ig_left" ] && [ -n "$ig_total" ] && [ "$ig_total" -gt 0 ]; then
  ig_pct=$(( (ig_total - ig_left) * 100 / ig_total ))
  [ "$ig_pct" -gt 100 ] && ig_pct=100
  color_for_pct "$ig_pct"
  services_line="${color}ideogram $(fmt_k "$ig_left")/$(fmt_k "$ig_total") cr\033[0m"
  delta=$(compute_delta "$ig_reset")
  [ -n "$delta" ] && services_line="${services_line} \033[2m${color}(${delta})\033[0m"
elif [ -n "$ig_err" ]; then
  services_line="\033[2m${GRAY}ideogram ${ig_err}\033[0m"
fi
el_str=""
if [ -n "$el_used" ] && [ -n "$el_limit" ] && [ "$el_limit" -gt 0 ]; then
  el_pct=$(( el_used * 100 / el_limit ))
  color_for_pct "$el_pct"
  el_str="${color}elevenlabs $(fmt_k "$el_used")/$(fmt_k "$el_limit") chars\033[0m"
  delta=$(compute_delta "$el_reset")
  [ -n "$delta" ] && el_str="${el_str} \033[2m${color}(${delta})\033[0m"
elif [ -n "$el_err" ]; then
  el_str="\033[2m${GRAY}elevenlabs ${el_err}\033[0m"
fi
if [ -n "$el_str" ]; then
  [ -n "$services_line" ] && services_line="${services_line}${SEP}"
  services_line="${services_line}${el_str}"
fi
[ -n "$services_line" ] && printf "\n%b" "$services_line"
exit 0
