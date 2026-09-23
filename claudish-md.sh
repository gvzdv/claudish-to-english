#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# claudish-md.sh — rewrite a Markdown file, or any text, into plain language
# ON DEMAND. Backs `/claudish file <path>`; also runs straight from a terminal.
#
#   claudish-md.sh notes.md                 rewrite -> stdout
#   pbpaste | claudish-md.sh                stdin (any text) -> stdout
#   claudish-md.sh notes.md -o simple.md    rewrite -> simple.md
#   claudish-md.sh notes.md --sibling       rewrite -> notes.plain.md
#   claudish-md.sh -l English notes.md      rewrite into English
#   claudish-md.sh https://…/doc.md         fetch a URL, rewrite -> stdout
#
# Same rewrite as the PostToolUse hook (rewrite-md.sh): the frontmatter split,
# prose measure, and system prompt all come from md-core.sh, and the provider,
# model, and language come from providers.sh / lang.sh, so every CLAUDISH_*
# setting and /claudish flag file applies here too. What differs is deliberate,
# because a person asked for THIS rewrite:
#   - no CLAUDISH_MD_DIR gate, no .md-extension gate, no CLAUDISH_MIN_CHARS
#     gate, no overwrite-marker skip (a leading marker line is dropped instead,
#     so the model never sees it)
#   - CLAUDISH_ENABLED and the off-file are NOT honoured: they pause the
#     automatic hooks, not a command you just typed
#   - it FAILS LOUDLY. This is not a hook, so there is no assistant message to
#     leave on screen: any problem prints `claudish-md: <reason>` on stderr and
#     exits non-zero. It still never writes or prints a partial or empty
#     rewrite — a file target is written atomically, and only on success.
#
# Options:
#   -o, --output PATH   write the rewrite to PATH instead of stdout
#   -s, --sibling       write NAME.<suffix>.md next to NAME.md (suffix from
#                       CLAUDISH_MD_SUFFIX, default "plain"; a file without a
#                       .md extension gets <suffix>.md appended)
#   -l, --lang NAME     rewrite into NAME, beating every other language source
#                       for this run; an EMPTY NAME keeps the input's language.
#                       Unset: the usual lang.sh resolution
#   -h, --help          usage
#   --                  end of options (for a path that starts with '-')
# The input is one FILE argument, a file:// or http(s) URL, or stdin when it
# is absent or "-". A file:// URL is just another way to name a local file:
# percent-escapes are decoded, and only an empty or "localhost" host is taken.
# Windows paths (C:\dir\doc.md, C:/dir/doc.md, file:///C:/dir/doc.md) are
# normalised for Git Bash — see win_path.
#
# URLs: fetched with curl, unauthenticated (public documents only). Links to a
# rendered page are swapped for the raw file first, since the page is HTML:
#   github.com/O/R/blob/REF/PATH   -> raw.githubusercontent.com/O/R/REF/PATH
#   <gitlab host>/…/-/blob/…       -> …/-/raw/…
#   gist.github.com/U/ID           -> gist.githubusercontent.com/U/ID/raw
# Any other URL is fetched as given, query string included. Only http and https
# are allowed, on the first request and on every redirect. A response that is
# HTML (by Content-Type, or by sniffing a leading <!DOCTYPE html>/<html>) is
# refused rather than rewritten, and so is one over CLAUDISH_MD_MAX_BYTES.
# --sibling names the output after the URL's last path segment and writes it
# in the CURRENT directory (…/docs/setup.md -> ./setup.plain.md), since there
# is no directory beside a URL.
#
# When writing a file (-o/--sibling) the absolute path written is printed on
# stdout; notes (the oauth caution) go to stderr. Exit codes: 0 done, 1 the
# rewrite failed (the reason says why), 2 usage error.
#
# Relevant config: CLAUDISH_PROVIDER / CLAUDISH_MODEL and the provider keys
# (providers.sh), CLAUDISH_LANG (lang.sh), CLAUDISH_MD_PROMPT_FILE,
# CLAUDISH_MD_SUFFIX, CLAUDISH_MD_TIMEOUT (LLM timeout, default 150s),
# CLAUDISH_MD_FETCH_TIMEOUT (URL download timeout, default 30s),
# CLAUDISH_MD_MAX_BYTES (URL download cap, default 1048576),
# CLAUDISH_STUB, CLAUDISH_DEBUG (logs to debug-md.log, like the hook).
# ---------------------------------------------------------------------------
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PROG="claudish-md"

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<EOF
usage: $PROG [-o PATH | -s] [-l LANGUAGE] [FILE | URL | -]

