# claudish-to-english

A Claude Code plugin that shows a **plain-English rewrite** of each assistant
message, produced by a **local LLM via ollama**. It is **display-only**: Claude's
own reasoning and the saved transcript keep the original text — only what you
read on screen changes.

An optional second hook rewrites **Markdown files** into plain English when they
are written or edited (opt-in, off by default).

> Status: working prototype. Every hook fails **open** — if anything goes wrong
> (ollama down, timeout, missing dependency), you simply see Claude's original
> text. The plugin can never swallow or corrupt an answer.

---

## Requirements (read this first)

This plugin shells out to a **local** model. Nothing works until these are in place:

| Requirement | Why | Install |
|---|---|---|
| **ollama**, running | Does the rewriting, locally | `brew install ollama` then `ollama serve` |
| A pulled model | The actual rewriter | `ollama pull gemma4:26b-mlx` (~17 GB; choose the model that fits into your memory) |
| `jq` | Parses hook JSON | ships with macOS; else `brew install jq` |
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

**Pick a model you actually have.** The default is `gemma4:26b-mlx`. Pull it (as
above), or pull a smaller/faster model and point the plugin at it by setting
`CLAUDISH_MODEL` to that model's exact ollama tag in your `env` (see
[Configuring the plugin](#configuring-the-plugin)). If `CLAUDISH_MODEL` names a
model you have not pulled, every rewrite is skipped — with the one-time notice
above.

---

## Install

From the community marketplace:

```shell
/plugin marketplace add anthropics/claude-plugins-community
/plugin install claudish-to-english@claude-community
```

Or directly from this repository (also serves its own marketplace):

```shell
/plugin marketplace add gvzdv/claudish-to-english
/plugin install claudish-to-english@gvzdv-plugins
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

## Configuration (env vars)

| Var | Default | Meaning |
|---|---|---|
| `CLAUDISH_ENABLED` | `1` | Master switch. `0` = pass everything through. |
| `CLAUDISH_MODE` | `append` | `append` or `replace` (display hook). |
| `CLAUDISH_MODEL` | `gemma4:26b-mlx` | ollama model name. |
| `CLAUDISH_OLLAMA` | `http://localhost:11434` | ollama base URL. |
| `CLAUDISH_MIN_CHARS` | `200` | Skip messages/files whose prose (code stripped) is shorter than this. |
| `CLAUDISH_STUB` | `0` | `1` = deterministic stub instead of the model (for testing display mechanics). |
| `CLAUDISH_TIMEOUT` | `45` | LLM client timeout for the **display** hook (seconds). Keep it below that hook's `timeout` (60s). |
| `CLAUDISH_MD_TIMEOUT` | `150` | LLM client timeout for the **Markdown file** hook (seconds). Higher on purpose — a large model rewriting a long doc is slow. Keep it below the `PostToolUse` hook `timeout` (180s). |
| `CLAUDISH_DEBUG` | `0` | `1` = write a debug log to `$TMPDIR/claudish-to-english/`. |
| `CLAUDISH_NOTICE` | `1` | `1` = show a one-time, once-per-session notice when a rewrite is skipped because ollama is unreachable, the call timed out, or the model isn't pulled (display hook appends it on screen; Markdown hook uses a `systemMessage`). `0` = stay fully silent (pure fail-open). |
| `CLAUDISH_MD_DIR` | *(unset)* | **Markdown hook opt-in.** Only `*.md` under this directory is rewritten. Unset = the Markdown hook does nothing. |
| `CLAUDISH_MD_MODE` | `sibling` | `sibling` (`NAME.plain.md`) or `overwrite` (in place). |
| `CLAUDISH_MD_SUFFIX` | `plain` | Sibling infix: `NAME.<suffix>.md`. |

In `hooks/hooks.json` the display hook (`MessageDisplay`) has a 60s `timeout` and
the Markdown hook (`PostToolUse`) has a 180s `timeout` — the file hook is higher
because a large model rewriting a long document can take a couple of minutes.
`CLAUDISH_TIMEOUT` and `CLAUDISH_MD_TIMEOUT` keep the LLM call itself bounded
below those ceilings, so it fails open cleanly instead of being killed mid-write.

**Quick kill switch:** set `CLAUDISH_ENABLED=0`, or disable the plugin.

### Reasoning models

The request sends `"think": false`. Models with a hidden reasoning phase
otherwise spend most of their time generating reasoning tokens you never see —
much slower for identical output quality on this simple task. Keep it off.

---

## Privacy / egress

The rewriter runs **entirely locally** against ollama, so **no conversation
content leaves your machine**. If you ever point `CLAUDISH_OLLAMA` at a
remote/hosted endpoint, that context (which can include file contents from tool
results) would be sent off-box — don't do that unless you understand and accept
it.

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
├── LICENSE
└── README.md
```

## License

MIT — see [LICENSE](./LICENSE).
