# claude-watch

![my-minimal-claude-code-statusline-config-v0-bw0th9wf90mg1](https://github.com/user-attachments/assets/05edca4f-749a-433b-b4da-262f840e0a1c)

## Installation

```sh
./install.sh
```

Copies `statusline-command.sh`, `usage-fetch.sh`, `ideogram-ledger` and `ideogram-hook.sh` into `~/.claude` (or `$CLAUDE_CONFIG_DIR`) and merges the `statusLine` block from `settings.json` into your `settings.json`, keeping everything else. It's safe to re-run: settings are rewritten only when something changes, with a timestamped backup.

**Upgrading from the `fetch-usage.sh` version:** `install.sh` also removes that setup's `PreToolUse`/`Stop` hooks (other hooks are kept). Claude Code now pipes usage itself, so `~/.claude/fetch-usage.sh` and the `/tmp/.claude_usage_cache` / `/tmp/.claude_token_cache` files are no longer used and can be deleted.

## How it works

- **`statusline-command.sh`** — reads the JSON piped by Claude Code and renders two lines: model/folder/branch, then usage stats and context window. When it runs inside a container it prefixes the first line with a `⬢ container` badge, detected through `/.dockerenv` or `$REMOTE_CONTAINERS`.
  - Git info comes from one `git status --porcelain=v2 --branch` call with `--no-optional-locks` (so it never competes with Claude's own git commands for the index lock) and a 1s timeout (`CLAUDE_WATCH_GIT_TIMEOUT`), so a huge repo can't stall the statusline. The whole payload is parsed in a single `jq` pass.
  - Branch is followed by git status glyphs when dirty: `+N` staged, `~N` modified, `?N` untracked, `↑N`/`↓N` ahead/behind upstream.
  - 5h/7d usage and context-window percentages turn yellow at 70%+ and red at 90%+, so a high burn rate is visible at a glance.
  - Usage comes from the `rate_limits` field Claude Code pipes to the statusline (Pro/Max subscriptions; hidden for API-key, Bedrock and Vertex sessions).
  - **Burn-rate projection:** when the current pace would hit 100% before the window resets, the line shows `⚠ limit in ~40m`. It stays quiet for the first 10% of a window, where the projection is noise.
  - **Prompt-cache countdown:** `cache 4m` shows how long until the prompt cache goes cold, turning yellow in the last minute and red at `cache cold`. Sending before it expires reuses the cached context; after, the whole context is re-read at full price.
  - **Compaction warning:** `⚠ compact soon` once the context window reaches 80% (`CLAUDE_WATCH_CTX_WARN` to change it), or 5 points under `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` when that's set.
- **Line 3 — Ideogram credits and ElevenLabs characters:** `ideogram 5/2.4k cr (6d 12h) • elevenlabs 12k/100k chars (5d 3h)`, colored by share used like the usage stats. The statusline only reads a cache (`~/.cache/claude-watch/services.json`); once it's older than `CLAUDE_WATCH_SERVICES_TTL` (300s) it starts `usage-fetch.sh` in the background, so a render never waits on the network. `CLAUDE_WATCH_SERVICES=0` hides the line.
  - **ElevenLabs:** `GET /v1/user/subscription` with the key in `~/.config/elevenlabs/api-key` (or `$ELEVENLABS_API_KEY`). The key needs the **User: Read** (`user_read`) permission; without it the line says `elevenlabs key needs user_read`.
  - **Ideogram** has no balance endpoint, so credits come from one machine-wide ledger that every spender records to (below).
- **`ideogram-ledger`** — the meter for Ideogram's subscription credits (2400 a month, reset at local midnight on the 1st). Linked into `~/.local/bin`.
  - `ideogram-ledger set-left 5.2` — the balance the dashboard shows now. Counting restarts from it until the 1st.
  - `ideogram-ledger add --credits 6 --id <generation_id> --app myapp --what "1 image"` (or `--usd 0.06`, `--estimated`).
  - `ideogram-ledger status` — `{"credits_left", "monthly_credits", "resets_at", "spent", "since"}`.
  - Files live in `~/.local/share/ideogram/` (`$IDEOGRAM_LEDGER_DIR`). `ledger.jsonl` holds one `{"v":1,"t","id","credits","estimated","app","what"}` per line, and `plan.json` holds `{"monthly_credits","credits_left","credits_set_at"}`. Writers append a whole line in one write, so no lock is needed; a container mounts the directory read-write and appends directly (posterize, redline). If an `id` repeats, it counts once: the last exact entry, else the last estimate.
  - The fetcher cross-checks `GET /v2/account/usage` and trusts it when it reports more spend than the ledger. So far it has returned empty line items.
- **`ideogram-hook.sh`** — a PostToolUse hook on `mcp__ideogram__.*`, registered by `install.sh`. The MCP server bills the same credits but reports no cost, so the hook records an estimate per call from Ideogram's price list (4.5: 3/6/10 credits for low/medium/high, 22 for high with source images or edits; ~48 for an x2 upscale). When `get_generation_status` later shows `usage_cost_usd_micros` (upscales do), the exact cost replaces the estimate. Video isn't priced yet. When estimates drift, correct them with `set-left`.
- **`settings.json`** — wires up the statusline with `refreshInterval: 30`, so reset countdowns tick while idle.

## Tests

```sh
bash test/statusline.test.sh   # fixture JSON + pinned clock (CLAUDE_WATCH_NOW) -> rendered output
bash test/usage-fetch.test.sh  # usage-fetch.sh with a fake curl and throwaway ledger/keys
bash test/ideogram-ledger.test.sh  # ledger math, dedup, concurrency, and the MCP hook
bash test/install.test.sh      # install.sh against a throwaway CLAUDE_CONFIG_DIR
```

CI runs both plus shellcheck on every push and PR.

## Dependencies

- `jq`
- `git` (optional, for branch display)
- `curl` (for line 3)
- `timeout` from coreutils (optional; without it git runs without a time limit)

## Notes

- Model name has the `Claude ` prefix stripped (e.g. `Claude Sonnet 4.6` → `Sonnet 4.6`).
