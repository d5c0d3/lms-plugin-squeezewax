# Build-order step 10: release details and master info, fetched on open

*Destination: `plans/build-order-step-10-details.md`.*

Written 2026-10-12 by the design chat. Input: decision 61
(`claude/decisions-step-10-scope.md`, rulings 1–12) and Phase 0
(`claude/phase0-step-10.md`).

- Base: `v1-buildout` at `5ceb5ef`, plugin 0.0.0.17.
- Pins: slimserver `a670a38`, `joalla/discogs_client` `58808df` (reference
  only).

**What it does.** Owned albums gain up to two submenus, in every app and on
players. Each submenu asks Discogs **only when opened**, with **one request**.
It shows a few lines, stores nothing, and ends with "Data provided by Discogs".
The sync also learns the user's Discogs currency, to label prices.

**What it does not do.** No request when the album menu itself opens. No
storage of Discogs data except one new pref (the currency label), no cache, no
schema change, no new setting. No change to the
ownership line, the links, the view or the sync. No price history, listings,
filters, price suggestions or estimated value.

## §0. Rulings (decision 61)

1. "Show your pressing's details" (called Release details below): `exact` albums only.
2. "Show master details" (called Master info below): `exact` or `version`, where
   `_effectiveMaster` gives an id. Labels and order: ruling 16.
3. Neither submenu on a `conflict` row. Same reason as its links (§15.26):
   its release id is not an answer.
4. **One request per open**, with no `curr_abbr` (Discogs ignores it, per T1).
   The price is labelled with the stored profile currency (ruling 15).
5. Budget spent → a "busy" line and no request (ruling 9).
6. Players: the notice plus the address as plain text (ruling 10).
7. No cache (ruling 11).

## §1. The album / track menu (`Menu.pm`)

`_itemFor` keeps today's rules for **when** a link or the ownership line
appears. It adds the submenus, **interleaved** after their links (decision 61,
ruling 16):

| # | `exact` (not conflict) | `version` (not conflict) | shown when |
|---|---|---|---|
| 1 | Discogs: Browse your pressing (link) | — (ruling 17) | link-capable, `exact`, `discogs_release_id` |
| 2 | Discogs: Show your pressing's details › | — | `exact`, `discogs_release_id` |
| 3 | Discogs: Browse all versions (link) | same | link-capable, `_effectiveMaster` |
| 4 | Discogs: Show master details › | same | `_effectiveMaster` |

- **Players, and link-capable apps with no link:** the ownership line first, as
  today, then rows 2 and 4 where they apply.
- **`conflict`:** as today, with no submenus.
- **`absent` or no row:** nothing.
- **Strings:**
  - the link labels **replace** `MENU_LINK_OWNED` and `MENU_LINK_MASTER`
    (texts only);
  - `MENU_LINK_FILES` is **retired**: `version` albums get no release link
    (ruling 17). This changes step 9b's matrix, so `menu-check.pl` part 1
    asserts that no `version` row ever carries a `/release/` weblink;
  - the new tokens are `MENU_DETAILS_RELEASE` and `MENU_DETAILS_MASTER`.

Each entry has core's "View tags" shape (`Slim/Menu/TrackInfo.pm:1259-1274`):

```
{ name => string(...), url => \&...::releaseDetails,
  passthrough => [ $releaseId ], isContextMenu => 1 }
```

- **Building the menu makes no request.** A code reference runs only when the
  entry is opened (`Slim/Control/XMLBrowser.pm:471-525`). `menu-check.pl`
  part 5 (zero requests) must stay green unchanged.
- The track menu gets the same entries. It goes through `_itemFor` already.

## §2. What each submenu shows

All lines are `type => 'text'`. One line per row, in this order. A line whose
source field is missing or empty is left out, never shown blank.

**Release details** (from `/releases/{id}`):

1. Label – cat. no., from `labels[0].name`, `labels[0].catno`.
2. Format · country · date, from `formats[0].name` + `descriptions`, `country`,
   `released_formatted`.
3. Genre · styles, from `genres`, `styles`.
4. Have N · Want N, from `community.have`, `.want`.
5. Rating A / 5 (C ratings), from `community.rating.average`, `.count`.
6. For sale: N, from X C, from `num_for_sale`, `lowest_price`, and C (the pref
   `discogsCurrency`). With N = 0 or the price null: "None for sale". With no C
   stored: "For sale: N" only.
7. Notice (see §2.1).

**Master info** (from `/masters/{id}`):

1. Year, from `year`.
2. Genre · styles, from `genres`, `styles`.
3. For sale: N, from X C, by the same rules as line 6 above.
4. Notice.

### §2.1 The notice

