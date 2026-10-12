# Phase 0, step 10: what the Discogs API provides (design chat, 2026-10-12)

Scope: decision 61's fields. This part covers data only. Terms (Restricted Data
for have/want), core's "View tags" pattern, and the `API.pm` throttle are still
open.

## Method, and how strong each source is

- **Live calls, observed 2026-10-12.** Unauthenticated, through a summarising
  fetch tool (its output is close to verbatim, but not raw). Calls made:
  `/releases/593568?curr_abbr=EUR` (album E), `/masters/63790?curr_abbr=EUR`,
  and `/marketplace/stats/593568?curr_abbr=EUR`.
- **The owner's run of the same calls**, with a token, as raw curl output.
  Section "Owner's authenticated run" below.
- **The developer docs**, read through the same summarising fetch. **Thin:** the
  page text stops inside the Marketplace "Order" section. The bodies of "Price
  Suggestions" and "Release Statistics" are not in it.
- **Client libraries (secondary):**
  - `joalla/discogs_client` @ `58808df`: `discogs_client/models.py`,
    `MarketplaceStats` and `PriceSuggestions`, around lines 584–612. Test
    fixture `discogs_client/tests/res/marketplace/stats/1.json`.
  - `bartve/disconnect` @ `8fca431` (2021): `lib/marketplace.js:148-155`,
    `lib/client.js:65-69`.
  - `iomonad/discogs` 0.1.6 docstrings on cljdoc
    (`src/discogs/marketplace.clj#L54`, `#L66`).
- **foo_discogs**, from the zip `zoomorph-foo_discogs-ef4dddf537e3` in the
  project files.

## Release (`/releases/{id}`) — one call

| site field | API | state |
|---|---|---|
| Have / Want | `community.have`, `.want` | **verified live** (1622 / 35) |
| Avg rating / Ratings | `community.rating.average`, `.count` | **verified live** (4.1 / 109) |
| N for sale | `num_for_sale` | **verified live** (54) |
| From X | `lowest_price` | **verified live**, but see the currency note below |
| to Y (highest) | none | **not found**: not in the live response or the docs |
| Last sold, Low / Median / High | none | **not found**: not in the live responses or the docs. No client library, and not foo_discogs, models them. |

Pressing facts are all in the same response: `labels`, `formats`, `country`,
`released`, `identifiers`, `notes`, `tracklist`, `extraartists`, `companies`,
`series`. **Verified live** (top-level keys).

**Currency note.** With `curr_abbr=EUR`, `/releases` gave `lowest_price` 1.49,
with no currency field. `/marketplace/stats` gave `{"value":1.33,"currency":"EUR"}`
for the same release, at the same moment. **Inferred:** the release figure was
not in EUR, possibly USD. That is **unverified**. Only `/marketplace/stats`
labels its currency.

## Master (`/masters/{id}`) — one call

- **Verified live:** `num_for_sale` (93) and `lowest_price` (1.49, unlabelled).
  Facts: `title`, `year`, `artists`, `genres`, `styles`, `tracklist`,
  `main_release`, `most_recent_release`, `versions_url`.
- **Not found at master level:** have, want, rating.
  - Not in the live responses, with or without a token.
  - The docs list no master stats or rating endpoint: the full list of URL
    templates was checked, and `/masters/{id}` and `/masters/{id}/versions`
    are the only master paths.
  - `/masters/{id}/versions` gives a per-version
    `stats.community.in_collection` / `in_wantlist`.
  - **Inferred:** adding those up needs one paged call per page of versions,
    and may not match the site's totals. **Owner, 2026-10-12: do not add them
    up.**
- **Not found:** median, highest, last sold.

## Other endpoints

- `/marketplace/stats/{release_id}`: `num_for_sale`, `lowest_price
  {value, currency}`, `blocked_from_sale`. **Verified live**, unauthenticated.
  The `joalla` fixture has the same shape.
- `/marketplace/price_suggestions/{release_id}`: suggested prices per condition
  (`joalla` `PriceSuggestions`).
  - Needs authentication: **secondary**. `disconnect` requires auth level 2,
    which a personal user token gives (`client.js:65-69`); `iomonad` agrees.
  - Needs the user's seller settings filled in, and returns an empty object
    otherwise: **secondary, `iomonad` only.**
  - These are suggestions, not sales data.
- `/releases/{id}/stats` (`num_have`, `num_want`) and `/releases/{id}/rating`:
  both duplicate what `/releases/{id}` already returns. **Docs.**

## Owner's authenticated run (2026-10-12, raw curl output, owner's machine)

- **`/releases/593568?curr_abbr=EUR` and `/masters/63790?curr_abbr=EUR`:** the
  same key set and the same values as the unauthenticated calls. No extra
  fields. `lowest_price` is still 1.49, with no currency label. **Verified
  (raw).**
  - **Caveat:** both endpoints also answer without authentication, so this run
    does not prove the token was actually sent.
