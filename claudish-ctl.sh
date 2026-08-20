#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# claudish-ctl.sh — runtime state switcher + dashboard backing /claudish.
#
# The hooks re-read flag files on every message, so switches take effect mid-
# session where the frozen env cannot:
#   off-file   (default ~/.claude/claudish-off)    exists -> rewrites paused
#   mode-file  (default ~/.claude/claudish-mode)   append|replace -> display mode
#   style-file (default ~/.claude/claudish-style)  tldr|5y -> rewrite style (display hook)
#   lang-file  (default ~/.claude/claudish-lang)   rewrite language (see lang.sh)
#   model-file (default ~/.claude/claudish-model)  model (see providers.sh)
# rewrite.sh reads mode/style; lang/model/off are shared with rewrite-md.sh.
# They PERSIST across sessions (like the off-file) until cleared — the dashboard
# flags any that are in force so that persistence is never a silent surprise,
# and the SessionStart hook (session-notice.sh) announces them on a new session.
#
# Usage: claudish-ctl.sh [status|on|off|append|replace|style [name]|language [name]|model [name]|last|cycle|reset]
#   status        (default) print the dashboard: every setting, its value, and
#                 WHERE that value comes from (env / a /claudish flag / default)
#   on            resume rewrites (keeps the current mode)
#   off           pause rewrites (originals only; also pauses the Markdown hook)
#   append        original + rewrite appended (and turn on)
#   replace       rewrite only (and turn on)
#   style X       rewrite style: "tldr" (short summary) or "5y" (explain like
#                 I'm five); no name / "default" resets to the plain rewrite.
#                 A custom CLAUDISH_PROMPT_FILE always wins over styles
#   language X    rewrite into language X, e.g. "language Brazilian Portuguese"
#                 (no name / "default" resets to the session/settings language)
#   model X       use model X for whatever provider is configured (no name /
#                 "default" resets to the provider default; also turns on)
#   last          print the ORIGINAL text of the last assistant message
#   cycle         off -> append -> replace -> off
#   reset         clear ALL overrides (off/mode/style/language/model) -> env
#
# Mutating commands print a one-line confirmation:
#   "claudish: <off|append|replace> (style: …, language: …, model: …)".
# Writes fail loudly (exit 1) if a flag file cannot be created/removed.
# ---------------------------------------------------------------------------
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

OFF_FILE="${CLAUDISH_OFF_FILE:-$HOME/.claude/claudish-off}"
MODE_FILE="${CLAUDISH_MODE_FILE:-$HOME/.claude/claudish-mode}"
STYLE_FILE="${CLAUDISH_STYLE_FILE:-$HOME/.claude/claudish-style}"
LANG_FILE="${CLAUDISH_LANG_FILE:-$HOME/.claude/claudish-lang}"
MODEL_FILE="${CLAUDISH_MODEL_FILE:-$HOME/.claude/claudish-model}"

