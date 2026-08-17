# claudish-to-english

<p align="center">
  <img
    src="https://github.com/gvzdv/claudish-to-english/releases/download/assets/comparison.png"
    width="820"
    alt="Side-by-side comparison: a dense, jargon-heavy Claude message labeled 'Claudish' on the left, and its plain-English rewrite on the right">
</p>

A Claude Code plugin that shows a **plain-English rewrite** of each assistant
message, produced by a **local LLM via ollama** (default), the **Anthropic
API**, or any **OpenAI-compatible API**. It is **display-only**:
Claude's own reasoning and the saved transcript keep the original text — only
what you read on screen changes.

An optional second hook rewrites **Markdown files** into plain English when they
are written or edited (opt-in, off by default).

> Status: working prototype. Every hook fails **open** — if anything goes wrong
> (provider down, timeout, missing key or dependency), you simply see Claude's
> original text. The plugin can never swallow or corrupt an answer.


---

## Requirements (read this first)

With the default `ollama` provider this plugin shells out to a **local** model,
and nothing works until these are in place. (With `CLAUDISH_PROVIDER=anthropic`
or `openai` you need only `jq`, `curl`, and an API key — see
[Providers](#providers).)

<a id="macos-setup"></a>
<details>
<summary><strong>macOS setup</strong></summary>

| Requirement | Why | Install |
|---|---|---|
| **ollama**, running | Does the rewriting, locally | `brew install ollama` then `ollama serve` |
| A pulled model | The actual rewriter | `ollama pull gemma4:26b-mlx` (~17 GB; choose the model that fits into your memory) |
| `jq` | Parses hook JSON | ships with macOS 15+; else `brew install jq` |
| `curl` | Talks to ollama | ships with macOS |

Warm the model once after `ollama serve` (the first call is a slow cold load):

```bash
ollama run gemma4:26b-mlx "hi"
```

**If the local model isn't ready, the plugin does nothing to your text** —
Claude's output shows normally, unchanged. That is by design, not a bug. It skips
(fails open) when ollama is down, the request times out, or the model isn't
pulled. The first time that happens in a session it tells you why: the display
hook appends a one-line notice on screen, and the Markdown hook shows a
`systemMessage`. So a silent skip is never a mystery (once per session; set
`CLAUDISH_NOTICE=0` to silence it).

**Pick a model you actually have.** The default is `gemma4:26b-mlx`, an
Apple-silicon (MLX) build — the right choice on a Mac, but **macOS-only**. On
Windows it doesn't run, so you must switch to a regular tag (see
[Windows setup](#windows-setup)). Pull it (as above), or pull a smaller/faster
model and point the plugin at it by setting `CLAUDISH_MODEL` to that model's
exact ollama tag in your `env` (see
[Configuring the plugin](#configuring-the-plugin)). If `CLAUDISH_MODEL` names a
model you have not pulled, every rewrite is skipped — with the one-time notice
above.

</details>

<a id="windows-setup"></a>
<details>
<summary><strong>Windows setup</strong></summary>

The hooks are bash scripts; on Windows, Claude Code runs them through **Git
Bash** (Git for Windows).

| Requirement | Why | Install |
|---|---|---|
| **Ollama**, running | Does the rewriting, locally | `winget install Ollama.Ollama`, then launch the Ollama app; it serves on `localhost:11434` |
| A pulled model | The actual rewriter | `ollama pull gemma4:26b` (choose a model that fits into your memory) |
| `jq` | Parses hook JSON | `winget install jqlang.jq` |
| `curl` | Talks to ollama | ships with Windows 10+ |
| Git Bash | Runs the hook scripts | Claude Code users usually already have it; else `winget install Git.Git` |

Restart your terminal after installing so `jq`, `ollama`, and Git Bash are on
PATH (check `jq --version` and `ollama --version`).

> **The default model is macOS-only — Windows users must override it.** The
> plugin's default, `gemma4:26b-mlx`, is an Apple-silicon (MLX) build that doesn't
> run on Windows, so leaving it unset means every rewrite is silently skipped.
> Always set `CLAUDISH_MODEL` to a regular (non-MLX) tag on Windows. The table
> above uses `gemma4:26b` as an example; choose another if it fits your machine
> better.

Warm the model once after launching Ollama (the first call is a slow cold load):

```powershell
ollama run gemma4:26b "hi"
```

Then set `CLAUDISH_MODEL` in the `env` block of your `settings.json` (see
[Configuring the plugin](#configuring-the-plugin) — that method is identical on
Windows), or for a one-off session from PowerShell:

```powershell
$env:CLAUDISH_MODEL = "gemma4:26b"; claude
```

Windows equivalents of the mid-session kill switch
([Toggling mid-session](#toggling-mid-session)):

```powershell
New-Item -ItemType File $HOME\.claude\claudish-off   # pause rewrites
Remove-Item $HOME\.claude\claudish-off               # resume
```

(In Git Bash the `touch`/`rm` commands from that section work as-is.)

Notes:
- Write `CLAUDISH_MD_DIR` with forward slashes
(`C:/dev/docs/plain`) so the bash-side path checks match
- The `CLAUDISH_DEBUG=1` log lands under Git Bash's temp directory
(`$TMPDIR/claudish-to-english/`, typically
`C:\Users\<you>\AppData\Local\Temp\claudish-to-english\`).

</details>

---

## Install

Directly from this repository (also serves its own marketplace):

```shell
/plugin marketplace add gvzdv/claudish-to-english
/plugin install claudish-to-english@gvzdv-plugins
```

After review by the Anthropic team, the plugin will be available to install from the community marketplace:

```shell
/plugin marketplace add anthropics/claude-plugins-community
/plugin install claudish-to-english@claude-community
```

If the install summary says `Run /reload-plugins to activate.`, run that command.

**Try before installing** (loads it for one session, no install):

```bash
claude --plugin-dir /path/to/claudish-to-english
```

Run `/reload-plugins` after edits; if it doesn't load, check the `/plugin`
**Errors** tab.

---

## Configuring the plugin

All behavior is controlled by `CLAUDISH_*` environment variables (full list in
[Configuration](#configuration-env-vars) below). When you install from a
marketplace, set them in Claude Code's **`env` block in `settings.json`** — do
**not** edit the plugin's own `hooks/hooks.json`, which lives in the read-only
plugin cache (`~/.claude/plugins/cache/…`) and is overwritten on every update.

For a personal, all-projects setup, use `~/.claude/settings.json`:

```json
{
  "env": {
    "CLAUDISH_MODEL": "gemma4:26b-mlx",
    "CLAUDISH_MODE": "append"
  }
}
```

The hooks are subprocesses Claude Code spawns, so they inherit these. A few
things to know:

- **Restart Claude Code after editing `env`.** The value is captured at launch,
  so a running session keeps the old one.
- **`env` does not merge across scopes.** The highest-precedence settings file
  that defines `env` supplies the *entire* block — it isn't combined with lower
  scopes. Precedence: managed → local → project → user. Keep all your
  `CLAUDISH_*` vars in whichever file wins.
- **Scopes:** `~/.claude/settings.json` (all your projects) ·
  `.claude/settings.json` (shared with a repo, checked in) ·
  `.claude/settings.local.json` (just you, just this repo).

Quick one-off without editing a file — hooks inherit the launching shell:

```bash
CLAUDISH_MODEL=llama3.2:3b claude
```

To confirm the hook is firing, set `CLAUDISH_DEBUG=1` and watch
`"$TMPDIR"/claudish-to-english/debug.log`.

---

## Customizing the rewrite prompt

Each hook ships with a default system prompt that asks the model for plain
English while preserving facts, code, and structure. You can **replace** either
prompt with your own to add specific rules or use wording that works
better with your model. To do so, point the hook at a file that holds
the prompt:

| Hook | Prompt file |
|---|---|
| Display (`rewrite.sh`) | `CLAUDISH_PROMPT_FILE` |
| Markdown (`rewrite-md.sh`) | `CLAUDISH_MD_PROMPT_FILE` |

The file's contents **replace** the built-in prompt, so
include every instruction you want the model to follow — otherwise the defaults
(keep facts, leave code blocks alone, output only the rewrite) are gone. Keeping
the prompt in a file avoids escaping a long, multi-line prompt inside a JSON
string. If the variable is unset, or the file is empty or unreadable, the hook
falls back to its built-in default, so a bad path never stops rewrites.

```json
{
  "env": {
    "CLAUDISH_PROMPT_FILE": "/ABS/PATH/prompts/plain.txt",
    "CLAUDISH_MD_PROMPT_FILE": "/ABS/PATH/prompts/md-plain.txt"
  }
}
```

The display hook still appends the **original user question** to your prompt, as
context to keep the rewrite on-topic (see
[How the display hook works](#how-the-display-hook-works)). Your prompt
replaces only the base instruction.

---

## How the display hook works

Claude Code fires the `MessageDisplay` event **once per streamed chunk**, not
once per message. Each fire is a separate process carrying `message_id`,
`index`, a `final` flag, and this chunk's `delta` (a text fragment, not the
whole message). So the hook **buffers every delta** to a temp file (keyed by
`message_id`) and only calls the model on the **final** chunk, once the whole
message is known:

```
chunk 0 (final:false) ─┐
chunk 1 (final:false) ─┤ append each delta to $TMPDIR/claudish-to-english/<session>/<message>/<index>.part
chunk 2 (final:false) ─┘  → emit nothing (append) or "" (replace)
chunk 3 (final:true)  ──► reconstruct full message → call ollama once → show the rewrite
                          → delete the buffer
```

On that final chunk it also reads the **original user question** from the
transcript and passes it to the model as **context only** — to keep the rewrite
on-topic. The model is told never to answer or repeat the question; it only
rewrites the assistant's message.

### Display modes

| `CLAUDISH_MODE` | On screen | Notes |
|---|---|---|
| `append` (default) | Original streams normally, then a `💬 In plain English:` block is appended. | Safest. No streaming loss; if the LLM fails you just don't get the extra block. |
| `replace` | Only the simplified version (original chunks suppressed while streaming). | Experimental. Appears all at once after LLM latency; on failure it re-shows the full original. |

---

## Markdown file rewrite (optional second hook)

A `PostToolUse` hook (`rewrite-md.sh`) rewrites Markdown **files** into plain
English when they are written or edited. Unlike the display hook, this changes
bytes on disk.

**Opt-in by directory.** It does nothing unless `CLAUDISH_MD_DIR` is set, and it
only touches `*.md` files whose resolved path is inside that directory. Every
other `README`, `CLAUDE.md`, or doc you edit is left alone.

| `CLAUDISH_MD_MODE` | Result | Notes |
|---|---|---|
| `sibling` (default) | Writes `NAME.plain.md` next to `NAME.md`. | Non-destructive; the original is never touched. |
| `overwrite` | Replaces `NAME.md` in place. | Adds a `<!-- claudish-to-english:rewritten -->` marker so a re-write is skipped (idempotent). A weak model can degrade real docs — use with care. |

In both modes: YAML frontmatter is split off and re-attached **verbatim**, fenced
code is left to the model instruction, short files are skipped, and the write is
atomic. Fail-open here means the file is left **exactly as the agent wrote it**.

**Large files are slow.** `gemma4:26b-mlx` (the default) rewrites at roughly 60
tokens/s, so a long plan or spec can take 30–120s. This hook allows up to
`CLAUDISH_MD_TIMEOUT` (150s) inside a 180s `PostToolUse` hook budget; if a rewrite
still times out you get the one-time notice above — raise those limits, or set
`CLAUDISH_MODEL` to a smaller model.

Enable it for one directory, in sibling mode (the safe default), the same way
as every other setting — the `env` block of your `settings.json`:

```json
{
  "env": {
    "CLAUDISH_MD_DIR": "/ABS/PATH/docs/plain",
    "CLAUDISH_MD_MODE": "sibling"
  }
}
```

In `overwrite` mode the marker comment is written **after** any YAML
frontmatter, so the frontmatter stays on line 1 where parsers expect it.

---

## Providers

Rewrites go through one of three providers, selected with `CLAUDISH_PROVIDER`
(both hooks share the setting). The default is unchanged from upstream: local
ollama, nothing leaves your machine.

| Provider | Endpoint | Key | Default model |
|---|---|---|---|
| `ollama` (default) | `CLAUDISH_OLLAMA` (`http://localhost:11434`) | none | `gemma4:26b-mlx` |
| `anthropic` | `CLAUDISH_ANTHROPIC_URL` (`https://api.anthropic.com`) + `/v1/messages` | `CLAUDISH_ANTHROPIC_KEY` or `ANTHROPIC_API_KEY` | `claude-haiku-4-5` |
| `openai` | `CLAUDISH_OPENAI_URL` + `/chat/completions` | `CLAUDISH_OPENAI_KEY` or `OPENAI_API_KEY` | `gpt-5.6-luna` |

> [!CAUTION]
> The cloud providers pick their key up from the **ambient environment**
> (`OPENAI_API_KEY` / `ANTHROPIC_API_KEY`), and `CLAUDISH_OPENAI_URL` defaults
> to api.openai.com. Anything that puts those variables into the environment
> Claude Code launches with — an `export` in your shell profile, a tool like
> direnv loading a project's `.env` into your shell, or the `env` block of a
> settings file — makes them visible to this plugin. In such an environment,
> setting the single variable `CLAUDISH_PROVIDER=openai` starts sending every
> assistant message (and, with the Markdown hook, file contents) to OpenAI's
> cloud. Likewise, `CLAUDISH_PROVIDER=anthropic` will quietly spend the same
> `ANTHROPIC_API_KEY` (and share its rate limits) that other tools on your
> machine may rely on. Selecting a cloud provider IS the consent switch — set
> it only when you mean it, and use the `CLAUDISH_*_KEY` variables when you
> want the plugin on a dedicated key.

```bash
# ollama (default) — local, nothing leaves your machine
export CLAUDISH_PROVIDER=ollama
export CLAUDISH_MODEL=gemma4:26b-mlx        # the default; any pulled tag works

# Anthropic — Claude Haiku
export CLAUDISH_PROVIDER=anthropic
export ANTHROPIC_API_KEY=sk-ant-...
export CLAUDISH_MODEL=claude-haiku-4-5      # the default; override to taste

# OpenAI — GPT-5.6 Luna
export CLAUDISH_PROVIDER=openai
export OPENAI_API_KEY=sk-...
export CLAUDISH_MODEL=gpt-5.6-luna          # the default; override to taste

# Any OpenAI-compatible server (LM Studio, llama.cpp server, vLLM, OpenRouter).
# A key is only required for api.openai.com — local servers work keyless.
export CLAUDISH_PROVIDER=openai
export CLAUDISH_OPENAI_URL=http://localhost:1234/v1
export CLAUDISH_MODEL=qwen3-30b
```

Notes:

- `CLAUDISH_MODEL` overrides any provider's default model.
- Requests to api.openai.com send `reasoning_effort: "none"` (GPT-5.6-class
  models otherwise spend reasoning tokens on a plain rewrite). Custom
  OpenAI-compatible URLs get no such field, since some local servers reject
  unknown fields. Force one with `CLAUDISH_OPENAI_EFFORT`, or set it
  **explicitly empty** (`CLAUDISH_OPENAI_EFFORT=`) to omit the field even for
  api.openai.com — needed for models that reject `reasoning_effort` entirely.
- The anthropic provider caps completions at `CLAUDISH_MAX_TOKENS` (default
  4096, since the Messages API requires an explicit cap).
- A rewrite that hits an output-token cap is **discarded**, not shown — on all
  three providers (ollama's `done_reason: "length"` included): a half-finished
  rewrite on screen is confusing, and in the Markdown hook's `overwrite` mode
  it would replace your real document. You get the original text plus the
  once-per-session notice suggesting a higher cap.
- Every provider failure stays fail-open: missing key, bad key, unreachable
  endpoint, or timeout just leaves the original text (plus the once-per-session
  notice, unless `CLAUDISH_NOTICE=0`).

> **Privacy:** the cloud providers send each assistant message (and, for the
> Markdown hook, file contents) to an external API. Read
> [Privacy / egress](#privacy--egress) before switching away from ollama.

---

## Configuration (env vars)

| Var | Default | Meaning |
|---|---|---|
| `CLAUDISH_ENABLED` | `1` | Master switch. `0` = pass everything through. Read once at session start. |
| `CLAUDISH_OFF_FILE` | `~/.claude/claudish-off` | Runtime kill switch. While this file exists, rewrites pause — re-checked every message, so unlike env vars it works mid-session. See [Toggling mid-session](#toggling-mid-session). |
| `CLAUDISH_MODE` | `append` | `append` or `replace` (display hook). |
| `CLAUDISH_PROMPT_FILE` | *(unset)* | Path to a file whose contents replace the display hook's system prompt (whole prompt, not merged). Empty/unreadable falls back to the built-in default. See [Customizing the rewrite prompt](#customizing-the-rewrite-prompt). |
| `CLAUDISH_PROVIDER` | `ollama` | `ollama`, `anthropic`, or `openai` — which LLM serves rewrites (both hooks). |
| `CLAUDISH_MODEL` | *(per provider)* | Model name; overrides the provider default (see [Providers](#providers)). The ollama default `gemma4:26b-mlx` is MLX (Apple-silicon only; Windows users must override). |
| `CLAUDISH_OLLAMA` | `http://localhost:11434` | ollama base URL. |
| `CLAUDISH_ANTHROPIC_KEY` | *(unset)* | Anthropic API key; falls back to `ANTHROPIC_API_KEY`. |
| `CLAUDISH_OPENAI_KEY` | *(unset)* | OpenAI(-compatible) API key; falls back to `OPENAI_API_KEY`. Only required for api.openai.com. |
| `CLAUDISH_OPENAI_URL` | `https://api.openai.com/v1` | Base URL for any OpenAI-compatible endpoint (LM Studio, llama.cpp server, vLLM, OpenRouter, ...). Trailing slashes are ignored. |
| `CLAUDISH_ANTHROPIC_URL` | `https://api.anthropic.com` | Base URL for the anthropic provider — override for proxies/gateways that speak the Messages API. |
| `CLAUDISH_OPENAI_EFFORT` | `none` on api.openai.com, else *(unset)* | `reasoning_effort` sent with openai-provider requests. Set explicitly empty to omit the field. |
| `CLAUDISH_MAX_TOKENS` | `4096` | Completion cap for the anthropic provider. Rewrites that hit the cap are discarded (fail-open), with a notice to raise it. |
| `CLAUDISH_MIN_CHARS` | `200` | Skip messages/files whose prose (code stripped) is shorter than this. |
| `CLAUDISH_STUB` | `0` | `1` = deterministic stub instead of the model (for testing display mechanics). |
| `CLAUDISH_TIMEOUT` | `45` | LLM client timeout for the **display** hook (seconds). Keep it below that hook's `timeout` (60s). |
| `CLAUDISH_MD_TIMEOUT` | `150` | LLM client timeout for the **Markdown file** hook (seconds). Higher on purpose — a large model rewriting a long doc is slow. Keep it below the `PostToolUse` hook `timeout` (180s). |
| `CLAUDISH_DEBUG` | `0` | `1` = write a debug log to `$TMPDIR/claudish-to-english/`. |
| `CLAUDISH_NOTICE` | `1` | `1` = show a one-time, once-per-session notice when a rewrite is skipped because the provider is unreachable, the call timed out, a key is missing, or the model isn't available (display hook appends it on screen; Markdown hook uses a `systemMessage`). `0` = stay fully silent (pure fail-open). |
| `CLAUDISH_MD_DIR` | *(unset)* | **Markdown hook opt-in.** Only `*.md` under this directory is rewritten. Unset = the Markdown hook does nothing. |
| `CLAUDISH_MD_MODE` | `sibling` | `sibling` (`NAME.plain.md`) or `overwrite` (in place). |
| `CLAUDISH_MD_SUFFIX` | `plain` | Sibling infix: `NAME.<suffix>.md`. |
| `CLAUDISH_MD_PROMPT_FILE` | *(unset)* | Path to a file whose contents replace the Markdown hook's system prompt (whole prompt, not merged). Empty/unreadable falls back to the built-in default. |

In `hooks/hooks.json` the display hook (`MessageDisplay`) has a 60s `timeout` and
the Markdown hook (`PostToolUse`) has a 180s `timeout` — the file hook is higher
because a large model rewriting a long document can take a couple of minutes.
`CLAUDISH_TIMEOUT` and `CLAUDISH_MD_TIMEOUT` keep the LLM call itself bounded
below those ceilings, so it fails open cleanly instead of being killed mid-write.

**Quick kill switch:** set `CLAUDISH_ENABLED=0` or disable the plugin (both apply
only from the next session start), or `touch ~/.claude/claudish-off` to pause a
session that's already running — see [Toggling mid-session](#toggling-mid-session)
below.

### Toggling mid-session

`CLAUDISH_ENABLED` and the other env vars are read once, when a session launches,
so they can't pause rewrites in a session that's already running. For that, both
hooks also check a **flag file** on every invocation — each fire is a fresh
process, so the check is always live:

```bash
touch ~/.claude/claudish-off   # pause rewrites, effective on the next message
rm    ~/.claude/claudish-off   # resume
```

You create and remove this file yourself; nothing creates it on install, and its
absence is the normal "on" state. While it exists, `ENABLED` is forced to `0` and
the fail-open path leaves Claude's original text untouched. Point a hotkey at a
two-line toggle script to flip rewrites from the keyboard across all running
sessions at once. Override the path with `CLAUDISH_OFF_FILE`.

### Reasoning models

The ollama request sends `"think": false`, and openai-provider requests to
api.openai.com send `reasoning_effort: "none"`. Models with a hidden reasoning
phase otherwise spend most of their time generating reasoning tokens you never
see — much slower for identical output quality on this simple task. Keep it off.

---

## Privacy / egress

With the default provider the rewriter runs **entirely locally** against
ollama, so **no conversation content leaves your machine**. Setting
`CLAUDISH_PROVIDER` to `anthropic` or `openai` changes that deliberately: every
rewritten assistant message (and, with the Markdown hook enabled, file
contents) is sent to that API. The same applies to pointing `CLAUDISH_OLLAMA`
or `CLAUDISH_OPENAI_URL` at a remote/hosted endpoint. Don't switch away from
local unless you understand and accept it.

## Related: a hosted version

This plugin is the original and stays local by default, so no changes are needed there.

If you prefer a hosted version of the same idea, [declaude](https://github.com/tenkenco/declaude)
is available. It uses the same approach, runs an open-weights model on its own GPUs, and exposes a
REST API, an MCP server, and an Ollama-compatible endpoint. Its source is MIT, and it credits this
repository in its README, system prompt, and third-party notices. See its README for the current
model, limits, and pricing.

It speaks the OpenAI protocol, so it can also back this plugin on a machine that cannot spare
17 GB, using the existing `openai` provider and nothing new:

```bash
export CLAUDISH_PROVIDER=openai
export CLAUDISH_OPENAI_URL=https://speak-english.tenken.co/v1
export CLAUDISH_OPENAI_KEY=$DECLAUDE_TOKEN
```

The key travels in the `Authorization` header, so it never appears in a URL.

> [!NOTE]
> Using declaude sends your assistant messages to a third-party server, similar to how the
> `anthropic` and `openai` providers operate. The default local `ollama` provider remains the only
> setup where data does not leave your machine.

---

## Layout

```
claudish-to-english/
├── .claude-plugin/
│   ├── plugin.json         # plugin manifest
│   └── marketplace.json    # so the repo can be added as a marketplace directly
├── hooks/
│   └── hooks.json          # MessageDisplay -> rewrite.sh ; PostToolUse -> rewrite-md.sh
├── rewrite.sh              # display-rewrite hook
├── rewrite-md.sh           # markdown-file rewrite hook (opt-in)
├── providers.sh            # provider layer (ollama/anthropic/openai), sourced by both hooks
├── CHANGELOG.md            # notable changes per version (Keep a Changelog)
├── LICENSE
└── README.md
```

## License

MIT — see [LICENSE](./LICENSE).