- **`/marketplace/stats/593568` and `/marketplace/price_suggestions/593568`:**
  both returned `{"message":"Invalid consumer token. Please register an app
  before making requests."}`.
  - The same `/marketplace/stats` call **without** any `Authorization` header
    returned 200 for me, earlier the same day.
  - **Inferred, two candidates; not settled:**
    1. `$T` was empty or wrong in the owner's shell. The header was then
       `Discogs token=`, which Discogs rejects, while the database endpoints
       ignore it. Nothing in the run rules this out.
    2. The marketplace endpoints refuse personal tokens. That would contradict
       `disconnect` (`client.js:65-69`: a user token gives level 2, which is
       enough for `price_suggestions`).
  - **Settling test:** `echo ${#T}` (must be non-zero), then `/oauth/identity`
    with the same header (it needs auth, so a 200 proves the token works), then
    the stats call again.

### Settling test, run by the owner (2026-10-12)

- `${#T}` = 41.
- `/oauth/identity` → the same "Invalid consumer token" error.
- **Candidate 2 is dropped.** The failure is not marketplace-specific: identity
  fails as well.
- **Personal tokens do pass `/oauth/identity` in the plugin.** The settings
  token test learned the username (`claude/hardware-report-step-9b.md` §7), and
  decisions §9.2 measured `x-discogs-ratelimit: 60` with one.
- **Inferred:** the string in `$T` is not the token Discogs knows. Possibly one
  stray character (41 long), or an old or revoked token. **Unverified:** the
  expected token length.
- **Re-run with a re-entered token (`read -rs`, length 40) — settled:**
  - **The cause was the string in `$T`, not app registration.**
  - `/oauth/identity` → 200, the owner's username. **Verified (raw).**
  - `/marketplace/stats/593568?curr_abbr=EUR` with the personal token →
    `{"num_for_sale":54,"lowest_price":{"value":1.33,"currency":"EUR"},"blocked_from_sale":false}`.
    **Verified (raw).** These are the same three fields as without a token, so
    being logged in adds no sales statistics.
  - **No consumer key or secret is needed** for the marketplace stats call.
    §9.1 stands unchanged.
  - **Currency, now verified at both ends:** in the same session, `/releases`
    `lowest_price` (1.49) differs from the labelled €1.33. So the release figure
    is not EUR. **Which currency it is: unverified.**
  - `/marketplace/price_suggestions`: **not run** with the valid token.

## Full call set, run by the owner with a valid token (2026-10-12)

Raw `curl -i` output from the owner's machine, nine calls. All returned
`HTTP/2 200` with `x-discogs-ratelimit: 60`; usage rose from 0 to 8, one per
call. Each reply's fields were listed by script (every leaf path).

| call | what came back (verified, raw) |
|---|---|
| `/oauth/identity` | the owner's id and username |
| `/releases/593568?curr_abbr=EUR` | `community.have` 1622, `.want` 35, `.rating` 4.1 / 109; `num_for_sale` 54; **`lowest_price` 1.33** |
| `/releases/593568/stats` | **only `{"is_offensive":false}`**. The `num_have` / `num_want` that the docs promise are absent. The docs are out of date here. |
| `/releases/593568/rating` | `rating` 4.1 / 109, the same as in `/releases` |
| `/masters/63790?curr_abbr=EUR` | `num_for_sale` 93, **`lowest_price` 1.33**. No have, want or rating. |
| `/masters/63790/versions?per_page=3` | 16 versions over 6 pages; per-version `stats.community.in_collection` / `in_wantlist` and `stats.user.*`; filter facets |
| `/marketplace/stats/593568` (with and without `curr_abbr=EUR`) | identical: `num_for_sale` 54, `lowest_price {1.33, EUR}`, `blocked_from_sale` false |
| `/marketplace/price_suggestions/593568` | 200, eight conditions from Mint to Poor, each `{currency: EUR, value}`. For example, NM 10.00 and VG+ 7.65. |

**Conclusions:**

- **No endpoint returns sales history** (Last sold, Low / Median / High) or the
  highest price. That is now verified across every documented release, master
  and marketplace read endpoint, with valid authentication.
- **Currency.** With a valid token, `/releases` and `/masters` `lowest_price`
  (1.33) equals the labelled EUR figure. The earlier 1.49 came from calls whose
  token was invalid. **Inferred:** a valid token makes `lowest_price` follow the
  user's currency. That currency is not labelled in `/releases` / `/masters`,
  only in `/marketplace/stats`.
- **Price suggestions work for this account.** Whether this account has seller
  settings filled in is **unknown**, so the claim that they're empty without
  them (iomonad) is still unverified. They are suggestions, not sales.
