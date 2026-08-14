#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Output-language resolver for claudish-to-english. Sourced by rewrite.sh and
# rewrite-md.sh — not executed directly.
#
# claudish_language [CWD] prints the language the rewrite should be written in,
# or nothing at all — and nothing means "no language was configured", which
# leaves the rewrite in whatever language the text it rewrites is already
# written in. English is not a default here, only one possible answer.
# First non-empty source wins:
#   1. CLAUDISH_LANG                      explicit override. Set but EMPTY
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
# The value is normalized to at most three words and 30 codepoints, because it
# lands in a system prompt and in an on-screen label — and a project's
# .claude/settings.json travels with the repository, so it is not necessarily
# the local user's own text. A language name fits ("Esperanto", "简体中文",
# "Brazilian Portuguese"); a paragraph of smuggled instructions does not.
# Every failure — no jq, unreadable or malformed JSON, missing or non-string
# key — comes back as an empty string, never an error: an unusable setting must
# leave rewrites working, in English.
# ---------------------------------------------------------------------------

# Collapse whitespace, trim, keep at most 3 words / 30 codepoints (jq slices by
# codepoint, so multibyte names survive). Empty in -> empty out.
_claudish_lang_clean() {
  [ -n "$1" ] || return 0
  jq -jn --arg v "$1" \
    '$v | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")
        | [splits(" ")][0:3] | join(" ") | .[0:30]' 2>/dev/null
  return 0
}

claudish_language() {
  # An explicitly set CLAUDISH_LANG always wins, including an explicitly EMPTY
  # one — the escape hatch for keeping rewrites in English on a session that
  # speaks something else.
  if [ -n "${CLAUDISH_LANG+x}" ]; then
    _claudish_lang_clean "$CLAUDISH_LANG"
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
