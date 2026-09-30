# Build-order step 9: the ownership menu and the "Records I own" view

Written 2026-09-29 by the design chat. Input: the step 9 session brief; hand-offs
34 (Phase 0), 35 (options), 36 (the survey's rulings). Records land as decisions
§15.25.

Base: `v1-buildout` at `aea0f1c`, `check-all.sh` 1811 green, plugin 0.0.0.13.
LMS pin: slimserver `a670a38c2b14ad42b86a39884bcb842121b35571`. Material checked at
`47e31ed`. Line numbers are for those commits; locate by symbol on `public/9.1`
(working agreement §6).

**What this step does.** It makes ownership visible for the first time, in three
places, all built once for every skin:

1. **An album menu entry.** On an owned album: one line saying what you own, and a
   link to the Discogs page where an id is stored.
2. **The same entry in the playing track's menu** (Now Playing).
3. **A "Records I own" library view.** The normal album grid, filtered to owned
   albums.

Plus two lines on the settings page: both mandatory Discogs notices, and the
derive-job status.

**What it does not do.** No badge on artwork: no skin offers a hook (34). No Discogs data in the menu: no label, catalogue
number, format, year, credits or value. No Re-match in the menu. No new setting.
No schema change. **No new Discogs request anywhere.** The username for the
settings link comes from identity calls the server already makes (§4, D4).

---

## §0. What this plan rests on

### §0.1 Rulings (decisions §15.25, from hand-off 36)

1. **No artwork badge in v1.** Verified for the Default UI and Material: the only
   cover icon is keyed on `albums.extid`, one per album, and it means "which
   service this album came from" (34). A plugin cannot add a second one, and
   writing `albums.extid` breaks the album (`Slim/Schema/Album.pm:78`). The
   request for a hook goes to `TODO.md`.
2. **Menu (A) + library view (B).** The view is a library, not an app. An app is
   recorded as a future feature (Flow 2, v3).
3. **The menu appears on owned albums only** (`ownership` `exact` or `version`).
4. **The menu carries no Discogs data.** It shows our conclusion and a link.
   "Data provided by Discogs" and "not affiliated…" both go on the settings page.
   This is compliant only because nothing next to the link is Discogs data. Adding
   any Discogs field to the menu later brings the notice back into the menu.
5. **Links:** `exact` → the release page; `version` → the master page, **only
   where a master id is already stored**. Otherwise no link.
6. **Value → step 10.** **Re-match → not in the menu.** **No new settings.**
7. **Now Playing = the track menu.**
8. **The derive status line** goes on the settings page.
9. **Artist-level badge: v3** (design §11). The brief's "likely v2" is wrong.

### §0.2 Defaults this plan applies, derived rather than decided

D1–D3 were proposed as defaults and **accepted by the user at the plan review
(2026-09-29)**; D4 was put as a question and answered.

- **D1 — identity by `album_key`, never by `lms_album_id`.** Found while writing
  this plan. **Verified:** the importer's skip path (`Importer.pm:275-278`) and its
  all-remote path (`:268-271`) return without touching the row, and the pass never
  names `lms_album_id` in an UPDATE (`Ownership.pm:922-940`). So after LMS
  reassigns `albums.id` (full wipe, or a retitle that re-creates the album), every
  unchanged album's `lms_album_id` goes stale. Design §10's "refreshed whenever a
  rescan completes" is **not true of the code**, and `TODO.md`'s "`lms_album_id`
  refresh" item is still open. A menu or view keyed on it would show the **wrong
  album as owned**, silently. So both key on `album_key`, computed from the
  album's tracks exactly as `Library::_finish` does. Design §10 gets the
  correction.
- **D2 — the version link describes the album, not the copy.** `_effectiveMaster`
  (`Ownership.pm:371-384`) returns the master of the *identified* release. A
  `version` album can reach its badge by the title route (node H) while its tags
  name a release under a *different* master. Then that master is not the one the
  user owns. Nothing stored says which node decided, and the collection is gone
  (§13.2). So the link is labelled as the album's page ("This album on Discogs"),
  never as "your version". It is accurate in both cases. **Inferred** to be rare:
  node H needs the titles to agree. Not measured.
- **D3 — a "Records I own" entry under My Music** as the way into the view,
  following core's `LibraryDemo` (`Slim/Plugin/LibraryDemo/Plugin.pm`,
  `registerNode` with `params => { library_id => … }`). Without it the only way in
  is switching the player's whole library.
- **D4 — decided by the user: the settings-page link points to the user's
  collection page, and the username is stored in a pref.** The terms want "the
  discogs.com page that includes the data", and for ownership that is the
  collection. The username is Restricted "Discogs User Data". Keeping it is
  accepted by the user (2026-09-29) as necessary to provide the link (§9.5's
  necessity test): it is the user's own name, on their own server, next to the
  token that is already stored. **Superseded the same day:** "fetched at render,
  never stored" (one request per page view). The URL form
  `https://www.discogs.com/user/{username}/collection` is **unverified**, a
  hardware check.

