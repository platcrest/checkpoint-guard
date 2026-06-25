#!/usr/bin/env bash
# Stop hook: blocks a turn that ends by handing determined work back to the operator
# (a fake checkpoint — "want me to land this?", "your call", "should I commit?", an option
# menu) and injects the gate test. Detects FORM, not subject: a fake ask and a real control-
# plane ask are byte-identical, so the reflect makes the model judge substance. Fail-open on
# any parse error (never trap a turn). On a reflect continuation a soft-close sign-off or a
# re-stated question passes (no loop) — only a fresh blatant re-offer blocks again.

input=$(cat 2>/dev/null) || exit 0
jq_bin=$(command -v jq 2>/dev/null || echo /usr/bin/jq)
[ -n "${CLAUDE_HEADLESS:-}${CLAUDE_CODE_CHILD_SESSION:-}" ] && exit 0   # interactive-only: never trap a headless/nested claude -p run

active=$(printf '%s' "$input" | "$jq_bin" -r '.stop_hook_active // false' 2>/dev/null)
tp=$(printf '%s' "$input" | "$jq_bin" -r '.transcript_path // empty' 2>/dev/null)
msg=$(printf '%s' "$input" | "$jq_bin" -r '.last_assistant_message // .assistant_message // empty' 2>/dev/null)

