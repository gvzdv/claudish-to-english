#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# PostToolUse Markdown rewrite hook  (opt-in by directory, fail-open)
#
# Fires after a Write/Edit and, IF the written file is a Markdown file that
# lives under CLAUDISH_MD_DIR, rewrites its prose into plain English using a
# local LLM (ollama). PostToolUse.updatedToolOutput only changes what Claude
# SEES, not the bytes on disk, so this hook does the file write itself.
#
# OPT-IN: does nothing unless CLAUDISH_MD_DIR is set. Only *.md files whose
# resolved path is inside that directory are touched. Everything else passes
# straight through — the extension + directory checks here are authoritative,
# so registration needs no path glob (avoids unverified glob-depth semantics).
#
# TWO MODES (CLAUDISH_MD_MODE):
#   sibling  (default)  write NAME.plain.md next to NAME.md; original untouched
#   overwrite           replace NAME.md in place (adds an idempotency marker)
#
# The writes here go through the shell, NOT Claude's Write tool, so they do
# NOT re-trigger PostToolUse — no loop.
#
# FAIL-OPEN CONTRACT: on ANY problem (disabled, no jq/curl, not under the dir,
# not markdown, parse error, LLM down, timeout, empty rewrite) the hook leaves
# the file exactly as the agent wrote it and exits 0. It never writes a partial
# or empty rewrite over real content.
#
# Config (env, with safe defaults):
#   CLAUDISH_ENABLED   1|0            master switch shared with the display hook (default 1)
#   CLAUDISH_OFF_FILE  <path>         flag file checked per message; when it exists,
#                                     rewrites pause (default ~/.claude/claudish-off).
#                                     Lets a hotkey/script toggle mid-session.
#   CLAUDISH_MD_DIR    <path>         REQUIRED opt-in. Only .md under here is rewritten.
#                                     Relative paths resolve against the tool's cwd.
#   CLAUDISH_MD_MODE   sibling|overwrite   (default sibling)
#   CLAUDISH_MD_SUFFIX <word>         sibling infix: NAME.<word>.md (default "plain")
#   CLAUDISH_MD_PROMPT_FILE <path>    file holding a replacement Markdown prompt
#                                     (whole prompt, not merged; empty or
#                                     unreadable -> built-in default)
#   CLAUDISH_LANG      <language>     language to rewrite into, e.g. "Esperanto".
#                                     Unset falls back to the session's `language`
#                                     setting from .claude/settings*.json (the same
#                                     key Claude Code answers in); with neither set,
#                                     the rewrite keeps the language of the file it
#                                     rewrites. Set it EMPTY to ignore the settings
#                                     key, or to "English" to force English.
#                                     See lang.sh
#   CLAUDISH_PROVIDER  ollama|anthropic|openai|orcarouter  which LLM serves rewrites (default
#                                     ollama; keys, base URLs, and per-provider model
#                                     defaults are documented in providers.sh)
#   CLAUDISH_MODEL     <model>        overrides the provider's default model
#   CLAUDISH_OLLAMA    <base url>     (default http://localhost:11434)
#   CLAUDISH_MIN_CHARS <n>            skip files whose prose (code stripped) is shorter (default 200)
#   CLAUDISH_STUB      1|0            deterministic stub instead of the LLM (mechanics testing)
#   CLAUDISH_MD_TIMEOUT <seconds>     LLM client timeout for file rewrites (default 150).
#                                     Large models rewriting long docs are slow; this is
#                                     higher than the display hook's timeout on purpose and
#                                     must stay below the PostToolUse hook timeout in hooks.json.
#   CLAUDISH_DEBUG     1|0            append a debug log (default 0)
#   CLAUDISH_NOTICE    1|0            once-per-session systemMessage when a rewrite is
#                                     skipped because the provider is unreachable, times
#                                     out, is missing a key or model (default 1)
# ---------------------------------------------------------------------------
set -uo pipefail

