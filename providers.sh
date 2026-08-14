#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Provider layer for claudish-to-english. Sourced by rewrite.sh and
# rewrite-md.sh — not executed directly.
#
# One function does the work: llm_complete SYSTEM USER runs a single chat
# completion against the configured provider and sets these globals:
#   rewrite   the completion text ("" on any failure)
#   curl_rc   curl exit code (0 unless transport failed; 1 when no API key)
#   err       provider error message ("" when none)
#   http      HTTP status of the response ("" when unknown; cloud providers only)
#   truncated 1 when the completion hit an output-token cap and was discarded
# It returns 2 when the JSON request body could not be built, 0 otherwise.
# llm_notice_why then maps a failure onto NOTICE_WHY, a one-line reason fit
# for the once-per-session setup notice ("" when the skip should stay
# silent — an empty completion with no transport error).
#
# Providers (CLAUDISH_PROVIDER):
#   ollama     (default) local ollama at CLAUDISH_OLLAMA
#   anthropic  Anthropic Messages API; key from CLAUDISH_ANTHROPIC_KEY or
#              ANTHROPIC_API_KEY; base URL from CLAUDISH_ANTHROPIC_URL
#   openai     any OpenAI-compatible /chat/completions endpoint (OpenAI,
#              LM Studio, llama.cpp server, vLLM, OpenRouter, ...); base URL
#              from CLAUDISH_OPENAI_URL, key from CLAUDISH_OPENAI_KEY or
#              OPENAI_API_KEY. A key is only required for the default
#              api.openai.com URL — local servers work keyless.
#
# Extra config:
#   CLAUDISH_MODEL          overrides the per-provider default model
#   CLAUDISH_MAX_TOKENS     completion cap for the anthropic provider (default
#                           4096; the Messages API requires an explicit cap)
#   CLAUDISH_OPENAI_EFFORT  reasoning_effort for the openai provider. Unset
#                           defaults to "none" against api.openai.com
#                           (GPT-5.6-class models otherwise burn reasoning
#                           tokens on a plain rewrite) and to omitted against
#                           custom compat URLs (some local servers reject
#                           unknown fields). Set it EMPTY
#                           (CLAUDISH_OPENAI_EFFORT=) to force the field off
#                           even for api.openai.com — needed for models that
#                           reject reasoning_effort entirely.
#
# The caller must define dbg() and set LLM_TIMEOUT before calling
# llm_complete, and may set TIMEOUT_HINT to customize llm_notice_why's
# timed-out advice. Fail-open stays the caller's job: every failure here
# comes back as an empty $rewrite, never an exit.
# ---------------------------------------------------------------------------

PROVIDER="${CLAUDISH_PROVIDER:-ollama}"
OLLAMA="${CLAUDISH_OLLAMA:-http://localhost:11434}"
# CLAUDISH_ANTHROPIC_AUTH=oauth borrows the Claude Code login: the access token
# is re-read from ~/.claude/.credentials.json on EVERY call (Claude Code
# refreshes it while running, and this hook only ever fires while it runs).
ANTHROPIC_AUTH="${CLAUDISH_ANTHROPIC_AUTH:-}"
ANTHROPIC_KEY="${CLAUDISH_ANTHROPIC_KEY:-${ANTHROPIC_API_KEY:-}}"
OPENAI_KEY="${CLAUDISH_OPENAI_KEY:-${OPENAI_API_KEY:-}}"
OPENAI_URL="${CLAUDISH_OPENAI_URL:-https://api.openai.com/v1}"
ANTHROPIC_URL="${CLAUDISH_ANTHROPIC_URL:-https://api.anthropic.com}"
MAX_TOKENS="${CLAUDISH_MAX_TOKENS:-4096}"

# Normalize away trailing slashes BEFORE any URL comparison, so
# ".../v1/" gets the same key requirement and effort default as ".../v1".
while [ "${OPENAI_URL%/}" != "$OPENAI_URL" ]; do OPENAI_URL="${OPENAI_URL%/}"; done
while [ "${ANTHROPIC_URL%/}" != "$ANTHROPIC_URL" ]; do ANTHROPIC_URL="${ANTHROPIC_URL%/}"; done

# An explicitly set CLAUDISH_OPENAI_EFFORT always wins — including an
# explicitly EMPTY one, which omits the field (the escape hatch for models
# that reject reasoning_effort). Only when unset does the api.openai.com
# default of "none" apply.
if [ -n "${CLAUDISH_OPENAI_EFFORT+x}" ]; then
  OPENAI_EFFORT="$CLAUDISH_OPENAI_EFFORT"
