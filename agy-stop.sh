#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# agy-stop.sh — Antigravity CLI (agy) Stop hook: APPEND-mode plain-language
# rewrite. PROTOTYPE.
#
# Antigravity has no hook that can display text or replace the reply. The only
# way to get the rewrite on screen is the Stop hook's {"decision":"continue",
# "reason":...}: the loop re-enters with `reason` injected as a system message.
# So this hook (1) reads the final assistant text from the transcript,
# (2) rewrites it through rewrite.sh (all NATURALIZE_* settings apply), and
# (3) returns "continue" with a reason that EMBEDS the finished rewrite and
# tells the model to output it verbatim, with no tools. That "echo pass" is a
# second model turn: it costs a model call and the echo is the model's, so
# it is not guaranteed byte-identical (see README caveats).
#
# Observed agy payload (CLI, 2026-10) differs from the docs: terminationReason
# was "NO_TOOL_CALL" (docs: "model_stop") and transcriptPath pointed to
# .../logs/transcript_full.jsonl. Both are accepted. Transcript lines are JSON
# steps; the assistant reply is the last {"type":"PLANNER_RESPONSE",
# "source":"MODEL"} step with non-empty .content.
#
# Loop guard: before returning "continue", a marker
# $STATE/<conversationId>.echo is written (default STATE:
# $TMPDIR/naturalize-agy); the next Stop for that
# conversation (the end of the echo pass) sees it, deletes it, and allows the
# stop. Markers older than 15 min are treated as stale. Recursion guard:
# NATURALIZE_HOOK_DEPTH is exported for the rewrite, so if the provider is a
# nested `agy -p` that loads this hook again, it exits at once.
#
# OUTPUT CONTRACT: always exit 0. Print {"decision":"continue",...} only when
# a rewrite is ready; otherwise {} (allow stop). Fail open on every error.
# ---------------------------------------------------------------------------
set -uo pipefail

allow() { printf '{}\n'; exit 0; }

[ -n "${NATURALIZE_HOOK_DEPTH:-}" ] && allow
export NATURALIZE_HOOK_DEPTH=1
command -v jq >/dev/null 2>&1 || allow
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SELF_DIR/rewrite.sh" ] || allow

payload="$(cat)"
[ -n "$payload" ] || allow
get() { printf '%s' "$payload" | jq -r "$1" 2>/dev/null; }

cid="$(get '.conversationId // empty' | tr -cd 'A-Za-z0-9_-')"
[ -n "$cid" ] || allow
# Deliberately NOT under rewrite.sh's buffer root ($TMPDIR/naturalize):
# rewrite.sh sweeps empty subdirectories there that are older than 30 min, which
# deleted this state dir mid-hook and made the marker write fail (no echo).
STATE="${NATURALIZE_AGY_STATE:-${TMPDIR:-/tmp}/naturalize-agy}"
mkdir -p "$STATE" 2>/dev/null || allow
marker="$STATE/$cid.echo"

# End of our own echo pass -> allow the stop (and clear the marker).
if [ -f "$marker" ]; then
  stale="$(find "$marker" -mmin +15 2>/dev/null)"
  rm -f "$marker"
  [ -z "$stale" ] && allow
fi

reason="$(get '.terminationReason // empty' | tr '[:upper:]' '[:lower:]')"
case "$reason" in model_stop|no_tool_call) ;; *) allow ;; esac
[ "$(get '.fullyIdle // false')" = "true" ] || allow
[ -z "$(get '.error // empty')" ] || allow

tp="$(get '.transcriptPath // empty')"
tp="${tp/#\~/$HOME}"
# The App, IDE and CLI keep transcripts under different app_data_dirs
# (~/.gemini/antigravity, antigravity-ide, antigravity-cli); we only trust the
# payload's path, but accept either file name in that same logs directory.
if [ ! -f "$tp" ] && [ -n "$tp" ]; then
  for alt in "${tp%/*}/transcript_full.jsonl" "${tp%/*}/transcript.jsonl"; do
    [ -f "$alt" ] && { tp="$alt"; break; }
  done
fi
[ -f "$tp" ] || allow
msg="$(jq -rs 'map(select(.type=="PLANNER_RESPONSE" and (.source//"MODEL")=="MODEL" and ((.content//"")|length>0))) | last | .content // empty' "$tp" 2>/dev/null)"
[ -n "${msg//[[:space:]]/}" ] || allow
cwd="$(get '.workspacePaths[0] // empty')"; [ -d "$cwd" ] || cwd="$PWD"

# Drive rewrite.sh exactly like a Claude MessageDisplay stream (append mode):
# chunk 0 = whole text (buffered), empty final chunk triggers the rewrite.
mid="agy-$cid-$(get '.executionNum // 0')"
chunk() {
  jq -nc --arg sid "agy-$cid" --arg mid "$mid" --arg cwd "$cwd" --arg d "$1" \
    --argjson i "$2" --argjson f "$3" \
    '{session_id:$sid,message_id:$mid,cwd:$cwd,index:$i,final:$f,delta:$d,hook_event_name:"MessageDisplay"}'
}
chunk "$msg" 0 false | NATURALIZE_MODE=append NATURALIZE_MODE_FILE=/dev/null/none \
  NATURALIZE_NOTICE="${NATURALIZE_NOTICE:-0}" bash "$SELF_DIR/rewrite.sh" >/dev/null 2>&1
res="$(chunk "" 1 true | NATURALIZE_MODE=append NATURALIZE_MODE_FILE=/dev/null/none \
  NATURALIZE_NOTICE="${NATURALIZE_NOTICE:-0}" bash "$SELF_DIR/rewrite.sh" 2>/dev/null)"
dc="$(printf '%s' "$res" | jq -r '.hookSpecificOutput.displayContent // empty' 2>/dev/null)"
# Keep "<rule>\n<label>\n\n<rewrite>", same as the Claude Code append block:
# drop only the blank lines before the rule.
case "$dc" in *$'────────────────────────\n'*) ;; *) allow ;; esac
rest="${dc#*$'────────────────────────\n'}"
out="────────────────────────"$'\n'"$rest"
body="${rest#*$'\n'}"
norm() { printf '%s' "$1" | tr -d '[:space:]'; }
[ -n "$(norm "$body")" ] || allow
[ "$(norm "$body")" = "$(norm "$msg")" ] && allow

instr="naturalize (plain-language display hook): your previous reply is complete. Now output ONLY the text between the markers BEGIN-CLAUDISH and END-CLAUDISH below, verbatim and in full, as your entire reply. Do not translate, summarize, rephrase, add anything before or after it, include the markers, or call any tools. This is not a new task.
BEGIN-CLAUDISH
$out
END-CLAUDISH"
mkdir -p "$STATE" 2>/dev/null; : > "$marker" 2>/dev/null || allow
jq -nc --arg r "$instr" '{decision:"continue",reason:$r}' 2>/dev/null || { rm -f "$marker"; allow; }
exit 0