### §0.3 What earlier steps establish and this must honour

- **design §382 / §10:** the badge reads `ownership`. Here, "badge" means the menu
  line and view membership. `exact` and `version` alike; no state test, no
  confirmation test, no join against anything Discogs.
- **§9.5:** store conclusions, not Content. This step stores nothing and fetches
  nothing.
- **§15.16 part 4:** a `conflict` row is untagged to the pass. Its release id is
  **not** an answer: no release link on a `conflict` row, whatever its ownership.
- **§14.10:** the owned collection entry's id is not kept. No migration here.
- **§382's reason:** nothing may make a grid page slow. Here nothing runs per
  tile: the view is built once per pass, the menu once per open.
- **§2a:** nothing here writes `discogs_match`.
- **Calling convention** (`CLAUDE.md`): public subs are class methods, `_`
  helpers plain functions.

### §0.4 Amendments this step makes to the record

| Record | Change (strikethrough-and-correction, reason kept) |
|---|---|
| design §4 | Corner overlay, "skin-independent by design", Now Playing overlay, "Rendering note" → no hook exists (34); v1 shows ownership in the album/track menu and a library view. Menu list: pressing details, credits → cut from v1 (notice placement); value → step 10; Re-match "always available" → not in v1. |
| design §9 "Badge" | Four settings struck; the owned colour returns only with a cover badge. |
| design §9 "Collection / value" | Adds the derive status line and the two notices. |
| design §10 | `lms_album_id` "refreshed whenever a rescan completes" → it is not (D1). |
| design §11 v1 | "Owned badge (grid + Now Playing) with badge context menu (pressing details, credits, on-demand value, Discogs link-out)" → as built. The app goes into v3 beside Flow 2. |
| design §12 | The skin-independence follow-up is answered (34). |
| decisions §9.6 | "a step-6 UI decision" is answered by §15.25. |
| `CLAUDE.md` build order | Step 9's title → "Ownership menu + owned library view". |

### §0.5 Phase 0 (design chat, 2026-09-29, read-only)

All **verified** at the pins unless marked.

| Need | API | Where |
|---|---|---|
| album menu entry | `Slim::Menu::AlbumInfo->registerInfoProvider( name => ( after/before/isa, func ) )` | `Slim/Menu/Base.pm:89`; example `Slim/Plugin/Favorites/Plugin.pm:96` |
| its callback | `func->( $client, $url, $album, $remoteMeta, $tags, $filter )` | `Slim/Menu/AlbumInfo.pm:162` |
| track menu entry | `Slim::Menu::TrackInfo->registerInfoProvider`, callback `( $client, $url, $track, $remoteMeta, $tags, $filter )` | `Slim/Menu/TrackInfo.pm:286` |
| a link item | `{ type => 'text', name => …, weblink => $url }` | core's own: `TrackInfo.pm:1197-1202`; passed through `Slim/Control/XMLBrowser.pm:1153-1154`; Default opens it (`HTML/Default/xmlbrowser.html`, `weblink` block, `target="_blank"`, no `rel`); Material opens it (`browse-functions.js:1186`, `openWebLink`) |
| Material shows album info | `albuminfo items` under "More" | `browse-page.js:1272` |
| library view | `Slim::Music::VirtualLibraries->registerLibrary({ id, name, string?, sql or scannerCB, priority? })` | `Slim/Music/VirtualLibraries.pm:150-238` |
| rebuild it | `->rebuild($id)`; wipes then refills `library_track`, then `library_album`/`library_contributor` | `:296-360` |
| registering mid-scan | logs an error but registers; builds only if empty and not scanning | `:213-235` |
| scan-time rebuilds | `startScan` at importer weight 100 (`init`), before our scan pass at 130 — so a scan-time rebuild would use the **previous** ownership | `VirtualLibraries.pm` `init`; `ScanSync.pm` |
| full wipe | clears `library_track` | `SQL/SQLite/schema_clear.sql:29` |
| Material library picker | lists `libraries` | `player-settings.js:137`, `browse-page.js:1643` |
| My Music entry | `Slim::Menu::BrowseLibrary->registerNode({ type => 'link', name, params => { library_id }, feed => \&Slim::Menu::BrowseLibrary::_albums, icon, id, weight })` | `Slim/Plugin/LibraryDemo/Plugin.pm` |