elif [ "$OPENAI_URL" = "https://api.openai.com/v1" ]; then
  OPENAI_EFFORT="none"
else
  OPENAI_EFFORT=""
fi

case "$PROVIDER" in
  anthropic) MODEL="${CLAUDISH_MODEL:-claude-haiku-4-5}" ;;
  openai)    MODEL="${CLAUDISH_MODEL:-gpt-5.6-luna}" ;;
  *)         MODEL="${CLAUDISH_MODEL:-gemma4:26b-mlx}" ;;
esac

# Split the "\n<status>" suffix appended by curl -w '\n%{http_code}' off $resp
# into $http. "000" (no response at all) is normalized to "".
_llm_split_status() {
  _nl='
'
  http="${resp##*"$_nl"}"
  case "$http" in
    [0-9][0-9][0-9]) resp="${resp%"$_nl"*}" ;;
    *)               http="" ;;
  esac
  [ "$http" = "000" ] && http=""
  return 0
}

# Write 'header = "<name>: <key>"' into a private (0600) temp file for
# curl -K, keeping the key off the curl command line — argv is visible to
# every local user via ps. Prints the file path; prints nothing on failure.
_llm_key_file() {
  _kf="$(mktemp "${TMPDIR:-/tmp}/claudish-key.XXXXXX" 2>/dev/null)" || return 0
  _kv="$2"
  _kv="${_kv//\\/\\\\}"; _kv="${_kv//\"/\\\"}"
  printf 'header = "%s: %s"\n' "$1" "$_kv" > "$_kf" 2>/dev/null \
    || { rm -f "$_kf" 2>/dev/null; return 0; }
  # curl accepts an EMPTY -K file and would proceed unauthenticated; a partial
  # write (ENOSPC) must therefore fail here, not at the endpoint.
  [ -s "$_kf" ] || { rm -f "$_kf" 2>/dev/null; return 0; }
  printf '%s' "$_kf"
}

