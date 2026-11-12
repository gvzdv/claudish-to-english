#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# codex-stop.sh — Codex CLI Stop hook: APPEND-mode plain-language rewrite.
#
# Codex has no hook that can change displayed assistant text (no equivalent of
# Claude Code's MessageDisplay), so this mirrors the Claude Code `append` mode
# as closely as Codex allows: when a turn ends, the final assistant message is
# rewritten and the rewrite is returned as {"systemMessage": "..."}, which
# Codex shows as a warning-styled message BELOW the original. The original
# stays on screen and in history; the rewrite never enters model context.
# (suppressOutput is parsed but not implemented by Codex, so `replace` mode is
# impossible here; NATURALIZE_MODE is ignored and append is forced.)
#
# The rewrite itself is NOT duplicated here: the message is fed to rewrite.sh
# as a synthetic two-chunk MessageDisplay stream (whole text, then an empty
# final chunk), so every display-hook setting applies unchanged —
# NATURALIZE_ENABLED, NATURALIZE_OFF_FILE, NATURALIZE_STYLE(_FILE), NATURALIZE_LANG /
# language, NATURALIZE_PROMPT_FILE, NATURALIZE_PROVIDER, NATURALIZE_MODEL,
# NATURALIZE_CODEX_EFFORT, NATURALIZE_TIMEOUT, NATURALIZE_MIN_CHARS, NATURALIZE_STUB,
# NATURALIZE_DEBUG, NATURALIZE_NOTICE, and the provider keys (providers.sh).
#
# OUTPUT CONTRACT: Codex requires JSON on stdout for Stop when exiting 0.
# We ALWAYS exit 0 and print either {"systemMessage": ...} or {}. We never
# print decision:block (that would start a continuation turn). Skips -> {}:
#   - last_assistant_message null/empty, or stop_hook_active true
#   - NATURALIZE_HOOK_DEPTH set (we are inside a nested `codex exec` started by
#     the codex provider — recursion guard)
#   - rewrite.sh disabled/failed/too short, or rewrite empty/identical
# ---------------------------------------------------------------------------
set -uo pipefail

out_empty() { printf '{}\n'; exit 0; }

# Recursion guard: the codex provider runs `codex exec`, which could load this
# plugin's hooks again. The marker is exported below and inherited by the
# nested codex process and its hooks. (providers.sh also passes
# `--disable hooks` to that nested call; this is the belt to those braces.)
[ -n "${NATURALIZE_HOOK_DEPTH:-}" ] && out_empty
export NATURALIZE_HOOK_DEPTH=1

command -v jq >/dev/null 2>&1 || out_empty
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -x "$SELF_DIR/rewrite.sh" ] || [ -f "$SELF_DIR/rewrite.sh" ] || out_empty

payload="$(cat)"
[ -n "$payload" ] || out_empty

active="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)"
[ "$active" = "true" ] && out_empty
msg="$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty' 2>/dev/null)"
[ -n "${msg//[[:space:]]/}" ] || out_empty
sid="$(printf '%s' "$payload" | jq -r '.session_id // "codex"' 2>/dev/null)"
tid="$(printf '%s' "$payload" | jq -r '.turn_id // empty' 2>/dev/null)"
[ -n "$tid" ] || tid="t$$.$(date +%s)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
[ -d "$cwd" ] || cwd="$PWD"
mid="codex-$tid"

# Chunk 0 carries the whole message (append mode: rewrite.sh just buffers it
# and prints nothing); the empty final chunk triggers the rewrite, and its
# displayContent is then "<empty final delta><label><rewrite>".
# transcript_path is deliberately not forwarded: rewrite.sh parses the Claude
# Code transcript format, and Codex's rollout format is not a stable interface.
chunk() {
  jq -nc --arg sid "$sid" --arg mid "$mid" --arg cwd "$cwd" --arg d "$1" \
    --argjson i "$2" --argjson f "$3" \
    '{session_id:$sid,message_id:$mid,cwd:$cwd,index:$i,final:$f,delta:$d,hook_event_name:"MessageDisplay"}'
}
chunk "$msg" 0 false | NATURALIZE_MODE=append NATURALIZE_MODE_FILE=/dev/null/none \
  bash "$SELF_DIR/rewrite.sh" >/dev/null 2>&1
res="$(chunk "" 1 true | NATURALIZE_MODE=append NATURALIZE_MODE_FILE=/dev/null/none \
  bash "$SELF_DIR/rewrite.sh" 2>/dev/null)"

dc="$(printf '%s' "$res" | jq -r '.hookSpecificOutput.displayContent // empty' 2>/dev/null)"
[ -n "${dc//[[:space:]]/}" ] || out_empty
dc="${dc#"${dc%%[![:space:]]*}"}"   # drop the leading blank lines before the rule

# Unchanged check: the text after the label line equals the original.
body="${dc#*$'────────────────────────\n'}"
body="${body#*$'\n'}"
norm() { printf '%s' "$1" | tr -d '[:space:]'; }
[ -n "$(norm "$body")" ] || out_empty
[ "$(norm "$body")" = "$(norm "$msg")" ] && out_empty

jq -nc --arg m "$dc" '{systemMessage:$m}' 2>/dev/null || out_empty
exit 0
