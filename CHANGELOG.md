# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.3.0]: https://github.com/gvzdv/claudish-to-english/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/gvzdv/claudish-to-english/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/gvzdv/claudish-to-english/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/gvzdv/claudish-to-english/releases/tag/v0.1.0