llm_complete() {
  _sys="$1"; _user="$2"
  rewrite=""; curl_rc=0; err=""; resp=""; http=""; finish=""; truncated=0
  hdrfile=""; cfgerr=0
  case "$PROVIDER" in
    anthropic)
      _oauth_beta=()
      if [ "$ANTHROPIC_AUTH" = "oauth" ]; then
        # sed, not jq: the token read must work even where jq is missing.
        ANTHROPIC_KEY="$(sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p' \
                        "$HOME/.claude/.credentials.json" 2>/dev/null)"
      fi
      if [ -z "$ANTHROPIC_KEY" ]; then dbg "anthropic: no key"; curl_rc=1; return 0; fi
      # No temperature: current Anthropic models reject sampling parameters.
      req="$(jq -n --arg m "$MODEL" --argjson t "$MAX_TOKENS" --arg s "$_sys" --arg u "$_user" \
            '{model:$m,max_tokens:$t,system:$s,messages:[{role:"user",content:$u}]}' 2>/dev/null)"
      [ -n "$req" ] || return 2
      if [ "$ANTHROPIC_AUTH" = "oauth" ]; then
        # OAuth tokens ride Authorization: Bearer and need the oauth beta flag.
        hdrfile="$(_llm_key_file "Authorization" "Bearer $ANTHROPIC_KEY")"
        _oauth_beta=(-H 'anthropic-beta: oauth-2025-04-20')
      else
        hdrfile="$(_llm_key_file "x-api-key" "$ANTHROPIC_KEY")"
      fi
      if [ -z "$hdrfile" ]; then
        cfgerr=1
        err="could not create a private temp file for the API key under ${TMPDIR:-/tmp} — nothing was sent"
        return 0
      fi
      # If the hook is killed mid-request the file must not linger in TMPDIR.
      # Single quotes: $hdrfile expands when the trap FIRES, immune to quoting
      # in the path (it is always set — reset to "" at the top of this call).
      trap 'rm -f "$hdrfile" 2>/dev/null' EXIT
      resp="$(printf '%s' "$req" | curl -sS --max-time "$LLM_TIMEOUT" -w '\n%{http_code}' \
              -K "$hdrfile" -H 'Content-Type: application/json' \
              -H 'anthropic-version: 2023-06-01' \
              ${_oauth_beta[@]+"${_oauth_beta[@]}"} \
              -X POST "$ANTHROPIC_URL/v1/messages" -d @- 2>/dev/null)"
      curl_rc=$?
      rm -f "$hdrfile" 2>/dev/null
      _llm_split_status
      # Join text blocks: models with thinking enabled emit non-text blocks first.
      rewrite="$(printf '%s' "$resp" | jq -j 'if (.content|type)=="array" then ([.content[] | select(.type=="text") | .text] | join("")) else empty end' 2>/dev/null)"
      err="$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null)"
      finish="$(printf '%s' "$resp" | jq -r '.stop_reason // empty' 2>/dev/null)"
      [ "$finish" = "max_tokens" ] && { truncated=1; rewrite=""; }
      ;;
    openai)
      if [ -z "$OPENAI_KEY" ] && [ "$OPENAI_URL" = "https://api.openai.com/v1" ]; then
        dbg "openai: no key"; curl_rc=1; return 0
      fi
      # No temperature or token cap: reasoning-tier OpenAI models reject
      # non-default sampling, and compat servers disagree on the cap's name.
      req="$(jq -n --arg m "$MODEL" --arg s "$_sys" --arg u "$_user" --arg e "$OPENAI_EFFORT" \
            '{model:$m,messages:[{role:"system",content:$s},{role:"user",content:$u}]}
             + (if $e == "" then {} else {reasoning_effort:$e} end)' 2>/dev/null)"
      [ -n "$req" ] || return 2
      auth=()
      if [ -n "$OPENAI_KEY" ]; then
        hdrfile="$(_llm_key_file "Authorization" "Bearer $OPENAI_KEY")"
        if [ -z "$hdrfile" ]; then
          cfgerr=1
          err="could not create a private temp file for the API key under ${TMPDIR:-/tmp} — nothing was sent"
          return 0
        fi
        trap 'rm -f "$hdrfile" 2>/dev/null' EXIT
        auth=(-K "$hdrfile")
      fi
      resp="$(printf '%s' "$req" | curl -sS --max-time "$LLM_TIMEOUT" -w '\n%{http_code}' \
              -H 'Content-Type: application/json' ${auth[@]+"${auth[@]}"} \
              -X POST "$OPENAI_URL/chat/completions" -d @- 2>/dev/null)"
      curl_rc=$?
      [ -n "${hdrfile:-}" ] && rm -f "$hdrfile" 2>/dev/null
      _llm_split_status
      rewrite="$(printf '%s' "$resp" | jq -j '.choices[0].message.content // empty' 2>/dev/null)"
      err="$(printf '%s' "$resp" | jq -r 'if (.error|type)=="object" then (.error.message // empty) else (.error // empty) end' 2>/dev/null)"
      finish="$(printf '%s' "$resp" | jq -r '.choices[0].finish_reason // empty' 2>/dev/null)"
      [ "$finish" = "length" ] && { truncated=1; rewrite=""; }
      ;;
    *)
      req="$(jq -n --arg m "$MODEL" --arg s "$_sys" --arg u "$_user" \
            '{model:$m,stream:false,think:false,options:{temperature:0.3},messages:[{role:"system",content:$s},{role:"user",content:$u}]}' 2>/dev/null)"
      [ -n "$req" ] || return 2
      resp="$(printf '%s' "$req" | curl -sS --max-time "$LLM_TIMEOUT" \
              -H 'Content-Type: application/json' -X POST "$OLLAMA/api/chat" -d @- 2>/dev/null)"
      curl_rc=$?
      rewrite="$(printf '%s' "$resp" | jq -j '.message.content // empty' 2>/dev/null)"
      err="$(printf '%s' "$resp" | jq -r '.error // empty' 2>/dev/null)"
      # ollama reports output-cap truncation as done_reason "length"; a
      # half-finished rewrite must be discarded like on the cloud providers.
      # (Response-side only — the request stays byte-identical to before.)
      finish="$(printf '%s' "$resp" | jq -r '.done_reason // empty' 2>/dev/null)"
      [ "$finish" = "length" ] && { truncated=1; rewrite=""; }
      ;;
  esac

  # Cloud providers: an HTTP error whose body carried no parseable message
  # (an HTML 404 from a URL that isn't an API, a bare 502 from a proxy) must
  # not turn into a silent skip forever — give the notice something to say.
  # A 2xx with an empty completion stays silent, as before.
  if [ "$PROVIDER" != "ollama" ] && [ -z "$rewrite" ] && [ -z "$err" ] \
     && [ "$curl_rc" = "0" ] && [ "$truncated" = "0" ] && [ -n "$http" ]; then
    case "$http" in
      2??) ;;
      # Server-side trouble: the URL is probably fine, the endpoint isn't.
      5??|429) err="HTTP $http from the endpoint — it may be down, overloaded, or rate-limiting" ;;
      *)   case "$PROVIDER" in
             anthropic) err="HTTP $http with no error message in the response — check that CLAUDISH_ANTHROPIC_URL points at an Anthropic-compatible API base URL" ;;
             *)         err="HTTP $http with no error message in the response — check that CLAUDISH_OPENAI_URL points at an OpenAI-compatible API base URL (usually ending in /v1)" ;;
           esac ;;
    esac
  fi

  dbg "$PROVIDER model=$MODEL curl_rc=$curl_rc http=${http:-none} resp_bytes=${#resp} rewrite_bytes=${#rewrite} truncated=$truncated err=${err:-none}"
  return 0
}