**Unverified, carried to hardware:** the Default UI's library picker; whether
Material's My Music shows a `registerNode` entry; Jivelite's handling of either;
`https://www.discogs.com/master/{id}` redirecting (captured payloads show
`/master/{id}-{slug}`; the release form's redirect is observed, §15.16).

---

## §1. Group A — one album's key (`Library.pm`)

A public `albumKey($albumId)`, returning the `album_key` of one LMS album, or undef
for an album with no qualifying tracks.

- **Same construction as `_finish`**, and it must not be a second copy of it: the
  qualifying predicate (`t.audio = 1`, `t.content_type NOT IN (…)`,
  `ORDER BY t.urlmd5`) is factored out of `$ALBUM_TRACKS_SQL` so both read one
  definition. A drifted copy yields a key that matches no row, so an owned album
  silently loses its menu.
- One indexed query per call. Called once per menu open, never per tile.

Suite: for **every** album the fixture library holds, `albumKey(id)` equals the key
`eachAlbum` produced. Assert across the whole set, not a sample.

---

## §2. Group B — the menu entry (new `SqueezeWax/Menu.pm`)

Registered from `Plugin.pm`'s `initPlugin`, server only. The album and track
providers share one function; the track provider resolves `$track->album` first
and returns nothing when there is none (a stream not in the library).

**Lookup:** `albumKey` → one `SELECT` by `album_key` on
`squeezewax.discogs_match`. Read-only.

| Row | Menu |
|---|---|
| none, or `ownership = 'absent'` | nothing (return undef) |
| `exact`, not `conflict`, release id present | "You own this pressing" + link "This album on Discogs" → `https://www.discogs.com/release/{discogs_release_id}` |
| `exact` otherwise | "You own this pressing", no link. **Inferred** unreachable (a conflict skips node C, `Ownership.pm:419-423`). Handled, not asserted impossible |
| `version`, `_effectiveMaster` defined, not `conflict` | "You own a version of this record" + link "This album on Discogs" → `https://www.discogs.com/master/{id}` |
| `version` otherwise | "You own a version of this record", no link |

- `_effectiveMaster` is **called**, not re-implemented. It is the stale-derivation
  guard (`Ownership.pm:357-368`), and a copy without it links a retagged album to
  its old master.
- Strings: `PLUGIN_SQUEEZEWAX_MENU_*`. Labels are descriptive only (design §1
  brand rules). "Discogs" never appears as a mark or a logo.
- Items are plain `text` with `weblink`, the core shape. No `nofollow` anywhere; no
  `rel` is added.
- **No Discogs request.** No `API::*` call is reachable from `Menu.pm`. The suite
  asserts it with a transport stub that fails on any call.

---

## §3. Group C — the "Records I own" view (new `SqueezeWax/View.pm`)

- **Registered in the server only**, from `initPlugin`, with a `scannerCB`, not
  `sql`: D1 forbids joining on `lms_album_id`. The callback reads the owned
  `album_key`s (one `SELECT` over `ownership IN ('exact','version')`), walks
  `Library->eachAlbum`, collects the current `album_id`s whose key is owned, and
  inserts their tracks into `library_track` for the given library id. **Every**
  track of an owned album goes in, including remote ones: a rip and a stream of one
  record are two owned albums (§13.10.3).
- **Not registered in the scanner.** Its scan-time rebuild runs at weight 100,
  before our pass at 130, so it would always be one pass behind.
- **Rebuilt after every completed pass.** From the server: after
  `Ownership->apply` returns `ok` in `API/Async.pm`'s sync path, and from the
  existing `['rescan','done']` handler (`Plugin.pm:280`), which covers the scanner's
  pass (`ScanSync.pm`) and a full wipe. Rebuild is local SQL, no request. Refused
  while a scan runs; the scan's own `rescan done` rebuilds afterwards.
- Name via a string token (`string =>`, `VirtualLibraries.pm:482-491`):
  `PLUGIN_SQUEEZEWAX_LIBRARY_OWNED`, "Records I own".
- **D3:** a My Music node, "Records I own", `feed => _albums`, `params =>
  { library_id => getRealId(…) }`, as `LibraryDemo` does.
- An empty view (no token, never synced) is an empty library, not an error.

---

## §4. Group D — the settings page (`Settings.pm`, `settings.html`)

1. **Both notices**, verbatim from decisions §9.6, in their own block:
   - "This application uses Discogs' API but is not affiliated with, sponsored or
     endorsed by Discogs. 'Discogs' is a trademark of Zink Media, LLC."
   - "Data provided by Discogs.", linked to the user's collection page (D4).
     **No request at render.** A new pref, `discogsUsername`, holds the username
     from any `GET /oauth/identity` the server already makes: the token test
     (`Settings.pm` `_tokenTested`) and the async sync (`API/Async.pm`
     `_gotIdentity`). The scanner does not write it: server prefs are not the
     scanner's to write. It is **cleared when the token changes**, in the same
     `setChange` that already reacts to `discogsToken` (`Plugin.pm`). Empty
     username → the link falls back to `https://www.discogs.com/`. On a server
     whose syncs all happen in the scan (§15.18 part 8) the name arrives only at
     the next token test; the fallback covers the gap. **No `rel="nofollow"`.** The page's
     existing links use `rel="noopener"` (`settings.html:13-14`). That is allowed,
     but the plan asks for no `rel` on this link at all, so there is nothing to
     argue about.
2. **Derive status**, next to "last synced": when releases are pending, "Deriving
   masters: N of M releases" (with "running" or "waiting" from
   `Derive->isRunning`, `Derive.pm:182`); nothing when none are pending. N and M
   come from one query at render, reusing `_pending`'s predicate
   (`Derive.pm:243-255`) as a count. The predicate is factored, not copied. No new
   state. Closes `TODO.md` 2026-09-29 "a derive session is invisible".

