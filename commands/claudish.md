---
description: Show the claudish dashboard, or switch the rewrite on the fly — on, off, append, replace, "style tldr|5y|caveman", "language <name>", "model <name>", "last" (reprint the previous original), "file <path or URL>" (rewrite a Markdown file or URL into NAME.plain.md), cycle, or reset. No argument shows the dashboard.
argument-hint: "[on|off|append|replace|style <tldr|5y|caveman|default>|language <name>|model <name>|last|file <path or URL>|cycle|reset|status]"
allowed-tools: Bash("${CLAUDE_PLUGIN_ROOT}/claudish-ctl.sh":*)
disable-model-invocation: true
---

Claudish, after applying "$ARGUMENTS": !`"${CLAUDE_PLUGIN_ROOT}/claudish-ctl.sh" --stdin-args <<'CLAUDISH_ARGV_EOF'
$ARGUMENTS
CLAUDISH_ARGV_EOF`

Decide how to present the script output above, based on "$ARGUMENTS":

- **Empty, "status", "menu", or "help"** — the output is a preformatted dashboard. Show it to the user verbatim inside a fenced code block, unchanged, and add nothing else. (Lines marked ⚠ are `/claudish` overrides that persist across sessions — the dashboard already explains them, so do not restate.)
- **"last"** — the output is the ORIGINAL text of the last assistant message. Reply with the literal line `<!-- claudish:original -->` as the VERY FIRST line (it tells the display hook not to rewrite this reply, and is stripped from view), then one short intro line (remind the user that ctrl+o shows the whole original chat), then the text verbatim.
- **"file …"** — the output is one line naming the rewritten file that was written (`claudish: wrote <path> …`), possibly followed by a note. Relay it to the user in one short line, keeping the path exact; do not open, read, or summarise the file. If the script printed an error instead, show that.
- **Anything else** (on/off/append/replace/style/language/model/cycle/reset) — the output is a one-line state summary (`claudish: <state> (style: …, language: …, model: …)`, where style `tldr` = short summary, `5y` = explain like I'm five, `caveman` = blunt caveman speak, `default` = plain rewrite). Relay it to the user in one short line. If the script printed an error instead, show that.

Do nothing else.