Rewrite a Markdown file, a file:// or public http(s) URL, or any text on stdin
into plain language, using the
same provider, model, language, and prompt as the claudish-to-english hooks.

  -o, --output PATH   write to PATH instead of stdout
  -s, --sibling       write NAME.${CLAUDISH_MD_SUFFIX:-plain}.md next to the input file
                      (for a URL: in the current directory, named after the URL)
  -l, --lang NAME     rewrite into NAME (e.g. English); empty keeps the input's language
  -h, --help          show this help

This script: $SELF_DIR/claudish-md.sh
EOF
}

out=""; sibling=0; lang_opt=""; lang_set=0
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)     usage; exit 0 ;;
    -o|--output)   [ $# -ge 2 ] || die "$1 needs a path" 2; out="$2"; shift 2 ;;
    -s|--sibling)  sibling=1; shift ;;
    -l|--lang|--language)
                   [ $# -ge 2 ] || die "$1 needs a language name" 2
                   lang_opt="$2"; lang_set=1; shift 2 ;;
    --)            shift; args+=("$@"); break ;;
    -)             args+=("-"); shift ;;
    -*)            die "unknown option $1 (see --help)" 2 ;;
    *)             args+=("$1"); shift ;;
  esac
done
[ "${#args[@]}" -le 1 ] || die "one input at a time (got ${#args[@]})" 2
src="${args[0]:--}"
[ -n "$out" ] && [ "$sibling" = "1" ] && die "use -o or --sibling, not both" 2
[ "$src" = "-" ] && [ "$sibling" = "1" ] && die "--sibling needs an input file, not stdin" 2
# A bare call from a terminal would otherwise sit waiting on the keyboard.
[ "$src" = "-" ] && [ -t 0 ] && { usage >&2; exit 2; }

# ---- shared layers (all required: a missing one is a broken install) -------
LLM_TIMEOUT="${CLAUDISH_MD_TIMEOUT:-150}"
DEBUG="${CLAUDISH_DEBUG:-0}"
LOG_ROOT="${TMPDIR:-/tmp}/claudish-to-english"
mkdir -p "$LOG_ROOT" 2>/dev/null || true
dbg() { [ "$DEBUG" = "1" ] && printf '%s [%s] cli: %s\n' "$(date '+%H:%M:%S')" "$$" "$*" >> "$LOG_ROOT/debug-md.log" 2>/dev/null; return 0; }

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"
for _lib in providers.sh lang.sh md-core.sh; do
  . "$SELF_DIR/$_lib" 2>/dev/null || die "cannot load $SELF_DIR/$_lib — reinstall the plugin"
