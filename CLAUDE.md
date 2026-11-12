# naturalize

A Claude Code plugin: a `MessageDisplay` hook shows a plain-language rewrite of
each assistant message, produced by a local or remote LLM. **Display-only** —
Claude's reasoning and the saved transcript always keep the original text.
The repo is [ValerioL29/agentish-to-english](https://github.com/ValerioL29/agentish-to-english).
It also ships append-mode Stop hooks for Codex (CLI and app) and Antigravity (CLI,
App, IDE). Grok Build can't display hook output and is not supported. See the
README's Supported hosts table.

Plain bash + `jq` + `curl`. No build, no test suite, no dependencies to install.

`CONTRIBUTING.md` is the full version of this file; it is the source of truth if
the two ever disagree.

## Layout

| File | Role |
|---|---|
| `rewrite.sh` | `MessageDisplay` hook — the main event. Buffers streamed chunks, rewrites on the final one |
| `rewrite-md.sh` | `PostToolUse` hook — rewrites Markdown files (opt-in, off by default) |
| `naturalize-md.sh` | on-demand CLI — rewrites a file or stdin; backs `/naturalize file`. **Not a hook: fails loudly** |
| `md-core.sh` | Markdown frontmatter split + system prompt, shared by `rewrite-md.sh` and `naturalize-md.sh` |
| `naturalize-ctl.sh` | backs `/naturalize`; writes the `~/.claude/naturalize-*` flag files, prints the dashboard |
| `session-notice.sh` | `SessionStart` hook — warns that flag files from an earlier session are still active |
| `providers.sh` | provider layer (ollama / anthropic / openai / codex / agy). Sourced by both hooks and the CLI |
| `lang.sh` | output-language resolver + the sanitiser for untrusted config values. Sourced by both hooks and the CLI |
| `commands/naturalize.md` | the `/naturalize` slash command |
| `hooks/hooks.json` | wires the three hooks |
| `agy-stop.sh` + `antigravity-plugin/` | Antigravity Stop hook prototype (append mode via a verbatim echo pass); plugin dir symlinks the scripts |
| `codex-stop.sh` | Codex Stop hook, append mode only; drives `rewrite.sh` and returns `systemMessage` or `{}` |
| `hooks/codex-hooks.json` + `.codex-plugin/plugin.json` | Codex packaging; loads only the Stop hook (timeout 620 = NATURALIZE_TIMEOUT 600 + 20) |

Config precedence is consistent throughout: **flag file > env var > settings
file > built-in default**. Flag files exist because env vars are frozen at
session launch and cannot be changed mid-session.

## Non-negotiable: hooks fail open

On *any* problem — provider down, timeout, no `jq`, malformed payload, missing
file — a hook emits nothing and exits 0, leaving Claude's original text on
screen. This outranks every other consideration. Never add a code path where a
failure can swallow or corrupt an assistant message.

The one exception is `naturalize-md.sh`, which is a command a person runs, not a
hook: it reports failures (`naturalize-md: <reason>`, non-zero exit) instead of
staying silent. It still never prints or writes a partial or empty rewrite.

When changing a hook, verify it directly. All three must print nothing, exit 0:

```bash
printf 'not json'                        | bash rewrite.sh; echo "rc=$?"
printf ''                                | bash rewrite.sh; echo "rc=$?"
printf '{"session_id":"s","final":true}' | bash rewrite.sh; echo "rc=$?"
```

## Testing

`NATURALIZE_STUB=1` replaces the LLM call with a deterministic string — enough for
all display mechanics, no provider needed. Redirect the `*_FILE` variables so
the developer's own `~/.claude/naturalize-*` files do not leak into the test:

```bash
BODY=$(python3 -c "print('This is a long assistant message. '*20)")
jq -nc --arg d "$BODY" \
  '{message_id:"m1",session_id:"s1",index:0,final:true,delta:$d,cwd:"/tmp"}' \
| NATURALIZE_STUB=1 NATURALIZE_STYLE=caveman \
  NATURALIZE_STYLE_FILE=/nonexistent NATURALIZE_LANG_FILE=/nonexistent \
  NATURALIZE_OFF_FILE=/nonexistent NATURALIZE_NOTICE=0 TMPDIR=/tmp/naturalize-test \
  bash rewrite.sh | jq -r '.hookSpecificOutput.displayContent'
```

Also run `bash -n` on every script touched. `NATURALIZE_DEBUG=1` logs to
`${TMPDIR:-/tmp}/naturalize/debug.log`.

To exercise the plugin in a real session, point a scratch project's
`.claude/settings.json` at the checkout **and** set
`"enabledPlugins": { "naturalize@valeriol29-plugins": false }` — otherwise
the installed copy and the working copy both fire on the same message and
whichever writes last wins.

## Repo-specific traps

Each of these has caused a real regression.

**A new style preset touches four readers**, and missing one fails silently:
`rewrite.sh` (prompt + label), `naturalize-ctl.sh` (`current_style`,
`style_source`, dashboard, validation + error text), `session-notice.sh`
(persisted-override warning), `commands/naturalize.md` (`description`,
`argument-hint`). Plus `README.md` and `CHANGELOG.md`.

**Never emit ANSI escape codes.** `displayContent` is rendered as markdown —
use `**bold**`. Colour codes are palette indices a terminal theme may remap onto
a grey or the background; they also leak as literal bytes into `claude -p`
output piped to a file; and the hook has no tty on any descriptor (`[ -t 1 ]` is
always false, `/dev/tty` will not open) so it cannot detect either case.

**`allowed-tools` in `commands/naturalize.md`** must be
`Bash("${CLAUDE_PLUGIN_ROOT}/naturalize-ctl.sh":*)` — the quote closes *after* the
path. The variant with the quote before the slash breaks every `/naturalize` call
with `Shell command permission check failed`. It has regressed twice; do not
"correct" it back. The same file sets `disable-model-invocation: true`: that
`allowed-tools` rule pre-approves the script, so without it Claude could run
`/naturalize file <URL>` (a network fetch and a file write) with no permission
prompt. Keep it.

**Untrusted config values go through `lang.sh`.** The `language` key comes from
`.claude/settings*.json`, which travels with a repository and is not necessarily
the local user's text. Route it through `_claudish_lang_clean` (folds control
characters to spaces, caps at three words / 30 codepoints) before it reaches a
prompt or the screen. Never print a raw config value.

**Comments are load-bearing.** This codebase explains *why*, not *what*, and the
header comment in each script is its real documentation. Match that density and
update the header when behaviour changes.

## Changelog and releases

Contributors add an entry under `## [Unreleased]` in `CHANGELOG.md` and **never**
bump `.claude-plugin/plugin.json` or create tags. The maintainer cuts releases.

When making a change, add the `CHANGELOG.md` entry as part of the work — not as
a follow-up. Use `### Added` / `### Changed` / `### Fixed`, and say *why*, not
just what.

To cut a release, use the `/release` skill in `.claude/skills/release/`. SemVer
at `0.x`: MINOR for a new user-facing feature, PATCH for fixes only. Only
`plugin.json` and `CHANGELOG.md` carry a version. The tag goes on the **merge**
commit, never the bump commit.