- **The docs are wrong about `/releases/{id}/stats`.** It must not be relied on.
  Use `community.*` from `/releases`.
- **Responses carry `set-cookie`.** The plugin must not depend on cookies, and
  this file does not reproduce them.

## T1, run by the owner with a valid token (2026-10-12, raw output)

- **`/users/deschman`** → `curr_abbr: 'EUR'`. **Verified:** the user's Discogs
  currency is readable from the profile with the token.
- **`curr_abbr` is ignored** by `/releases/593568` and `/masters/63790`. With
  `USD`, `EUR` and `JPY`, `lowest_price` is 1.33 every time. **Verified.**
  - The docs' `curr_abbr` parameter on `/releases` has no effect, at least for a
    logged-in user.
  - **Inferred:** prices always come in the account's own currency. It matches
    the labelled €1.33 from `/marketplace/stats` and the profile's EUR.
- **Consequence:** a currency setting in SqueezeWax cannot change the prices.
  It could only mislabel them. Ruling 14's setting is unworkable.

### T1b: `/marketplace/stats` with `curr_abbr`, owner, logged in (raw)

- With `USD`: `{"value":1.49,"currency":"USD"}`. With `JPY`:
  `{"value":236.61,"currency":"JPY"}`. **Verified:** this endpoint honours
  `curr_abbr`.
- **So the behaviour differs by endpoint (verified, one account, one
  release):**
  - `/marketplace/stats` converts and labels the price;
  - `/releases` and `/masters` ignore `curr_abbr` and return the account
    currency, unlabelled.
  - This contradicts the docs for `/releases`. Whether Discogs means it is
    **unverified**; it is a question for Help Center request #1281019.
- **Explains the early 1.49:** the unauthenticated or broken-token `/releases`
  calls returned USD 1.49. **Inferred:** without a valid login, the price comes
  in USD and the parameter is ignored there too.
- **No change to ruling 15.** A currency of the user's choosing would need
  `/marketplace/stats`, which means a second request for Release details,
  rejected for wait time. For Master info there is no stats endpoint, so it
  isn't possible at all.

## foo_discogs, read

- **Endpoints it calls:** artists, database/search, masters, releases,
  releases/{id}/rating/{user}, users, oauth. **No marketplace endpoint**
  (grep of `*.cpp *.h` for `api.discogs.com/…`).
- **What it reads:**
  - Release: `community.have` / `want` / `rating.average` / `rating.count`
    (`discogs.cpp:1000-1008`), exposed as `DISCOGS_USERS_HAVE` / `_WANT` /
    `_AVG_RATING` / `_RATING_VOTES` (`discogs.h:892-896`).
  - Master: no have, want or rating.
  - Prices: none of any kind.
  - This matches our findings.
- **Authentication:** OAuth 1.0a, with a consumer key and secret compiled into
  the binary (`fetcher.h:8-9`, `fetcher.cpp:203`). This is the approach
  decisions §9.1 rejects for SqueezeWax (a shipped secret). It is **not a model
  to copy.** The values are not reproduced here.

## App registration

- **Owner's suggestion, 2026-10-12:** "we miss a marketplace app registration".
- **Recorded, decisions §9.1 "Application registration":** register SqueezeWax,
  **commit neither key nor secret**. The only stated purpose is Discogs'
  breaking-change emails.
- **Whether registration was ever done:** **unverified.** Not found in this
  search.
- **Whether a consumer key is needed for the marketplace:** **unverified**, and
  the settling test above decides it. If one is needed, §9.1's reasons still
  stand: a secret can't ship in a public plugin. Every user would then have to
  register their own app. That is a design change, for the owner.

## Where the evidence is thin

- The unauthenticated calls went through a summarising tool. The owner's calls
  are raw, but only the database ones succeeded.
- Whether the owner's token was actually sent is unknown (see the settling test).
- The docs text for Marketplace "Release Statistics" and "Price Suggestions" is
  missing.
- "Not found" means absent from the live responses, the docs text as summarised,
  three client libraries and foo_discogs. A field present only in a marketplace
  response with valid authentication would be missed.
- The currency of the unlabelled `lowest_price` is inferred, not verified.

## Effect on decision 61

The site's sales-history figures (Last sold, Low / Median / High, highest price)
were not found in the API by any route checked. Master have / want / rating are
not available, and are not to be added up (owner). The open question is only
whether the marketplace stats call (the labelled "from €X") works with the
user's token.

---

# Phase 0, part 2: terms, menu pattern, throttle (2026-10-12)

Sources and how strong each is:

- **TOU:** <https://support.discogs.com/hc/en-us/articles/360009334593>, read
  2026-10-12 through a summarising fetch.
- **LMS core:** `slimserver` at the pin `a670a38` (2026-06-19), read, not run.
- **SqueezeWax:** `v1-buildout` @ `5ceb5ef`, read, not run.