done
# file:// names a local file: turn it into the path, then carry on as for any
# FILE. Percent-escapes are decoded (a browser's "copy link" gives %20 for a
# space); a backslash is escaped first so printf %b decodes only the %XX.
case "$src" in
  [Ff][Ii][Ll][Ee]://*)
    _p="${src#*://}"
    case "$_p" in
      /*)          ;;
      localhost/*) _p="/${_p#localhost/}" ;;
      *)           die "a file:// URL must name a local path (file:///path/to/file.md): $src" 2 ;;
    esac
    _p="${_p//\\/\\\\}"
    src="$(printf '%b' "${_p//%/\\x}")"
    dbg "file url -> $src"
    ;;
esac

# A Windows drive path, as pasted from Explorer or a Windows editor, carries
# backslashes that dirname/basename (and so --sibling) cannot split. Git Bash
# ships cygpath, which gives the /c/dir form every tool here understands;
# without it, forward slashes alone are enough for Git Bash's cat and cd. Only
# the drive-letter form is touched: on macOS/Linux a backslash is a legal
# filename character and stays as typed.
win_path() {
  case "$1" in
    [A-Za-z]:[\\/]*)
      if command -v cygpath >/dev/null 2>&1; then cygpath -u -- "$1" 2>/dev/null && return 0; fi
      printf '%s' "${1//\\//}" ;;
    *) printf '%s' "$1" ;;
  esac
}
# file:///C:/dir/doc.md decodes to /C:/dir/doc.md — drop that leading slash.
case "$src" in /[A-Za-z]:/*) src="${src#/}" ;; esac
src="$(win_path "$src")"
[ -n "$out" ] && out="$(win_path "$out")"

is_url=0
case "$src" in
  [Hh][Tt][Tt][Pp]://*|[Hh][Tt][Tt][Pp][Ss]://*) is_url=1 ;;
  *://*) die "only http:// and https:// URLs are supported: $src" 2 ;;
esac
if [ "$is_url" = "1" ]; then
  command -v curl >/dev/null 2>&1 || die "curl is required to fetch a URL"
elif [ "$PROVIDER" != "codex" ]; then
  command -v curl >/dev/null 2>&1 || die "curl is required for the $PROVIDER provider"
fi

# Map a link to a rendered page onto its raw file (see the header). Anything
# that matches none of the patterns comes back unchanged. The query string and
# fragment are dropped only when a pattern matched: a rendered-page URL's
# ?plain=1 or #L10 means nothing to the raw host, but another URL's query may
# be load-bearing (a signed link).
raw_url() {
  _u="${1%%#*}"; _u="${_u%%\?*}"
  _r="$(printf '%s' "$_u" | sed -E \
    -e 's#^https?://github\.com/([^/]+)/([^/]+)/blob/(.+)$#https://raw.githubusercontent.com/\1/\2/\3#' \
    -e 's#^(https?://[^/]*gitlab[^/]*/.+)/-/blob/(.+)$#\1/-/raw/\2#' \
    -e 's#^https?://gist\.github\.com/([^/]+)/([0-9A-Fa-f]+)/?$#https://gist.githubusercontent.com/\1/\2/raw#')"
  if [ "$_r" != "$_u" ]; then printf '%s' "$_r"; else printf '%s' "$1"; fi
}