- **Link-capable apps** (the same test `_itemFor` uses today):
  `{ type => 'text', name => 'Data provided by Discogs', weblink => <uri> }`.
  `<uri>` is the reply's own `uri` field (§9.5: "the payload carries uri").
  Like today's links, no `rel`.
- **Otherwise (players):** two lines, "Data provided by Discogs" and the address
  as plain text, without `https://`.
- **Unverified** whether the plain address meets the TOU (ruling 10). The
  question goes to Help Center request #1281019.

### §2.2 Number formats

- **Price:** two decimals, then the currency code as Discogs sends it, e.g.
  "from 1.33 EUR". No symbol mapping, so nothing to get wrong per currency.
- **Rating:** one decimal.
- **Counts:** as given.

## §3. Fetching (new module, `Details.pm`)

- **A third small caller**, with the same shape as `Derive.pm`
  `_fetch` / `_fire` / `_handle` (`:366-498`). It shares `API->buildRequest`,
  `classifyResponse`, `rateWait` and `noteResponse`. It does **not** reuse
  `API/Async.pm`'s `_get`, which belongs to the sync (`$run`, `_fail`).
- **One request per open.** Before it, if `API->rateWait` is non-zero, make no
  request and show only the busy line, with N = that wait.
- **No retry.** A 429 on a menu means "busy".
- **`timeout => 15`**, as the sync and Derive use. Worst case 15 s. Hardware
  decides whether apps wait that long (§7).
- **Token:** read from the prefs as the sync does. With no token: one line,
  "Add your Discogs token in Settings", and no request.
- **Nothing is written anywhere:** no table, no prefs, no cache on disk. Since
  hardware report 64 a reply is held in memory for up to 2 minutes (decisions
  §15.33).
- **Logging:** one INFO line per request (path and outcome), so hardware can
  count requests per open.

## §4. Errors, as one text line each

| `classifyResponse` result | line |
|---|---|
| `rate_limited`, or `rateWait` > 0 | "Discogs is busy, try again in N s" |
| `unauthorized` | "Discogs rejected the token – check Settings" |
| `not_found` | "Not found on Discogs" |
| `no_response`, `server_error`, `empty_body`, `malformed_json`, `unknown` | "Discogs did not answer – try again" |

- **On any failure:** only the error line is shown, with no notice, because no
  Discogs data is shown.

## §4b. The currency label (`Settings.pm`, `API/Async.pm`, `Plugin.pm`)

> Amended: Test token no longer asks for the currency; only the sync does (decisions §15.35).

Decision 61, ruling 15.

- **New pref `discogsCurrency`** (string, default `''`). It is written only
  where `discogsUsername` is written today:
  - **token test** (`Settings.pm:406-413`): after a successful identity, one
    `/users/{username}` request; store its `curr_abbr` if non-empty;
  - **server sync** (`API/Async.pm` `_gotIdentity`, `:424-447`): the same
    request, before the first collection page.
- **Never fatal.** A failed or empty profile reply keeps the old value, and the
  token test or sync carries on as today. The request goes through the shared
  budget (`rateWait` / `noteResponse`), like every other request.
- **Cleared with the username** when the token changes (`Plugin.pm:64-78`).
- **The scan-time sync (`API/Sync.pm`) does not write it**, as it doesn't
  write the username. Unverified whether scanner-side prefs reach the server.
- **Cost:** +1 request per server sync and per token test. Prices themselves
  stay live, one request per open.
- **Rejected (T1):** a currency setting, because Discogs ignores `curr_abbr`.
  Also rejected: holding the label in memory with a 6-hour refresh (owner).

## §5. Strings (`strings.txt`)

New `PLUGIN_SQUEEZEWAX_` tokens:

- the two entry names, and the three link labels reworded (§1);
- one per line label in §2;
- the four error lines in §4, and the no-token line;
- `DETAILS_NOTICE` "Data provided by Discogs".

Labels are descriptive; no brand use (design §1).

## §6. Suite

`menu-check.pl` (extended) and a new `details-check.pl`, with HTTP stubbed at
`SimpleAsyncHTTP` as `queue-check.pl` does:

1. **The menu matrix:** `exact` / `version` / `conflict` / `absent`, crossed with
   release id present or not, and master usable / stale / absent. Assert which
   entries appear (§1 table). **Building any menu makes zero requests**
   (part 5, unchanged).
2. **Release details opened:** exactly 1 request, `/releases/{id}`, with no
   `curr_abbr`, plus the token and User-Agent. The price is labelled with
   `discogsCurrency`; with the pref empty, the line shows the count only.
   - The lines follow §2, using fixtures cut from the owner's real replies
     (`claude/phase0-step-10.md`, album E).