The same two notices also go into the repository README / usage documentation.

---

## §5. The seam suite — `scripts/menu-check.pl`

New, picked up by `check-all.sh`. Honest stubs following `queue-check.pl`.

1. **Key agreement:** §1's whole-set assertion.
2. **The table in §2**, row by row, including the stale derivation (no link),
   `conflict` with a release id (no release link), and absent/no-row (no entry).
3. **D1 made testable:** build a fixture, then reassign `albums.id` for an owned
   album *without* touching `discogs_match`. The menu still finds it; the view
   still holds its tracks. An album now holding the old id is **not** shown as
   owned.
4. **The view equals the owned set:** its albums are exactly the owned keys'
   current albums, rip and stream both. It is rebuilt after `apply`, and a
   `version` → `absent` change drops the album.
5. **Zero requests:** a failing transport stub over the whole suite. The
   username: written by the token test and the async sync's identity step;
   cleared when the token changes; the fallback link when it is empty; never
   written to the database.
6. **Derive line:** counts against a fixture with pending, settled and stale rows.

---

## §6. Model and phasing for Claude Code

**Model: Opus.** The one failure here is silent: the wrong album shown as owned
(D1, D2). The working agreement's rule for that is Opus.

| | |
|---|---|
| P | this plan, decisions §15.25, the §0.4 doc edits, TODO edits (pre-cut, hand-off 38) |
| A | `Library::albumKey` + the factored predicate (+`library-check.pl`, `menu-check.pl` part 1) |
| B | `Menu.pm`, both providers, strings (+`menu-check.pl` 2, 5) |
| C | the view, its rebuild hooks, the My Music node (+`menu-check.pl` 3, 4) |
| D | settings notices, derive line, README notices (+`settings-check.pl`, `menu-check.pl` 6) |
| E | `CLAUDE.md` step 9 status, TODO ticks |

Each phase committed before the next. Then a package build for §7.

---

## §7. Hardware checks (after merge, reference server)

0. **Before.** Back up both databases; record ownership counts (expect 150
   `exact`, 54 `version`, 302 `absent`).
1. **Album menu, Material and Default**, on four albums: an `exact` (release link
   opens the right page); a `version` with a stored master (master link opens —
   **settles the `/master/{id}` redirect**); a `version` without (line, no link); an
   `absent` (no entry).
2. **Track menu** from Now Playing, same four.
3. **Nothing asks Discogs:** open menus with the log at INFO; zero requests.
4. **The view:** appears in Material's library picker and in the Default UI's
   (**settles the unverified picker**); the My Music entry appears in both. Album
   count = owned albums (204 expected, less any album LMS merges). Spot-check a rip
   and a stream of one record: both present.
5. **Rebuild:** press "Sync collection now" after changing the collection by one
   record; the view follows without a rescan. Then a rescan: the view survives.
6. **D1 on hardware** — record whether it can be provoked (a retitle that
   re-creates an album). If not, `TODO.md`, not "pass".
7. **Settings page:** both notices present; the link opens **your collection
   page** (settles the URL form) and carries no `nofollow` (view source); after
   a token test the link carries your username; changing the token clears it; the derive line appears during a derive run and disappears after.
8. **Jivelite / a player**, if the owner has one: does the entry show? Does the
   view? Photo either way. Settles the logo question from 35 as a side effect.
9. **Timings:** menu open, and view rebuild on this library.

Anything that cannot be provoked goes to `TODO.md` rather than being marked
passed.

---

## §8. Open at the plan review

Nothing. D1–D4 were settled 2026-09-29 (§0.2).

The decisions record carries one new pref, `discogsUsername`, and the finding that
the token test bypasses the shared rate state (not changed here).

## §9. Where the evidence is thin

- Default UI picker, Material's My Music handling of a plugin node, Jivelite: not
  read (§0.5).
- D2's frequency is inferred, not measured.
- The master URL form is inferred from captured `uri` fields; the release form's
  redirect is one user observation (§15.16).
- One library, one collection, as always.
