---
name: update-contributors
description: Update contributors.json and regenerate the README contributor credits by querying GitHub profile data with gh api. Use when the user says "update contributors", "sync contributors", "add new contributors", or asks to refresh contributor credits.
allowed-tools: shell
---

# Update contributors skill

This skill keeps the project's contributor credits in sync across two files:

1. `contributors.json` — the human-edited source of truth
2. `README.md` — the rendered contributor tables between `CONTRIBUTORS-LIST:START`/`END` markers. Maintainers render with code contributors but keep a maintainer badge.

## When to invoke

Run this skill when the user asks anything like:
- "update contributors", "sync contributors", "add new contributors", "refresh credits"
- "who's missing from the contributor table?"
- "regenerate the contributor table"

## Tooling

- Use `gh api` for GitHub data. Prefer authenticated `gh` (`gh auth status`) to avoid rate limits.
- Use `python3 .agents/skills/update-contributors/generate-readme-contributors.py` to regenerate `README.md`.
- Do **not** use third-party contributor generators or recreate legacy contributor config files.

## `contributors.json` schema

Top-level fields:

- `repo`: GitHub `owner/name`, used for commit links.
- `readme`: README path to rewrite.
- `contributorsPerRow`: table layout width.
- `contributors`: ordered list of credits.

Contributor fields:

- `role`: one of `maintainer`, `code`, or `design`.
- `github`: optional GitHub username. If present, the generator queries `gh api users/<github>` for `displayName`, `avatarUrl`, and the canonical GitHub profile URL.
- `id`: required for non-GitHub contributors unless `displayName` is unique enough.
- `displayName`: optional label. For GitHub users, omit it unless you want to override the GitHub login.
- `profileUrl`: optional profile link for non-GitHub contributors.
- `avatarUrl`: optional image URL. Non-GitHub contributors can omit it; the README cell will render without an avatar.
- `buyMeACoffeeUrl`: optional Buy Me a Coffee link. When present, the README generator adds a ☕ link under the contributor badge, and the in-app **Buy Us a Coffee** settings screen lists that maintainer.
- `source`: optional note such as `reddit`.

## Step-by-step process

### 1. Snapshot the current state

```bash
# Existing GitHub logins in contributors.json
python3 -c "import json; d=json.load(open('contributors.json')); print('\n'.join(c['github'] for c in d['contributors'] if c.get('github')))" | sort -fu

# GitHub contributors (excluding the bot account)
gh api repos/Apollo-Reborn/Apollo-Reborn/contributors --paginate -q '.[] | select(.type=="User") | .login' | sort -fu
```

`comm -23` between the two lists tells you who's new. Show this list to the user before doing anything destructive.

### 2. Decide each contributor's role

Look up each new GitHub contributor's commits to make an informed default suggestion:

```bash
gh api "repos/Apollo-Reborn/Apollo-Reborn/commits?author=<login>" -q '.[].commit.message' | head -10
```

Default suggestions:
- Code commits / merged PRs → `code`
- Workflow / Makefile / packaging changes → `code`
- Design assets (icons, wallpapers, themes, app artwork) → `design`
- Project owner / primary maintainer → `maintainer`

**Ask the user** to confirm the role for ambiguous contributors. Do not guess for design/icon work or non-GitHub credits.

### 3. Edit `contributors.json`

Add entries by hand using the minimal schema. Prefer only `role` + `github` for GitHub users:

```json
{
  "role": "code",
  "github": "octocat"
}
```

For non-GitHub contributors, provide stable identity fields:

```json
{
  "role": "design",
  "id": "harunatsu91202024",
  "displayName": "harumatsu",
  "profileUrl": "https://www.reddit.com/user/harunatsu91202024/",
  "source": "reddit"
}
```

### 4. Regenerate the README contributor tables

Run:

```bash
python3 .agents/skills/update-contributors/generate-readme-contributors.py
```

The generator queries GitHub profiles through `gh api users/<login>` and rewrites only the generated contributor block in `README.md`.

### 5. Verify

```bash
python3 -m json.tool contributors.json >/dev/null
python3 .agents/skills/update-contributors/generate-readme-contributors.py
git --no-pager diff --stat contributors.json README.md .agents/skills/update-contributors
```

Show the diff to the user before they commit. Do **not** auto-commit.

## Notes & gotchas

- GitHub's contributors API only checks commit authors. Designers, icon artists, and Reddit-only contributors must be added manually to `contributors.json`.
- Keep `contributors.json` ordered as it should appear in the README.
- GitHub contributors always use their canonical GitHub profile URL from `gh api`; use `profileUrl` only for non-GitHub contributors.
- Non-GitHub contributors can omit `avatarUrl`; the generated README will show a text-only cell.
- Never commit on the user's behalf.
- If `gh` is not authenticated, prompt the user to run `gh auth login` rather than trying to proceed with anonymous API calls (you may hit rate limits fast).
