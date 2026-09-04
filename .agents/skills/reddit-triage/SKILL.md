---
name: reddit-triage
description: Triage r/ApolloReborn community activity — fetch comments/inbox via the maintainer triage tooling, cross-check reports against GitHub issues/PRs and the Fider request board, file untracked bugs and feature requests, and draft human-approved Reddit replies. Use when asked to triage Reddit, review the comments on an announcement thread, or process community bug reports and requests.
allowed-tools: shell
---

# Reddit triage

Turn a Reddit thread or the community's recent activity into: tracked GitHub
issues, Fider feature requests, and a drafts file of replies for the maintainer
to approve. Nothing is ever posted to Reddit without explicit human approval of
the exact text.

## Step 0. Preconditions

The private maintainer tooling must be cloned as a sibling of this repo:

```bash
ls ../reddit-triage/client.py || git clone git@github.com:Apollo-Reborn/reddit-triage.git ../reddit-triage
```

It requires maintainer access and a one-time OAuth setup — follow that repo's
README (`config.json` from the example template, then `auth.py`). If the clone,
`config.json`, or the auth token is missing, stop and tell the user exactly
which setup step is needed; don't attempt the OAuth dance unattended.

The tooling enforces its own request pacing and reply caps — never work around
them.

## Step 1. Fetch

Two modes — pick based on what was asked:

**Digest cycle** (inbox + subreddit + watched threads; marks items seen in
`state.json` so the next run only surfaces new activity):

```bash
cd ../reddit-triage && uv run fetch.py        # digest → digests/<ts>.md
```

**Ad-hoc thread** (e.g. "triage the comments on this announcement post").
Deliberately does NOT go through `fetch.py`, so seen-state and digests are
untouched:

```bash
cd ../reddit-triage && uv run --with requests python - <<'EOF'
import client as c

rc = c.RedditClient()
resp = rc.get("/comments/THREAD_ID", limit=500, sort="top", depth=10)
post = resp[0]["data"]["children"][0]["data"]
print(f"POST: {post['title']}  (score={post['score']}, {post['num_comments']} comments)")

out, mores = [], []
def walk(children, depth=0):
    for ch in children:
        if ch["kind"] == "t1":
            d = ch["data"]
            out.append((depth, d))
            replies = d.get("replies")
            if isinstance(replies, dict):
                walk(replies["data"]["children"], depth + 1)
        elif ch["kind"] == "more":
            mores.append(ch["data"])

walk(resp[1]["data"]["children"])
for depth, d in out:
    indent = "  " * depth
    body = (d.get("body") or "").replace("\n", f"\n{indent}| ")
    print(f"{indent}[{d['name']}] u/{d.get('author')} (score {d.get('score')}):")
    print(f"{indent}| {body}\n")
print(f"TOTAL comments fetched: {len(out)}")
for m in mores:
    print(f"MORE stub: count={m.get('count')} children={m.get('children')}")
EOF
```

If any `MORE stub` lines print, fetch those children too
(`/api/morechildren?link_id=t3_<id>&children=<csv>`) before triaging —
never report a thread as fully reviewed while stubs are unexpanded.

## Step 2. Classify

Bucket every item:

- **bug report** — something broke, ideally with a version/regression window
- **feature request** — new behavior or restoring removed behavior
- **support question** — answerable from docs/code, no tracker entry needed
- **praise / chatter** — no action
- **self-resolved** — reporter fixed it in-thread; no action, note the fix

## Step 3. Cross-check before filing anything

- **GitHub issues** — check open AND closed; reports filed via
  report.apolloreborn.app arrive as anonymous GitHub issues whose text often
  matches a Reddit comment verbatim (same reporter):

  ```bash
  gh issue list --repo Apollo-Reborn/Apollo-Reborn --state open --limit 200 \
    --json number,title,labels
  gh issue list --repo Apollo-Reborn/Apollo-Reborn --state closed --limit 40 \
    --search "<keywords>" --json number,title
  gh pr list --repo Apollo-Reborn/Apollo-Reborn --state open --limit 100 \
    --json number,title,author
  ```

- **Fider request board** (listing/search is public, no auth):

  ```bash
  curl -s "https://apolloreborn.fider.io/api/v1/posts?limit=100"
  curl -s "https://apolloreborn.fider.io/api/v1/posts?query=<keywords>"
  ```

- **The codebase** — when a comment makes a claim about app/tweak behavior
  ("this option was removed", "does X need an API key?"), verify against the
  source before answering or filing. Past examples: a settings mode that was
  deliberately retired (feature request, not bug), asset fallbacks that are
  intentionally stripped, an API key that only gates composing rather than
  viewing.

## Step 4. File untracked items

**Bugs** with enough substance → GitHub:

```bash
gh issue create --repo Apollo-Reborn/Apollo-Reborn --label bug \
  --title "[Bug]: <symptom>" --body "<body>"
```

Body: summary, quoted comment, the Reddit permalink, the version/regression
window, and any likely-cause notes. For thin reports (one sentence, no
environment or logs), prefer a reply asking the reporter to submit via
report.apolloreborn.app — that auto-creates a far richer issue (environment
table + crash attachments) than a hand-filed stub.

**Feature requests** → Fider. If the repo root has a `.env` with
`FIDER_API_KEY` (gitignored; never print the key):

```bash
# Show the drafted title/body to the user and get explicit approval FIRST —
# the post publishes under the key owner's account.
curl -s -X POST "https://apolloreborn.fider.io/api/v1/posts" \
  -H "Authorization: Bearer $(grep '^FIDER_API_KEY=' .env | cut -d= -f2-)" \
  -H "Content-Type: application/json" \
  -d '{"title": "<title>", "description": "<body>"}'
```

Credit the requester with their u/username and the comment permalink in the
body. Without a key, write paste-ready title/body blocks to
`../reddit-triage/drafts/fider-<date>.md` for the maintainer to post manually.

## Step 5. Draft replies

Write `../reddit-triage/drafts/<date>-<slug>.md`, one section per reply:

```markdown
### reply-to: t1_abc123
Reply text in markdown. Everything until the next section header.

### reply-to: t1_xyz789
SKIP
```

`t1_` = comment, `t3_` = post, `t4_` = private message; a `SKIP` (or empty)
body skips the item. Max 10 replies per run — split larger batches into
multiple files. Typical replies: answers to support questions (verified against
the code), links to the issues/requests just filed, and asks for
report.apolloreborn.app submissions or missing details.

Validate the file:

```bash
cd ../reddit-triage && uv run reply.py drafts/<file>.md --dry
```

## Step 6. Hard rules

- **Never** run `reply.py` without `--dry` unless the human has reviewed and
  approved the exact drafts file. Posting is always the human's call.
- Never post, vote, or send anything on Reddit outside the approved drafts
  flow.
- Fider posts and GitHub issues that a reply links to must exist **before**
  that reply is posted — publish in dependency order.
- Drafts and digests contain user content — they stay in the gitignored
  `drafts/`/`digests/` directories, never in a commit.

## Step 7. Wrap up

End with a summary the maintainer can act on at a glance:

- a table of every actionable thread item → already tracked (where) /
  newly filed (link) / reply drafted / no action (why)
- paths of every file created, and the exact `reply.py` command to post the
  drafts after review
- any posting-order dependencies (e.g. "paste the Fider drafts before sending
  reply 3, which links to them")