# The /claudish slash command passes the user's whole argument string as ONE
# quoted "$ARGUMENTS" positional, so nothing typed after /claudish is re-parsed
# as shell syntax. Split that single string back into words here (globbing off,
# so a literal "*" is not expanded) to keep multi-word args like
# `language Brazilian Portuguese` working. A direct multi-arg call from a
# terminal already has $# > 1 and is left untouched; an empty string yields zero
# positionals, so bare `/claudish` still falls through to the status dashboard.
if [ $# -le 1 ]; then
  set -f
  # shellcheck disable=SC2086
  set -- ${1:-}
  set +f
fi

fail() { printf 'claudish-ctl: %s\n' "$1" >&2; exit 1; }

# Borrow the hooks' own resolvers so the dashboard can't drift from them:
# providers.sh sets PROVIDER + the provider-default MODEL, lang.sh resolves the
# effective language. providers.sh is sourced with its model-file override
# NEUTRALISED (pointed at a path that does not exist) so $MODEL is the clean
# PROVIDER default — otherwise a `model default` that removes the file this same
# run would read the file's value back through $MODEL. current_model reads the
# real file itself, fresh. Both sources are fail-soft.
_saved_mf="${CLAUDISH_MODEL_FILE:-}"
export CLAUDISH_MODEL_FILE="$SELF_DIR/.claudish-no-model-file"
MODEL=""; PROVIDER=""
dbg() { :; }
. "$SELF_DIR/providers.sh" 2>/dev/null || true
if [ -n "$_saved_mf" ]; then export CLAUDISH_MODEL_FILE="$_saved_mf"; else unset CLAUDISH_MODEL_FILE; fi
claudish_language() { :; }
. "$SELF_DIR/lang.sh" 2>/dev/null || true

# ---- effective values (each reads its flag file FRESH) --------------------
current_model() {
  m=""
  [ -f "$MODEL_FILE" ] && m="$(head -c 128 "$MODEL_FILE" 2>/dev/null | tr -cd 'A-Za-z0-9:._/-' | head -c 64)"
  [ -n "$m" ] && { printf '%s' "$m"; return; }
  printf '%s' "${MODEL:-${CLAUDISH_MODEL:-unknown}}"
}
current_lang() {
  l="$(claudish_language "$PWD" 2>/dev/null)"
  [ -n "$l" ] && printf '%s' "$l" || printf 'auto'
}
current_mode() {
  m=""
  [ -f "$MODE_FILE" ] && m="$(cat "$MODE_FILE" 2>/dev/null | tr -d '[:space:]')"
  case "$m" in append|replace) printf '%s' "$m" ;; *) printf '%s' "${CLAUDISH_MODE:-append}" ;; esac
}
current_style() {
  s=""
  [ -f "$STYLE_FILE" ] && s="$(cat "$STYLE_FILE" 2>/dev/null | tr -d '[:space:]')"
  case "$s" in tldr|5y) printf '%s' "$s"; return ;; esac
  case "${CLAUDISH_STYLE:-}" in tldr|5y) printf '%s' "$CLAUDISH_STYLE" ;; *) printf 'default' ;; esac
}
state() { [ -f "$OFF_FILE" ] && printf 'off' || current_mode; }

turn_on() { rm -f "$OFF_FILE" 2>/dev/null || fail "cannot remove $OFF_FILE"; }
set_mode() { { printf '%s\n' "$1" > "$MODE_FILE"; } 2>/dev/null || fail "cannot write $MODE_FILE"; turn_on; }

# ---- provenance: where does each effective value come from? ---------------
# "flag" is the one worth flagging — a /claudish file that persists across
# sessions. The dashboard turns these into a ⚠ line.
mode_source() {
  if [ -f "$MODE_FILE" ]; then
    case "$(cat "$MODE_FILE" 2>/dev/null | tr -d '[:space:]')" in append|replace) echo flag; return ;; esac
  fi
  [ -n "${CLAUDISH_MODE+x}" ] && { echo env; return; }
  echo default
}
style_source() {
  if [ -f "$STYLE_FILE" ]; then
    case "$(cat "$STYLE_FILE" 2>/dev/null | tr -d '[:space:]')" in tldr|5y) echo flag; return ;; esac
  fi
  case "${CLAUDISH_STYLE:-}" in tldr|5y) echo env; return ;; esac
  echo default
}
lang_source() {
  [ -f "$LANG_FILE" ] && [ -n "$(head -c 64 "$LANG_FILE" 2>/dev/null | tr -d '[:space:]')" ] && { echo flag; return; }
  [ -n "${CLAUDISH_LANG+x}" ] && { echo env; return; }
  [ -n "$(claudish_language "$PWD" 2>/dev/null)" ] && { echo settings; return; }
  echo default
}
model_source() {
  [ -f "$MODEL_FILE" ] && [ -n "$(head -c 128 "$MODEL_FILE" 2>/dev/null | tr -d '[:space:]')" ] && { echo flag; return; }
  [ -n "${CLAUDISH_MODEL+x}" ] && { echo env; return; }
  echo provider
}

