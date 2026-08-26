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
#   codex      the OpenAI codex CLI, non-interactively (codex exec); uses the
#              CLI's own login, so no API key and no local model server. The
#              rewrite runs with --sandbox read-only outside any repo.
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
#   CLAUDISH_CODEX_EFFORT   model_reasoning_effort for the codex provider (e.g.
#                           "low"). Unset uses the codex CLI's configured
#                           effort. Applies to the rewrite only.
#
# The caller must define dbg() and set LLM_TIMEOUT before calling
# llm_complete, and may set TIMEOUT_HINT to customize llm_notice_why's
# timed-out advice. Fail-open stays the caller's job: every failure here
# comes back as an empty $rewrite, never an exit.
# ---------------------------------------------------------------------------

PROVIDER="${CLAUDISH_PROVIDER:-ollama}"
OLLAMA="${CLAUDISH_OLLAMA:-http://localhost:11434}"
# CLAUDISH_ANTHROPIC_AUTH=oauth borrows the Claude Code login: the access token
# is re-read on EVERY call from the macOS login Keychain, or from
# ~/.claude/.credentials.json on other platforms (Claude Code refreshes it
# while running, and this hook only ever fires while it runs; a token past its
# expiresAt is discarded rather than sent). UNOFFICIAL — use at your own risk;
# the hooks say so on screen once per session. The token is only ever sent to
# https://api.anthropic.com: oauth mode refuses to run with a
# CLAUDISH_ANTHROPIC_URL override, so the credential cannot leak to a proxy.
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
  codex)     MODEL="${CLAUDISH_MODEL:-}" ;;  # empty = the codex CLI's configured default
  *)         MODEL="${CLAUDISH_MODEL:-gemma4:26b-mlx}" ;;
esac

# Runtime model override written by /claudish (claudish-ctl.sh): a file re-read
# on every message, so a `/claudish model X` switch takes effect mid-session
# where the frozen CLAUDISH_MODEL env cannot. It wins over the env/default
# resolved above; `/claudish model default` removes it and restores that.
# Sanitised to the characters model names use — the value also lands on the
# request. Provider-agnostic: X is passed to whatever provider is configured.
_model_file="${CLAUDISH_MODEL_FILE:-${HOME:-}/.claude/claudish-model}"
if [ -f "$_model_file" ]; then
  _mf="$(head -c 128 "$_model_file" 2>/dev/null | tr -cd 'A-Za-z0-9:._/-' | head -c 64)"
  [ -n "$_mf" ] && MODEL="$_mf"
