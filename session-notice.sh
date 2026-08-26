#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# session-notice.sh — SessionStart hook. Announces any /claudish overrides that
# are still in force at the start of a session.
#
# The /claudish flag files persist across sessions by design (so does the
# off-file). That is convenient but can surprise: a language or model set in an
# earlier session silently applies to a brand-new one. This hook makes it
# visible — it prints a one-line systemMessage listing whatever is active, so a
# new session never applies a leftover override silently. It changes NO state.
#
# Fail-open and non-blocking: SessionStart cannot block a session anyway, and on
# any problem this emits nothing and exits 0.
#
# Config:
#   CLAUDISH_NOTICE 1|0   set 0 to stay silent (shared with the rewrite hooks)
#   CLAUDISH_OFF_FILE / _MODE_FILE / _LANG_FILE / _MODEL_FILE  override paths
# ---------------------------------------------------------------------------
set -uo pipefail

[ "${CLAUDISH_NOTICE:-1}" = "1" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# SessionStart delivers JSON on stdin; we don't need any of it, but draining the
# pipe keeps the hook well-behaved.
cat >/dev/null 2>&1 || true

OFF_FILE="${CLAUDISH_OFF_FILE:-$HOME/.claude/claudish-off}"
MODE_FILE="${CLAUDISH_MODE_FILE:-$HOME/.claude/claudish-mode}"
STYLE_FILE="${CLAUDISH_STYLE_FILE:-$HOME/.claude/claudish-style}"
LANG_FILE="${CLAUDISH_LANG_FILE:-$HOME/.claude/claudish-lang}"
MODEL_FILE="${CLAUDISH_MODEL_FILE:-$HOME/.claude/claudish-model}"

parts=""
add() { parts="${parts:+$parts, }$1"; }

[ -f "$OFF_FILE" ] && add "off (rewrites paused)"

if [ -f "$MODE_FILE" ]; then
  case "$(cat "$MODE_FILE" 2>/dev/null | tr -d '[:space:]')" in
    append|replace) add "mode=$(cat "$MODE_FILE" 2>/dev/null | tr -d '[:space:]')" ;;
  esac
fi

if [ -f "$STYLE_FILE" ]; then
  case "$(cat "$STYLE_FILE" 2>/dev/null | tr -d '[:space:]')" in
    tldr|5y) add "style=$(cat "$STYLE_FILE" 2>/dev/null | tr -d '[:space:]')" ;;
  esac
fi

if [ -f "$LANG_FILE" ]; then
  l="$(head -c 64 "$LANG_FILE" 2>/dev/null | tr -d '\r\n' | tr -s ' ')"
  [ -n "$(printf '%s' "$l" | tr -d '[:space:]')" ] && add "language=$l"
fi

if [ -f "$MODEL_FILE" ]; then
  m="$(head -c 128 "$MODEL_FILE" 2>/dev/null | tr -cd 'A-Za-z0-9:._/-' | head -c 64)"
  [ -n "$m" ] && add "model=$m"
fi

# Nothing overridden -> stay completely silent.
[ -n "$parts" ] || exit 0

msg="claudish: overrides from an earlier /claudish are still active — ${parts}. Run /claudish to review, or /claudish reset to clear (set CLAUDISH_NOTICE=0 to silence)."
jq -n --arg m "$msg" '{systemMessage:$m}' 2>/dev/null || exit 0
exit 0