WARN=0  # set when any value is a persisting /claudish override

status_label() {
  case "$(state)" in
    off)     _mean="originals only" ;;
    replace) _mean="rewrite only" ;;
    *)       _mean="original + rewrite" ;;
  esac
  if [ -f "$OFF_FILE" ]; then
    WARN=1; printf '⚠ /claudish off — %s; persists across sessions' "$_mean"; return
  fi
  case "$(mode_source)" in
    flag) WARN=1; printf '⚠ /claudish — %s; beats env, persists across sessions' "$_mean" ;;
    env)  printf 'env CLAUDISH_MODE — %s' "$_mean" ;;
    *)    printf 'default — %s' "$_mean" ;;
  esac
}
style_label() {
  case "$(style_source)" in
    flag) WARN=1; printf '⚠ /claudish — beats env CLAUDISH_STYLE, persists across sessions' ;;
    env)  printf 'env CLAUDISH_STYLE' ;;
    *)    printf 'default — plain-language rewrite' ;;
  esac
}
language_label() {
  case "$(lang_source)" in
    flag)     WARN=1; printf '⚠ /claudish — beats env & settings, persists across sessions' ;;
    env)      printf 'env CLAUDISH_LANG' ;;
    settings) printf 'your .claude/settings.json language' ;;
    *)        printf 'default — keeps each message'\''s own language' ;;
  esac
}
model_label() {
  case "$(model_source)" in
    flag)     WARN=1; printf '⚠ /claudish — beats env CLAUDISH_MODEL, persists across sessions' ;;
    env)      printf 'env CLAUDISH_MODEL' ;;
    *)        printf '%s provider default' "${PROVIDER:-ollama}" ;;
  esac
}
provider_label() { [ -n "${CLAUDISH_PROVIDER+x}" ] && printf 'env CLAUDISH_PROVIDER' || printf 'default'; }

dashboard() {
  # Compute labels first (they set WARN as a side effect).
  _sl="$(status_label)"; _yl="$(style_label)"; _ll="$(language_label)"; _ml="$(model_label)"; _pl="$(provider_label)"
  printf '\n  claudish · plain-language rewrite of each assistant message\n\n'
  printf '  %-9s %-16s · %s\n' 'status'   "$(state)"            "$_sl"
  printf '  %-9s %-16s · %s\n' 'style'    "$(current_style)"    "$_yl"
  printf '  %-9s %-16s · %s\n' 'language' "$(current_lang)"     "$_ll"
  printf '  %-9s %-16s · %s\n' 'model'    "$(current_model)"    "$_ml"
  printf '  %-9s %-16s · %s\n' 'provider' "${PROVIDER:-ollama}" "$_pl"
  printf '\n  change   /claudish on · off · append · replace · style <tldr|5y> · language <name> · model <name>\n'
  printf '  other    /claudish last · cycle · reset (clear all overrides) · status\n'
  if [ "$WARN" = "1" ]; then
    printf '\n  ⚠ lines above are /claudish overrides in ~/.claude/claudish-* that persist\n'
    printf '    across sessions. Reset one with its `default` form, or all with /claudish reset.\n'
  fi
  printf '\n'
}

cmd="${1:-status}"

