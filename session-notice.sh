#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# session-notice.sh — SessionStart hook. Announces any /naturalize overrides that
# are still in force at the start of a session.
#
# The /naturalize flag files persist across sessions by design (so does the
# off-file). That is convenient but can surprise: a language or model set in an
# earlier session silently applies to a brand-new one. This hook makes it
# visible — it prints a one-line systemMessage listing whatever is active, so a
# new session never applies a leftover override silently. It changes NO state.
#
# Fail-open and non-blocking: SessionStart cannot block a session anyway, and on
# any problem this emits nothing and exits 0.
#
# Config:
#   NATURALIZE_NOTICE 1|0   set 0 to stay silent (shared with the rewrite hooks)
#   NATURALIZE_OFF_FILE / _MODE_FILE / _LANG_FILE / _MODEL_FILE  override paths
# ---------------------------------------------------------------------------
set -uo pipefail

[ "${NATURALIZE_NOTICE:-1}" = "1" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# lang.sh owns the authoritative normalisation of a language value — the same
# fold the on-screen label relies on, so a control character in the flag file
# cannot reach this notice either. Missing file -> the local fallback below.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SELF_DIR/lang.sh" 2>/dev/null || true

# SessionStart delivers JSON on stdin; we don't need any of it, but draining the
# pipe keeps the hook well-behaved.
cat >/dev/null 2>&1 || true

OFF_FILE="${NATURALIZE_OFF_FILE:-$HOME/.claude/naturalize-off}"
MODE_FILE="${NATURALIZE_MODE_FILE:-$HOME/.claude/naturalize-mode}"
STYLE_FILE="${NATURALIZE_STYLE_FILE:-$HOME/.claude/naturalize-style}"
LANG_FILE="${NATURALIZE_LANG_FILE:-$HOME/.claude/naturalize-lang}"
MODEL_FILE="${NATURALIZE_MODEL_FILE:-$HOME/.claude/naturalize-model}"

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
    tldr|5y|caveman) add "style=$(cat "$STYLE_FILE" 2>/dev/null | tr -d '[:space:]')" ;;
  esac
fi

if [ -f "$LANG_FILE" ]; then
  l="$(head -c 64 "$LANG_FILE" 2>/dev/null)"
  if command -v _claudish_lang_clean >/dev/null 2>&1; then
    l="$(_claudish_lang_clean "$l")"
  else
    # lang.sh unavailable: fold control bytes to spaces here rather than print
    # them. tr is byte-oriented, and every byte of a multibyte character is
    # >= 0x80, so UTF-8 names pass through untouched.
    l="$(printf '%s' "$l" | tr '[:cntrl:]' ' ' | tr -s ' ')"
  fi
  [ -n "$(printf '%s' "$l" | tr -d '[:space:]')" ] && add "language=$l"
fi

if [ -f "$MODEL_FILE" ]; then
  m="$(head -c 128 "$MODEL_FILE" 2>/dev/null | tr -cd 'A-Za-z0-9:._/-' | head -c 64)"
  [ -n "$m" ] && add "model=$m"
fi

# Nothing overridden -> stay completely silent.
[ -n "$parts" ] || exit 0

msg="naturalize: overrides from an earlier /naturalize are still active — ${parts}. Run /naturalize to review, or /naturalize reset to clear (set NATURALIZE_NOTICE=0 to silence)."
jq -n --arg m "$msg" '{systemMessage:$m}' 2>/dev/null || exit 0
exit 0
