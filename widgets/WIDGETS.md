# Apollo Reborn Widgets

Home Screen, Lock Screen, and StandBy widgets for Apollo, shipped as a single
WidgetKit extension (`ApolloRebornWidgets.appex`) injected into the app. Nine
widgets live in one extension (one App ID), built with classic SiriKit
`IntentConfiguration` so their configuration survives third-party re-signing.

## At a glance

| Widget | Sizes | Configurable | Source / default |
|---|---|---|---|
| **Showerthoughts** | S · M · L · Lock (rect, inline) | Setup code only | r/showerthoughts · Top: Week |
| **Jokes** | S · M · L · Lock (rect, inline) | Setup code only | r/Jokes · Top: Today |
| **Post** | S · M · L | Subreddit, Sort, Caption | r/popular · Hot |
| **Feed** | M · L | Subreddit, Sort, Compact | r/popular · Hot |
| **Photo** | S · M · L | Subreddit, Sort, Caption | r/EarthPorn · Top: Today |
| **Shortcuts** | S · M · L | Source, Subreddits | curated / your list |
| **Apollo Actions** | M | — (static) | fixed actions |
| **Calendar** | S · M · L | Subreddit, Date Style, Show Title | r/EarthPorn · Top: Week (fixed) |
| **Headline** | Lock (rect, inline) | Subreddit | r/worldnews · Hot |

Sizes: **S** = small (2×2), **M** = medium (4×2), **L** = large (4×4), **Lock**
= Lock Screen / StandBy accessory slots. Any widget that supports **S** also
appears in **StandBy** (landscape charging).

---

## Shared concepts

### Setup code (one-time, shared)
Most widgets read Reddit through Apollo's API key. Because a sideloaded app and
its widget can't share an App Group, the key is passed via a **setup code**:

1. In Apollo: **Settings → Apollo Reborn → Copy Widget Setup Code**.
2. Long-press any widget → **Edit Widget** → paste into **Setup Code**.

Paste it into **one** widget and the rest pick it up automatically — they all
share the same stash and reload immediately. The field also accepts a bare
Reddit client ID (your API key) instead of the full code. *Apollo Actions* and
*Shortcuts* (with letter avatars) need no setup code at all.

### Sort options
Where a widget exposes **Sort**: **Hot**, **New**, **Top: Today**, **Top: This
Week**. Unset falls back to the widget's default (see table).

### Caption (Post & Photo)
A single **Caption** picker controls how much text overlays the post:
- **None** – clean image, no text (image posts).
- **Title** – title only.
- **Title + Stats** – + score and comments.
- **Detailed** – + age, author (and the body preview, for text posts).

### Rotation & refresh
- **Rotating widgets** (Showerthoughts, Jokes, Post, Photo) cycle through a pool
  of top posts: the visible post is a function of the wall-clock time, advancing
  ~every 25 min across an ~8 h window, so glances feel fresh without burning
  WidgetKit's reload budget. A circular **↻** button shows the next one on tap.
- **Feed** is a list; it refreshes ~every 30 min and has a **↻** reload button.
- **Calendar** locks one photo per calendar day (see below).
- **Shortcuts** refreshes icons ~daily.

### Content filtering
Every widget hides NSFW, spoiler, stickied, and removed/deleted posts. (NSFW is
not currently exposed as an option — the app-only token can't reliably fetch
dedicated 18+ subreddits anyway.)

### Tapping
Content widgets deep-link into Apollo via the `apollo://` scheme — a post opens
the thread, a subreddit tile opens the subreddit, an action opens that screen.

### StandBy / Night Mode
In StandBy (landscape charging) the small layout is scaled up. **Calendar** and
**Photo** dim their image in Night Mode (dark room) so the date/caption stays
legible instead of a red-tinted photo.

---

## Widgets

### Showerthoughts
A single rotating top post from r/showerthoughts on Apollo's blue gradient.
- **Sizes:** Small, Medium, Large, Lock Screen (Rectangular, Inline).
- **Config:** Setup Code only.
- **How it works:** pulls Top: This Week, rotates through the pool, ↻ for the
  next. This is also the **zero-config lock-screen widget** — no options to fuss
  with on the Lock Screen.

### Jokes
A joke from r/Jokes — the title is the setup, the body is the punchline — on a
purple gradient.
- **Sizes:** Small, Medium, Large, Lock Screen (Rectangular, Inline).
- **Config:** Setup Code only.
- **How it works:** Top: Today, filtered to self-text jokes (so there's always a
  punchline). Rotates; ↻ for the next. On the Lock Screen it shows the setup —
  tap to open Apollo for the punchline.

### Post
The top post from a subreddit you choose. Adapts to content: image posts get a
full-bleed photo with a title scrim; text/self posts render title + body on the
gradient.
- **Sizes:** Small, Medium, Large.
- **Config:** Setup Code · **Subreddit** (default `popular`) · **Sort** (default
  Hot) · **Caption** (default Title + Stats).