ENABLED="${CLAUDISH_ENABLED:-1}"
# Runtime kill switch: env is frozen at session launch, so a hotkey or script
# can't flip CLAUDISH_ENABLED mid-session. A flag file can be checked fresh on
# every invocation. Create it to pause rewrites instantly; remove it to resume.
[ -f "${CLAUDISH_OFF_FILE:-$HOME/.claude/claudish-off}" ] && ENABLED=0
MD_DIR="${CLAUDISH_MD_DIR:-}"
MD_MODE="${CLAUDISH_MD_MODE:-sibling}"
MD_SUFFIX="${CLAUDISH_MD_SUFFIX:-plain}"
MIN_CHARS="${CLAUDISH_MIN_CHARS:-200}"
STUB="${CLAUDISH_STUB:-0}"
LLM_TIMEOUT="${CLAUDISH_MD_TIMEOUT:-150}"
DEBUG="${CLAUDISH_DEBUG:-0}"
NOTICE="${CLAUDISH_NOTICE:-1}"

MARKER="<!-- claudish-to-english:rewritten -->"
LOG_ROOT="${TMPDIR:-/tmp}/claudish-to-english"
mkdir -p "$LOG_ROOT" 2>/dev/null || true

dbg() { [ "$DEBUG" = "1" ] && printf '%s [%s] %s\n' "$(date '+%H:%M:%S')" "$$" "$*" >> "$LOG_ROOT/debug-md.log" 2>/dev/null; return 0; }

# Fail-open: leave the file as the agent wrote it.
pass_through() { dbg "pass_through: ${1:-}"; exit 0; }

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# Provider layer (ollama/anthropic/openai/orcarouter): MODEL/OLLAMA defaults,
# llm_complete, llm_notice_why. Missing file -> fail open.
. "$SELF_DIR/providers.sh" 2>/dev/null || pass_through "no providers.sh"

# Output-language resolver (lang.sh). Defined here first so a missing file
# degrades to "no configured language" — the rewrite then keeps the file's own
# language — instead of stopping rewrites.
claudish_language() { :; }
. "$SELF_DIR/lang.sh" 2>/dev/null || dbg "no lang.sh; keeping the file's language"