fi

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
      _oauth_hdrs=()
      if [ "$ANTHROPIC_AUTH" = "oauth" ]; then
        # The subscription token is account-scoped, refreshable, and harder to
        # revoke than an API key — it must never travel anywhere but Anthropic.
        # Refuse an overridden base URL outright (a proxy would receive the raw
        # credential); proxy setups should use an API key instead.
        if [ "$ANTHROPIC_URL" != "https://api.anthropic.com" ]; then
          cfgerr=1
          err="oauth mode sends the Claude Code token only to https://api.anthropic.com, but CLAUDISH_ANTHROPIC_URL is set to ${ANTHROPIC_URL} — unset the URL override or switch to an API key. Nothing was sent"
          dbg "anthropic oauth: refused non-default URL"
          return 0
        fi
        # oauth mode NEVER uses an env-supplied key: reset before the reads so a
        # stale ANTHROPIC_API_KEY cannot ride the Bearer header (and 401), and
        # every call stays a fresh token read, as documented.
        ANTHROPIC_KEY=""
        # macOS keeps the credentials in the login Keychain, not on disk, so the
        # file read is the fallback there. `security` ships with the OS.
        _cred=""
        if [ "$(uname -s)" = "Darwin" ]; then
          _cred="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null)"
        fi
        [ -n "$_cred" ] || _cred="$(cat "${HOME:-}/.claude/.credentials.json" 2>/dev/null)"
        # Narrow to the claudeAiOauth object before extracting fields, so a
        # file that grows another section with its own accessToken can never
        # hand us that token (or mismatch it with our expiresAt). Parameter
        # expansion, not sed: it must work across pretty-printed lines. The
        # object holds no nested braces, so the first "}" after the key ends
        # it; a blob without the key passes through unchanged.
        case "$_cred" in
          *'"claudeAiOauth"'*) _cred="${_cred#*\"claudeAiOauth\"}"; _cred="${_cred%%\}*}" ;;
        esac
        # sed, not jq: the token read must work even where jq is missing.
        # Whitespace-tolerant around the colon, so a pretty-printed or
        # hand-edited credentials file parses the same as the compact JSON
        # Claude Code writes today.
        ANTHROPIC_KEY="$(printf '%s' "$_cred" \
          | sed -n 's/.*"accessToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
        _exp="$(printf '%s' "$_cred" \
          | sed -n 's/.*"expiresAt"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
        _cred=""
        # expiresAt is ms since epoch; 0 or absent means unknown — send anyway
        # and let a 401 report it. A token Claude Code hasn't refreshed yet (an
        # idle session, a long tool run) is discarded here instead of burning a
        # doomed request; 30s of slack covers clock skew and request time. The
        # 2>/dev/null guards keep a corrupt (non-integer-sized) value fail-open.
        if [ -n "$ANTHROPIC_KEY" ] && [ "${_exp:-0}" -gt 0 ] 2>/dev/null; then
          _now="$(date +%s 2>/dev/null)"
          case "$_now" in
            *[!0-9]*|'') : ;;  # no usable clock — send and let the API decide
            *) if [ "$_exp" -le "$(( (_now + 30) * 1000 ))" ] 2>/dev/null; then
                 dbg "anthropic oauth: token expired (expiresAt=${_exp}ms); discarded"
                 ANTHROPIC_KEY=""
               fi ;;
          esac
        fi
      fi
      if [ -z "$ANTHROPIC_KEY" ]; then dbg "anthropic: no key"; curl_rc=1; return 0; fi
      # No temperature: current Anthropic models reject sampling parameters.
      req="$(jq -n --arg m "$MODEL" --argjson t "$MAX_TOKENS" --arg s "$_sys" --arg u "$_user" \
            '{model:$m,max_tokens:$t,system:$s,messages:[{role:"user",content:$u}]}' 2>/dev/null)"
      [ -n "$req" ] || return 2
      if [ "$ANTHROPIC_AUTH" = "oauth" ]; then
        # OAuth tokens ride Authorization: Bearer and need the oauth beta flag.
        hdrfile="$(_llm_key_file "Authorization" "Bearer $ANTHROPIC_KEY")"
        # Also present as the Claude Code CLI (these hooks only ever run inside
        # one): Anthropic buckets OAuth traffic by User-Agent, and requests
        # without a claude-cli UA land in an aggressively rate-limited default
        # bucket. The version is a snapshot, not kept in sync — the bucketing
        # keys on the product token, not the number.
        _oauth_hdrs=(-H 'anthropic-beta: oauth-2025-04-20' \
                     -H 'User-Agent: claude-cli/2.1.247 (external, cli)' \
                     -H 'x-app: cli')
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
              ${_oauth_hdrs[@]+"${_oauth_hdrs[@]}"} \
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
    codex)
      if ! command -v codex >/dev/null 2>&1; then
        dbg "codex: CLI not found"; curl_rc=1; return 0
      fi
      _out="$(mktemp "${TMPDIR:-/tmp}/claudish-codex-out.XXXXXX" 2>/dev/null)" || return 2
      _errf="$(mktemp "${TMPDIR:-/tmp}/claudish-codex-err.XXXXXX" 2>/dev/null)" || { rm -f "$_out"; return 2; }
      trap 'rm -f "$_out" "$_errf" 2>/dev/null' EXIT
      # codex has no separate system channel; prepend the system prompt.
      # No timeout(1) on stock macOS, so background the call and kill on expiry.
      # CLAUDISH_CODEX_EFFORT overrides the CLI's configured reasoning effort
      # for the rewrite only ("low" keeps a per-message rewrite at seconds
      # even when the CLI's coding default is a high-effort tier).
      codex exec --sandbox read-only --skip-git-repo-check -C "${TMPDIR:-/tmp}" \
        ${MODEL:+-m "$MODEL"} \
        ${CLAUDISH_CODEX_EFFORT:+-c "model_reasoning_effort=${CLAUDISH_CODEX_EFFORT}"} \
        -o "$_out" "$_sys

