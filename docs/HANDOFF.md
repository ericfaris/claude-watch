# Handoff — claude-watch

## What it is

The Claude Code statusline for this machine, plus the machine-wide Ideogram credit meter.
It's a fork of an upstream statusline repo (`origin` = `ericfaris/claude-watch`). It runs locally out of
`~/.claude` and isn't deployed anywhere.

- Line 1: model (effort), folder, branch + git glyphs, GitHub URL, container badge.
- Line 2: 5h/7d usage with countdowns and burn-rate warning, context window and compaction
  warning, prompt-cache countdown. All of it comes from the JSON Claude Code pipes in.
- Line 3: `ideogram <left>/<monthly> cr (reset)` • `elevenlabs <used>/<limit> chars (reset)`, read
  from `~/.cache/claude-watch/services.json`. `usage-fetch.sh` refreshes that cache in the background
  when it's more than 300s old.

## Commands

```sh
./install.sh                         # copy scripts to ~/.claude, link ~/.local/bin/ideogram-ledger,
                                     # merge statusLine + the mcp__ideogram__ PostToolUse hook into settings.json
bash test/statusline.test.sh         # rendering
bash test/usage-fetch.test.sh        # fetcher (fake curl)
bash test/ideogram-ledger.test.sh    # ledger math + MCP hook
bash test/install.test.sh            # installer
shellcheck -s sh -S warning statusline-command.sh usage-fetch.sh ideogram-ledger ideogram-hook.sh install.sh
```

CI (`.github/workflows/test.yml`) runs all of the above. After changing a script, re-run
`./install.sh`. The installed copies in `~/.claude` are what actually run.

## Config and state outside git

- `~/.config/ideogram/api-key` and `~/.config/elevenlabs/api-key` (mode 600): machine-wide keys.
  The ElevenLabs key needs **User: Read** (added 2026-10-25), or line 3 shows
  `elevenlabs key needs user_read`.
- `~/.local/share/ideogram/{ledger.jsonl,plan.json}`: the shared credit ledger.
  `ideogram-ledger set-left <n>` sets the dashboard balance. The spec is in the README and in
  global `~/.claude/CLAUDE.md` → "Ideogram".
- `~/.claude/settings.json`: the `statusLine` block and the `PostToolUse` hook
  (`sh ~/.claude/ideogram-hook.sh`). `install.sh` keeps other settings and hooks.

## Shared-system wiring

- Writers to the ledger: posterize (`posterize/shared_ledger.py`, mounted at `/run/ideogram`),
  redline (`scripts/ideogramLedger.ts`), and Claude's MCP calls through `ideogram-hook.sh`.
- Not registered with Sentinel or Cloudflare, since nothing is served.

## Open items (priority order)

1. vandal-preachers still reads `ELEVENLABS_API_KEY` from `deploy/env/{campaign,frostscribe}.env`.
   Switch it to a read-only mount of `~/.config/elevenlabs/api-key` plus `*_API_KEY_FILE`.
2. The hook's price table is an estimate (4.5 low/medium/high = 3/6/10, 22 with images or edits;
   upscale x2 ≈ 48; Ideogram 3/4 guessed at 3/6/9; video unpriced = 0). Correct drift with
   `set-left`.
3. The `/v2/account/usage` line-item shape is a guess (`credits`, else `*usd_micros`). Verify it
   if the endpoint ever starts returning data.

## Decisions that may get revisited

- Split by role: code uses the Ideogram **API** (exact costs) and interactive work uses the
  **MCP** (estimated by the hook). Only subscription credits are tracked, not the API $ balance
  (the user's choice, 2026-10-25).
- Ideogram usage isn't read from any one app (an early draft asked posterize's container). It
  comes from the app-neutral ledger, so it survives apps going away.

## Gotchas

- A statusline render must never block on the network: only the cache is read, and the fetcher
  is detached and holds a mkdir lock (stale after 60s).
- Keys go to curl on stdin (`-H @-`), never on argv.
- jq `//` swallows `false`. Use `if . == null` for booleans (prompt-cache `warm`).
- Spend in the same second as `set-left` is already in the anchor. Anchored counts use `t > since`.