3. **Master info opened:** exactly 1 request, `/masters/{id}`, with the same
   label rules.
4. **Busy:** with `rateWait` > 0 at open, zero requests and the busy line.
5. **Each error class** gives its line, and the notice only when data is shown.
6. **Notice:**
   - link-capable → one item with `weblink` = the reply's `uri`, and no `rel`
     anywhere;
   - player (stub client, player User-Agent, as in step 9b) → the text line and
     the plain address, with **no `weblink`**.
7. **No token:** zero requests, the token line.
8. **Currency pref:**
   - the token test and the async sync each make one `/users/{username}`
     request and store `curr_abbr`;
   - a failing profile call leaves the sync's result and the token test's
     message unchanged, and keeps the old value;
   - a token change clears it.
9. **Nothing stored:** the row count of every `squeezewax.*` table, and the
   prefs, are unchanged after each open.
10. **Every `noteResponse` call** happens once per reply, including error replies.

## §7. Hardware (owner-led, short)

1. **Log level first** (working agreement §4.1): `plugin.squeezewax` at INFO.
2. **Material:**
   - Album E: four rows in §1's order and wording. Open each submenu. The lines
     match §2, and the notice is a link that opens the Discogs page.
   - V1: "Browse all versions" and "Show master details" only, with **no**
     release link.
   - V2 / A: no entries.
3. **Default UI:** the same, via album info.
4. **SqueezePlay:**
   - E shows the ownership line plus both submenus.
   - Opened, they show text lines, the notice and the plain address, with no
     link row.
   - **Does SqueezePlay wait for the replies?**
5. **Requests per open:** the log shows exactly 1 per open, and 0 when the album
   menu opens without a submenu.
   - Paging: if Material asks again for a second page, record it. Inferred not
     to happen (short lists).
6. **Busy:** press "Sync collection now", then open Release details at once.
   Expect the busy line, or normal lines if the budget allows. Record which.
7. **Token removed** (then restored): the token line.
8. **Currency:**
   - After "Test token", Release details shows "… EUR".
   - Change the token: the price line shows the count only, until the next test
     or sync.

## §8. Docs edits (in the build)

- **decisions §15.31:** decision 61 rulings 1–15, verbatim, with 12 and 14 marked superseded, plus the Phase 0
  summary.
- **design:**
  - §4: the menu list gains the two entries; estimated value is struck,
    "removed, §15.31".
  - §7: rewritten to §2 above. Listing, filters and cache are struck as
    "dropped, §15.31".
  - §9: "Marketplace preferences" struck.
  - §11: add v2 items — master info for unowned albums, owned-version menus,
    "Add to Discogs wantlist".
- **TODO.md:**
  - Close 2026-09-13 "minimum scope".
  - Add the Help Center follow-up (ruling 10).
  - Add the §7 hardware items.
- **CLAUDE.md:** step 10's line points at this plan.

## §9. Phasing

| | |
|---|---|
| P | §8's doc edits, and this plan into `plans/` |
| A | `Details.pm` and the fixtures; `details-check.pl` parts 2–7, 9, 10 |
| B | `Menu.pm` entries and strings; `menu-check.pl` part 1 |
| C | the currency label (§4b) and suite part 8 |

**T1 is done** (decision 61, ruling 15): the profile carries `curr_abbr`, and
`curr_abbr` is ignored on `/releases` and `/masters`.

Then package **0.0.0.18**. The open on-screen check of 0.0.0.17 is done at the
same hardware session (`TODO.md`, 2026-10-12).

## §10. Where the evidence is thin

- **The async callback in menus is read, not run** (XMLBrowser `:471-525`).
  Whether Material, SqueezePlay and the Default UI wait up to 15 s is unknown.
  This is §7.4.
- **Paging re-fetch** is inferred from "lists with code are not cached"
  (`:342-347`). Observed in report 64 (10 requests in 13 s); answered by the
  2-minute hold, decisions §15.33.
- **The price follows the account currency.** Inferred from T1, one account
  (EUR): the parameter is ignored, and 1.33 equals the labelled €1.33.
- **A stored label can lag** if the user changes currency on Discogs. This is an
  accepted risk (ruling 15).
- **Scanner-side prefs reaching the server** is unverified. That's why the
  scan-time sync doesn't write the pref.
- **The plain-address notice on players** is not confirmed by Discogs.
- **Have / Want / rating are not classed by the TOU.** They are treated as
  Content: live, never stored.
- **The fixtures are one release and one master.** Fields missing on other
  releases (no label, no `released_formatted`, an empty `genres`) are handled
  by §2's "leave out the line" rule. That rule is not tested against real
  variety.
