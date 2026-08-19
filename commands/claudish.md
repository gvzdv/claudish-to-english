---
description: Show the claudish dashboard, or switch the rewrite on the fly — on, off, append, replace, "style tldr|5y", "language <name>", "model <name>", "last" (reprint the previous original), cycle, or reset. No argument shows the dashboard.
argument-hint: "[on|off|append|replace|style <tldr|5y|default>|language <name>|model <name>|last|cycle|reset|status]"
allowed-tools: Bash("${CLAUDE_PLUGIN_ROOT}"/claudish-ctl.sh:*)
---

Claudish, after applying "$ARGUMENTS": !`"${CLAUDE_PLUGIN_ROOT}/claudish-ctl.sh" $ARGUMENTS`

Decide how to present the script output above, based on "$ARGUMENTS":

- **Empty, "status", "menu", or "help"** — the output is a preformatted dashboard. Show it to the user verbatim inside a fenced code block, unchanged, and add nothing else. (Lines marked ⚠ are `/claudish` overrides that persist across sessions — the dashboard already explains them, so do not restate.)
- **"last"** — the output is the ORIGINAL text of the last assistant message. Reply with the literal line `<!-- claudish:original -->` as the VERY FIRST line (it tells the display hook not to rewrite this reply, and is stripped from view), then one short intro line (remind the user that ctrl+o shows the whole original chat), then the text verbatim.
- **Anything else** (on/off/append/replace/style/language/model/cycle/reset) — the output is a one-line state summary (`claudish: <state> (style: …, language: …, model: …)`, where style `tldr` = short summary, `5y` = explain like I'm five, `default` = plain rewrite). Relay it to the user in one short line. If the script printed an error instead, show that.

Do nothing else.