# Download $1 into $content, or die with a reason. The body goes to a private
# temp file first so curl's size cap and the status line stay separate from
# the text; the file is removed before this returns. (providers.sh installs its
# own EXIT trap later, so nothing may rely on a trap set here beyond the fetch.)
fetch_url() {
  _max="${CLAUDISH_MD_MAX_BYTES:-1048576}"
  case "$_max" in ''|*[!0-9]*) _max=1048576 ;; esac
  _ft="${CLAUDISH_MD_FETCH_TIMEOUT:-30}"
  case "$_ft" in ''|*[!0-9]*) _ft=30 ;; esac
  _bodyf="$(mktemp "${TMPDIR:-/tmp}/claudish-fetch.XXXXXX" 2>/dev/null)" || die "cannot create a temp file"
  trap 'rm -f "$_bodyf" 2>/dev/null' EXIT
  [ -t 2 ] && printf '%s: fetching %s…\n' "$PROG" "$1" >&2
  _meta="$(curl -sSL --fail --proto '=http,https' --proto-redir '=http,https' \
            --max-redirs 5 --max-time "$_ft" --max-filesize "$_max" \
            -H 'Accept: text/markdown, text/plain;q=0.9, */*;q=0.1' \
            -o "$_bodyf" -w '%{http_code} %{content_type}' -- "$1" 2>/dev/null)"
  _rc=$?
  _code="${_meta%% *}"; _ctype="${_meta#* }"
  dbg "fetch url=$1 curl_rc=$_rc http=$_code type=$_ctype"
  if [ "$_rc" != "0" ]; then
    rm -f "$_bodyf" 2>/dev/null
    # Judge by the status, not curl's exit code: --fail reports an HTTP error
    # as 22 over HTTP/1.1 but as 56 over HTTP/2.
    case "$_code" in
      404)     die "not found (HTTP 404): $1 — check the link; a private repository also answers 404 without a login" ;;
      401|403) die "access denied (HTTP $_code): $1 — only public documents can be fetched" ;;
      [45]??)  die "HTTP $_code fetching $1" ;;
    esac
    case "$_rc" in
      28) die "timed out after ${_ft}s fetching $1 — raise CLAUDISH_MD_FETCH_TIMEOUT" ;;
      63) die "$1 is larger than CLAUDISH_MD_MAX_BYTES ($_max bytes)" ;;
      6)  die "cannot resolve the host in $1" ;;
      1)  die "redirected to a URL that is not http(s): $1" ;;
      *)  die "could not fetch $1 (curl exit $_rc)" ;;
    esac
  fi
  # --max-filesize only works when the server announces a length; a chunked
  # response is checked here instead, after the fact.
  _size="$(wc -c < "$_bodyf" | tr -d ' ')"
  [ "${_size:-0}" -le "$_max" ] || { rm -f "$_bodyf"; die "$1 is larger than CLAUDISH_MD_MAX_BYTES ($_max bytes)"; }
  content="$(cat "$_bodyf")"
  rm -f "$_bodyf" 2>/dev/null; trap - EXIT
  case "$(printf '%s' "$_ctype" | tr 'A-Z' 'a-z')" in
    text/html*|application/xhtml*) _html=1 ;;
    *) _html=0
       case "$(printf '%s' "$content" | sed -n '/[^[:space:]]/{s/^[[:space:]]*//;p;q;}' | tr 'A-Z' 'a-z')" in
         '<!doctype html'*|'<html'*) _html=1 ;;
       esac ;;
  esac
  [ "$_html" = "0" ] || die "$1 returned an HTML page, not Markdown — use the link to the raw file"
  return 0
}

# ---- read the input --------------------------------------------------------
if [ "$src" = "-" ]; then
  content="$(cat)" || die "could not read stdin"
  src_label="stdin"
elif [ "$is_url" = "1" ]; then
  fetch="$(raw_url "$src")"
  [ "$fetch" != "$src" ] && printf '%s: fetching the raw file %s\n' "$PROG" "$fetch" >&2
  fetch_url "$fetch"
  src_label="$src"
else
  [ -e "$src" ] || die "no such file: $src"
  [ -f "$src" ] || die "not a regular file: $src"
  [ -r "$src" ] || die "cannot read: $src"
  content="$(cat -- "$src")" || die "cannot read: $src"
  src_label="$src"
fi

md_split "$content"
# A file the hook already rewrote in overwrite mode carries the marker as the
# first non-blank body line; the hook would skip it, but a person asked for
# this one, so drop the marker rather than send it to the model.
body_first="$(printf '%s\n' "$body" | sed -n '/[^[:space:]]/{p;q;}')"
if [ "$body_first" = "$MD_MARKER" ]; then
  body="$(printf '%s\n' "$body" | awk -v m="$MD_MARKER" '!done && $0==m {done=1; next} {print}')"
fi
prose_len="$(md_prose_len "$body")"
[ "${prose_len:-0}" -gt 0 ] || die "$src_label has no prose to rewrite"
dbg "input=$src_label bytes=${#content} prose_len=$prose_len fm_lines=${fm_lines:-0}"