# Read-only views print the dashboard and exit; `last` prints a transcript.
case "$cmd" in
  status|menu|help|dashboard|"") dashboard; exit 0 ;;
  last)
    # The rewrite is display-only: transcripts always keep Claude's original
    # text. Transcripts live under ~/.claude/projects/<encoded cwd>/, so scope
    # the search to the CURRENT project first (the command runs in the session's
    # cwd) and take the most recently touched transcript there — with several
    # sessions open on the SAME project that is still the best available guess.
    # Fall back to all projects when the encoded directory does not exist.
    proj="$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
    tp="$(ls -t "$HOME/.claude/projects/$proj"/*.jsonl 2>/dev/null | head -n1)"
    [ -n "$tp" ] || tp="$(ls -t "$HOME/.claude/projects"/*/*.jsonl 2>/dev/null | head -n1)"
    [ -n "$tp" ] || { printf 'claudish-ctl: no session transcript found\n' >&2; exit 1; }
    jq -rs '
      [ .[]
        | select(.type=="assistant" and .isSidechain!=true)
        | [.message.content[]? | select(.type=="text") | .text]
        | join("\n\n")
        | select(length>0) ]
      | last // "claudish-ctl: no assistant message in the transcript yet"
    ' "$tp" 2>/dev/null || { printf 'claudish-ctl: could not parse %s\n' "$tp" >&2; exit 1; }
    exit 0
    ;;
esac

# Mutating commands.
case "$cmd" in
  on)      turn_on ;;
  off)     { : > "$OFF_FILE"; } 2>/dev/null || fail "cannot create $OFF_FILE" ;;
  append)  set_mode append ;;
  replace) set_mode replace ;;
  style)
    s="$(printf '%s' "${2:-}" | tr -d '[:space:]')"
    case "$s" in
      ''|default|Default) rm -f "$STYLE_FILE" 2>/dev/null || fail "cannot remove $STYLE_FILE" ;;
      tldr|5y)            { printf '%s\n' "$s" > "$STYLE_FILE"; } 2>/dev/null || fail "cannot write $STYLE_FILE" ;;
      *) printf 'claudish-ctl: unknown style "%s" (use tldr|5y|default)\n' "$s" >&2; exit 2 ;;
    esac
    turn_on
    ;;
  language)
    # Take the WHOLE remaining argument so multi-word names survive (e.g.
    # "Brazilian Portuguese"). lang.sh (via _claudish_lang_clean) does the
    # authoritative normalisation on read, so multibyte names like "简体中文"
    # survive too; here we only strip newlines and cap the length.
    shift
    lang="$(printf '%s' "$*" | tr -d '\r\n' | head -c 64)"
    case "$lang" in
      ''|default|Default) rm -f "$LANG_FILE" 2>/dev/null || fail "cannot remove $LANG_FILE" ;;
      *) { printf '%s\n' "$lang" > "$LANG_FILE"; } 2>/dev/null || fail "cannot write $LANG_FILE" ;;
    esac
    turn_on
    ;;
  model)
    # Sanitise to the characters model names use (ollama tags, OpenAI/Anthropic ids).
    m="$(printf '%s' "${2:-}" | tr -cd 'A-Za-z0-9:._/-' | head -c 64)"
    case "$m" in
      ''|default|Default) rm -f "$MODEL_FILE" 2>/dev/null || fail "cannot remove $MODEL_FILE" ;;
      *) { printf '%s\n' "$m" > "$MODEL_FILE"; } 2>/dev/null || fail "cannot write $MODEL_FILE" ;;
    esac
    turn_on
    ;;
  reset)   rm -f "$OFF_FILE" "$MODE_FILE" "$STYLE_FILE" "$LANG_FILE" "$MODEL_FILE" 2>/dev/null || fail "cannot remove one or more flag files" ;;
  cycle)
    case "$(state)" in
      off)    set_mode append ;;
      append) set_mode replace ;;
      *)      { : > "$OFF_FILE"; } 2>/dev/null || fail "cannot create $OFF_FILE" ;;
    esac
    ;;
  *)
    printf 'claudish-ctl: unknown command "%s" (use status|on|off|append|replace|style [name]|language [name]|model [name]|last|cycle|reset)\n' "$cmd" >&2
    exit 2
    ;;
esac

printf 'claudish: %s (style: %s, language: %s, model: %s)\n' "$(state)" "$(current_style)" "$(current_lang)" "$(current_model)"
