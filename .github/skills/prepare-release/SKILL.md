---
name: prepare-release
description: Bump the tweak version in `control` and add a new `changelog.md` entry from unreleased changes since the last tagged release. Use when the user says "prepare release", "bump version", "cut a release", "draft changelog", or asks to write release notes.
allowed-tools: shell
---

# Prepare release skill

Drafts a new release: bumps `Version:` in `control` and prepends a user-facing entry to `changelog.md`.

## When to invoke

- "prepare a release", "cut v2.x.0", "bump version", "draft changelog", "write release notes"
- After a batch of PRs have merged and the user wants a release write-up

## Step 1. Establish the baseline

```bash
grep ^Version control                              # current version
git tag --sort=-v:refname | head -5                # latest release tag
sed -n '/^## \[Unreleased\]/,/^## \[/p' changelog.md  # existing unreleased bullets
git log --oneline <last-tag>..HEAD                 # PR merge commits (use only to enumerate PR numbers)
```

The `## [Unreleased]` section at the top of `changelog.md` is the primary source — incoming PRs populate it as they merge. Use `git log` only to enumerate merged PR numbers (`(#NNN)` suffix on merge commits) and to spot anything that didn't get a bullet. Then ask the user for **unmerged PRs** they want bundled in.

For every PR (merged or unmerged) in scope, **use GitHub MCP tools** to fully analyze it — do not rely on commit messages alone:

- `mcp__github__get_pull_request` — title, body/description, labels, author
- `mcp__github__get_pull_request_files` — the actual changed files, additions/deletions, patches
- `mcp__github__get_pull_request_comments` / `get_pull_request_reviews` — extra context from review discussion when the body is thin

`gh pr view <num>` / `gh pr diff <num>` and other GitHub CLI commands are acceptable fallbacks if the MCP tools are unavailable.

The PR description tells you the intent; the file list tells you what actually shipped (new settings, new files, scope of touched modules). Cross-reference both before drafting a bullet, especially when the description is vague or stale.

If the user gives rough notes, treat those as the authoritative scope and merge them with whatever is already under `## [Unreleased]`, validating each note against the PR data above.

## Step 2. Decide the version

Follow the SemVer-ish convention used by prior entries (see `changelog.md`):

- **Minor bump** (`2.14.0 → 2.15.0`) for any new feature, even small ones — this is the default
- **Patch bump** (`2.7.1 → 2.7.2`) for fix-only releases

Edit `control`:

```
Version: <new>
```

Then bump the **monotonic IPA build number** in [`distribution/config.json`](../../../distribution/config.json):

```json
"app": {
  "buildVersion": "<previous + 1>",
  ...
}
```

This is the `CFBundleVersion` the release pipeline writes into the IPA and the AltStore source `buildVersion`. AltStore validates the source value against the downloaded IPA before installing, and it **must increase monotonically** across releases — never reuse or decrement. See [`DISTRIBUTION.md`](../../../DISTRIBUTION.md) for the full versioning model.

## Step 3. Draft the changelog entry

Rename the existing `## [Unreleased]` heading to `## [vX.Y.Z] - YYYY-MM-DD` (today's date) and fold in any extra bullets from notes/git log. Then **insert a fresh empty `## [Unreleased]` section above it** so the next round of PRs has somewhere to land.

Also add a new compare-link to the reference-link footer at the bottom of `changelog.md`, matching the existing pattern:

```markdown
[vX.Y.Z]: https://github.com/Apollo-Reborn/Apollo-Reborn/compare/<prev-tag>...vX.Y.Z
```

Insert it as the new top entry of the footer block (entries are ordered newest-first).

### Structure

```markdown
## [Unreleased]

### Features

- ...

### Fixes

- ...

## [vX.Y.Z] - YYYY-MM-DD

### Features

- ...

### Fixes

- ...
```

- Omit `### Features` or `### Fixes` if empty in the released section.
- For fix-only releases, a flat bullet list with no subheadings is fine (see v2.11.0, v2.7.2).

### Bullet style

- **User-facing language.** Describe what the user sees or can do, not the implementation. Drop internal mechanics (thread-safety details, debounce intervals, refactor notes, rebase context).
- **Keep it to roughly one sentence.** Each bullet should read at a glance, like the surrounding entries. Resist piling on rationale, background, or every edge case — even for nuanced fixes, state the before/after and the one caveat that matters, then stop. Deep explanation belongs in the README or `docs/`, not the changelog. If a bullet grows into multiple sentences with parentheticals, it's too verbose; trim it or split out a sub-bullet.
- **Bold the feature name or setting path** the first time it appears: `**Inline Media Previews**`, `**Settings > Custom API > Media**`.
- **Lead with a verb**: "Add", "Fix", "Improve", "Show", "Replace".
- **Indented sub-bullets** for configuration details, sub-features, or caveats tied to the parent bullet.
- Keep one bullet per logical change. Merge tightly-related items into a parent + sub-bullet group instead of repeating.
- Filter out: build/CI/tooling changes, internal refactors, dependency bumps, doc-only edits, anything not user-observable.

### Contributor attribution

Format: `(#PR: @handle)` or `(#PR: @handle1, @handle2)` at the **end** of the bullet.

- Get the PR number from `git log --oneline` (merge commit subject ends in `(#NNN)`) or from the user's notes.
- Multiple PRs that share a bullet: `(#262, #266: @icpryde, @jordanearle)`.
- Group related sub-bullets under one parent and put the credit on the parent only — don't repeat the same `@handle` on every child bullet.
- For non-GitHub credit (e.g. Reddit icon designers), write it inline in prose: `(thanks @jordanearle and /u/harunatsu91202024!)` — matches prior entries.

## Step 4. Verify

```bash
grep ^Version control
grep buildVersion distribution/config.json
sed -n '1,60p' changelog.md
tail -5 changelog.md
git --no-pager diff control distribution/config.json changelog.md
```

Confirm:
- `control` has the new `Version:`
- `distribution/config.json` `buildVersion` is incremented (strictly greater than the previous release)
- A fresh empty `## [Unreleased]` section sits above the new release entry
- The footer has a new `[vX.Y.Z]: ...compare/<prev>...vX.Y.Z` link

Show the diff to the user. **Do not commit or tag** — the user does that.

## Notes

- Read the most recent 2–3 changelog entries before drafting to match tone and section conventions; they drift over time.
- Prefer GitHub MCP tools (`mcp__github__get_pull_request`, `get_pull_request_files`, `get_pull_request_comments`, `get_pull_request_reviews`) for PR analysis. They give you the description, full file list, and review discussion — far richer than commit messages or `git log`.
- If a PR description is vague, the changed-files list is usually the most reliable signal for what shipped. Look for new settings keys, new `.xm`/`.m` files, and added entries to `Makefile` / settings VCs.
- Skip PRs that only touch the release pipeline / distribution sources / CI workflows (e.g. `distribution/`, `scripts/`, `.github/workflows/`) — those aren't user-facing tweak changes. Only mention them if they introduce a user-visible install/distribution change.
- Don't invent PR numbers or handles. If you can't map a note to a PR, ask the user or omit the parenthetical.
- Bump version in `control` (tweak/.deb) **and** `distribution/config.json` `buildVersion` (IPA `CFBundleVersion`, monotonic). `src/Version.h` is auto-generated by the Makefile — don't touch it.