## Terms

- **Restricted Data includes "Marketplace Data … pricing suggestions … pricing …
  sales history".**
  - So `num_for_sale` and `lowest_price` are Restricted. That's **verified**
    for pricing; for the for-sale count it is **inferred** from "related
    inventory" and "including but not limited to".
- **Have / Want / rating appear in neither the CC0 list nor the Restricted list.**
  - Their class is **unclassified by the TOU**, not verified either way.
  - It does not change v1: they are "Content" whatever their class, so item 5
    (six hours, store no longer than necessary) applies to them as to prices.
- **Restricted-only rules:** no transfer to third parties, no commercial use,
  no ad platforms. A personal, self-hosted, free plugin meets these (inferred).
- **Six-hour rule versus fetch-on-open:** each open fetches live and stores
  nothing (§9.5).
  - LMS does **not** session-cache a menu list that contains code-backed items
    (`Slim/Control/XMLBrowser.pm:342-347`, "Don't cache if list has coderefs").
    So a reopened submenu is fetched again, not shown from a stale copy.
    **Inferred** from reading.
  - Design §7's "cache briefly" is **not needed**, so it is dropped.
- **Images** (release photos) are Restricted. v1 shows none.

## Menu pattern ("View tags")

- `Slim/Menu/TrackInfo.pm:1259-1274` `infoTagDump` returns
  `{ name, url => \&tagDump, passthrough => [...], isContextMenu => 1 }`.
  `tagDump` (`:1276-1358`) builds `type => 'text'` items and calls
  `$callback->($menu)`. **Verified (read).**
- `Slim/Control/XMLBrowser.pm:471-525`:
  - for a code-backed `url` it builds a callback and calls
    `$url->($client, $callback, \%args, @passthrough)`;
  - the reply goes on through `_cliQuerySubFeed_done`;
  - the request is marked processing up front (`:53`).
  - **Inferred:** the callback may be called later, after a Discogs reply, so
    an async fetch fits this pattern.
  - **Unverified until hardware:** whether Material and SqueezePlay wait
    15 seconds without giving up.
- The web UI has the same branch (`Slim/Web/XMLBrowser.pm:470`, `:1175`). Read,
  not run.
- **Paging risk (inferred):** since the list is not cached, each later page of
  the submenu may call the code again, which means another Discogs request. Our
  submenus are short, so it's likely one page each. **Hardware:** count requests
  per open in the log.
- **Core precedent for a code-backed item on the album menu:**
  `Slim/Menu/AlbumInfo.pm:576-600` `rescanAlbum`.

## Throttle and transport (ours)

- **Shared budget:** `API.pm:244-277`. `rateWait` returns seconds to wait;
  `noteResponse` takes the rate headers after each reply. **Verified (read).**
- **`API/Async.pm` `_get` / `_fire` / `_handle` (`:304-422`) belong to the sync.**
  They count requests on `$run`, retry 429s with `backoffFor`, and end a sync
  through `_fail`. They are **not a general request helper.**
- `Derive.pm` (`:366-498`) has its own `_fetch` / `_fire` / `_handle` over the
  same `API.pm` functions. **That is the precedent for step 10:** a third small
  caller, sharing `rateWait` / `noteResponse`, with `timeout => 15`.
- **When the budget is spent**, the sync waits `rateWait` seconds
  (`Async.pm:311-318`). For a menu, waiting would mean the submenu hangs. The
  plan decides.
- **Errors map cleanly** to `classifyResponse` (`API.pm:124-154`): 401, 404,
  429, 5xx, empty or malformed body, no response.
  - The HTTP status of "Invalid consumer token" was not captured (no `-i` in
    that run), so it is **unverified** whether it's a 401.

## Found while reading: the notice on players (compliance)

- §9.6 requires "Data provided by Discogs" **with a hyperlink** next to the data.
- §15.26 ruling 3: links don't open on players (SqueezePlay; `canFollowWeblinks`
  is false).
- So, on a player, a Discogs-data submenu can show the notice text but not a
  working link. **No decision record addresses this.** §15.26 ruling 4 put
  pressing details on players without mentioning it.
- **Unverified** whether text alone, or text plus the address as plain text,
  meets the TOU. This goes to the owner.

## Requests per open

| submenu | minimum | with a labelled currency |
|---|---|---|
| Release details | 1 (`/releases/{id}`) | 2 (+ `/marketplace/stats/{id}`) |
| Master info | 1 (`/masters/{id}`) | not possible: there is no master stats endpoint |

- The master's `lowest_price` can only be shown unlabelled, or labelled with a
  currency learned some other way. **Unverified:** whether any endpoint gives
  the user's currency. `/oauth/identity` didn't; `/users/{name}` is not checked.