$_user" >/dev/null 2>"$_errf" &
      _pid=$!
      _t=0
      while kill -0 "$_pid" 2>/dev/null; do
        if [ "$_t" -ge "$LLM_TIMEOUT" ]; then
          kill -TERM "$_pid" 2>/dev/null; wait "$_pid" 2>/dev/null
          curl_rc=28
          rm -f "$_out" "$_errf" 2>/dev/null
          dbg "codex timed out after ${LLM_TIMEOUT}s"
          return 0
        fi
        sleep 1; _t=$((_t + 1))
      done
      wait "$_pid"; _rc=$?
      rewrite="$(cat "$_out" 2>/dev/null)"
      if [ "$_rc" != "0" ]; then
        err="$(tail -c 400 "$_errf" 2>/dev/null)"
        err="${err:-codex exec failed with exit $_rc}"
        rewrite=""
      fi
      rm -f "$_out" "$_errf" 2>/dev/null
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
      # cfgerr first: oauth mode can refuse before any token is read (URL
      # override), and that reason must win over the generic no-key lines. In
      # API-key mode cfgerr only ever arises after a key exists, so the two
      # conditions cannot both hold and the reorder changes nothing there.
      if [ "${cfgerr:-0}" = "1" ]; then
        NOTICE_WHY="${err:-provider configuration error}"
      elif [ "$ANTHROPIC_AUTH" = "oauth" ] && [ -z "$ANTHROPIC_KEY" ]; then
        NOTICE_WHY="could not read a fresh Claude Code access token (macOS login Keychain, or ~/.claude/.credentials.json elsewhere) — check that Claude Code is logged in; rewrites are off"
      elif [ -z "$ANTHROPIC_KEY" ]; then
        NOTICE_WHY="no Anthropic API key in this session's environment (set CLAUDISH_ANTHROPIC_KEY or ANTHROPIC_API_KEY), so rewrites are off"
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
    codex)
      if ! command -v codex >/dev/null 2>&1; then
        NOTICE_WHY="the codex CLI is not on PATH (install it or pick another CLAUDISH_PROVIDER), so rewrites are off"
      elif [ "$curl_rc" = "28" ]; then
        NOTICE_WHY="the rewrite timed out after ${LLM_TIMEOUT}s — ${TIMEOUT_HINT:-raise the timeout}"
      elif [ -n "${err:-}" ]; then
        NOTICE_WHY="codex error: ${err}"
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

# One-line "riding your subscription" caution for oauth mode: prints the text
# when it applies (anthropic provider in oauth mode), nothing otherwise. The
# hooks show it once per session next to their existing notice plumbing — the
# wording lives here so both hooks stay identical.
llm_oauth_note() {
  [ "$PROVIDER" = "anthropic" ] || return 0
  [ "$ANTHROPIC_AUTH" = "oauth" ] || return 0
  printf '%s' "rewrites are riding your Claude subscription through the local Claude Code login (CLAUDISH_ANTHROPIC_AUTH=oauth). This is UNOFFICIAL — Anthropic has not blessed it, it may stop working at any time, and it could put your Claude account at risk. Use at your own risk"
}
