# claude-watch

![my-minimal-claude-code-statusline-config-v0-bw0th9wf90mg1](https://github.com/user-attachments/assets/05edca4f-749a-433b-b4da-262f840e0a1c)

## Installation

**1. Copy the script**

```sh
cp statusline-command.sh ~/.claude/statusline-command.sh
chmod +x ~/.claude/statusline-command.sh
```

**2. Merge `settings.json` into `~/.claude/settings.json`**

Add the `statusLine` block from `settings.json` into your existing `~/.claude/settings.json`. If you don't have one yet, copy it directly:

```sh
cp settings.json ~/.claude/settings.json
```

**Upgrading from the `fetch-usage.sh` version:** remove its `PreToolUse`/`Stop` hooks from `~/.claude/settings.json`. Claude Code now pipes usage itself, so the script, its hooks and the `/tmp/.claude_usage_cache` / `/tmp/.claude_token_cache` files are no longer used.

## How it works

- **`statusline-command.sh`** — reads the JSON piped by Claude Code and renders two lines: model/folder/branch, then usage stats and context window. When it runs inside a container it prefixes the first line with a `⬢ container` badge, detected through `/.dockerenv` or `$REMOTE_CONTAINERS`.
  - Branch is followed by git status glyphs when dirty: `+N` staged, `~N` modified, `?N` untracked, `↑N`/`↓N` ahead/behind upstream.
  - 5h/7d usage and context-window percentages turn yellow at 70%+ and red at 90%+, so a high burn rate is visible at a glance.
  - Usage comes from the `rate_limits` field Claude Code pipes to the statusline (Pro/Max subscriptions; hidden for API-key, Bedrock and Vertex sessions).
  - **Burn-rate projection:** when the current pace would hit 100% before the window resets, the line shows `⚠ limit in ~40m`. It stays quiet for the first 10% of a window, where the projection is noise.
  - **Compaction warning:** `⚠ compact soon` once the context window reaches 80% (`CLAUDE_WATCH_CTX_WARN` to change it), or 5 points under `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` when that's set.
- **`settings.json`** — wires up the statusline with `refreshInterval: 30`, so reset countdowns tick while idle.

## Tests

```sh
bash test/statusline.test.sh
```

Feeds fixture JSON through the script with a pinned clock (`CLAUDE_WATCH_NOW`) and asserts on the rendered output.

## Dependencies

- `jq`
- `git` (optional, for branch display)

## Notes

- Model name has the `Claude ` prefix stripped (e.g. `Claude Sonnet 4.6` → `Sonnet 4.6`).
