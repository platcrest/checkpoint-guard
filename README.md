# checkpoint-guard

A [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) [Stop hook](https://docs.claude.com/en/docs/claude-code/hooks) that stops the agent from ending a turn by handing already-decided work back to you.

You know the pattern:

> I've identified the fix. **Want me to apply it?**

> The change is ready. **Should I commit and push?**

> Here are three options: 1) … 2) … 3) … **Which would you like?**

The work was already determined — the question is theater. A *fake checkpoint* that stalls the turn and makes you do the clicking. This hook catches that move and reflects the turn back with one instruction: if nothing real is blocking, do it now and report the result; if one genuine gate exists (something destructive, a fork with no sane default, input you can't get), do every reversible step first and then name that one gate.

## What it catches

It matches on **form, not subject**. A fake "want me to commit?" and a real "approve this irreversible migration?" are byte-identical, so the hook can't classify by topic — it detects the *handoff shape* and makes the model judge substance. Three tiers:

- **Tier 1 — explicit handoff:** "want me to…", "your call", "let me know how you'd like to proceed", "ready when you are", "thoughts?", or an option menu ("pick one") with ≥2 list items.
- **Tier 2 — permission-seeking:** "should I commit?", "I can push if you want" — asking to do work it already knows how to do.
- **Tier 3 — soft-park:** naming work, then deferring it with a hedge ("left out of scope", "noted for later", "a separate fix until it bites", "flag it if you want").

Properties:

- **Fails open.** Any parse error, missing `jq`, or empty message exits 0 and never traps your turn.
- **Loop-safe.** On the reflect continuation, a genuinely re-stated question or a soft sign-off passes; only a fresh blatant re-offer blocks again.
- **Interactive-only.** Headless / nested `claude -p` runs are skipped.
- **Quote-aware.** Fenced code, blockquotes, and quoted spans are stripped before matching, so a turn that *quotes* a checkpoint phrase won't trip the guard — only the model's own unquoted ask fires it.

## Install

Requires `jq`. `perl` is optional (used only to strip curly quotes).

1. Drop the script into your project:

   ```bash
   mkdir -p .claude/hooks
   curl -o .claude/hooks/checkpoint-guard.sh \
     https://raw.githubusercontent.com/platcrest/checkpoint-guard/main/checkpoint-guard.sh
   chmod +x .claude/hooks/checkpoint-guard.sh
   ```

2. Register it as a Stop hook in `.claude/settings.json`:

   ```json
   {
     "hooks": {
       "Stop": [
         {
           "matcher": "",
           "hooks": [
             {
               "type": "command",
               "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/checkpoint-guard.sh"
             }
           ]
         }
       ]
     }
   }
   ```

Next time the agent tries to end a turn with a fake checkpoint, it gets reflected back instead.

## How it works

On the `Stop` event Claude Code pipes the turn's JSON to the hook over stdin. It reads the last assistant message (falling back to the transcript tail), sanitizes it, lowercases it, and scans for the three tiers. On a hit it returns `decision: "block"` with a reflect prompt as the `reason`, and the model re-runs the turn under that instruction:

> If the remaining work crosses no real gate — destructive/irreversible action, a control-plane diff to approve, a fork with no derivable default, or input you can't get — do it now and report the result. If one gate is real, do every reversible step first, then name that one gate and what it blocks. Don't re-ask, pad, defer work as "optional/later," or invent a gate.

## Tuning

The patterns are plain `grep -E` regexes near the top of the script (`T1`, `AV`, the Tier-2 block, `SP`). Add or remove phrases to fit how your agent talks. Tier 3 is the most aggressive — if legitimate out-of-scope notes get caught, loosen the `SP` patterns.

## License

[MIT](LICENSE)
