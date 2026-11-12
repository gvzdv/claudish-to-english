<!--
Thanks for the PR. The checklist is short on purpose — every line is something
that has actually broken here before. Delete any section that does not apply.
Full detail: CONTRIBUTING.md
-->

## What this changes

<!-- One or two sentences. What and why. -->

## How you tested it

<!--
Paste the command and its output. `NATURALIZE_STUB=1` avoids needing a provider:

  BODY=$(python3 -c "print('This is a long assistant message. '*20)")
  jq -nc --arg d "$BODY" '{message_id:"m1",session_id:"s1",index:0,final:true,delta:$d,cwd:"/tmp"}' \
  | NATURALIZE_STUB=1 NATURALIZE_STYLE_FILE=/nonexistent NATURALIZE_LANG_FILE=/nonexistent \
    NATURALIZE_OFF_FILE=/nonexistent NATURALIZE_NOTICE=0 TMPDIR=/tmp/naturalize-test \
    bash rewrite.sh | jq -r '.hookSpecificOutput.displayContent'
-->

---

## Checklist

- [ ] `bash -n` passes on every script I touched
- [ ] **Fails open**: bad input, empty payload, and a missing provider each emit
      nothing and exit 0 — Claude's original text stays on screen
- [ ] `CHANGELOG.md` entry added under `## [Unreleased]`
      (`### Added` / `### Changed` / `### Fixed`)
- [ ] I did **not** bump `.claude-plugin/plugin.json` or create a tag — the
      maintainer cuts releases
- [ ] `README.md` updated if anything user-facing changed (new env vars get a row
      in the Configuration table)

### If you added or changed a style preset

`NATURALIZE_STYLE` is validated by an allowlist in four places. Missing one fails
silently:

- [ ] `rewrite.sh` — system prompt + on-screen label
- [ ] `naturalize-ctl.sh` — `current_style`, `style_source`, dashboard, validation + error text
- [ ] `session-notice.sh` — the persisted-override warning
- [ ] `commands/naturalize.md` — `description` and `argument-hint`

### If you changed anything shown on screen

- [ ] No ANSI escape codes. `displayContent` is markdown — use `**bold**`.
      (Colour codes are palette indices a terminal theme can remap onto a grey,
      and they leak as raw bytes into piped `claude -p` output.)
- [ ] Checked in a real session, not just in the emitted JSON
- [ ] Any value from config or a flag file goes through `lang.sh`'s
      `_claudish_lang_clean` before being printed

### If you touched `commands/naturalize.md`

- [ ] `allowed-tools` still reads
      `Bash("${CLAUDE_PLUGIN_ROOT}/naturalize-ctl.sh":*)` — quote closes **after**
      the path. The other form breaks every `/naturalize` call.