- **How it works:** fetches the top ~50, rotates through them, ↻ for the next,
  tap opens the post in Apollo.

### Feed
A scrolling-style list of a subreddit's top posts, each row linking to its post.
- **Sizes:** Medium, Large.
- **Config:** Setup Code · **Subreddit** (default `popular`) · **Sort** (default
  Hot) · **Compact** (default off — hides thumbnails and fits more rows).
- **How it works:** fetches the top ~12; the row count fits the widget height
  (a Medium shows ~2–3, a Large fills by device size). ↻ reloads. Thumbnails on
  the trailing edge unless Compact is on.

### Photo
A full-bleed top image from a subreddit, minimal chrome — great as a rotating
art/photography frame.
- **Sizes:** Small, Medium, Large.
- **Config:** Setup Code · **Subreddit** (default `EarthPorn`) · **Sort**
  (default Top: Today) · **Caption** (default Title; choose **None** for a clean
  image).
- **How it works:** image posts only, top ~25, rotates, ↻ for the next, subtle
  vignette, StandBy night dim, tap opens the post.

### Shortcuts
A grid of colored tiles, one per subreddit, that open the sub in Apollo — like
Apple's Shortcuts tiles.
- **Sizes:** Small (2×2), Medium (2×3), Large (2×4).
- **Config:** **Source** (Popular / New / Home / Custom) · **Subreddits** (a
  comma/space/newline list, used when Source = Custom) · Setup Code (optional).
- **How it works:** no network needed — tiles use letter avatars and a stable
  color palette. If a setup code is present, it fetches each subreddit's real
  icon and brand color. Tap a tile to open that subreddit.

### Apollo Actions
A Threads-style quick-action panel: a "Search Apollo" pill (with the Apollo
mascot) plus four tiles — **Home** (front-page feed), **Popular**, **All**,
**Inbox**.
- **Sizes:** Medium only.
- **Config:** none (static — nothing to set up).
- **How it works:** each control deep-links via `apollo://`. Search/Home/Inbox
  are routed by the tweak (Home opens the actual front-page feed, not the
  subreddit picker); Popular/All use Apollo's native URL handling.

### Calendar
One **locked photo of the day** from a subreddit with the date overlaid — a
photo by day, a clean date display by night.
- **Sizes:** Small, Medium, Large.
- **Config:** Setup Code · **Subreddit** (default `EarthPorn`) · **Date Style**
  · **Show Title** (default off). Sort is fixed to Top: This Week (best image).
- **Date styles** (each a distinct system font):
  - **Rounded** – SF Pro Rounded, big friendly day number.
  - **Serif** – New York, editorial masthead with a hairline rule.
  - **Mono** – monospaced digital readout with an ISO date line.
  - **Condensed** – heavy condensed numerals, sports-poster.
  - **Stamp** – outlined, rotated date-stamp.
- **How it works:** picks one image per calendar day **deterministically** and
  **persists** it, so it never changes during the day and won't repeat a recent
  day (a rolling ~150-day history avoids dupes). It pre-renders the next few
  days so the photo flips at midnight even without a reload. Dims in StandBy
  Night Mode. Tap opens the source post.

### Headline
The top headline from a subreddit, on your Lock Screen — a rotating ticker of
what's hot.
- **Sizes:** Lock Screen only (Rectangular, Inline).
- **Config:** Setup Code · **Subreddit** (default `worldnews`).
- **How it works:** fetches the current top ~10 (Hot) and rotates through their
  titles; tap opens the post in Apollo. Text-only, like all Lock-Screen widgets.

---

## Availability notes

- **iOS 17+** (the extension targets iOS 17; validated on iOS 26).
- **Sideloading / App-ID budget.** A widget is an app extension, and each
  extension consumes one App ID. The limit depends on the signer:
  - **Paid Apple Developer account or TrollStore:** no practical limit — widgets
    work alongside Apollo's other extensions.
  - **Free Apple ID:** capped at ~10 App IDs per 7 days, one per extension. App +
    the single widget extension = 2 App IDs, which **fits** — so free accounts
    *can* have widgets. The catch is the **standard** build ships ~6 extensions
    (≈7 App IDs), which usually exceeds the free budget; a trimmed / widgets-only
    build (app + just the widget) is what fits a free account.
  - The **no-extensions** variant strips *all* extensions — including the widget —
    to fit free accounts, so it has no widgets by design. (All 9 widgets live in
    one extension, so they only ever cost one App ID, no matter how many you use.)
- The widget extension is self-contained; it doesn't depend on Apollo's app
  version, only on the Apollo Reborn tweak being installed (for the setup-code
  button).
