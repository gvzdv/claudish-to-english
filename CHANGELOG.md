# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **An `orcarouter` provider** (`CLAUDISH_PROVIDER=orcarouter`): rewrites go
  through [OrcaRouter](https://www.orcarouter.ai)'s OpenAI-compatible
  `/chat/completions` endpoint (`https://api.orcarouter.ai/v1`), which routes
  across many upstream models with automatic failover. Key from
  `CLAUDISH_ORCAROUTER_KEY` or `ORCAROUTER_API_KEY`; base URL override
  `CLAUDISH_ORCAROUTER_URL`; default model `orcarouter/auto` (override with
  `CLAUDISH_MODEL`).

## [0.9.0] - 2026-08-28

### Added
- **Contributor and release documentation.** `CONTRIBUTING.md` covers setup,
  testing a change without a provider (`CLAUDISH_STUB=1`), the rule that
  outranks everything else (every hook must fail open), and the traps that have
  caused real regressions here. A pull-request template puts the same checklist
  in front of every PR, `CLAUDE.md` gives Claude Code the same ground rules
  automatically, and a `/release` skill executes a release cut in two phases so
  the version bump, the changelog link refs, and tagging the merge commit stop
  being things anyone has to remember. `.claude/settings.local.json` is now
  gitignored; `.claude/skills/` is tracked.

### Changed
- **Every rewrite prompt now states whose voice it is reading**: the input is
  one turn of a conversation, so the model is told that "I"/"me"/"my" are the
  assistant and "you"/"your" are the user, and that the rewrite must keep that
  point of view. Without it the pronouns had nothing to anchor to and rewrites
  could invert the roles — reading "I" as the rewriter, or addressing the
  assistant instead of the user. The line is added after the
  `CLAUDISH_PROMPT_FILE` override rather than before it (where the output
  language sits): a custom prompt legitimately replaces style and language
  choices, but this is a fact about the input, so it applies to every rewrite —
  default, style preset, and custom prompt alike.

## [0.8.0] - 2026-08-27

### Added
- A **`caveman` style preset** (`CLAUDISH_STYLE=caveman`, `/claudish style
  caveman`) alongside `tldr` and `5y`: blunt caveman speak — very short
  sentences, simple forceful words, no articles, present tense, a grunt where a
  sentence would only hedge. Like the other presets it replaces the base prompt
  only, so facts, numbers, file paths, commands, and identifiers are kept exact
  and fenced code blocks are left alone; a usable `CLAUDISH_PROMPT_FILE` still
  wins over it, and the output language still applies.

### Changed
- **Every style now labels its block with its own emoji and marks the word that
  carries the style in bold**: 💬 In plain **language**:, 📌 **TL;DR**:,
  👶 Like you're **five**:, 🦴 **Ugh.** Me say:. The emphasis is markdown,
  rendered by Claude Code itself, deliberately **not** ANSI colour codes: the
  16-colour codes are palette indices a terminal theme is free to remap onto a
  grey or onto the background (Solarized maps four of the bright slots to
  monotones), and raw escapes would also leak as literal bytes into `claude -p`
  output piped to a file. Bold is an attribute rather than a palette lookup, so
  it survives every theme and degrades to readable text off-terminal.

### Fixed
- The **session-start override notice now reports `style=caveman`**. It
  allowlisted only `tldr` and `5y`, so a `caveman` set by `/claudish style`
  persisted across sessions with nothing on screen to say so — the one warning
  that exists for flag files that outlive their session.
- **A `language` setting can no longer smuggle a terminal escape sequence onto
  the screen.** `lang.sh` collapsed whitespace but ESC is not whitespace, so a
  `language` of `$'\033[2J'` in a project's `.claude/settings.json` — a file
  that travels with the repository and is not necessarily the local user's own
  text — reached the label verbatim. Control characters are now folded to
  spaces, by codepoint, before the existing three-word / 30-codepoint caps.
  The session-start notice printed the language flag file through a `\r\n`-only
  filter, so it had the same hole on its own surface; it now routes the value
  through `lang.sh`, which also makes the two agree on the word cap.

## [0.7.1] - 2026-08-27

### Fixed
- `/claudish` no longer fails with `Shell command permission check failed`.
  The command's `allowed-tools` rule closed its quote in the wrong place —
  `Bash("${CLAUDE_PLUGIN_ROOT}"/claudish-ctl.sh:*)` — while the injected
  command quotes the whole path
  (`"${CLAUDE_PLUGIN_ROOT}/claudish-ctl.sh" --stdin-args …`), so the rule's
  prefix never matched the command and the call was refused. Bash injected
  from a slash command is allow-or-fail with no permission prompt to fall back
  on, which turned the mismatch into a hard error on every invocation. The
  misplaced quote arrived with the command itself in 0.5.0, so `/claudish` has
  been unusable in every release since.

## [0.7.0] - 2026-08-26

### Added
- An **opt-in oauth mode for the anthropic provider**
  (`CLAUDISH_ANTHROPIC_AUTH=oauth`) that rides the local Claude Code login
  instead of an API key: the OAuth access token is re-read on **every call**
  from the macOS login Keychain (item `Claude Code-credentials`) or
  `~/.claude/.credentials.json` elsewhere, and sent as `Authorization: Bearer`
  with the `oauth-2025-04-20` beta flag, a `claude-cli` User-Agent, and
  `x-app: cli` — rewrites then bill to the existing Claude subscription, no
  separate API billing. Guard rails: the token is **only ever sent to
  `https://api.anthropic.com`** (the mode refuses a `CLAUDISH_ANTHROPIC_URL`
  override, so the credential cannot leak to a proxy), a token past its
  `expiresAt` is discarded rather than sent, an env `ANTHROPIC_API_KEY` is
  never used as the Bearer token, and every failure keeps the fail-open
  contract (original text plus the once-per-session notice). **UNOFFICIAL —
  use at your own risk:** Anthropic has not blessed third-party use of the
  Claude Code token, so the first successful oauth rewrite of each session
  says so on screen (`CLAUDISH_NOTICE=0` silences it). Contributed by
  [@JackBhanded](https://github.com/JackBhanded) in
  [PR #20](https://github.com/gvzdv/claudish-to-english/pull/20), with the
  macOS Keychain read by [@hanjoonchoe](https://github.com/hanjoonchoe).

## [0.6.0] - 2026-08-20

### Added
- A **`codex` provider** (`CLAUDISH_PROVIDER=codex`) that runs the rewrite
  through the OpenAI codex CLI non-interactively (`codex exec`, `--sandbox
  read-only`, `--skip-git-repo-check`, outside any repo). It uses the CLI's own
  login, so there is **no API key and no local model server** — a third keyless
  path alongside ollama. `CLAUDISH_MODEL` maps to `codex -m`; unset uses the
  CLI's configured default. A new `CLAUDISH_CODEX_EFFORT` maps to
  `-c model_reasoning_effort=<value>`, overriding the CLI's reasoning effort for
  the per-message rewrite only (e.g. `low` keeps it fast even when the CLI's
  coding default is a high-effort tier). The call is bounded by a background
  poll-and-kill loop (stock macOS has no `timeout(1)`), reads the final message
  from `codex exec -o`, and fails open like every other provider — a missing
  CLI, a non-zero exit, or a timeout just leaves the original text plus the
  once-per-session notice. Contributed by
  [@datvo06](https://github.com/datvo06) in
  [PR #15](https://github.com/gvzdv/claudish-to-english/pull/15).

## [0.5.1] - 2026-08-20

### Fixed
- The `/claudish` command now hands the user's argument string to
  `claudish-ctl.sh` through a **quoted here-doc on stdin** instead of
  interpolating it into the command line, and the script splits it back into
  words itself (globbing disabled). Claude Code substitutes `$ARGUMENTS`
  textually *before* the shell parses the command, so the earlier `"$ARGUMENTS"`
  quoting could not neutralize it — command substitution (`$(…)`, backticks) and
  `$VAR` expansion stayed live inside the quotes, an embedded quote could break
  out, and input like `/claudish language $HOME` was silently mangled. A quoted
  here-doc delimiter makes the shell copy the argument verbatim, so nothing
  typed after `/claudish` is re-parsed as shell syntax: `$`, `$(…)`, backticks,
  quotes, operators (`;`/`|`/`&&`) and `*` all reach the script as literal text.
  Multi-word names like `language Brazilian Portuguese`, direct terminal
  invocation, and bare `/claudish` all behave exactly as before.
  Reported by [@MakhBeth](https://github.com/MakhBeth) in
  [PR #17](https://github.com/gvzdv/claudish-to-english/pull/17).

## [0.5.0] - 2026-08-19

### Added
- The `/claudish` slash command for mid-session control, backed by
  `claudish-ctl.sh`. It switches rewrites on the fly — `on`/`off`,
  `append`/`replace`, `language <name>`, `model <name>`, `last` (reprint the
  original of the last message), `cycle`, and `reset` — by writing flag files
  the hooks re-read every message, so changes take effect without relaunching.
- A `/claudish` dashboard (bare `/claudish`, or `status`). It lists each
  setting, its current value, and where that value comes from — an env var, a
  `/claudish` override, `settings.json`, or the default — flagging every
  persisting override with ⚠ so its cross-session persistence is never silent.
- A `SessionStart` hook (`session-notice.sh`) that prints a one-line notice at
  the start of any new session with leftover `/claudish` overrides active, so a
  language or model set in an earlier session never applies silently. Gated by
  `CLAUDISH_NOTICE`; `/claudish reset` clears all overrides at once.
- Rewrite-style presets for the display hook: `/claudish style tldr` (a short
  summary) and `5y` (explain like I'm five), also settable at launch with
  `CLAUDISH_STYLE` or live via `CLAUDISH_STYLE_FILE`. A style replaces only the
  built-in base prompt — the output language still applies, and a
  `CLAUDISH_PROMPT_FILE` still wins (custom prompt > style > built-in). The
  on-screen label follows the style (`💬 TL;DR:`, `💬 Like you're five:`).
  Ported from [PR #17](https://github.com/gvzdv/claudish-to-english/pull/17).
- `/claudish language` now accepts multi-word names (e.g. `Brazilian
  Portuguese`); `/claudish last` prefers the current project's most recent
  transcript before falling back to all projects; and `claudish-ctl.sh` fails
  loudly if it cannot write a flag file instead of proceeding silently.
- Runtime flag-file overrides that back the command, each sitting above its env
  var and re-checked per message: `CLAUDISH_MODE_FILE` (`~/.claude/claudish-mode`,
  read by the display hook), `CLAUDISH_LANG_FILE` (`~/.claude/claudish-lang`) and
  `CLAUDISH_MODEL_FILE` (`~/.claude/claudish-model`), both read by `lang.sh` /
  `providers.sh` and so honoured by both hooks. This generalises the existing
  `CLAUDISH_OFF_FILE` pattern to mode, language, and model.
- `/claudish last` reprints an assistant message's original text; the display
  hook now recognises a leading `<!-- claudish:original -->` marker and passes
  such a reply through unrewritten (the marker is stripped from view).

Ported from the [claudish-tldr](https://github.com/MakhBeth/claudish-tldr) fork
by Davide Di Pumpo, adapted to the provider layer and language resolver.

## [0.4.0] - 2026-08-14

### Added
- Output language. A rewrite can be pinned to a language with `CLAUDISH_LANG`,
  or with the `language` key in `.claude/settings*.json` — the same key Claude
  Code answers in, read in the same order of precedence (`lang.sh`). The
  on-screen label then names it: `💬 In plain Esperanto:`. An empty
  `CLAUDISH_LANG` ignores the settings key; `English` forces English.

### Changed
- The built-in prompts no longer hard-code English. They ask for plain
  language in the language the input is already written in, so an Esperanto
  session gets an Esperanto rewrite instead of an English one. Set
  `CLAUDISH_LANG=English` to keep the previous behaviour. A prompt supplied
  through `CLAUDISH_PROMPT_FILE` / `CLAUDISH_MD_PROMPT_FILE` is unaffected: it
  still replaces the whole prompt.
- With no language configured, the display label reads `💬 In plain language:`
  rather than `💬 In plain English:`, which it can no longer promise.

## [0.3.0] - 2026-08-13

### Added
- Customizable rewrite prompts. Point the display hook at a prompt file with
  `CLAUDISH_PROMPT_FILE`, or the Markdown hook with `CLAUDISH_MD_PROMPT_FILE`;
  the file's contents replace the built-in prompt wholesale. An unset, empty, or
  unreadable file falls back to the built-in default, so a bad path never stops
  rewrites. Defaults are unchanged.

## [0.2.0] - 2026-08-13

### Added
- Provider layer (`providers.sh`): rewrites can run against local **ollama**
  (default, unchanged), the **Anthropic** Messages API, or any
  **OpenAI-compatible** endpoint, selected with `CLAUDISH_PROVIDER` (#10).
- Runtime kill-switch flag file (`~/.claude/claudish-off`, overridable with
  `CLAUDISH_OFF_FILE`) to pause and resume rewrites mid-session, since env vars
  are frozen at launch (#4).
- Windows setup documentation and model-default guidance (#7).
- Comparison screenshot at the top of the README.

### Fixed
- Markdown `overwrite` mode: the idempotency marker is written after any YAML
  frontmatter, so the frontmatter stays on line 1 where parsers expect it.
  Leftover display-hook temp files are also cleaned up (#1).
- Quote `CLAUDE_PLUGIN_ROOT` in the hook commands so plugin paths containing
  spaces resolve correctly (#6).

## [0.1.1] - 2026-08-10

### Added
- One-time, per-session notice explaining why a rewrite was skipped when the
  provider is unreachable, the call times out, or the model isn't available
  (`CLAUDISH_NOTICE`, default on).

### Changed
- Default model set to `gemma4:26b-mlx` (Apple-silicon MLX build).
- Separate per-hook timeouts: `CLAUDISH_TIMEOUT` (display) and
  `CLAUDISH_MD_TIMEOUT` (Markdown file).
- Added the "Configuring the plugin" section to the README.

## [0.1.0] - 2026-08-10

### Added
- Initial release. A `MessageDisplay` hook (`rewrite.sh`) that rewrites each
  assistant message into plain English with a local ollama model — `append`
  and `replace` display modes, a prose-length gate, and a fail-open contract
  that always leaves Claude's original text on screen if anything goes wrong.
- Optional `PostToolUse` Markdown-file rewrite hook (`rewrite-md.sh`), opt-in by
  directory (`CLAUDISH_MD_DIR`), with `sibling` and `overwrite` modes.

[Unreleased]: https://github.com/gvzdv/claudish-to-english/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/gvzdv/claudish-to-english/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/gvzdv/claudish-to-english/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/gvzdv/claudish-to-english/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/gvzdv/claudish-to-english/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/gvzdv/claudish-to-english/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/gvzdv/claudish-to-english/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/gvzdv/claudish-to-english/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/gvzdv/claudish-to-english/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/gvzdv/claudish-to-english/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/gvzdv/claudish-to-english/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/gvzdv/claudish-to-english/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/gvzdv/claudish-to-english/releases/tag/v0.1.0
