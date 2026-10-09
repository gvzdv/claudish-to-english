#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Markdown rewrite core for claudish-to-english. Sourced by rewrite-md.sh (the
# PostToolUse hook) and claudish-md.sh (the on-demand CLI) — not executed
# directly. Both must produce the same rewrite for the same file, so the parts
# that decide WHAT is sent and HOW it is reassembled live here, once:
#
#   md_split CONTENT       split YAML frontmatter off; sets the globals
#                            fm        the frontmatter block, delimiters included
#                                      ("" when there is none)
#                            body      everything after it (the whole input
#                                      when there is no frontmatter)
#                            fm_lines  line count of fm (unset when none)
#   md_prose_len BODY      prints the non-space character count (codepoints,
#                          not bytes) outside fenced code — the measure the
#                          hook's CLAUDISH_MIN_CHARS gate compares against.
#                          Needs jq; prints 0 when the count fails
#   md_system_prompt LANG  prints the system prompt: the built-in default, plus
#                          a language line when LANG is non-empty, all replaced
#                          by CLAUDISH_MD_PROMPT_FILE when that file is usable
#   MD_MARKER              the overwrite-mode idempotency marker
#
# The caller must define dbg(). Nothing here exits or writes files — gating,
# failure policy (the hook fails open, the CLI fails loudly), and the write
# itself stay with the caller.
# ---------------------------------------------------------------------------

MD_MARKER="<!-- claudish-to-english:rewritten -->"

# If the input opens with a '---' line and has a closing '---', hold the whole
# frontmatter block (delimiters included) aside so only the body is rewritten.
# Frontmatter is only frontmatter when it starts on line 1, which is why the
# hook runs this BEFORE its marker check and writes the marker after it.
md_split() {
  fm=""
  body="$1"
  [ "$(printf '%s' "$1" | head -n1)" = "---" ] || return 0
  _md_total="$(printf '%s\n' "$1" | wc -l | tr -d ' ')"
  fm="$(printf '%s\n' "$1" | awk 'NR==1{print;next} /^---[[:space:]]*$/{print;exit} {print}')"
  fm_lines="$(printf '%s\n' "$fm" | wc -l | tr -d ' ')"
  if [ "$fm_lines" -lt "$_md_total" ]; then
    body="$(printf '%s\n' "$1" | awk -v n="$fm_lines" 'NR>n')"
  else
    fm=""
    dbg "frontmatter had no closing '---'; treating whole file as body"
  fi
  return 0
}

# Codepoints via jq, not bytes via wc -c: a byte count let a Cyrillic file pass
# CLAUDISH_MIN_CHARS at half the length and a CJK one at a third, so one
# threshold meant a different length per script. `tr -d '[:space:]'` stays
# byte-oriented and stays correct — every byte of a multibyte character is
# >= 0x80, so none is mistaken for whitespace. A count that is not a number
# comes back as 0, which the hook reads as "too short" and so fails open.
md_prose_len() {
  _md_n="$(printf '%s' "$1" \
    | awk 'BEGIN{f=0} /^```/{f=!f; next} f==0{print}' \
    | tr -d '[:space:]' | jq -Rs 'length' 2>/dev/null)"
  case "$_md_n" in ''|*[!0-9]*) _md_n=0 ;; esac
  printf '%s' "$_md_n"
}

md_system_prompt() {
  _md_sys="You rewrite Markdown prose into much simpler, plain language. Write the rewrite in the same language as the file you are rewriting. Keep every fact, name, number, link, and file path. Keep all Markdown structure — headings, lists, tables, and links. Do NOT change fenced code blocks or any YAML frontmatter; reproduce them exactly. Use short sentences and everyday words. Output ONLY the rewritten Markdown, with no preamble, labels, or commentary."
  # A configured language overrides "same language as the file" — it is the last
  # word in the prompt, and it names the language explicitly. The line goes on
  # BEFORE the prompt-file check on purpose: a usable CLAUDISH_MD_PROMPT_FILE
  # replaces the whole prompt, this line included. That file is the user's
  # prompt in full, and it states its own language.
  if [ -n "${1:-}" ]; then
    _md_sys="$_md_sys"$'\n\n'"Write the rewritten Markdown in $1 instead, whatever language the original is in. Use $1 for all prose, including headings, list items, and table cells. Keep code, identifiers, file paths, link targets, and YAML frontmatter exactly as they are."
  fi
  if [ -n "${CLAUDISH_MD_PROMPT_FILE:-}" ]; then
    _md_p=""
    [ -r "$CLAUDISH_MD_PROMPT_FILE" ] && _md_p="$(cat "$CLAUDISH_MD_PROMPT_FILE" 2>/dev/null)"
    if [ -n "$_md_p" ]; then
      _md_sys="$_md_p"
    else
      dbg "CLAUDISH_MD_PROMPT_FILE set but empty/unreadable ($CLAUDISH_MD_PROMPT_FILE); using default prompt"
    fi
  fi
  printf '%s' "$_md_sys"
}
