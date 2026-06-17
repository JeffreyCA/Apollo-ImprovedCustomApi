# Web JSON spike — findings & go/no-go (June 12, 2026)

Spike for the OAuth-free escape hatch: drive `www.reddit.com/...json` with a
WebView-harvested session cookie instead of `oauth.reddit.com` + bearer tokens
(the Hydra recovery model), against the day Reddit revokes the remaining API
keys with no path to new ones. Everything below was measured live in the iOS 26
simulator (`scripts/run-in-sim.sh`, signed-in account) on a residential
network.

## Code state & how to exercise it (for a handoff)

The spike landed on branch `web-json-spike` (commit "Add Web JSON spike…"); the
deferred-work build-out below sits on top of it. Files:
`src/ApolloWebJSON.{h,m}` (transport + keychain + expiry),
`src/ApolloWebJSONIdentity.xm` (identity, item 3),
`src/ApolloWebSessionLoginViewController.{h,m}` (login + modhash harvest +
expiry prompt). Modified: `Makefile`, `src/Tweak.xm` (rewrite splice +
response-side expiry hook + `%ctor` hydration + expiry-prompt observer),
`src/ApolloState.{h,m}` + `src/UserDefaultConstants.h`,
`src/CustomAPIViewController.m` (settings switch + status row),
`src/ApolloImageUploadHost.xm` (ignore the synthetic bearer). Grep `[WebJSON]`
and `WebJSON` to find every touch point. See "Deferred work — IMPLEMENTED" below
for per-item status and what still needs device verification.

To reproduce (simulator, per CLAUDE.md): `scripts/run-in-sim.sh` to build+launch
injected; in Apollo → Settings → Apollo Reborn → API Keys, toggle **Web JSON
Mode (Experimental)** on, then **Web Session Login (Experimental)** to harvest a
cookie. Watch the flow with the `apollofix` os_log subsystem
(`xcrun simctl spawn "$(cat .sim/device.txt)" log show --last 2m --predicate 'subsystem == "apollofix"' | grep WebJSON`).
**Important:** the spike only browses on an Apollo that already has an OAuth
credential (a restored account *or* a configured API key) — see the cold-start
caveat. Test against a `--backup` that signs you in, not a keyless install.

## TL;DR — GO (transport proven, cheaply)

Both load-bearing unknowns resolved in favor of the migration:

1. **Apollo parses Reddit's web listing JSON as-is.** With the flag on,
   `oauth.reddit.com/hot.json` and `/r/pics/hot.json` were rewritten to
   `www.reddit.com` equivalents and the feed rendered **fully and correctly**
   (posts, thumbnails, flairs, vote counts, subreddit header) with **zero
   response transformation**. Both hosts speak the same
   `{kind, data: {children, after}}` shape; the feared per-endpoint transform
   layer is unnecessary for listings.
2. **Cookie auth survives Apollo's request path.** A `Cookie:` header set
   explicitly in the `__NSCFLocalSessionTask _onqueue_resume` chokepoint
   (Authorization stripped, `HTTPShouldHandleCookies = NO`) authenticated
   cleanly — HTTP 200 + personalized content through RDKClient's
   AFNetworking session, no serializer complaints.

## What was built (flag-gated, dormant by default)

- `src/ApolloWebJSON.{h,m}` — `ApolloWebJSONRewriteRequest()`: whitelist-gated
  rewrite (front page + `/r/<sub>` + sorts `hot|new|top|rising|best|controversial`,
  GET only), ensures `.json` path suffix, strips `Authorization`, attaches
  `sWebSessionCookieHeader`, keeps the custom User-Agent. Spliced as an
  early-return into the existing `oauth.reddit.com || www.reddit.com` branch in
  `src/Tweak.xm` (mirrors the notification-backend splice).
- `src/ApolloWebSessionLoginViewController.{h,m}` — WKWebView login at
  `https://www.reddit.com/login` on the **persistent** data store. Auth state is
  decided by an `/api/me.json` probe (`callAsyncJavaScript` in the page world),
  **not** by cookie presence — see "Login/harvest details" below for why. On an
  existing session it prompts *Keep Current Session / Re-authenticate / Cancel*;
  Re-authenticate clears `.reddit.com` cookies and reloads so the login form
  actually appears. Once a probe (run on `didFinishNavigation` + a 2s poll, since
  the login form submits via fetch with no navigation) reports a logged-in user,
  it harvests all `.reddit.com` cookies into a `name=value; …` header, rewrites
  session-only cookies to ~10,000-day expiry, persists, and dismisses.
