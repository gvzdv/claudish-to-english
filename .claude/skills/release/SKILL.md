---
name: release
description: Cut a naturalize release — pick the version, move the CHANGELOG's Unreleased section under it, bump plugin.json, open the release PR, then tag the merge commit and create the GitHub release. Use when asked to cut, ship, or publish a release, bump the version, or when changes are sitting under "## [Unreleased]" and need releasing.
---

# Cut a release

Two phases. **Phase 1** prepares the release and opens a PR. Then you STOP: the
maintainer reviews and merges. **Phase 2** tags and publishes, and can only run
after the merge because the tag must point at the merge commit.

If `$1` is a version (`0.9.0`, `v0.9.0` — strip any leading `v`), use it. If not,
derive it and confirm before writing anything.

## Phase 1 — prepare

### 1. Check the ground

```bash
git switch main && git pull --ff-only
git status --short
jq -r .version .claude-plugin/plugin.json
sed -n '1,40p' CHANGELOG.md
```

Stop and report if: the tree is dirty, `main` is not current, or `CHANGELOG.md`
has no `## [Unreleased]` section with real entries under it. An empty Unreleased
section means there is nothing to release — say so rather than cutting an empty
version.

### 2. Pick the version

SemVer at `0.x`, based on what is actually under `## [Unreleased]`:

- **MINOR** (`0.8.0` → `0.9.0`) if there is anything under `### Added`, or a
  `### Changed` entry that alters behaviour users rely on. New style preset, new
  provider, new env var.
- **PATCH** (`0.8.0` → `0.8.1`) only if every entry is under `### Fixed`.

Never hide a feature in a patch. State the version and the reason in one line
before proceeding.

### 3. Edit the two files

Only these two carry a version. `marketplace.json` does not pin one — leave it.

**`CHANGELOG.md`** — three edits:

1. `## [Unreleased]` → `## [<version>] - <today, YYYY-MM-DD>`.
   Get today's date with `date +%F`; do not guess it.
2. Add a comparison link ref in the block at the bottom, directly above the
   previous version's line:
   `[<version>]: https://github.com/ValerioL29/agentish-to-english/compare/v<previous>...v<version>`
3. Repoint the Unreleased ref:
   `[Unreleased]: https://github.com/ValerioL29/agentish-to-english/compare/v<version>...HEAD`

Leave the `[Unreleased]` *ref* in place but do **not** re-add an empty
`## [Unreleased]` heading — this repo adds that heading only when there is
something to put under it.

While you are in the file, tidy the prose of the entries if they read like PR
descriptions rather than changelog entries, but do not change their meaning or
drop anything.

**`.claude-plugin/plugin.json`** — bump `"version"`. Edit the string in place so
key order and formatting survive; do not round-trip the file through a JSON
serialiser.

### 4. Verify before committing

```bash
jq empty .claude-plugin/plugin.json && jq -r .version .claude-plugin/plugin.json
for f in *.sh; do bash -n "$f" || echo "FAIL $f"; done
```

Then confirm every `## [x]` heading has a matching `[x]:` ref and there are no
orphans:

```bash
python3 - <<'PY'
import re, io
s = io.open('CHANGELOG.md', encoding='utf-8').read()
heads = re.findall(r'^## \[([^\]]+)\]', s, re.M)
refs  = re.findall(r'^\[([^\]]+)\]:', s, re.M)
print("headings without a ref:", [h for h in heads if h not in refs] or "none")
print("orphaned refs:", [r for r in refs if r not in heads and r != 'Unreleased'] or "none")
PY
```

`jq -r .version` must equal the new heading. Show the full `git diff` — it should
touch exactly two files.

### 5. Branch, commit, PR

```bash
git switch -c release/<version> origin/main
git commit -am "chore: v<version> — <one-line summary of what ships>"
git push -u origin release/<version>
gh pr create --base main \
  --title "chore: v<version> — <summary>" \
  --body-file <a file you write>
```

The PR body should state why MINOR or PATCH, list the two changed files, and
summarise what the release ships (drawn from the changelog section).

### 6. Stop

Report the PR URL and say the tag comes after the merge, since it must point at
the merge commit. **Do not merge the PR yourself** unless the maintainer
explicitly asks.

## Phase 2 — after the merge

Only once the release PR is merged.

```bash
git switch main && git pull --ff-only
git log --oneline -3
```

Identify the **merge commit** (`Merge pull request #N from ValerioL29/release/<version>`).
Tag that, *not* the `chore:` bump commit — tagging the bump leaves the release
branch's commits dangling inside `compare/v<version>...HEAD` next cycle.

```bash
git tag v<version> <merge-commit-sha>
git push origin v<version>
```

Verify the tag lands on the right tree before moving on:

```bash
git log -1 --format='%h %s' v<version>
git show v<version>:.claude-plugin/plugin.json | jq -r .version   # == <version>
```

Then create the GitHub release, with notes taken from the CHANGELOG section
rather than auto-generated — the hand-written entries are the point:

```bash
gh release create v<version> \
  --title "v<version> — <summary>" \
  --notes-file <the extracted CHANGELOG section>
```

Extract the section by slicing from `## [<version>]` to the next `## [` line.

Report the tag and release URLs.

## Notes

- Tags here are **lightweight** and sit at the release merge commit. `v0.3.0` is
  the exception (it predates the convention and sits on a bump commit); do not
  "fix" it.
- Tags for `v0.4.0`–`v0.7.1` were backfilled, so those releases have tags but no
  GitHub release objects. That is expected; do not backfill releases unless
  asked.
- If a tag already exists for the target version, stop and report it. Never
  force-move a published tag.