# fallback: join the text blocks of the last assistant turn from the transcript tail
# (schema: top-level type:"assistant", .message.content[] blocks; tail -50, never the full JSONL)
if [ -z "$msg" ] && [ -n "$tp" ] && [ -f "$tp" ]; then
  msg=$(tail -n 50 "$tp" 2>/dev/null | "$jq_bin" -rs '
    map(select(.type=="assistant" and (.message.content|type=="array")
               and (.message.content|any(.type=="text"))))
    | last // {} | .message.content // [] | map(select(.type=="text") | .text) | join("\n")' 2>/dev/null)
fi
[ -n "$msg" ] || exit 0

# sanitize: drop fenced code + blockquotes, then strip "quoted"/`backticked`/curly-quoted spans
# so a turn that QUOTES a checkpoint phrase passes — only the model's own unquoted ask fires.
# Not single quotes (apostrophes in don't / I'll would break the patterns).
clean=$(printf '%s\n' "$msg" | awk '/^[[:space:]]*```/ { f = !f; next } f { next } /^[[:space:]]*>/ { next } { print }')
clean=$(printf '%s' "$clean" | sed -e 's/`[^`]*`//g' -e 's/"[^"]*"//g')
command -v perl >/dev/null 2>&1 && clean=$(printf '%s' "$clean" | perl -CSD -pe 's/\x{201C}.*?\x{201D}//g' 2>/dev/null)

# scan the WHOLE message (lowercased): a fake checkpoint can sit above trailing prose/bullets
scan=$(printf '%s' "$clean" | tr '[:upper:]' '[:lower:]')

AV='(add|write|change|run|deploy|push|merge|commit|implement|update|remove|create|delete|refactor|land|apply|build|fix|revert|rollback|rename|move|extract|drop|set up|wire|install)'
frag=""; tier2=""

# Tier 1: explicit delegation/handoff — always fires, anywhere in the message (these forms are
# performative; they don't occur referentially in normal prose).
T1='want me to|do you want me to|would you (like|prefer|want) me to'
T1="$T1"'|(do you want|would you like) (it|this|that) (applied|implemented|landed|committed|pushed|shipped)'
T1="$T1"'|(proceed|continue|apply|implement|land it|push it|ship it)\?|(ok|okay|all right) to (proceed|continue|apply|implement|land|push|ship|run)'
T1="$T1"'|up to you|at your discretion|awaiting your (word|call|go|approval)|ready when you are|standing by'
T1="$T1"'|say the word|give( me)?( the)? (word|green light|go.?ahead)|on your (go|signal)|the ball.?s?( is)? in your court'
T1="$T1"'|over to you|the choice is yours|pending your (confirmation|approval)|how would you like|let me know what you think|thoughts\?|wdyt'
T1="$T1"'|i.?ll (pause|stop|hold) here|i.?ll leave (it|this) (to|with) you'
frag=$(printf '%s' "$scan" | grep -oE "$T1" 2>/dev/null | head -1)

# "your call" / "your move" are handoffs too, but also backward references in completion prose
# ("your call honored"). Fire ONLY at a clause boundary — followed by , . ? ! : or end-of-line —
# which is syntactic, not positional: it spares the referential use at any length/position.
# (Colon catches the "your call:" + list handoff form; a referential "your call" is word-followed.)
if [ -z "$frag" ]; then
  frag=$(printf '%s' "$scan" | grep -oE 'your (call|move)([,.?!:]|$)' 2>/dev/null | head -1)
fi

# option-menu closer: a clause-boundary cue (so "pick one X" prose doesn't trip it) + >=2 list items
if [ -z "$frag" ] && printf '%s' "$scan" | grep -Eq '(choose|pick) one([,.?!:]|$)|which option|needs? your (decision|input|call)'; then
  items=$(printf '%s\n' "$clean" | grep -cE '^[[:space:]]*([0-9]+[.)]|[-*])[[:space:]]')
  [ "${items:-0}" -ge 2 ] && frag="option-menu handoff"
fi

# Tier 2: ambiguous permission to do a determined action ("should I commit?", "I can push if you
# want") — always fires (no length escape; a genuine fork is caught and re-stated as a named gate).
if [ -z "$frag" ]; then
  t2=""
  printf '%s' "$scan" | grep -Eq '\b(should|shall|may|can) i\b' \
    && printf '%s' "$scan" | grep -Eq "\b$AV\b" \
    && t2=$(printf '%s' "$scan" | grep -oE '\b(should|shall|may|can) i\b[^.?!]*' | head -1)
  [ -z "$t2" ] && t2=$(printf '%s' "$scan" | grep -oE 'let me know (how|which|whether to|how you.?d like|how you want|your preference|once you|after you)' | head -1)
  if [ -z "$t2" ] && printf '%s' "$scan" | grep -Eq '\b(i can|i could|i.?ll)\b' \
       && printf '%s' "$scan" | grep -Eq 'if you want|if you.?d like|if you approve|once you confirm|on your go.?ahead|say the word' \
       && printf '%s' "$scan" | grep -Eq "\b$AV\b"; then
    t2="conditional offer to do determined work"
  fi
  [ -n "$t2" ] && { frag="$t2"; tier2=1; }
fi

# Tier 3: soft-park — naming work you identified, then deferring it with a hedge instead of doing it
# or naming a real gate ("a clean separate fix until it actually bites", "left out of scope", "noted for
# later", "one watch item", "flag it if you want X"). Now detected. Bias to catch: a genuine out-of-scope
# note is the accepted false positive, one cheap reflect for the model to judge. tier2=1 → loop-safe.
if [ -z "$frag" ]; then
  SP='(if|when|once|until|unless|till)\b[^.?!]*\bbites?\b|comes?( back| around| round)* to bite|\bbites? (us|you|me|back)\b'
  SP="$SP"'|if it ever (surfaces|comes up|matters|breaks)'
  SP="$SP"'|(clean |its own )?separate (fix|change|task|pr|concern)'
  SP="$SP"'|(deliberately )?left (it |this |that )?(out of scope|for later|unaddressed)'
  SP="$SP"'|out of scope (if|but|for now)|noted for later|park(ed|ing)?\b'
  SP="$SP"'|for a (future|later|separate) (session|pass|fix|turn|time|change)|down the line|for later'
  SP="$SP"'|watch[ -]?item|(flag|let me know|tell me|ping me|lmk)( (it|this|that|me))? (if you want|if you.?d like)'
  frag=$(printf '%s' "$scan" | grep -oE "$SP" 2>/dev/null | head -1)
  [ -n "$frag" ] && tier2=1
fi

[ -n "$frag" ] || exit 0

# Reflect continuation (already blocked once this turn): pass a soft-close sign-off or a re-stated
# question (Tier 2) so a genuine fork can't loop; a fresh blatant Tier-1 re-offer still blocks.
if [ "$active" = "true" ]; then
  [ -n "$tier2" ] && exit 0
  printf '%s' "$frag" | grep -qE "i.?ll (pause|stop|hold) here|i.?ll leave (it|this) (to|with) you" && exit 0
fi

reflect="Guard: \"$frag\". If the remaining work crosses no real gate — destructive/irreversible action, a control-plane diff to approve, a fork with no derivable default, or input you can't get — do it now and report the result. If one gate is real, do every reversible step first, then name that one gate and what it blocks. Don't re-ask, pad, defer work as \"optional/later,\" or invent a gate."

"$jq_bin" -nc --arg r "$reflect" \
  '{decision:"block",reason:$r,hookSpecificOutput:{hookEventName:"Stop",additionalContext:$r}}' 2>/dev/null \
  || { printf '%s\n' "$reflect" >&2; exit 2; }
exit 0