- Settings (`CustomAPIViewController`, API Keys section): "Web JSON Mode
  (Experimental)" switch + "Web Session Login (Experimental)" row (visible only
  while the mode is on).
- Flag `UDKeyWebJSONEnabled` (default NO) + `sWebJSONEnabled` /
  `sWebSessionCookieHeader` globals hydrated in `%ctor`. Cookie header persists
  in `standardUserDefaults` — **spike-grade; a real build moves it to the
  keychain** (it's a full account credential).

Flag OFF (the shipped default) was regression-tested: zero `[WebJSON]`
activity, stock oauth behavior byte-for-byte (the helper returns nil before
touching the request).

## Measured results per endpoint

| Request | Unauthenticated | With harvested cookie |
|---|---|---|
| `www.reddit.com/hot.json` (front page) | **403** — Reddit's ~190 KB HTML block page | **200**, feed renders, personalized |
| `www.reddit.com/r/pics/hot.json` | **403** (same block page, also via curl) | **200**, full subreddit renders |
| `www.reddit.com/.json`, `/r/apple/new.json` (curl, browser UA) | **403** | not separately tested (same gate) |

**Unauthenticated web JSON is dead across the board** — not just
`/api/info.json` as previously observed (`Tweak.xm` Recently Read comment).
Reddit now serves its block page to all anonymous `...json` requests
regardless of User-Agent. There is no anonymous fallback tier; the cookie
login is a hard prerequisite, not an enhancement. Apollo degrades gracefully
on the 403 (keeps cached content; AFNetworking rejects the HTML body without
crashing).

### Login/harvest details

- **Auth state is detected via `/api/me.json`, not cookie names.** This was a
  late but important correction. Cookie *presence* is unreliable on two counts:
  (1) Reddit sets `reddit_session` **and** `token_v2` for *anonymous* web
  sessions too, so neither name proves you're logged in; (2) `WKHTTPCookieStore
  getAllCookies` can return an empty/stale snapshot in the moments right after
  the WKWebView is created, even while the network stack already has the
  persisted cookies (so `/login` silently re-authenticates). The login VC now
  runs `fetch('/api/me.json')` via `callAsyncJavaScript` in the page's content
  world (httpOnly cookies included) and keys all decisions on whether that
  returns a username. This is the same signal a future write/identity layer
  needs anyway.
- The login form submits via fetch with no page navigation, so a 2-second poll
  (re-running the probe) — not `didFinishNavigation` — is what catches the
  moment auth completes. Harvest yielded 10–13 cookies (`reddit_session`,
  `token_v2`, `loid`, `csrf_token`, `edgebucket`, …); the serialized header is
  ~2.7 KB and `/api/me.json` confirmed it authenticates as the real account.
- The persistent `WKWebsiteDataStore` retained the session across an app
  **uninstall** in the simulator — the default data store lives outside the app
  container. Treat the WebView cookie store as a credential cache with its own
  lifecycle. "Web Session Login" now detects an existing session up front and
  prompts **Keep Current Session / Re-authenticate / Cancel**; Re-authenticate
  clears all `.reddit.com` cookies so the login form actually appears instead of
  auto-logging-in. (Verified live: prompt named `u/ClydeDroid`; Re-authenticate
  surfaced the real Log In form.)
- old.reddit cookie naming (iOS < 16 path) was not exercised — flagged in the
  VC as a thing to record when first tested on an old-iOS device.

### Cold-start caveat (confirmed by experiment)

On a **truly fresh install — no API keys, no account, no backup** — enabling
Web JSON mode and harvesting a cookie does **not** make the feed load. Apollo's
request pipeline is gated on obtaining an OAuth credential first: it fires
`www.reddit.com/api/v1/access_token` (which needs a configured API client ID),
and with none it never mints a token, never issues the `hot.json` listing
request, and the spinner never resolves — so there's nothing at the chokepoint
for the rewrite to intercept (`[WebJSON] Rewrote` never logs). The harvested
cookie is valid but inert. **Web JSON mode is a transport layer on top of an
Apollo that already believes it's authenticated** (restored account *or*
configured API key); making it work from a keyless cold start is exactly the
deferred "identity integration" item below — the gate on shipping.

### Response-shape diff

None observed for listings. `RDKClient objectsFromListingResponse:` logged no
non-dict warnings; every visible feed element (including vote arrows/scores,
NSFW-blurred thumbnails, flair pills) populated. Auth-state-dependent fields
(`likes`, `saved`, `over_18` gating) rendered consistent with the signed-in
account because the cookie session is that account. No transformer was built —
correctly, per plan.

## Deferred work — IMPLEMENTED (June 12, 2026)

All four deferred items below were built out on top of the spike. Code compiles
and launches cleanly in the iOS 26 simulator with the flag off (zero regression)
and on (ctor hydration + keychain round-trip verified). The parts that genuinely
can't be exercised without a live Reddit account / device are flagged
**[needs device verification]** — that's the remaining shipping gate, not unbuilt
code. Touch points are tagged `[WebJSON]` / `[WebJSON][identity]` in the logs.

New file since the spike: `src/ApolloWebJSONIdentity.xm` (item 3). The transport
(`ApolloWebJSON.{h,m}`), login VC, settings, `Tweak.xm`, and `ApolloState` were
extended; `Makefile` registers the new file.

1. **Whitelist → full read coverage** — DONE. `ApolloWebJSONClassifyReadPath`
   now routes the front page, `/r/<sub>[/sort]`, comments
   (`/r/<sub>/comments/...` and bare `/comments/...`), user pages
   (`/user|/u/<name>[/where]` incl. `/m/<multi>`), `/search` (global + scoped),
   `/subreddits/...` (subscriptions/discovery), `/message/...` (inbox), `/prefs`,
   `/duplicates`, sub `about`/`wiki`, **and every `/api/*` GET** (served as JSON
   natively, no `.json` suffix). Listing-style pages get `.json` appended;
   `/api/*` paths don't. Unrecognized paths fall through to the oauth path
   untouched. _[needs device verification]_ inbox/messaging response shapes —
   no transform was needed for any surface tested, but inbox was not exercised
   against a live account.
2. **Write actions via modhash** — DONE. Any POST/PUT/DELETE to a routable
   `/api/*` path (token + media-upload endpoints excluded) is re-pointed at
   `www.reddit.com` with the cookie + an `X-Modhash` header. The modhash is read
   from `/api/me.json` (`data.modhash`) at login time
   (`_probeModhashWithCompletion:`) and stored alongside the cookie. The
   settings row shows "(read-only — no write token)" when a session has a cookie
   but no modhash. _[needs device verification]_ end-to-end vote/comment/submit
   against live Reddit (and its web-side ratelimit/captcha behavior).
3. **Identity integration** — DONE, including the no-account cold start.
   Verified end-to-end in the iOS 26 simulator (account tab shows the user;
   personalized subscriptions/profile/inbox/vote-state load; upvote/downvote
   work). `ApolloWebJSONIdentity.xm`:
   - **Auth state + credential**: `RDKClient` reports authenticated and gets a
     synthetic `RDKOAuthCredential` (dummy bearer, ~100-yr duration) when a usable
     cookie session exists and no live credential is present.
   - **Token mint/refresh short-circuit**:
     `retrieveAccessTokenForApplicationOnlyWithCompletion:` /
     `retrieveAccessTokenWithCompletion:` / `refreshAccessTokenWithCompletion:`
     replace the keyless `api/v1/access_token` POST (which 403s and fires the
     completion with an error — the actual cold-start stall) with an instant
     synthetic success. The completion type was **confirmed in Hopper** to be
     `void(^)(id, NSError *)` (the app-only mint invokes it `(nil, error)`;
     refresh forwards the same block); a failed real mint leaves the credential
     intact, so the substitution only suppresses the error callback. Guarded so a
     real working OAuth credential is never bypassed. The synthetic bearer is
     excluded from `sLatestRedditBearerToken` capture.
   - **Account synthesis** (`ApolloWebJSONSynthesizeSignedInAccount`): the vote /
     comment UI and account tab gate on `AccountManager.currentAccountIndex != nil`
     (RE'd in `-[AccountManager init]` = `sub_100825acc`), NOT on `RDKClient` auth.
     `AccountManager` is pure Swift with no ObjC accessor for its accounts
     collection, so instead of constructing Swift objects we write the on-disk
     blobs its loader reads: `RedditAccounts2` (NSUserDefaults, `NSKeyedArchiver`
     of `[RDKClient]`), `2RedditAccounts2` (Valet keychain, archive of
     `[[String:String]]`), and `CurrentRedditAccountIndex`. A real archived
     `RDKClient` (the app-only client) is reused as the template, flipped to a
     user account (`usesApplicationOnlyOAuth=NO`, `currentUser`, modhash, full
     scope). Runs at login harvest (with a restart prompt) and in `%ctor` before
     AccountManager loads (so it takes effect same-launch). The dummy token in the
     sensitive blob is fine — the cookie authenticates at the chokepoint.
   **Only remaining check:** device validation of the real-keychain/Valet account
   write (the sim uses Tweak.xm's virtualized Valet). The Valet service string and
   blob formats were read from a live install, and the write mirrors the existing
   `ApolloReplayValetKeychainItems` path that already works on device.
4. **Session lifecycle + keychain** — DONE. The cookie header, modhash, and
   username now live in the keychain (`ApolloWebJSON.m`), migrated out of
   `NSUserDefaults` on first launch (migration only drops the defaults copy once
   the keychain write is confirmed). `ApolloWebJSONNoteResponse` (wired to
   `__NSCFLocalSessionTask _onqueue_didFinishWithError:`) watches for the 403
   text/html block page on a request *we* cookie-authenticated and posts
   `ApolloWebJSONSessionExpiredNotification`, which surfaces a one-shot "session
   expired — sign in again" prompt from the topmost VC. Hydra's far-future
   cookie-expiry trick remains in the login VC.

### Simulator keychain gotcha (recorded)

The sim virtualizes the keychain (`Tweak.xm` Sec* fishhooks) **only for queries
whose `kSecAttrService` contains `com.christianselig.Apollo`** (`IsValetQuery`).
The Web JSON keychain items are therefore namespaced
`com.christianselig.Apollo.webjson` so they ride that virtualization; an
unrelated service name fails in the sim with `errSecMissingEntitlement`
(-34018). On device the name is just a namespace and any value works.

Estimate to ship: all four items are implemented and the full read + write +
cold-start-identity flow is **verified in the simulator**. The remaining work is
**on-device validation** (real keychain/Valet account write; live vote/comment
round-trips) — no new plumbing.

## Gotchas recorded for the next person

- Set the `Cookie` header explicitly on the request; do not trust the session
  cookie jar (RDKClient's AFHTTPSessionManager config is an unknown, and
  `HTTPShouldHandleCookies = NO` also prevents the jar from overwriting it).
- Reddit's 403 block page is ~190 KB of HTML with `Content-Type: text/html` —
  cheap to detect for the session-expiry check (item 4).
- In the simulator workflow, `scripts/run-in-sim.sh` with a `.sim/backup.zip`
  present wipes the app container on every launch (uninstall → reinstall →
  preload) — move the zip aside while iterating on state you want to keep,
  e.g. a harvested cookie session.

## Tester-feedback fixes (June 13, 2026)

Five issues from the PR #442 test thread (r/ApolloReborn + GitHub). All changes
compile for the simulator and the build launches cleanly (hooks install, no
crash, flag-off path unaffected).

1. **Spurious "session expired" prompt after backgrounding (FIXED).**
   `ApolloWebJSONNoteResponse` counted a 3-streak of 403 text/html block pages,
   but a concurrent Cloudflare/rate-limit burst on app resume could cross it with
   a still-valid cookie. Now, at the threshold, `ApolloWebJSONVerifySessionThenAnnounce`
   fires a direct `GET /api/me.json` (tagged `X-Apollo-WebJSON-Probe` so it
   bypasses the rewrite + counter) and only announces expiry if the probe fails.
   `src/ApolloWebJSON.m`.
2. **Blank account tab after mid-session login (UX polished).** `AccountManager`
   loads accounts only at init; iOS can't self-relaunch, so the restart stays but
   the foot-guns are gone: the login alert now says "Quit & Reopen" with a clear
   "account stays inactive" defer option, sets `UDKeyWebJSONPendingRestart`, and
   the Web Session Login settings row shows an orange "quit & reopen to activate"
   reminder (tapping it offers to quit) until the next launch clears the flag in
   `%ctor`. `ApolloWebSessionLoginViewController.m`, `CustomAPIViewController.m`,
   `Tweak.xm`, `UserDefaultConstants.h`.
3. **Profile posts/comments list empty — ROOT CAUSE CONFIRMED & FIXED (June 15).**
   Live sim repro (fresh u/ClydeDroid cookie) showed the Account tab spinning with
   **zero `/user/` requests** and `[BannedProfile] … reason=no-username`. Dumping
   the archived `RedditAccounts2` blob proved the loaded account's `currentUser`
   (an `RDKMe`) had **no username** (NSKeyedArchiver omits nil values, so the
   username key was simply absent; `fullName` was the broken `t2_(null)`). Karma /
   avatar / age live on `currentUser` and render from cache without the username,
   which is exactly why testers saw the **header but an empty listing** — the
   listing needs `/user/<username>/overview`, which a nil username never builds.
   **Fix:** backfill the username onto the **live** `currentUser` from the
   harvested web-session identity (`ApolloWebJSONBackfillUsernameOnUser`), hooked
   at `-[RDKClient setCurrentUser:]` (fires on account load) with a belt-and-
   suspenders call in `ApolloWebJSONInstallSyntheticCredentialIfNeeded`. The
   on-disk blob can't be repaired (`RDKMe`'s MTLModel encoding drops a re-set
   username on re-archive — tried and verified). Confirmed in sim:
   `Backfilled live currentUser.username -> u/ClydeDroid`, the ProfileViewController
   then reports `username=ClydeDroid`, and `/user/ClydeDroid/overview.json` fires +
   routes to www. `src/ApolloWebJSONIdentity.xm`.
4. **Comment editing "not an available option" — FIXED (June 15).** Two parts:
   (a) **Affordance** — the Edit option gates on `comment.author ==
   currentUser.username`, so it was hidden for the same nil-username reason as #3;
   the #3 backfill restores it (confirmed: Edit now appears, and edits persist
   server-side). (b) **Empty re-render after save** — www.reddit.com's
   `/api/editusertext` *and* `/api/comment` return each thing's `data` in the
   legacy old-reddit shape `{parent, content:"<html>"}` instead of the modern
   comment JSON oauth returns, so Apollo parsed no `body`/`score` and re-rendered
   the comment empty with 0 upvotes (the write succeeded; only the display object
   was wrong). **Fix:** `ApolloWebJSONFixupWriteResponseObject` (hooked at
   `-[RDKResponseSerializer responseObjectForResponse:data:error:]`) detects the
   legacy shape, pulls the `t1_…` fullname out of the `content` HTML, re-fetches
   the modern object via `info.json`, and swaps it into the `things` envelope.
   Confirmed in sim for both edit and new-comment posting (`Rebuilt /api/editusertext
   … from info.json`, `Rebuilt /api/comment … from info.json`). Also kept the
   earlier host-check broadening (`ApolloIsRedditWriteHost`) so write
   post-processing survives the www rewrite. `src/ApolloWebJSON.{h,m}`,
   `src/ApolloWebJSONIdentity.xm`, `src/ApolloImageUploadHost.xm`.
5. **Keyless image uploads — Track A FAILED, clean Imgur fallback shipped (June 15/16).**
   **Track A (truly keyless native Reddit upload): not viable.** Device test +
   credential replay confirmed `www.reddit.com/api/media/asset.json` returns
   Reddit's **403 HTML block page** for cookie+modhash auth — across every modhash
   placement (X-Modhash header, `uh` form field, multipart, urlencoded, with/without
   Origin/Referer). The lease endpoint requires a real OAuth bearer (Reddit's web
   client uploads via a GraphQL mutation using a token the logged-in site embeds),
   which the cookie-only session doesn't have. So the lease rewrite was reverted:
   `ApolloWebJSONWritePathIsRoutable` now **always** keeps `/api/media/asset.json`
   on the oauth path (routing it to www only 403s — and would have broken uploads
   for a real-account user who also has Web JSON Mode on).
   **Fallback (shipped):** in a keyless session (the resolved upload bearer is the
   synthetic placeholder), both `NSURLSession uploadTask…` hooks now short-circuit
   **before** attempting the doomed Reddit lease and fall back to Apollo's default
   Imgur path; if no Imgur key is set either, a one-time alert
   (`ApolloWarnKeylessUploadUnavailableOnce`) explains that image upload needs an
   Imgur API key (the previous copy wrongly told users to switch the provider to
   Reddit to upload without keys). Provider-agnostic, and inert for non-Web-JSON
   users (the bearer is only synthetic when `HasUsableSession`). Compile-verified;
   confirm the alert on device. `src/ApolloImageUploadHost.xm`, `src/ApolloWebJSON.m`.

### Follow-up spike — harvest a web OAuth bearer (would unblock native upload)

The logged-in www.reddit.com session has an OAuth access token (new reddit embeds
one for its GraphQL calls). If the login WebView harvested that bearer alongside
the cookie + modhash, `/api/media/asset.json` (and potentially the whole transport)
could use a real bearer instead of cookie rewriting — making native keyless upload
work and the mode more robust. Not yet attempted (needs RE of where the token is
exposed + write testing with consent). Tracked as the chosen "investigate token"
follow-up to the June 16 uploads decision.

Glass IPA app-ID install limit (tester #4) is out of scope — Apple's free-account
cap of 10 app IDs / 7 days, not a code issue.
