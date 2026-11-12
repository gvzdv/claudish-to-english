#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Output-language resolver for naturalize. Sourced by rewrite.sh and
# rewrite-md.sh — not executed directly.
#
# claudish_language [CWD] prints the language the rewrite should be written in,
# or nothing at all — and nothing means "no language was configured", which
# leaves the rewrite in whatever language the text it rewrites is already
# written in. English is not a default here, only one possible answer.
# First non-empty source wins:
#   1. NATURALIZE_LANG                      explicit override. Set but EMPTY
#                                         ignores the settings below and keeps
#                                         the text's own language; set it to
#                                         "English" to actually force English.
#   2. <cwd>/.claude/settings.local.json  .language
#   3. <cwd>/.claude/settings.json        .language
#   4. ~/.claude/settings.json            .language
#
# 2-4 read the same `language` key Claude Code itself reads to build the
# "# Language" block of its system prompt, in the same precedence order. So a
# session already answering in one language gets its rewrite in that language,
# with nothing extra to configure.
#
# The value is normalized to at most three words and 30 codepoints, with control
# characters folded to spaces, because it lands in a system prompt and in an
# on-screen label — and a project's .claude/settings.json travels with the
# repository, so it is not necessarily the local user's own text. A language
# name fits ("Esperanto", "简体中文", "Brazilian Portuguese"); a paragraph of
# smuggled instructions does not, and neither does a terminal escape sequence.
# Every failure — no jq, unreadable or malformed JSON, missing or non-string
# key — comes back as an empty string, never an error: an unusable setting must
# leave rewrites working, in English.
# ---------------------------------------------------------------------------

# Fold control characters to spaces, collapse whitespace, trim, keep at most 3
# words / 30 codepoints (jq slices by codepoint, so multibyte names survive).
# Empty in -> empty out.
#
# The control-character fold matters because this value is printed straight into
# the on-screen label, and ESC is not whitespace: without it a `language` of
# $'\033[2J' would reach the terminal as a real escape sequence. Folding to a
# space rather than deleting keeps "Brazilian\nPortuguese" two words, and turns
# an escape into harmless literal text that the word/length caps then trim.
# Filtering by codepoint (not a regex) avoids depending on how the regex engine
# spells a control-character class.
_claudish_lang_clean() {
  [ -n "$1" ] || return 0
  jq -jn --arg v "$1" \
    '$v | explode
        | map(if . < 32 or . == 127 or (. >= 128 and . <= 159) then 32 else . end)
        | implode
        | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")
        | [splits(" ")][0:3] | join(" ") | .[0:30]' 2>/dev/null
  return 0
}

claudish_language() {
  # Runtime override written by /naturalize (naturalize-ctl.sh): a file re-read on
  # every message, so a `/naturalize language X` switch takes effect mid-session
  # where the frozen NATURALIZE_LANG env cannot. It sits ABOVE the env and the
  # settings files for the same reason the off-file sits above NATURALIZE_ENABLED
  # — only a per-message file can be flipped without relaunching. `/naturalize
  # language default` removes it and restores the resolution below. The file
  # persists across sessions (like the off-file); cleaned like every source.
  _cl_file="${NATURALIZE_LANG_FILE:-${HOME:-}/.claude/naturalize-lang}"
  if [ -f "$_cl_file" ]; then
    _cl_rv="$(_claudish_lang_clean "$(head -c 64 "$_cl_file" 2>/dev/null)")"
    if [ -n "$_cl_rv" ]; then printf '%s' "$_cl_rv"; return 0; fi
  fi

  # An explicitly set NATURALIZE_LANG always wins, including an explicitly EMPTY
  # one — the escape hatch for keeping rewrites in English on a session that
  # speaks something else.
  if [ -n "${NATURALIZE_LANG+x}" ]; then
    _claudish_lang_clean "$NATURALIZE_LANG"
    return 0
  fi

  _cl_cwd="${1:-$PWD}"
  for _cl_f in "$_cl_cwd/.claude/settings.local.json" \
               "$_cl_cwd/.claude/settings.json" \
               "${HOME:-}/.claude/settings.json"; do
    [ -r "$_cl_f" ] || continue
    # Guard the type: a `language` that is not a string (null, number, object)
    # must read as "unset", not as its jq stringification.
    _cl_v="$(jq -r 'if (.language | type) == "string" then .language else empty end' \
             "$_cl_f" 2>/dev/null)"
    _cl_v="$(_claudish_lang_clean "$_cl_v")"
    if [ -n "$_cl_v" ]; then printf '%s' "$_cl_v"; return 0; fi
  done
  return 0
}
