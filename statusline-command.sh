#!/bin/sh
input=$(cat)

in_container=""
if [ -f /.dockerenv ] || [ -n "$REMOTE_CONTAINERS" ]; then
  in_container="1"
fi

# --- model ---
model=$(echo "$input" | jq -r '.model.display_name // ""' | sed 's/^Claude //')

# --- reasoning effort ---
# models with "1M context" -> "(1M - <effort>)", others -> "(<effort>)"
effort=$(echo "$input" | jq -r '.effort.level // ""')
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
dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
dir_name=$(basename "$dir")

# --- git branch + remote URL + status glyphs ---
branch=""
github_url=""
git_glyphs=""
if [ -d "${dir}/.git" ] || git -C "$dir" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || git -C "$dir" rev-parse --short HEAD 2>/dev/null)
  remote_url=$(git -C "$dir" remote get-url origin 2>/dev/null)
  if echo "$remote_url" | grep -q "github.com"; then
    github_url=$(echo "$remote_url" \
      | sed 's|git@github.com:|https://github.com/|' \
      | sed 's|\.git$||')
  fi

  porcelain=$(git -C "$dir" status --porcelain 2>/dev/null)
  staged=$(printf '%s\n' "$porcelain" | grep -c '^[MADRC]')
  modified=$(printf '%s\n' "$porcelain" | grep -c '^.[MD]')
  untracked=$(printf '%s\n' "$porcelain" | grep -c '^??')
  ahead=$(git -C "$dir" rev-list --count '@{u}..HEAD' 2>/dev/null)
  behind=$(git -C "$dir" rev-list --count 'HEAD..@{u}' 2>/dev/null)

  [ "$staged" -gt 0 ] 2>/dev/null && git_glyphs="${git_glyphs} +${staged}"
  [ "$modified" -gt 0 ] 2>/dev/null && git_glyphs="${git_glyphs} ~${modified}"
  [ "$untracked" -gt 0 ] 2>/dev/null && git_glyphs="${git_glyphs} ?${untracked}"
  [ -n "$ahead" ] && [ "$ahead" -gt 0 ] 2>/dev/null && git_glyphs="${git_glyphs} \xe2\x86\x91${ahead}"
  [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null && git_glyphs="${git_glyphs} \xe2\x86\x93${behind}"
  git_glyphs=$(printf '%s' "$git_glyphs" | sed 's/^ *//')
fi

# --- usage stats (5h / 7d), piped by Claude Code as .rate_limits ---
# resets_at is epoch seconds. CLAUDE_WATCH_NOW overrides the clock (tests).
now_epoch=${CLAUDE_WATCH_NOW:-$(date -u "+%s")}
five_h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty | round')
seven_d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty | round')
five_h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty | floor')
seven_d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty | floor')

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
  else
    echo "${minutes}m"
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

# --- burn-rate color: green/gray under 70%, yellow 70-89%, red 90%+ ---
color_for_pct() {
  pct=$(printf "%.0f" "$1" 2>/dev/null)
  [ -z "$pct" ] && pct=0
  if [ "$pct" -ge 90 ]; then
    echo "\033[38;2;224;108;117m"
  elif [ "$pct" -ge 70 ]; then
    echo "\033[38;2;229;192;123m"
  else
    echo "\033[38;2;156;162;175m"
  fi
}

# --- context window ---
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx_str=""
ctx_tokens_str=""
if [ -n "$used" ]; then
  used_int=$(printf "%.0f" "$used")
  ctx_str="${used_int}%"
  ctx_used=$(echo "$input" | jq -r '(.context_window.current_usage.cache_read_input_tokens + .context_window.current_usage.cache_creation_input_tokens + .context_window.current_usage.input_tokens + .context_window.current_usage.output_tokens) // empty' 2>/dev/null)
  ctx_total=$(echo "$input" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)
  if [ -n "$ctx_used" ] && [ -n "$ctx_total" ]; then
    ctx_used_k=$(( ctx_used / 1000 ))
    ctx_total_k=$(( ctx_total / 1000 ))
    ctx_tokens_str="${ctx_used_k}k/${ctx_total_k}k"
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
  [ "$used_int" -ge "$ctx_warn" ] 2>/dev/null && compact_soon="1"
fi

# --- assemble output ---
SEP="\033[90m • \033[0m"
WARN="\033[1m\033[38;2;224;108;117m"

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
  five_h_color=$(color_for_pct "$five_h")
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
  seven_d_color=$(color_for_pct "$seven_d")
  printf "%b7d %s%%\033[0m" "$seven_d_color" "$seven_d"
  if [ -n "$seven_d_reset" ]; then
    delta=$(compute_delta "$seven_d_reset")
    [ -n "$delta" ] && printf " \033[2m%b(%s)\033[0m" "$seven_d_color" "$delta"
  fi
  eta=$(burn_eta "$seven_d" "$seven_d_reset" 604800)
  [ -n "$eta" ] && printf " %b\xe2\x9a\xa0 limit in ~%s\033[0m" "$WARN" "$eta"
fi
if [ -n "$ctx_str" ]; then
  ctx_color=$(color_for_pct "$used")
  printf "\033[90m | \033[0m"
  printf "%bctx %s\033[0m" "$ctx_color" "$ctx_str"
  [ -n "$ctx_tokens_str" ] && printf " \033[2m%b(%s)\033[0m" "$ctx_color" "$ctx_tokens_str"
  [ -n "$compact_soon" ] && printf " %b\xe2\x9a\xa0 compact soon\033[0m" "$WARN"
fi
