# naturalize

<p align="center">
  <img
    src="https://github.com/ValerioL29/agentish-to-english/releases/download/assets/comparison.png"
    width="820"
    alt="Side-by-side comparison: a dense, jargon-heavy assistant message on the left, and its plain-English rewrite on the right">
</p>

A Claude Code plugin that shows a **plain-English rewrite** of each assistant
message, produced by a **local LLM via ollama** (default), the **codex CLI**,
the **Google Antigravity CLI**,
the **Anthropic API**, or any **OpenAI-compatible API**. It is **display-only**:
Claude's own reasoning and the saved transcript keep the original text — only
what you read on screen changes.

If your session speaks something other than English, so does the rewrite: it
follows the message's own language, or the `language` setting Claude Code
already answers in. See [Output language](#output-language).

An optional second hook rewrites **Markdown files** into plain language when
they are written or edited (opt-in, off by default). You can also rewrite any
file, URL, or pasted text **on demand** — `/naturalize file <path or URL>` in a session, or
`naturalize-md.sh` from a terminal. See
[Rewriting a file or text on demand](#rewriting-a-file-or-text-on-demand).

> Status: working prototype. Every hook fails **open** — if anything goes wrong
> (provider down, timeout, missing key or dependency), you simply see Claude's
> original text. The plugin can never swallow or corrupt an answer.

## Supported hosts

[naturalize](https://github.com/ValerioL29/agentish-to-english) uses the same
scripts and settings on every host. What differs is how each host lets a hook
show text.

| Host | Mode | How the rewrite appears | Status |
| --- | --- | --- | --- |
| Claude Code (CLI, desktop, IDE) | replace or append, plus on-demand `/naturalize file` | `MessageDisplay` hook changes what you see; history keeps the original | tested |
| Codex CLI | append | Stop hook `systemMessage`, a warning-styled block under the answer | tested |
| Codex app (ChatGPT desktop) | append | same Stop hook and `systemMessage`; the app shows hook messages as warnings | untested |
| Antigravity CLI (`agy`) | append | Stop hook makes the agent echo the rewrite as an extra reply | tested (prototype) |
| Antigravity App / IDE | append | same Stop hook, loaded from `~/.gemini/config/` | untested |
| Grok Build (CLI / ACP) | — | Grok ignores stdout of `Stop` and other passive hooks, so nothing can be shown | not possible |

"Tested" means someone ran it end to end on Linux. "Untested" means the
host's docs say it loads the same hook, but nobody has run it in that app yet.
Every host fails open: if the rewrite fails, you see the original answer and
nothing else.

The same environment variables work on every host. The ones you will most
likely set:

```bash
export NATURALIZE_PROVIDER=codex     # ollama (default), codex, agy, anthropic, openai
# export NATURALIZE_MODEL=...      # optional; each provider has a default
export NATURALIZE_CODEX_EFFORT=low   # codex provider only; faster rewrites
export NATURALIZE_TIMEOUT=45         # seconds; keep the hook timeout >= this + 20
export NATURALIZE_LANG=English       # output language (the name is NATURALIZE_LANG)
export NATURALIZE_PROMPT_FILE=~/my-prompt.txt   # optional custom rewrite prompt
```

Export them before you start the CLI. Desktop apps don't read your shell
profile, so see each host's section. The full list is in
[Configuration (env vars)](#configuration-env-vars).

| Host | Install | Turn off |
| --- | --- | --- |
| Claude Code | [Install](#install) | `/naturalize off`, or disable the plugin |
| Codex CLI and app | [Codex](#codex-cli-and-codex-app-append-mode-only) | disable the hook in `/hooks` or Settings |
| Antigravity CLI, App, IDE | [Antigravity](#antigravity-cli-app-and-ide-prototype-append-mode-only) | `agy plugin disable naturalize`, or toggle it in Customizations > Hooks |
| Grok Build | [Grok Build](#grok-build-not-supported) | — |

---

## Requirements (read this first)

With the default `ollama` provider this plugin shells out to a **local** model,
and nothing works until these are in place. (With `NATURALIZE_PROVIDER=anthropic`
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
`NATURALIZE_NOTICE=0` to silence it).

**Pick a model you actually have.** The default is `gemma4:26b-mlx`, an
Apple-silicon (MLX) build — the right choice on a Mac, but **macOS-only**. On
Windows it doesn't run, so you must switch to a regular tag (see
[Windows setup](#windows-setup)). Pull it (as above), or pull a smaller/faster
model and point the plugin at it by setting `NATURALIZE_MODEL` to that model's
exact ollama tag in your `env` (see
[Configuring the plugin](#configuring-the-plugin)). If `NATURALIZE_MODEL` names a
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
> Always set `NATURALIZE_MODEL` to a regular (non-MLX) tag on Windows. The table
> above uses `gemma4:26b` as an example; choose another if it fits your machine
> better.

Warm the model once after launching Ollama (the first call is a slow cold load):

```powershell
ollama run gemma4:26b "hi"
```

Then set `NATURALIZE_MODEL` in the `env` block of your `settings.json` (see
[Configuring the plugin](#configuring-the-plugin) — that method is identical on
Windows), or for a one-off session from PowerShell:

```powershell
$env:NATURALIZE_MODEL = "gemma4:26b"; claude
```

Windows equivalents of the mid-session kill switch
([Toggling mid-session](#toggling-mid-session)):

```powershell
New-Item -ItemType File $HOME\.claude\naturalize-off   # pause rewrites
Remove-Item $HOME\.claude\naturalize-off               # resume
```

(In Git Bash the `touch`/`rm` commands from that section work as-is.)

Notes:
- Write `NATURALIZE_MD_DIR` with forward slashes
(`C:/dev/docs/plain`) so the bash-side path checks match
- The `NATURALIZE_DEBUG=1` log lands under Git Bash's temp directory
(`$TMPDIR/naturalize/`, typically
`C:\Users\<you>\AppData\Local\Temp\naturalize\`).

</details>

---

## Install

Directly from this repository (also serves its own marketplace):

```shell
/plugin marketplace add ValerioL29/agentish-to-english
```
```shell
/plugin install naturalize@valeriol29-plugins
```

If the install summary says `Run /reload-plugins to activate.`, run that command.

**Try before installing** (loads it for one session, no install):

```bash
claude --plugin-dir /path/to/agentish-to-english
```

Run `/reload-plugins` after edits; if it doesn't load, check the `/plugin`
**Errors** tab.

---

## Antigravity CLI, App, and IDE (prototype, append mode only)

> **Prototype.** Tested on the Antigravity CLI (`agy`) only, on Linux, in
> October 2026. The App and IDE read the same hook files
> ([hooks docs](https://antigravity.google/docs/hooks/)), but nobody has run
> the plugin there yet.

Antigravity has no hook that can display text or replace the reply, so the
Antigravity plugin works around it with the `Stop` hook (`agy-stop.sh`):

1. When a turn ends (`terminationReason` is `NO_TOOL_CALL` or `model_stop`,
   `fullyIdle` is true, no `error`), the hook reads the last assistant step
   from `transcriptPath` and rewrites it through `rewrite.sh`. All the usual
   settings apply (`NATURALIZE_PROVIDER`, `NATURALIZE_MODEL`, `NATURALIZE_TIMEOUT`,
   `NATURALIZE_MIN_CHARS`, `NATURALIZE_LANG`, `NATURALIZE_STYLE`, …).
2. It returns `{"decision":"continue","reason":"…"}`. The reason holds the
   finished rewrite, with the rule line and the `💬 In plain **language**:` label, and tells the
   agent to output it verbatim and call no tools. Antigravity adds it as a
   system message and runs **one extra model turn**, the "echo pass". The
   plain version appears as a second reply below the original.
3. Before it returns, the hook writes a marker,
   `$TMPDIR/naturalize-agy/<conversationId>.echo`
   (`NATURALIZE_AGY_STATE` overrides the directory). The `Stop` after the echo
   pass finds the marker, deletes it, and lets the turn end, so it can't loop.
   A marker older than 15 minutes is ignored.

It fails open. On any skip or error it prints `{}`, and the turn ends
normally. `NATURALIZE_HOOK_DEPTH` is exported for the rewrite, so a nested
`agy -p` rewrite (from the agy provider, if you use it) exits the hook right
away.

**Install (CLI):**

```bash
git clone https://github.com/ValerioL29/agentish-to-english
agy plugin install ./agentish-to-english/antigravity-plugin
```

This copies the plugin, with its symlinked scripts dereferenced, to
`~/.gemini/config/plugins/naturalize/`. Run
`agy plugin uninstall naturalize` to remove it, and reinstall after
you update the checkout. Plugin hooks run with the plugin directory as their
working directory. For a single workspace, you can instead point
`.agents/hooks.json` at the checkout:

```json
{"naturalize-append": {"Stop": [{"type": "command",
  "command": "bash /path/to/agentish-to-english/agy-stop.sh", "timeout": 620}]}}
```

The 620s timeout is `NATURALIZE_TIMEOUT` (sized for 600) plus 20s. Export the
`NATURALIZE_*` variables before you launch `agy`.

**Install (Antigravity App or IDE, untested):** both read global hooks from
`~/.gemini/config/hooks.json` and workspace hooks from `.agents/hooks.json`.
Use an absolute path, because the docs don't say which working directory the
App and IDE give plugin hooks:

```json
{"naturalize-append": {"Stop": [{"type": "command",
  "command": "bash /path/to/agentish-to-english/agy-stop.sh", "timeout": 620}]}}
```

Then check that it is on in Settings > Customizations > Hooks (App) or
… > Customizations > Hooks in the agent side panel (IDE). A desktop app does
not inherit variables from your shell, so put settings you need, such as
`NATURALIZE_PROVIDER`, in the command itself:
`"command": "NATURALIZE_PROVIDER=agy bash /path/to/agentish-to-english/agy-stop.sh"`.
The App and IDE keep transcripts under `~/.gemini/antigravity` and
`~/.gemini/antigravity-ide`. The hook reads whatever `transcriptPath` the
payload gives and also accepts `transcript.jsonl` or `transcript_full.jsonl`
in that folder, so it doesn't depend on which app runs it. If you installed
the plugin with `agy plugin install`, don't also add this entry, or the hook
runs twice.

**Turn it off:** `agy plugin disable naturalize` (or `uninstall`),
`enabled: false` on the `naturalize-append` entry in a `hooks.json`, the
Customizations > Hooks toggle in the App or IDE, `NATURALIZE_ENABLED=0`, or the
off-file (`~/.claude/naturalize-off`).

**Caveats:**

- The echo is the model's own output. In tests it was byte-identical, but
  nothing guarantees that.
- Each turn costs one extra model call. The echoed text also stays in the
  conversation context.
- Each turn takes longer: the rewrite (about 6s with codex at medium effort)
  plus the echo pass (about 5s).
- The agent sees the rewrite, unlike Claude Code's display-only rewrite.
- The echo uses the same block as Claude Code's append mode: a
  `────────────────────────` rule, the `💬 In plain **…**:` label, then the
  rewrite. Under `agy -p` it is printed right after the original.
- The hook payload differed from the docs in testing. `terminationReason` was
  `NO_TOOL_CALL`, and `transcriptPath` pointed at `transcript_full.jsonl`. The
  hook accepts both forms.

---

## Codex CLI and Codex app (append mode only)

The Codex plugin does one thing: an **append-mode Stop hook**. Codex has no
hook that can change displayed assistant text, so there is no `replace` mode
and no on-demand skill or command; the Claude Code plugin is unaffected.

**Install (Codex CLI):** Codex reads this repo's marketplace file, so you can
add it straight from GitHub:

```bash
codex plugin marketplace add ValerioL29/agentish-to-english
codex plugin add naturalize@valeriol29-plugins
```

For a local checkout, use `codex plugin marketplace add /path/to/agentish-to-english`.
Codex uses `.codex-plugin/plugin.json`, which loads only
`hooks/codex-hooks.json`. Then open `/hooks` and trust the Stop hook (below).

**Codex app (ChatGPT desktop), untested.** The app and the CLI share
`~/.codex` (config, plugins, and hook trust) on the same machine, and the
[plugins docs](https://learn.chatgpt.com/docs/plugins) say the desktop app can
install plugins. So a plugin added with the commands above should also load in
the app. If the app asks you to review hooks, trust the
`naturalize` Stop hook in its hook settings. The
[hooks docs](https://learn.chatgpt.com/docs/hooks) say a `systemMessage` is
shown "as a warning in the UI or event stream", so expect a warning-style
block, not a normal reply. Two things to watch: the app does not get variables
from your shell, so set `NATURALIZE_*` values somewhere the app's process sees
them (or rely on the defaults); and plugin hooks don't run in
cloud-orchestrated ChatGPT Work threads, only local ones.

**Codex append mode (Stop hook).** The Codex manifest points `hooks` at
`hooks/codex-hooks.json` (so Claude's `hooks/hooks.json` is never loaded by
Codex). It registers one `Stop` hook, `codex-stop.sh`, which mirrors the Claude
Code `append` display mode as closely as Codex allows:

- When a turn ends, the final assistant message (`last_assistant_message`) is
  rewritten and returned as `{"systemMessage": "…"}`. Codex shows it as a
  **second, warning-styled message** below the answer, with the same
  `💬 In plain **language**:` label (or the style's label). The original
  answer stays on screen and in history, and the rewrite never enters the
  model's context.
- There is no `replace` mode: Codex parses `suppressOutput` but does not
  implement it, so `NATURALIZE_MODE` is ignored here and append is forced.
- The rewrite reuses `rewrite.sh` unchanged, so the same settings apply:
  `NATURALIZE_PROVIDER`, `NATURALIZE_MODEL`, `NATURALIZE_CODEX_EFFORT`,
  `NATURALIZE_TIMEOUT`, `NATURALIZE_MIN_CHARS`, `NATURALIZE_LANG` (and the
  `language` settings key), `NATURALIZE_STYLE`, `NATURALIZE_PROMPT_FILE`,
  `NATURALIZE_NOTICE`, `NATURALIZE_DEBUG`, and the flag files from `/naturalize`.
  The hook's own `timeout` in `hooks/codex-hooks.json` is **620s** =
  `NATURALIZE_TIMEOUT` (default 45; sized for users who set 600) + ~20s for startup and
  the nested CLI. Keep `hook timeout ≥ NATURALIZE_TIMEOUT + 20`; if you go above
  600, raise the hook timeout too. The rewrite's own timeout still fails open
  first, so normal turns only wait as long as the rewrite takes.
- It fails open. It prints `{}` (nothing shown, turn unaffected) when the
  message is empty or too short, when `stop_hook_active` is true, or when the
  rewrite fails, times out, or comes back empty or unchanged. It never
  returns `decision: "block"`, so it can't start an extra turn.
- With `NATURALIZE_PROVIDER=codex`, the rewrite runs a nested `codex exec`. That
  call passes `--disable hooks`, and the hook also exits early when
  `NATURALIZE_HOOK_DEPTH` is set, so the hook can't call itself recursively.
- Each finished turn waits for the rewrite (a few seconds with a fast model,
  e.g. `NATURALIZE_CODEX_EFFORT=low`).

Codex does **not** run plugin hooks until you trust them. After installing,
open `/hooks` in the Codex CLI (or the hooks settings in the app), review the `naturalize` Stop hook and
trust it (re-trust after updating the plugin, because trust is tied to the hook's
hash). To turn it off, disable that hook in `/hooks`, set
`NATURALIZE_ENABLED=0` before launching Codex, or create the off-file
(`~/.claude/naturalize-off`, or `NATURALIZE_OFF_FILE`) to pause it mid-session.
For scripted runs, `codex exec --dangerously-bypass-hook-trust` runs it without
persisted trust.

The same `bash`, `jq`, `curl`, and [provider setup](#providers) apply. Export
`NATURALIZE_PROVIDER`, `NATURALIZE_MODEL`, and any provider key or endpoint in the
shell **before launching Codex**, so the hook inherits them. The Codex manifest
loads only `hooks/codex-hooks.json`, so Claude's `hooks/hooks.json` and
`/naturalize` command are not picked up.

---

## Grok Build (not supported)

Grok Build can load Claude Code hook files (`.claude/settings.json`) and its
own plugins, but its [hooks docs](https://docs.x.ai/build/features/hooks)
say that "for passive events, stdout is ignored". `Stop` is passive, and
`PreToolUse` is the only event that can change anything. There is no
`MessageDisplay` event and no way for a hook to show text or start another
turn, so neither replace nor append mode can work. Grok Build runs as a TUI,
headless, or over ACP inside other apps; we found no separate Grok desktop app
with its own hook system. A Grok plugin was drafted on the
`wip/grok-build-plugin` branch and shelved for this reason.

If you open a project in Grok Build that has this plugin in
`.claude/settings.json`, the hooks may still run and spend a rewrite call with
nothing shown. Set `NATURALIZE_ENABLED=0` for Grok sessions to avoid that.

---

## Configuring the plugin

There are two ways to control naturalize, and they complement each other:

- **`/naturalize`** — a slash command for live, day-to-day toggles: on/off, display
  mode, language, and model. Changes take effect immediately, mid-session. This
  is what most people reach for. See
  [Controlling it live](#controlling-it-live-naturalize).
- **`NATURALIZE_*` environment variables** — your durable defaults, and the only
  way to set everything `/naturalize` doesn't cover (provider, API keys, base URLs,
  the Markdown hook, timeouts). Full list in
  [Configuration](#configuration-env-vars) below.

Set the durable ones in Claude Code's **`env` block in `settings.json`** — do
**not** edit the plugin's own `hooks/hooks.json`, which lives in the read-only
plugin cache (`~/.claude/plugins/cache/…`) and is overwritten on every update.

For a personal, all-projects setup, use `~/.claude/settings.json`:

```json
{
  "env": {
    "NATURALIZE_MODEL": "gemma4:26b-mlx",
    "NATURALIZE_MODE": "append"
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
  `NATURALIZE_*` vars in whichever file wins.
- **Scopes:** `~/.claude/settings.json` (all your projects) ·
  `.claude/settings.json` (shared with a repo, checked in) ·
  `.claude/settings.local.json` (just you, just this repo).

Quick one-off without editing a file — hooks inherit the launching shell:

```bash
NATURALIZE_MODEL=llama3.2:3b claude
```

To confirm the hook is firing, set `NATURALIZE_DEBUG=1` and watch
`"$TMPDIR"/naturalize/debug.log`.

---

## Controlling it live: `/naturalize`

`/naturalize` is the interactive front-end for the four most-used settings —
on/off, display mode, language, and model. Changes take effect on the next
assistant message, mid-session, with nothing to relaunch:

```
/naturalize              show the dashboard (current state + where each value comes from)
/naturalize on           resume rewrites (keeps the current mode)
/naturalize off          pause rewrites (originals only; also pauses the Markdown hook)
/naturalize append       show the original, then the rewrite below it
/naturalize replace      show only the rewrite
/naturalize style X      rewrite style: tldr | 5y (explain like I'm five) | caveman
/naturalize style        reset to the default plain-language rewrite
/naturalize language fr  rewrite into French (any name, incl. non-Latin like 简体中文)
/naturalize language     reset to the session/settings language (see "Output language")
/naturalize model X      use model X for whatever provider is configured
/naturalize model        reset to the provider default
/naturalize last         reprint the ORIGINAL of the last message (handy in replace mode)
/naturalize file PATH    rewrite a Markdown file (or URL) into NAME.plain.md (see "on demand" below)
/naturalize cycle        step off → append → replace → off
/naturalize reset        clear ALL overrides — back to your env/settings defaults
```

Bare `/naturalize` prints a **dashboard** — each setting, its current value, and
where that value comes from (an env var, a `/naturalize` override, your
`settings.json`, or the default):

```
  naturalize · plain-language rewrite of each assistant message

  status    replace          · ⚠ /naturalize — rewrite only; beats env, persists across sessions
  style     tldr             · ⚠ /naturalize — beats env NATURALIZE_STYLE, persists across sessions
  language  French           · ⚠ /naturalize — beats env & settings, persists across sessions
  model     gemma4:26b-mlx   · ollama provider default
  provider  ollama           · default
```

Each switch writes a small flag file under `~/.claude/` that the hooks re-read
every message (the paths and their `NATURALIZE_*_FILE` overrides are in the
[env-var table](#configuration-env-vars); the underlying mechanism is under
[Toggling mid-session](#toggling-mid-session)). A live `/naturalize` switch **beats
the matching env var** — `NATURALIZE_MODE`, `NATURALIZE_LANG`, or `NATURALIZE_MODEL`.

**These overrides persist across sessions** (like the off-file), until you clear
them with the per-setting `default` form, `/naturalize on`, or `/naturalize reset`.
So a `/naturalize language French` set today still applies to a session you open
tomorrow. The state is never silent, though: the dashboard flags every persisting
override with ⚠, and a `SessionStart` notice lists any that are active at the top
of a new session (`NATURALIZE_NOTICE=0` silences it). For a *permanent* default,
set the matching env var in `settings.json` rather than using `/naturalize`.

`/naturalize last` works because the rewrite is display-only: the transcript always
keeps Claude's original text, so the command just reprints it (prefixed with an
internal `<!-- naturalize:original -->` marker that tells the display hook not to
rewrite that reply, and which is stripped from view).

---

## Output language

The rewrite comes back in the **same language as the text it rewrites**. An
Esperanto answer is simplified into Esperanto, an English one into English;
nothing is translated unless you ask for it.

To pin a language, set one. The hooks read the same `language` key Claude Code
itself answers in, in the same order of precedence, so a session that already
speaks Esperanto needs no extra configuration:

| Source | Example |
|---|---|
| `NATURALIZE_LANG` (env) | `"NATURALIZE_LANG": "Esperanto"` |
| `<project>/.claude/settings.local.json` | `"language": "Esperanto"` |
| `<project>/.claude/settings.json` | `"language": "Esperanto"` |
| `~/.claude/settings.json` | `"language": "Esperanto"` |

The first one that is set wins, and the on-screen label then names it —
💬 In plain **Esperanto**:

`NATURALIZE_LANG` set but **empty** ignores the settings key and goes back to
following the input's language; set it to `English` to force English on a
non-English session.

A configured language is appended to the built-in prompt. A prompt supplied
through `NATURALIZE_PROMPT_FILE` or `NATURALIZE_MD_PROMPT_FILE` replaces the whole
prompt, language line included — that file is your prompt in full, and it
states its own language (see below).

An unreadable, malformed, or non-string setting is ignored the way every other
failure here is: rewrites keep working, in the input's language.

One caveat: a rewrite is only as good as the model that writes it, and small
local models simplify English noticeably better than they simplify anything
else. If non-English results disappoint, try a larger model or a cloud provider
(see [Providers](#providers)).

---

## Customizing the rewrite prompt

Each hook ships with a default system prompt that asks the model for plain
language while preserving facts, code, and structure.

For a quick change of tone without writing a prompt, the display hook also has
three **built-in style presets** — `tldr` (a short summary), `5y` (explain like
I'm five), and `caveman` (blunt caveman speak) — set with
[`/naturalize style`](#controlling-it-live-naturalize) or
`NATURALIZE_STYLE`. Each one labels its block with its own emoji, so the style in
use is visible at a glance:

| style | label |
|---|---|
| *(default)* | 💬 In plain **language**: |
| `tldr` | 📌 **TL;DR**: |
| `5y` | 👶 Like you're **five**: |
| `caveman` | 🦴 **Ugh.** Me say: |

The bold word is markdown, rendered by Claude Code itself — no ANSI colour
codes, so the label cannot be washed out by a terminal colour scheme and stays
readable when `claude -p` output is piped to a file. For full control, you can instead **replace** either prompt
with your own to add specific rules or use wording that works better with your
model (this wins over a style preset). To do so, point the hook at a file that
holds the prompt:

| Hook | Prompt file |
|---|---|
| Display (`rewrite.sh`) | `NATURALIZE_PROMPT_FILE` |
| Markdown (`rewrite-md.sh`) | `NATURALIZE_MD_PROMPT_FILE` |

The file's contents **replace** the built-in prompt, so
include every instruction you want the model to follow — otherwise the defaults
(keep facts, leave code blocks alone, output only the rewrite) are gone. Keeping
the prompt in a file avoids escaping a long, multi-line prompt inside a JSON
string. If the variable is unset, or the file is empty or unreadable, the hook
falls back to its built-in default, so a bad path never stops rewrites.

```json
{
  "env": {
    "NATURALIZE_PROMPT_FILE": "/ABS/PATH/prompts/plain.txt",
    "NATURALIZE_MD_PROMPT_FILE": "/ABS/PATH/prompts/md-plain.txt"
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
chunk 1 (final:false) ─┤ append each delta to $TMPDIR/naturalize/<session>/<message>/<index>.part
chunk 2 (final:false) ─┘  → emit nothing (append) or "" (replace)
chunk 3 (final:true)  ──► reconstruct full message → call ollama once → show the rewrite
                          → delete the buffer
```

On that final chunk it also reads the **original user question** from the
transcript and passes it to the model as **context only** — to keep the rewrite
on-topic. The model is told never to answer or repeat the question; it only
rewrites the assistant's message.

### Display modes

| `NATURALIZE_MODE` | On screen | Notes |
|---|---|---|
| `append` (default) | Original streams normally, then a 💬 In plain **language**: block is appended (💬 In plain **Esperanto**: when a language is configured; other styles use their own emoji — see [Customizing the rewrite prompt](#customizing-the-rewrite-prompt)). | Safest. No streaming loss; if the LLM fails you just don't get the extra block. |
| `replace` | Only the simplified version (original chunks suppressed while streaming). | Experimental. Appears all at once after LLM latency; on failure it re-shows the full original. |

---

## Markdown file rewrite (optional second hook)

A `PostToolUse` hook (`rewrite-md.sh`) rewrites Markdown **files** into plain
language when they are written or edited. Unlike the display hook, this changes
bytes on disk.

**Opt-in by directory.** It does nothing unless `NATURALIZE_MD_DIR` is set, and it
only touches `*.md` files whose resolved path is inside that directory. Every
other `README`, `CLAUDE.md`, or doc you edit is left alone.

| `NATURALIZE_MD_MODE` | Result | Notes |
|---|---|---|
| `sibling` (default) | Writes `NAME.plain.md` next to `NAME.md`. | Non-destructive; the original is never touched. |
| `overwrite` | Replaces `NAME.md` in place. | Adds a `<!-- naturalize:rewritten -->` marker so a re-write is skipped (idempotent). A weak model can degrade real docs — use with care. |

In both modes: YAML frontmatter is split off and re-attached **verbatim**, fenced
code is left to the model instruction, short files are skipped, and the write is
atomic. Fail-open here means the file is left **exactly as the agent wrote it**.

**Large files are slow.** `gemma4:26b-mlx` (the default) rewrites at roughly 60
tokens/s, so a long plan or spec can take 30–120s. This hook allows up to
`NATURALIZE_MD_TIMEOUT` (150s) inside a 180s `PostToolUse` hook budget; if a rewrite
still times out you get the one-time notice above — raise those limits, or set
`NATURALIZE_MODEL` to a smaller model.

Enable it for one directory, in sibling mode (the safe default), the same way
as every other setting — the `env` block of your `settings.json`:

```json
{
  "env": {
    "NATURALIZE_MD_DIR": "/ABS/PATH/docs/plain",
    "NATURALIZE_MD_MODE": "sibling"
  }
}
```

In `overwrite` mode the marker comment is written **after** any YAML
frontmatter, so the frontmatter stays on line 1 where parsers expect it.

---

## Rewriting a file or text on demand

The hooks only act on what Claude writes. To rewrite **any** Markdown file, a
Markdown document at a URL, or any text at all, whenever you like, use
`naturalize-md.sh`. It gives the same
rewrite as the Markdown hook (same prompt, same frontmatter handling, same
provider, model, and language settings, `/naturalize` overrides included), but
you choose the input and where the result goes.

**Inside a session**, point `/naturalize` at a file:

```
/naturalize file docs/architecture.md     → writes docs/architecture.plain.md
/naturalize file ~/notes/meeting notes.md → paths with spaces work; no quotes needed
/naturalize file https://github.com/o/r/blob/main/docs/setup.md
                                        → writes ./setup.plain.md in the session's folder
```

It writes `NAME.plain.md` next to the file and replies with one line naming it.
The rewrite is not shown in the chat, so Claude never has to read the whole
document back to you. Open the file to read it.

**From a terminal**, run the script directly:

```bash
naturalize-md.sh notes.md                 # rewrite -> stdout
naturalize-md.sh notes.md -o simple.md    # rewrite -> simple.md
naturalize-md.sh notes.md --sibling       # rewrite -> notes.plain.md
pbpaste | naturalize-md.sh                # any text on stdin -> stdout
naturalize-md.sh -l English notes.md      # into English, whatever the input language
naturalize-md.sh https://example.com/guide.md          # a URL -> stdout
naturalize-md.sh file:///Users/me/notes/guide.md       # a file:// link works like the path
naturalize-md.sh 'C:\Users\me\notes\guide.md'         # Windows paths too (Git Bash); quote backslashes
naturalize-md.sh --sibling https://example.com/guide.md  # -> ./guide.plain.md
```

**URLs.** Any public `http(s)` link to a Markdown or plain-text file works.
Links to a *rendered* page on GitHub (`…/blob/…`), GitLab (`…/-/blob/…`), or
Gist are quietly switched to the raw file, because the page itself is HTML. Any
other page that comes back as HTML is refused with a message, rather than
rewritten. The download is unauthenticated, so private repositories answer
404. It is limited to `NATURALIZE_MD_MAX_BYTES` (1 MB) and
`NATURALIZE_MD_FETCH_TIMEOUT` (30s), and only `http`/`https` are followed, on
redirects too. With `--sibling` (and `/naturalize file`) the output is named
after the last part of the URL and written in the current folder, since there
is no folder next to a URL.

For an installed plugin, the script is in the plugin cache. Bare `/naturalize`
prints its full path on the `files` line of the dashboard. That path changes
when the plugin updates, so if you use the script often, an alias that finds
the latest copy keeps working:

```bash
alias naturalize-md='"$(ls -d ~/.claude/plugins/cache/*/naturalize/*/ | sort -V | tail -1)naturalize-md.sh"'
```

**Output language.** Like everything else in the plugin, the rewrite keeps the
input's own language unless a language is configured (see
[Output language](#output-language)). For English specifically, pass
`-l English`, or set `/naturalize language English` once — that also applies to
`/naturalize file`.

How it differs from the hook, on purpose — you asked for *this* rewrite:

- **No gates.** It ignores `NATURALIZE_MD_DIR`, the `.md` extension, and
  `NATURALIZE_MIN_CHARS`. It also runs while rewrites are paused
  (`/naturalize off`), because pausing only stops the automatic hooks.
- **It fails loudly.** A hook fails open by leaving the original on screen. A
  command you ran has no original to fall back to, so any problem (provider
  down, timeout, missing key, bad path) prints `naturalize-md: <reason>` and exits
  non-zero. It still never prints or writes a partial or empty rewrite, and a
  file target is replaced atomically, only on success.
- **Timeout.** The LLM call uses `NATURALIZE_MD_TIMEOUT` (150s). Under
  `/naturalize file` it is capped at 110s (90s plus a 20s download for a URL),
  because Claude Code stops a slash command's shell step at 2 minutes. For a long document on a slow local
  model, run it from a terminal with a higher limit
  (`NATURALIZE_MD_TIMEOUT=600 naturalize-md.sh --sibling big.md`), or pick a
  smaller model.

Exit codes: `0` done, `1` the rewrite failed, `2` usage error. When writing a
file, the absolute path written is printed on stdout.

---

## Providers

Rewrites go through one of four providers, selected with `NATURALIZE_PROVIDER`
(both hooks share the setting). The default is local ollama, so nothing leaves
your machine.

| Provider | Endpoint | Key | Default model |
|---|---|---|---|
| `ollama` (default) | `NATURALIZE_OLLAMA` (`http://localhost:11434`) | none | `gemma4:26b-mlx` |
| `codex` | OpenAI codex CLI (`codex exec`) — uses the CLI's own login | none | *(CLI default)* |
| `agy` | Google Antigravity CLI (`agy -p`) — uses the CLI's own login | none | *(CLI default)* |
| `anthropic` | `NATURALIZE_ANTHROPIC_URL` (`https://api.anthropic.com`) + `/v1/messages` | `NATURALIZE_ANTHROPIC_KEY` or `ANTHROPIC_API_KEY` | `claude-haiku-4-5` |
| `openai` | `NATURALIZE_OPENAI_URL` + `/chat/completions` | `NATURALIZE_OPENAI_KEY` or `OPENAI_API_KEY` | `gpt-5.6-luna` |

### codex

`NATURALIZE_PROVIDER=codex` runs the rewrite through the OpenAI codex CLI
(`codex exec`, read-only sandbox, outside any repo), using the CLI's own
login. No API key and no local model server. `NATURALIZE_MODEL` overrides
the CLI's configured model; unset uses the CLI default. `NATURALIZE_CODEX_EFFORT`
overrides the CLI's reasoning effort for the rewrite only (e.g. `low` keeps a
per-message rewrite fast even when the CLI's coding default is a high-effort
tier). Requires `codex` on PATH; fails open like every other provider.

### agy (Google Antigravity)

`NATURALIZE_PROVIDER=agy` runs the rewrite through the Google Antigravity CLI in
headless mode (`agy -p`), using the credentials cached by an interactive `agy`
login. No API key and no local model server. Run `agy` once interactively to
sign in first: an unauthenticated headless run fails with "authentication
required", and the session notice tells you so.

- `NATURALIZE_MODEL` picks the model slug (list them with `agy models`, e.g.
  `gemini-3.8-flash-medium`); unset uses the CLI default.
- `NATURALIZE_AGY_EFFORT` passes `--effort low|medium|high`; unset uses the CLI
  default. `low` keeps per-message rewrites fast.
- `NATURALIZE_AGY_WORKDIR` is the directory `agy` runs in (default
  `${TMPDIR:-/tmp}/naturalize-agy-ws`). It is a scratch directory on purpose, so
  the agent never runs inside your project.

Requires `agy` on PATH; fails open like every other provider.

> [!CAUTION]
> The cloud providers pick their key up from the **ambient environment**
> (`OPENAI_API_KEY` / `ANTHROPIC_API_KEY`), and `NATURALIZE_OPENAI_URL` defaults
> to api.openai.com. Anything that puts those variables into the environment
> Claude Code launches with — an `export` in your shell profile, a tool like
> direnv loading a project's `.env` into your shell, or the `env` block of a
> settings file — makes them visible to this plugin. In such an environment,
> setting the single variable `NATURALIZE_PROVIDER=openai` starts sending every
> assistant message (and, with the Markdown hook, file contents) to OpenAI's
> cloud. Likewise, `NATURALIZE_PROVIDER=anthropic` will quietly spend the same
> `ANTHROPIC_API_KEY` (and share its rate limits) that other tools on your
> machine may rely on. Selecting a cloud provider IS the consent switch — set
> it only when you mean it, and use the `NATURALIZE_*_KEY` variables when you
> want the plugin on a dedicated key.

```bash
# ollama (default) — local, nothing leaves your machine
export NATURALIZE_PROVIDER=ollama
export NATURALIZE_MODEL=gemma4:26b-mlx        # the default; any pulled tag works

# Anthropic — Claude Haiku
export NATURALIZE_PROVIDER=anthropic
export ANTHROPIC_API_KEY=sk-ant-...
export NATURALIZE_MODEL=claude-haiku-4-5      # the default; override to taste

# Anthropic — no API key: ride the Claude Code login you're already using.
# Re-reads the OAuth access token from the macOS login Keychain (item
# `Claude Code-credentials`), or ~/.claude/.credentials.json elsewhere, on
# every call (Claude Code keeps it fresh while running, and these hooks only
# run while it runs; a token past its expiresAt is discarded, not sent), and
# authenticates with Authorization: Bearer + the oauth-2025-04-20 beta flag
# instead of x-api-key. Rewrites then ride your Claude subscription — no
# separate API billing. The token is only ever sent to
# https://api.anthropic.com: this mode refuses to run with a
# NATURALIZE_ANTHROPIC_URL override, so the credential cannot leak to a proxy.
#
# ⚠️ UNOFFICIAL — USE AT YOUR OWN RISK. Anthropic has not blessed third-party
# use of the Claude Code token: this mode may stop working without warning,
# and programmatic use of a subscription credential could put your Claude
# account at risk. The first rewrite of each session repeats this caution on
# screen. When the mode breaks, the hook fails open (original text,
# once-per-session notice) like every other failure.
export NATURALIZE_PROVIDER=anthropic
export NATURALIZE_ANTHROPIC_AUTH=oauth
export NATURALIZE_MODEL=claude-haiku-4-5      # the default; override to taste

# OpenAI — GPT-5.6 Luna
export NATURALIZE_PROVIDER=openai
export OPENAI_API_KEY=sk-...
export NATURALIZE_MODEL=gpt-5.6-luna          # the default; override to taste

# Any OpenAI-compatible server (LM Studio, llama.cpp server, vLLM, OpenRouter).
# A key is only required for api.openai.com — local servers work keyless.
export NATURALIZE_PROVIDER=openai
export NATURALIZE_OPENAI_URL=http://localhost:1234/v1
export NATURALIZE_MODEL=qwen3-30b
```

Notes:

- `NATURALIZE_MODEL` overrides any provider's default model.
- Requests to api.openai.com send `reasoning_effort: "none"` (GPT-5.6-class
  models otherwise spend reasoning tokens on a plain rewrite). Custom
  OpenAI-compatible URLs get no such field, since some local servers reject
  unknown fields. Force one with `NATURALIZE_OPENAI_EFFORT`, or set it
  **explicitly empty** (`NATURALIZE_OPENAI_EFFORT=`) to omit the field even for
  api.openai.com — needed for models that reject `reasoning_effort` entirely.
- The anthropic provider caps completions at `NATURALIZE_MAX_TOKENS` (default
  4096, since the Messages API requires an explicit cap).
- A rewrite that hits an output-token cap is **discarded**, not shown — on the
  ollama, anthropic, and openai providers (ollama's `done_reason: "length"`
  included): a half-finished
  rewrite on screen is confusing, and in the Markdown hook's `overwrite` mode
  it would replace your real document. You get the original text plus the
  once-per-session notice suggesting a higher cap.
- Every provider failure stays fail-open: missing key, bad key, unreachable
  endpoint, or timeout just leaves the original text (plus the once-per-session
  notice, unless `NATURALIZE_NOTICE=0`).

> **Privacy:** the cloud providers send each assistant message (and, for the
> Markdown hook, file contents) to an external API. Read
> [Privacy / egress](#privacy--egress) before switching away from ollama.

---

## Configuration (env vars)

| Var | Default | Meaning |
|---|---|---|
| `NATURALIZE_ENABLED` | `1` | Master switch. `0` = pass everything through. Read once at session start. |
| `NATURALIZE_OFF_FILE` | `~/.claude/naturalize-off` | Runtime kill switch. While this file exists, rewrites pause — re-checked every message, so unlike env vars it works mid-session. See [Toggling mid-session](#toggling-mid-session). |
| `NATURALIZE_MODE` | `append` | `append` or `replace` (display hook). |
| `NATURALIZE_MODE_FILE` | `~/.claude/naturalize-mode` | Runtime display-mode override: `append`/`replace` in this file wins over `NATURALIZE_MODE`, re-checked every message. Written by `/naturalize append`/`replace`. See [Controlling it live](#controlling-it-live-naturalize). |
| `NATURALIZE_STYLE` | *(unset)* | Rewrite-style preset (display hook): `tldr` = a clearly shorter summary, `5y` = explain like I'm five, `caveman` = blunt caveman speak. Unset = the default plain-language rewrite. A usable `NATURALIZE_PROMPT_FILE` wins over any style (custom prompt > style > built-in); the output language still applies. |
| `NATURALIZE_STYLE_FILE` | `~/.claude/naturalize-style` | Runtime style override: `tldr`/`5y`/`caveman` in this file wins over `NATURALIZE_STYLE`, re-checked every message. Written by `/naturalize style <tldr\|5y\|caveman>`. See [Controlling it live](#controlling-it-live-naturalize). |
| `NATURALIZE_PROMPT_FILE` | *(unset)* | Path to a file whose contents replace the display hook's system prompt (whole prompt, not merged). Empty/unreadable falls back to the built-in default. See [Customizing the rewrite prompt](#customizing-the-rewrite-prompt). |
| `NATURALIZE_LANG` | *(unset)* | Language to rewrite into, e.g. `Esperanto`. Unset falls back to the `language` key in `.claude/settings*.json`; with neither set, the rewrite keeps the input's language. Empty ignores the settings key; `English` forces English. See [Output language](#output-language). |
| `NATURALIZE_LANG_FILE` | `~/.claude/naturalize-lang` | Runtime language override: a language name in this file wins over `NATURALIZE_LANG` and the settings key, re-checked every message. Written by `/naturalize language <name>`. See [Controlling it live](#controlling-it-live-naturalize). |
| `NATURALIZE_PROVIDER` | `ollama` | `ollama`, `codex`, `agy`, `anthropic`, or `openai` — which LLM serves rewrites (both hooks). |
| `NATURALIZE_MODEL` | *(per provider)* | Model name; overrides the provider default (see [Providers](#providers)). The ollama default `gemma4:26b-mlx` is MLX (Apple-silicon only; Windows users must override). |
| `NATURALIZE_MODEL_FILE` | `~/.claude/naturalize-model` | Runtime model override: a model name in this file wins over `NATURALIZE_MODEL`, re-checked every message (applies to whatever provider is configured). Written by `/naturalize model <name>`. See [Controlling it live](#controlling-it-live-naturalize). |
| `NATURALIZE_OLLAMA` | `http://localhost:11434` | ollama base URL. |
| `NATURALIZE_ANTHROPIC_KEY` | *(unset)* | Anthropic API key; falls back to `ANTHROPIC_API_KEY`. |
| `NATURALIZE_OPENAI_KEY` | *(unset)* | OpenAI(-compatible) API key; falls back to `OPENAI_API_KEY`. Only required for api.openai.com. |
| `NATURALIZE_OPENAI_URL` | `https://api.openai.com/v1` | Base URL for any OpenAI-compatible endpoint (LM Studio, llama.cpp server, vLLM, OpenRouter, ...). Trailing slashes are ignored. |
| `NATURALIZE_ANTHROPIC_URL` | `https://api.anthropic.com` | Base URL for the anthropic provider — override for proxies/gateways that speak the Messages API. |
| `NATURALIZE_OPENAI_EFFORT` | `none` on api.openai.com, else *(unset)* | `reasoning_effort` sent with openai-provider requests. Set explicitly empty to omit the field. |
| `NATURALIZE_CODEX_EFFORT` | *(unset)* | `model_reasoning_effort` for the codex provider (e.g. `low`). Unset uses the codex CLI's configured effort. Applies to the rewrite only. |
| `NATURALIZE_AGY_EFFORT` | *(unset)* | `--effort` (`low`/`medium`/`high`) for the agy provider. Unset uses the Antigravity CLI default. |
| `NATURALIZE_AGY_WORKDIR` | `${TMPDIR:-/tmp}/naturalize-agy-ws` | Scratch directory the agy provider runs `agy -p` in. |
| `NATURALIZE_MAX_TOKENS` | `4096` | Completion cap for the anthropic provider. Rewrites that hit the cap are discarded (fail-open), with a notice to raise it. |
| `NATURALIZE_MIN_CHARS` | `200` | Skip messages/files whose prose (code stripped) is shorter than this. Counted in **characters**, so one threshold means the same length in every script. |
| `NATURALIZE_STUB` | `0` | `1` = deterministic stub instead of the model (for testing display mechanics). |
| `NATURALIZE_TIMEOUT` | `45` | LLM client timeout for the **display** hook (seconds). Keep it below that hook's `timeout` (60s). |
| `NATURALIZE_MD_TIMEOUT` | `150` | LLM client timeout for the **Markdown file** hook and for `naturalize-md.sh` (seconds). Higher on purpose — a large model rewriting a long doc is slow. Keep it below the `PostToolUse` hook `timeout` (180s). |
| `NATURALIZE_DEBUG` | `0` | `1` = write a debug log to `$TMPDIR/naturalize/`. |
| `NATURALIZE_NOTICE` | `1` | `1` = show a one-time, once-per-session notice when a rewrite is skipped because the provider is unreachable, the call timed out, a key is missing, or the model isn't available (display hook appends it on screen; Markdown hook uses a `systemMessage`). Also gates the `SessionStart` notice that announces leftover `/naturalize` overrides. `0` = stay fully silent (pure fail-open). |
| `NATURALIZE_MD_DIR` | *(unset)* | **Markdown hook opt-in.** Only `*.md` under this directory is rewritten. Unset = the Markdown hook does nothing. |
| `NATURALIZE_MD_MODE` | `sibling` | `sibling` (`NAME.plain.md`) or `overwrite` (in place). |
| `NATURALIZE_MD_FETCH_TIMEOUT` | `30` | Download timeout (seconds) when `naturalize-md.sh` or `/naturalize file` is given a URL. Capped at 20 under `/naturalize file`. |
| `NATURALIZE_MD_MAX_BYTES` | `1048576` | Largest document `naturalize-md.sh` will download from a URL; anything bigger is refused. |
| `NATURALIZE_MD_SUFFIX` | `plain` | Sibling infix: `NAME.<suffix>.md` (Markdown hook, `naturalize-md.sh --sibling`, `/naturalize file`). |
| `NATURALIZE_MD_PROMPT_FILE` | *(unset)* | Path to a file whose contents replace the Markdown system prompt (whole prompt, not merged), for both the hook and `naturalize-md.sh`. Empty/unreadable falls back to the built-in default. |

In `hooks/hooks.json` the display hook (`MessageDisplay`) has a 60s `timeout` and
the Markdown hook (`PostToolUse`) has a 180s `timeout` — the file hook is higher
because a large model rewriting a long document can take a couple of minutes.
`NATURALIZE_TIMEOUT` and `NATURALIZE_MD_TIMEOUT` keep the LLM call itself bounded
below those ceilings, so it fails open cleanly instead of being killed mid-write.

The Codex (`hooks/codex-hooks.json`) and Antigravity (`antigravity-plugin/hooks.json`)
Stop hooks have a 620s `timeout`. Keep that at least `NATURALIZE_TIMEOUT` + 20s;
if you raise `NATURALIZE_TIMEOUT` past 600, raise the hook timeout too.

**Quick kill switch:** set `NATURALIZE_ENABLED=0` or disable the plugin (both apply
only from the next session start), or `touch ~/.claude/naturalize-off` to pause a
session that's already running — see [Toggling mid-session](#toggling-mid-session)
below.

### Toggling mid-session

`NATURALIZE_ENABLED` and the other env vars are read once, when a session launches,
so they can't pause rewrites in a session that's already running. For that, both
hooks also check a **flag file** on every invocation — each fire is a fresh
process, so the check is always live:

```bash
touch ~/.claude/naturalize-off   # pause rewrites, effective on the next message
rm    ~/.claude/naturalize-off   # resume
```

You create and remove this file yourself; nothing creates it on install, and its
absence is the normal "on" state. While it exists, `ENABLED` is forced to `0` and
the fail-open path leaves Claude's original text untouched. Point a hotkey at a
two-line toggle script to flip rewrites from the keyboard across all running
sessions at once. Override the path with `NATURALIZE_OFF_FILE`. `/naturalize`
([Controlling it live](#controlling-it-live-naturalize)) is the friendly front-end
for this, writing the same kind of flag files for mode, language, and model too.

### Reasoning models

The ollama request sends `"think": false`, and openai-provider requests to
api.openai.com send `reasoning_effort: "none"`. Models with a hidden reasoning
phase otherwise spend most of their time generating reasoning tokens you never
see — much slower for identical output quality on this simple task. Keep it off.

---

## Privacy / egress

With the default provider the rewriter runs **entirely locally** against
ollama, so **no conversation content leaves your machine**. Setting
`NATURALIZE_PROVIDER` to `anthropic` or `openai` changes that deliberately: every
rewritten assistant message (and, with the Markdown hook enabled or when you
run `naturalize-md.sh` / `/naturalize file`, file contents) is sent to that API.
Giving `naturalize-md.sh` a URL also makes a plain download request to that host,
whatever the provider. The same applies to pointing `NATURALIZE_OLLAMA`
or `NATURALIZE_OPENAI_URL` at a remote/hosted endpoint. Don't switch away from
local unless you understand and accept it.

---

## Layout

```
agentish-to-english/
├── .claude-plugin/
│   ├── plugin.json         # Claude Code manifest
│   └── marketplace.json    # so the repo can be added as a marketplace directly
├── .codex-plugin/
│   └── plugin.json         # Codex packaging: hooks/codex-hooks.json only (append mode)
├── commands/
│   └── naturalize.md       # /naturalize slash command (runtime on/off, mode, language, model, last, file)
├── hooks/
│   ├── hooks.json          # Claude Code: SessionStart -> session-notice.sh ; MessageDisplay -> rewrite.sh ; PostToolUse -> rewrite-md.sh
│   └── codex-hooks.json    # Codex: Stop -> codex-stop.sh
├── rewrite.sh              # display-rewrite hook
├── codex-stop.sh           # Codex Stop hook: append-mode rewrite as a systemMessage (drives rewrite.sh)
├── antigravity-plugin/     # Antigravity plugin: plugin.json, hooks.json, symlinks to the scripts
├── agy-stop.sh             # Antigravity Stop hook: append mode via a verbatim echo pass
├── rewrite-md.sh           # markdown-file rewrite hook (opt-in)
├── naturalize-md.sh          # on-demand rewrite of a file or stdin (CLI; backs /naturalize file)
├── md-core.sh              # Markdown frontmatter split + prompt, shared by rewrite-md.sh and naturalize-md.sh
├── naturalize-ctl.sh         # runtime state switcher + dashboard backing /naturalize (writes the flag files)
├── session-notice.sh       # SessionStart hook: announces leftover /naturalize overrides on a new session
├── providers.sh            # provider layer (ollama/codex/agy/anthropic/openai), sourced by both hooks
├── lang.sh                 # output-language resolver (env + .claude/settings*.json), sourced by both hooks
├── CHANGELOG.md            # notable changes per version (Keep a Changelog)
├── LICENSE
└── README.md
```

## Contributing

Bug reports and PRs welcome. See **[CONTRIBUTING.md](CONTRIBUTING.md)** for how
to set up a working copy, how to test a change without a provider
(`NATURALIZE_STUB=1`), the one rule that outranks everything (every hook must
**fail open**), and the traps that have bitten before — a new style preset
touches four files, and on-screen text must never use ANSI colour codes.

Add your changelog entry under `## [Unreleased]`; the maintainer cuts releases.

## License

MIT — see [LICENSE](./LICENSE).