# ---- resolve the target before the (slow) rewrite, so a bad path fails fast -
target=""
if [ "$sibling" = "1" ] && [ "$is_url" = "1" ]; then
  # Last path segment of the URL, reduced to filename-safe characters, in the
  # current directory. A URL ending in "/" (or naming nothing usable) gets
  # "document" — the server's name is never trusted to be a safe path.
  _seg="${src%%#*}"; _seg="${_seg%%\?*}"; _seg="${_seg#*://}"
  case "$_seg" in */*) _seg="${_seg#*/}" ;; *) _seg="" ;; esac  # drop the host
  _seg="${_seg%/}"; _seg="${_seg##*/}"
  _seg="$(printf '%s' "$_seg" | tr -cd 'A-Za-z0-9._-' | head -c 100)"
  case "$_seg" in ''|.*) _seg="document" ;; esac
  case "$_seg" in
    *.md) target="$PWD/${_seg%.md}.${CLAUDISH_MD_SUFFIX:-plain}.md" ;;
    *)    target="$PWD/$_seg.${CLAUDISH_MD_SUFFIX:-plain}.md" ;;
  esac
elif [ "$sibling" = "1" ]; then
  case "$src" in
    *.md) target="${src%.md}.${CLAUDISH_MD_SUFFIX:-plain}.md" ;;
    *)    target="$src.${CLAUDISH_MD_SUFFIX:-plain}.md" ;;
  esac
elif [ -n "$out" ]; then
  target="$out"
fi
if [ -n "$target" ]; then
  _tdir="$(cd "$(dirname -- "$target")" 2>/dev/null && pwd -P)" \
    || die "output directory does not exist: $(dirname -- "$target")"
  target="$_tdir/$(basename -- "$target")"
  [ -d "$target" ] && die "output path is a directory: $target"
  [ -w "$_tdir" ] || die "cannot write to $_tdir"
fi

# ---- output language: -l beats every other source for this run -------------
# Through _claudish_lang_clean like every other source: the value reaches the
# system prompt, and /claudish file hands us text typed into a session.
if [ "$lang_set" = "1" ]; then
  OUT_LANG="$(_claudish_lang_clean "$lang_opt")"
else
  OUT_LANG="$(claudish_language "$PWD")"
fi
dbg "language=${OUT_LANG:-same as the input (default)}"

# ---- rewrite ---------------------------------------------------------------
rewrite=""
if [ "${CLAUDISH_STUB:-0}" = "1" ]; then
  rewrite="STUB-SIMPLIFIED-MD ✦ manual prose_len=$prose_len lang=${OUT_LANG:-same} ✦"$'\n\n'"$body"
else
  [ -t 2 ] && printf '%s: rewriting %s with %s%s…\n' "$PROG" "$src_label" "$PROVIDER" "${MODEL:+ ($MODEL)}" >&2
  sys="$(md_system_prompt "$OUT_LANG")"
  llm_complete "$sys" "$body" || die "could not build the request"
fi

if [ -z "$rewrite" ]; then
  TIMEOUT_HINT="raise CLAUDISH_MD_TIMEOUT, or set CLAUDISH_MODEL to a smaller model"
  llm_notice_why
  die "${NOTICE_WHY:-the model returned an empty rewrite} — nothing written"
fi

_onote="$(llm_oauth_note 2>/dev/null)"
[ -n "$_onote" ] && printf '%s: note: %s.\n' "$PROG" "$_onote" >&2

# ---- emit ------------------------------------------------------------------
# Same reassembly as the hook's sibling mode: frontmatter verbatim, a blank
# line, then the rewritten body.
emit() { [ -n "$fm" ] && printf '%s\n\n' "$fm"; printf '%s\n' "$rewrite"; }

if [ -z "$target" ]; then
  emit
  exit 0
fi

tmp="$target.claudish.$$.tmp"
emit > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; die "could not write $tmp"; }
mv -f "$tmp" "$target" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; die "could not move the rewrite into place at $target"; }
dbg "wrote $target"
printf '%s\n' "$target"