# Print the canonical absolute path of $1 (its parent directory must exist).
# Runs in a subshell so the cd never leaks.
canon() (
  p="$1"
  case "$p" in /*) ;; *) p="$CWD/$p" ;; esac
  d="$(dirname "$p")"; b="$(basename "$p")"
  cd "$d" 2>/dev/null || exit 0
  printf '%s/%s' "$(pwd -P)" "$b"
)

[ "$ENABLED" = "1" ]        || pass_through "disabled"
[ -n "$MD_DIR" ]            || pass_through "no CLAUDISH_MD_DIR (feature off)"
command -v jq   >/dev/null 2>&1 || pass_through "no jq"
command -v curl >/dev/null 2>&1 || pass_through "no curl"

payload="$(cat)"
[ -n "$payload" ] || pass_through "empty payload"

CWD="$(printf '%s' "$payload"      | jq -r '.cwd // "."' 2>/dev/null)"
SID="$(printf '%s' "$payload"      | jq -r '.session_id // "nosession"' 2>/dev/null)"
file="$(printf '%s' "$payload"     | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -n "$file" ] || pass_through "no file_path"

# ---- extension guard (belt-and-suspenders) -------------------------------
case "$file" in
  *.plain.md)      pass_through "skip our own .plain.md output" ;;
  *."$MD_SUFFIX".md) pass_through "skip our own sibling output" ;;
  *.md)            ;;
  *)               pass_through "not markdown" ;;
esac

# ---- directory gate: file must resolve inside CLAUDISH_MD_DIR -------------
file_abs="$(canon "$file")"
dir_abs="$(canon "$MD_DIR")"
[ -n "$file_abs" ] && [ -n "$dir_abs" ] || pass_through "could not resolve paths"
case "$file_abs" in
  "$dir_abs"/*) ;;
  *)            pass_through "outside CLAUDISH_MD_DIR ($file_abs not under $dir_abs)" ;;
esac
[ -f "$file_abs" ] || pass_through "file not on disk"

content="$(cat "$file_abs" 2>/dev/null)" || pass_through "unreadable"
dbg "candidate: $file_abs mode=$MD_MODE bytes=${#content}"

first_line="$(printf '%s' "$content" | head -n1)"

# ---- protect YAML frontmatter --------------------------------------------
# If the file opens with a '---' line and has a closing '---', hold the whole
# frontmatter block (delimiters included) aside and rewrite only the body.
# This runs BEFORE the idempotency check on purpose: in overwrite mode the
# marker goes after the frontmatter, because frontmatter is only frontmatter
# when it starts on line 1 of the file.
fm=""
body="$content"
if [ "$first_line" = "---" ]; then
  total="$(printf '%s\n' "$content" | wc -l | tr -d ' ')"
  fm="$(printf '%s\n' "$content" | awk 'NR==1{print;next} /^---[[:space:]]*$/{print;exit} {print}')"
  fm_lines="$(printf '%s\n' "$fm" | wc -l | tr -d ' ')"
  if [ "$fm_lines" -lt "$total" ]; then
    body="$(printf '%s\n' "$content" | awk -v n="$fm_lines" 'NR>n')"
  else
    fm=""
    dbg "frontmatter had no closing '---'; treating whole file as body"
  fi
fi

# ---- idempotency: never re-chew a file we already rewrote (overwrite) -----
# The marker is the first non-blank line of the BODY, after any frontmatter.
# v0.1.1 and earlier wrote it on line 1 of the file, ahead of the frontmatter;
# that layout is still recognised so those files are not rewritten twice.
body_first="$(printf '%s\n' "$body" | sed -n '/[^[:space:]]/{p;q;}')"
if [ "$first_line" = "$MARKER" ] || [ "$body_first" = "$MARKER" ]; then
  pass_through "already rewritten (marker present)"
fi

# ---- prose length gate (strip fenced code, count non-space chars) ---------
prose_len="$(printf '%s' "$body" \
  | awk 'BEGIN{f=0} /^```/{f=!f; next} f==0{print}' \
  | tr -d '[:space:]' | wc -c | tr -d ' ')"
dbg "prose_len=$prose_len min=$MIN_CHARS fm_lines=${fm_lines:-0}"
[ "${prose_len:-0}" -ge "$MIN_CHARS" ] || pass_through "below min_chars"

# ---- output language ------------------------------------------------------
# Resolved after the cheap gates, since it reads settings files. Empty -> the
# rewrite keeps the language the file is already written in.
OUT_LANG="$(claudish_language "$CWD")"
dbg "language=${OUT_LANG:-same as the file (default)}"

# ---- obtain the rewrite ---------------------------------------------------
rewrite=""
curl_rc=0
err=""
if [ "$STUB" = "1" ]; then
  rewrite="STUB-SIMPLIFIED-MD ✦ mode=$MD_MODE prose_len=$prose_len ✦"$'\n\n'"$body"
  dbg "stub rewrite"
else
  # Base system prompt, replaceable via CLAUDISH_MD_PROMPT_FILE (a file holding
  # the whole prompt). An unset/empty/unreadable file falls back to this default.
  sys="You rewrite Markdown prose into much simpler, plain language. Write the rewrite in the same language as the file you are rewriting. Keep every fact, name, number, link, and file path. Keep all Markdown structure — headings, lists, tables, and links. Do NOT change fenced code blocks or any YAML frontmatter; reproduce them exactly. Use short sentences and everyday words. Output ONLY the rewritten Markdown, with no preamble, labels, or commentary."
  # A configured language overrides "same language as the file" — it is the last
  # word in the prompt, and it names the language explicitly. The line goes on
  # BEFORE the prompt-file check on purpose: a usable CLAUDISH_MD_PROMPT_FILE
  # replaces the whole prompt, this line included. That file is the user's
  # prompt in full, and it states its own language.
  if [ -n "$OUT_LANG" ]; then
    sys="$sys"$'\n\n'"Write the rewritten Markdown in $OUT_LANG instead, whatever language the original is in. Use $OUT_LANG for all prose, including headings, list items, and table cells. Keep code, identifiers, file paths, link targets, and YAML frontmatter exactly as they are."
  fi
  if [ -n "${CLAUDISH_MD_PROMPT_FILE:-}" ]; then
    _p=""
    [ -r "$CLAUDISH_MD_PROMPT_FILE" ] && _p="$(cat "$CLAUDISH_MD_PROMPT_FILE" 2>/dev/null)"
    if [ -n "$_p" ]; then
      sys="$_p"
    else
      dbg "CLAUDISH_MD_PROMPT_FILE set but empty/unreadable ($CLAUDISH_MD_PROMPT_FILE); using default prompt"
    fi
  fi
  llm_complete "$sys" "$body" || pass_through "req build failed"
fi

# Empty/failed rewrite -> fail open (file left exactly as the agent wrote it).
# When the cause is a FIXABLE setup problem (ollama down, timeout, model not
# pulled), surface a ONE-TIME, per-session systemMessage so the silent skip is
# not a mystery. A systemMessage does not block the tool and is not fed to
# Claude as context; the file is still left untouched either way.
if [ -z "$rewrite" ]; then
  notified="$LOG_ROOT/$SID.md-notified"
  if [ "$NOTICE" = "1" ] && [ ! -e "$notified" ]; then
    TIMEOUT_HINT="raise CLAUDISH_MD_TIMEOUT (and the PostToolUse hook timeout in hooks.json), or set CLAUDISH_MODEL to a smaller model"
    llm_notice_why
    why=""
    [ -n "$NOTICE_WHY" ] && why="$NOTICE_WHY — Markdown rewrite of $(basename "$file") skipped, file left unchanged."
    if [ -n "$why" ]; then
      : > "$notified" 2>/dev/null || true
      jq -n --arg m "claudish-to-english: $why (shown once per session; set CLAUDISH_NOTICE=0 to silence)" \
        '{systemMessage:$m}' 2>/dev/null
      dbg "emitted setup notice"
      exit 0
    fi
  fi
  pass_through "empty rewrite -> fail open"
fi

# ---- reassemble + write atomically ---------------------------------------
tmp="$file_abs.claudish.$$.tmp"
if [ "$MD_MODE" = "overwrite" ]; then
  target="$file_abs"
  # Frontmatter first — it stops being frontmatter if anything precedes it.
  { [ -n "$fm" ] && printf '%s\n\n' "$fm"; printf '%s\n\n' "$MARKER"; printf '%s\n' "$rewrite"; } > "$tmp" 2>/dev/null \
    || pass_through "tmp write failed"
else
  target="${file_abs%.md}.$MD_SUFFIX.md"
  { [ -n "$fm" ] && printf '%s\n\n' "$fm"; printf '%s\n' "$rewrite"; } > "$tmp" 2>/dev/null \
    || pass_through "tmp write failed"
fi

mv -f "$tmp" "$target" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; pass_through "atomic mv failed"; }
dbg "wrote $target (mode=$MD_MODE)"

# Once-per-session oauth caution: oauth mode bills rewrites to the user's
# Claude subscription through an unofficial mechanism, and a systemMessage is
# the only on-screen surface this hook has. The marker is shared with the
# display hook (same root and session id) — one caution per session, not two.
oauth_noted="$LOG_ROOT/$SID.oauth-noted"
if [ "$NOTICE" = "1" ] && [ ! -e "$oauth_noted" ]; then
  _onote="$(llm_oauth_note 2>/dev/null)"
  if [ -n "$_onote" ]; then
    : > "$oauth_noted" 2>/dev/null || true
    jq -n --arg m "claudish-to-english: $_onote. Shown once per session; set CLAUDISH_NOTICE=0 to silence." \
      '{systemMessage:$m}' 2>/dev/null
  fi
fi
exit 0