llm_notice_why() {
  # shellcheck disable=SC2034  # NOTICE_WHY is read by the sourcing scripts
  NOTICE_WHY=""
  case "$PROVIDER" in
    anthropic)
      if [ "$ANTHROPIC_AUTH" = "oauth" ] && [ -z "$ANTHROPIC_KEY" ]; then
        NOTICE_WHY="could not read the Claude Code access token from ~/.claude/.credentials.json, so rewrites are off"
      elif [ -z "$ANTHROPIC_KEY" ]; then
        NOTICE_WHY="no Anthropic API key in this session's environment (set CLAUDISH_ANTHROPIC_KEY or ANTHROPIC_API_KEY), so rewrites are off"
      elif [ "${cfgerr:-0}" = "1" ]; then
        NOTICE_WHY="${err:-provider configuration error}"
      elif [ "${truncated:-0}" = "1" ]; then
        NOTICE_WHY="the rewrite hit the ${MAX_TOKENS}-token output cap and was discarded rather than shown half-finished — raise CLAUDISH_MAX_TOKENS"
      elif [ -n "${err:-}" ]; then
        NOTICE_WHY="Anthropic API error: ${err}"
      elif [ "$curl_rc" = "28" ]; then
        NOTICE_WHY="the rewrite timed out after ${LLM_TIMEOUT}s — ${TIMEOUT_HINT:-raise the timeout}"
      elif [ "$curl_rc" != "0" ]; then
        NOTICE_WHY="cannot reach ${ANTHROPIC_URL} (curl exit $curl_rc)"
      fi
      ;;
    openai)
      if [ -z "$OPENAI_KEY" ] && [ "$OPENAI_URL" = "https://api.openai.com/v1" ]; then
        NOTICE_WHY="no OpenAI API key in this session's environment (set CLAUDISH_OPENAI_KEY or OPENAI_API_KEY), so rewrites are off"
      elif [ "${cfgerr:-0}" = "1" ]; then
        NOTICE_WHY="${err:-provider configuration error}"
      elif [ "${truncated:-0}" = "1" ]; then
        NOTICE_WHY="the rewrite hit the model's output-token limit and was discarded rather than shown half-finished — use a shorter message, or raise the completion cap if you run the server yourself"
      elif [ -n "${err:-}" ]; then
        NOTICE_WHY="OpenAI API error: ${err}"
      elif [ "$curl_rc" = "28" ]; then
        NOTICE_WHY="the rewrite timed out after ${LLM_TIMEOUT}s — ${TIMEOUT_HINT:-raise the timeout}"
      elif [ "$curl_rc" != "0" ]; then
        NOTICE_WHY="cannot reach ${OPENAI_URL} (curl exit $curl_rc)"
      fi
      ;;
    *)
      # truncated first: it can only occur on a successful response, so none
      # of the pre-existing branches (whose wording must stay byte-identical)
      # can ever fire for the same state.
      if [ "${truncated:-0}" = "1" ]; then
        NOTICE_WHY="the rewrite hit ollama's output-token limit and was discarded rather than shown half-finished — raise the model's output cap (num_predict) or use a shorter message"
      elif [ "$curl_rc" = "28" ]; then
        NOTICE_WHY="the rewrite timed out after ${LLM_TIMEOUT}s (model too slow for this message) — ${TIMEOUT_HINT:-raise the timeout or set CLAUDISH_MODEL to a smaller model}"
      elif [ "$curl_rc" != "0" ]; then
        NOTICE_WHY="can't reach ollama at $OLLAMA — start it with \`ollama serve\` (see the plugin README)"
      elif printf '%s' "${err:-}" | grep -qi 'not found'; then
        NOTICE_WHY="ollama model '$MODEL' isn't available — pull it with \`ollama pull $MODEL\`, or set CLAUDISH_MODEL to a model you have"
      elif [ -n "${err:-}" ]; then
        NOTICE_WHY="ollama returned an error: ${err}"
      fi
      ;;
  esac
}
