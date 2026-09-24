# Build-order step 8: review queue + manual re-match

**Status:** plan, drafted in the design chat 2026-09-24, revised the same day
on Claude Code's Phase 0 report (§0.5). Code: none yet. Checked against
`d5c0d3/lms-plugin-squeezewax` `v1-buildout` at `97a7062`, slimserver
`a670a38c2b14ad42b86a39884bcb842121b35571` (the same pin as every prior step),
and `refs/Spotty-Plugin` at `57c29c6` (Phase 0; the design chat first read
`68fd614`, and the cited lines match at both).

Every claim carries a tag: **verified** (read in source, cited), **observed**
(run, environment named), **inferred** (reasoned from reading, not run), or
**unverified**. Items marked **DEFAULT** were not chosen by the user; they are
the plan's default and are open at review.

Baseline, **observed** 2026-09-24 twice (design chat's clone; Phase 0):
`scripts/check-all.sh` → 882 assertions, all green.

---

## §0. What this plan rests on

### §0.1 Rulings taken in this session (2026-09-24) — decisions §15.16

- **R1 Home.** The queue is its own plugin web page, not a section of the
  settings page and not the LMS menu system. Web UI only, like the settings
  page (`Plugin.pm` loads `Settings.pm` only under `main::WEBUI`). Precedents,
  all **verified**:
  - `Slim/Web/Settings/Server/Status.pm` — no `prefs()` (inherits the empty
    base), dispatches on its own action (`abortScan`, `:26`), never tests
    `saveSettings`; its template sets `nosubmit = 1` (`status.html:44`) and
    uses the standard header and footer. **The closest precedent: the queue
    page's exact shape.**
  - `Slim/Plugin/OnlineLibrary/EditGenreMappings.pm:19-22` — overrides `new`
    to `addPageFunction` only, with no `SUPER::new`, which keeps it out of the
    settings menu; constructed from `Slim/Plugin/OnlineLibrary/Settings.pm:23`;
    linked from `Slim/Plugin/OnlineLibrary/HTML/EN/plugins/OnlineLibrary/settings.html:77`.
  - Spotty `Settings/Auth.pm:26-32` (registration `:29-31`), constructed from
    `Settings.pm:24`.
- **R2 One reason column, `review_reason`.** Shared by writers under a fixed
  precedence (R3). Six values: `conflict` (importer), `ambiguous`,
  `artist-disagree`, `artist-absent`, `various-gated`, `orphan` (ownership
  pass). TODO 2026-09-19 specified four; `conflict` and `orphan` are a
  deliberate widening by R3/R5.
- **R3 Precedence: `conflict` is sticky.** Only the importer writes or clears
  it. The pass never overwrites it. The importer clears it on a clean
  identification (`_recordMatch`). The pass's values are re-derived every
  sync. The importer also clears `orphan` when it relinks the row.
- **R4 A conflict row does not badge from its incumbent id.** The pass treats a
  row whose `review_reason = 'conflict'` as untagged: it skips node C, never
  writes its `state`, and the title route alone decides `ownership`. Amends
  §15.3. **Two kinds of conflict, stated separately (Phase 0 C4):**
  - a **fresh** conflict (NULL release id) is already untagged today
    (`Ownership.pm:338` requires a release id) — R4 changes nothing for it;
  - an **incumbent** conflict (§3a's demotion keeps the release id,
    `Match.pm:612-614`) is tagged today and, being strict, can be promoted to
    `confirmed` at `Ownership.pm:351`. R4 stops that. Closes TODO 2026-09-19
    "a conflict row with an incumbent id looks like a tagged candidate" and
    restores §3a's intent. The comment at `Ownership.pm:334-337` ("a conflict
    row has … a NULL release id, so it is not tagged") is false for this kind;
    B1 corrects it.
- **R5 Orphans are a separate list on the same page.** §13.10.5 stays the
  exhaustive list for the review queue, minus R8. The pass marks orphans
  `orphan`, because it already sees them (`Ownership.pm:512-517`,
  **verified**). **Manual orphans included** — see D1.
- **R6 Manual re-match chooses from the user's own Discogs collection. It never
  searches Discogs and never offers a release the user does not own.** Premise:
  a well-maintained collection and well-tagged rips (design §3, §14.4).
  Amends design §3's "search-as-you-type against Discogs".
  - **Fetch:** opening re-match runs a normal collection sync (the same
    requests as the button: 1 identity + `ceil(items/100)`; **observed** 4 for
    203 items). The pass runs as usual; the entry list is also handed to the
    page for one render and then dropped — the same lifetime §15.13 part 1
    gives the pass. Nothing is stored (§13.2, §9.5).
  - **Choices:** first the entries whose title key matches the album's
    (`Ownership::_titleKey`), then the whole collection with a filter box
    (client-side, over what was rendered — no request per keystroke; with
    JavaScript off the full list is shown).
  - **Fields, fixed set:** title, artists, year, format, label with catalogue
    number, release id, and the "Data provided by Discogs" link (§3.3). A
    user-configurable field picker is recorded as a possible future feature,
    not built. Images are excluded: whether and how they may be shown is
    **unverified** against Discogs' terms (§9.9 already records that image
    URLs are withheld without authentication).
  - **Two copies of one release show twice** — one row per collection
    instance, as the sync keys them (`API/Async.pm:532-536`). Either row links
    the same release.
  - **Consequence, stated:** the collection is gone by the time the user
    presses confirm, so the badge changes at the next sync, not at confirm.
    The page says so.
- **R7 Reject deletes the row.** For TODO 2026-09-07 grounds (a) and (b), and
  for orphans. A user-invoked deletion, justified as §10.4 justifies clear &
  rebuild: invariant 2 governs automatic deletion; this is explicit, confirmed
  and single-row. Recorded as the **third permitted deletion** in
  `discogs_match`. Ground (a) now means the **incumbent** conflict only: a
  fresh conflict whose tags are removed is already deleted by `Match.pm:673-683`
  (asserted `match-check.pl:441-443`), and that deletion is unchanged. **No
  stored dismiss:** a computed item (ambiguous, artist, gated) leaves the queue
  only through a manual link or a change in tags or collection, so the queue
  cannot become the wrong-badge recovery path §14.4 rules out.
- **R8 §13.5's all-tags read is deferred past step 8, possibly for good.** v1's
  review queue holds three contents: ambiguous matches, artist disagreement or
  absence, and Strict conflicts. Amends §13.5 and §13.10.5. §15.13 part 7's
  accepted gap becomes v1's: an owned album whose later tracks carry a
  different release id can badge `exact`. Same premise as §14.4. Revisit
  trigger: a wrong `exact` badge seen.
- **R9 Migration 4 is a guarded `ADD COLUMN` and nothing else.** No backfill
  (§1.1).
- **R10 The seam test is queue → sync → link → pass**, owned by a new suite,
  `scripts/queue-check.pl` (§3.2). Discharges TODO 2026-09-24's build-order
  obligation.
- **R11 Relink for users with no tag names is not built.** The importer's `use`
  gate stays `scalar @{discogsTagNames}` (§15.8). A user with manual links and
  no tag names loses them when a folder moves. Accepted for now; recorded in
  design as a possible future feature and in TODO.
- **R12 DEFAULT — clear & rebuild (§10) is not step 8's.** Decided 2026-09-07,
  never built, owned by no step since the build order was renumbered. Recorded
  in TODO with its own later step.
- **R13 A row carrying only an ownership conclusion and/or a pass-written
  review reason is regenerable, and may be deleted freely.** It carries no
  decision and no snapshot; the pass rebuilds it at every sync. So:
  - §2a's governing rule and the SQL delete guard at `Ownership.pm:598-604`
    (three NULLs) are **unchanged**, and `_isOwnershipOnly` (`:316-322`) is
    **unchanged**. The guard still protects exactly what it was written to
    protect: rows with a decision or a snapshot. A pass-written reason is
    never on such a row except `orphan`, and an orphan has a tier (Phase 0 C2).
  - The pass decides *whether* to delete from its new conclusion (§2.1).
  - `relinkOrphan` deletes such a row on its target key before its UPDATE,
    **whatever reason it carries** (Phase 0 C3). The next sync re-derives.

### §0.2 Defaults this plan applies, derived rather than decided here

- **D1 A manual row on an album still in the library never carries a pass
  reason.** The user has decided; if the chosen release later leaves the
  collection, the pass falls to the title route (`Ownership.pm:358-363`) and
  the album simply stops badging. Without this, a manual link to a record
  whose title is shared would re-enter the queue as `ambiguous` at every sync.
  **An orphan is not a verdict on a live album**, so a manual orphan does get
  `orphan` (user ruling, 2026-09-24): manual rows are what recovery exists for
  (§15.5).
- **D2 `undecodable` is not a reason.** Not in §13.10.5; stays a logged count.
- **D3 Fresh conflicts that predate migration 4 are found by §3a's own
  predicate.** The review list selects `review_reason = 'conflict' OR
  (match_tier = 'strict' AND discogs_release_id IS NULL)`. Exact per §3a, and
  not a backfill. **Incumbent conflicts that predate migration 4 cannot be
  found**: nothing recorded them, and `scanner.log` is rewritten each scan.
  They surface when their files next change. Stated, not solved.
- **D4 Orphan list actions: relink to a fitting album, or reject.** Fitting
  albums are the key-miss albums whose §15.5 fit key equals the orphan's
  snapshot (`Match::_fitKey`), pre-filled with the previous answer (§2).
  **A zero-fit orphan offers reject only**; relinking it to an arbitrary album
  is recorded as future work. **DEFAULT** — flag at review.
- **D5 A manual link is an identification, so it captures the snapshot**
  (§15.4): `snapshot_artist`, `snapshot_album_title`, `snapshot_track_count`
  from the album, bytes as the iterator supplies them.
- **D6 The page identifies albums by `album_key`, never by `lms_album_id`.**
  Phase 0 §3 found no accessor for either lookup the page needs, and flagged
  that `lms_album_id` goes stale on a full rescan (`Match.pm:702-704`), so a
  conflict re-read by id could read the wrong album's tags. Instead the page
  walks the library once per render with `Library->eachAlbum` and indexes it
  by `album_key`. The iterator already carries everything needed: `album_id`,
  `title`, `artist`, `local_tracks`, `source_timestamp` and `candidates`
  (POD `Library.pm:95-110`, built at `:238-270`, **verified**). **No new SQL in `Library.pm`.** The walk
  is collected first and acted on afterwards: `eachAlbum` holds one
  `prepare_cached` handle, so no query may run inside its callback
  (`Importer.pm`'s `_prePass` comment). Cost **inferred** small: the whole pass,
  which does the same walk plus its writes, measured 39–50 ms on 764 albums
  (TODO 2026-09-19).

### §0.3 What earlier steps established that this plan must honour

- **Ownership stays the pass's to write.** Nothing here writes `ownership`
  from the UI. A manual link changes the badge only through an identification
  the pass honours: a manual row with a release id is "tagged" at node C, and
  its state is never moved (`Ownership.pm:338-364`, `$strict` at `:343`,
  **verified**).
- **Confirming writes `match_tier = 'manual'`, `state = 'confirmed'`** and is
  exempt from the collection cross-check (design §3). **Nothing overwrites
  manual** (`Match.pm:517-525`).
- **Every server-side write goes through `Match->_writeOk`** (`Match.pm:60-85`),
  which refuses during a scan.
- **The queue must not key on `state = 'candidate'`** (§13.4, §14.3; 305 of
  329 candidates on the reference server are unowned).
- **§2a invariant 4:** orphans are never swept automatically.
- **§9.6 attribution:** "Data provided by Discogs", with a followed hyperlink
  to the discogs.com page, next to any Discogs data shown.
- **The settings form's hidden `saveSettings`** is on every submit
  (`HTML/EN/settings/footer.html:39`; the visible button at `:38` sits inside
  `IF NOT nosubmit`; **verified**). The base handler (`Slim/Web/Settings.pm:135`)
  saves only what `prefs()` lists (`:150-182`); the default `prefs()` is empty
  (`:117-119`); nothing in the header, footer or base handler needs a
  non-empty `prefs()` (Phase 0 §4, **verified**). So a queue page with no
  `prefs()` saves nothing, and its handler dispatches on its own action names
  only.

### §0.4 Amendments this step makes to the record

| Record | Change |
|---|---|
| §14.8 invariant 3 | A row may also exist to carry a review reason: "a row exists where there is an identification, an ownership conclusion other than `absent`, **or a review reason**". |
| §15.13 part 5 | The pass deletes an ownership-only row when its new conclusion is `absent` **and** it has no new reason. The SQL guard is unchanged (R13). |
| §15.3 | The pass does not move `state` on a `conflict` row (R4). |
| §2a invariant 2 / §10.4 | A third permitted deletion: user reject (R7). The first (`Match.pm:673-683`) is unchanged. |
| §13.5, §13.10.5 | All-tags read deferred; three queue contents in v1 (R8). |
| §15.5 part 4 | The ambiguous relink is offered from the orphan list (R5, D4). |
| §15.13 part 1 | The sync keeps three more fields per entry (year, formats, labels) for the re-match list; lifetime unchanged (§2.2). |
| design §3 | "Choose from your collection", not "search-as-you-type" (R6). |
| design §10 | `review_reason` column. |

### §0.5 Phase 0 results (Claude Code, 2026-09-24, read-only, at `97a7062`)

- Baseline 882, all green. Every citation resolves; six were imprecise and
  are corrected in this revision.
- `ADD COLUMN` with a CHECK and no default: valid on 3.22.0 per the SQLite
  documentation (`lang_altertable.html`; the CHECK is not re-tested against
  existing rows before 3.37.0, which is harmless because every existing row is
  NULL); **observed** on 3.50.6 on an attached, schema-qualified table,
  including CHECK rejection. Not run on a 3.22 build.
- `_decide`'s buckets are exactly six; §2.1's mapping is exhaustive. `_apply`
  currently discards the bucket (`Ownership.pm:459` takes two of three).
- No caller or stub reads a second sync-callback argument.
- The reference-server SQL and an orphan-recompute script are in the Phase 0
  report; the user runs them. The orphan list cannot come from
  `squeezewax.db` alone — the script recomputes `album_key` from `library.db`.
- Eleven contradictions reported (C1–C11) and resolved in this revision: C1,
  C4 in R4/R7; C2, C3 in R13; C5 in D1; C6 in R6; C7 in §2.2; C8 in §1.1; C9 in
  §4; C10 in §3.2; C11 in R2.

---

## §1. Group A — schema and write paths

### §1.1 Migration 4 (`Schema.pm`, appended to `@MIGRATIONS`)

```
ALTER TABLE squeezewax.discogs_match ADD COLUMN review_reason TEXT
  CHECK (review_reason IN ('conflict','ambiguous','artist-disagree',
                           'artist-absent','various-gated','orphan'))
```

- **Guarded:** run only if `SELECT name FROM pragma_table_info(?)` with
  `'discogs_match'` returns no `review_reason` — the form both existing guards
  use (`Schema.pm:525-527`, `:590-592`; Phase 0 C8). Migrations must be
  idempotent (`Schema.pm:29-31`) and `ADD COLUMN` is not.
- **Asserts** (`schema-check.pl`): 3 → 4; row count unchanged; every existing
  row NULL in the new column; the CHECK rejects `'bogus'` on UPDATE; an
  INSERT that omits the column leaves it NULL; a second run is a no-op; a v4
  file refuses an older plugin (existing `_migrate` behaviour, re-asserted at 4).
- No index: the queue selects from ~500 rows (**inferred** adequate).

### §1.2 Importer-side writes (`Match.pm`, `Importer.pm`)

- `_recordConflict`: set `review_reason = 'conflict'` in both the INSERT and
  the ON CONFLICT list.
- `_recordMatch`: set `review_reason = NULL` (a clean identification clears
  a conflict, R3). Also clears any pass reason; the next sync re-derives it.
- `_recordNoMatch`: **unchanged.** Its narrow delete still removes a fresh
  conflict whose tags are gone (`:673-683`). An incumbent conflict whose tags
  are gone reaches the `kept` path (`:697-712`) and keeps `conflict` until the
  user rejects it (ground (a), R7).
- `relinkOrphan`: in one transaction, **first** delete a row on the target key
  matching `match_tier IS NULL AND discogs_release_id IS NULL AND
  snapshot_track_count IS NULL` (R13, whatever its reason), **then** UPDATE,
  and set `review_reason = NULL` if it was `orphan`. Still asserts exactly one
  row updated. Closes TODO 2026-09-19 "an ownership-only row blocks a later
  relink" (the PK collision), for the scanner's relink and the page's.
- `Importer::_prePass` (`Importer.pm:323`): treat a row with `match_tier IS
  NULL` as a key miss, consistent with §15.13 part 6. `snapshotRows` stays
  unfiltered, so `match-check.pl:1073-1075` survives as written.

### §1.3 New write entry points (`Match.pm`, all behind `_writeOk`)

- `recordManual( \%album, $releaseId, $masterId )` — UPSERT:
  `match_tier = 'manual'`, `state = 'confirmed'`, the two ids, `matched_at`,
  `source_timestamp` from the album, the three snapshot columns (D5),
  `review_reason = NULL`. Never names `ownership`. Deletes any strict
  `discogs_no_match` row for the key (invariant 1). Integer-validates both ids
  (`master_id` 0 or absent → NULL, as `_indexCollection` treats it).
- `rejectRow( $albumKey )` — DELETE of one row, only where
  `match_tier = 'manual' OR review_reason IN ('conflict','orphan') OR
  (match_tier = 'strict' AND discogs_release_id IS NULL)`. Nothing else is
  rejectable: a computed item has no user decision to undo (R7).
- `relinkOrphan` is reused, unchanged in signature, for the page's relink.

---

## §2. Group B — the pass and the sync

### §2.1 The pass (`Ownership.pm`)

- `_loadRows` also selects `review_reason`.
- `_apply` takes `_decide`'s third return value (today discarded at `:459`).
- `_decide`: a row with `review_reason = 'conflict'` is not tagged (R4).
- Reason from the bucket (**verified**, `Ownership.pm:327-421`; exhaustive per
  Phase 0 §6): `ambiguous` → `ambiguous`; `various` → `various-gated`;
  `disagree` → `artist-disagree`; `lms-absent` / `discogs-absent` →
  `artist-absent`; `undecodable` → none (D2).
- Writes:
  - Never overwrite `conflict` (R3). Never write a reason on a manual row
    whose album is current (D1).
  - **No row, reason set** (ownership is then `absent`) → INSERT `album_key`,
    `lms_album_id`, `ownership = 'absent'`, `review_reason` (§14.8 amended).
  - Existing row → UPDATE `review_reason` when it changed, with the same
    "don't name a column you don't own" discipline as `state`
    (`Ownership.pm:564-591`).
  - Delete an ownership-only row when its new ownership is `absent` **and**
    its new reason is NULL (R13).
  - **Orphans:** an unseen row carrying an identification and a snapshot
    (§15.5 part 3), manual ones included, gets `orphan` unless it is
    `conflict`. An unseen ownership-only row is deleted, as now.
  - Deterministic, so the `SELECT *` determinism pair
    (`ownership-check.pl:604-614`) holds with the new column.
- Summary line gains the reason counts actually written.
- **Assertions this deliberately changes** (Phase 0 §9; B1 rewrites each, and
  says so in the commit): `ownership-check.pl:547-548`, `:550-551`,
  `:555-556`, `:557-558`, `:567-568` — each asserts "no row" for an album that
  now gets a reason row. `:545` (`h_none` gets no row) **must survive**: it is
  §14.8's boundary. `:596-597`'s "not a row per album" margin gets thinner;
  B1 tightens it to an exact count.
- **New assertions:** an incumbent conflict is not promoted and gets no
  `state` write (no fixture covers it today — `ownership-check.pl:492-493`
  builds only a fresh one); a manual current row gets no reason; a manual
  orphan gets `orphan`; a lapsed reason row is deleted; `conflict` survives a
  pass.

### §2.2 The sync hands its list to its caller (`API/Async.pm`)

- `_gotPage` keeps three more fields per entry, from `basic_information`:
  `year`, `formats` (names and descriptions) and `labels` (name and catno).
  Present in the fixture (**verified**). Amends the "five fields and nothing
  else" comment at `:529-530` (§0.4). The pass ignores them.
- The `_testFilter`ed list, built inline today at `:703`, is hoisted into a
  variable inside `if ( $result->{ok} )` (`:699`), handed to the pass, and
  passed as the callback's second argument at the single exit (`:730`)
  **only when the final result is ok** — after the pass has also succeeded
  (Phase 0 C7). A pass refusal therefore reaches the page as its existing
  `refused` error.
- The other three callback sites — `no_token` (`:225`), `already_running`
  (`:233`), superseded (`:680`) — keep passing one argument.
- Existing callers (`Plugin.pm:236` → `_syncDone`, `Settings.pm:252`) and the
  four `sync-check.pl` call sites read only the first argument (**verified**,
  Phase 0 §7). Nothing is stored or logged from the list; it is dropped when
  the callback returns.

---

## §3. Group C — the page, and the seam

### §3.1 `SqueezeWax/Queue.pm` + `HTML/EN/plugins/SqueezeWax/queue.html`

- `Slim::Web::Settings` subclass; `new` registers the page only (R1);
  `page` = `protectURI('plugins/SqueezeWax/queue.html')`; **no `prefs()`**.
  Constructed from `Settings.pm` beside itself; linked from `settings.html`,
  with the count of open items.
- **Handler dispatch:** its own action names only (`rematch`, `link`,
  `reject`, `relink`), each tested explicitly; `saveSettings` is ignored.
  Every action refused while scanning (same rule and string as the settings
  page). The render is deferred through `$callback` for `rematch`, as
  `_syncNow` does (`Settings.pm:252-260`).
- **Lists (no Discogs request), via one library walk (D6):**
  - Review: `review_reason` in the pass values or `conflict`, plus D3's
    predicate, excluding `orphan`. Each item: album title and artist from the
    walk, and the reason in words.
  - Conflict items re-read the tags of the walk's `candidates` when opened
    (§3a); if unreadable, "conflict recorded, tags no longer readable".
  - Orphans: `review_reason = 'orphan'`, shown from the snapshot and release
    id, with D4's fitting albums.
- **Re-match (R6):** needs a token; refused with the settings page's strings
  when missing, rejected or scanning. Renders title-key matches, then the full
  collection with a client-side filter, with R6's fixed fields and one row per
  instance.
- **Confirm** writes through `recordManual`, with the album taken from the
  walk by `album_key`; the page states that the badge changes at the next sync
  or scan.
- **Reject** asks for confirmation (client side, and the handler requires a
  confirm field), then `rejectRow`.
- **Buttons:** reuse the settings page's disable-on-click script
  (`settings.html:163-249`), including the copy-to-hidden-input step
  (`:213-219`) and the deferred disable (`:237-241`). Per-row buttons carry the
  album key as their value; the hidden input copies `clicked.value` (`:217`)
  before the relabel (`:223`), so this works unchanged (**verified**, Phase 0).
- Standard settings header and footer with `nosubmit = 1`, as
  `settings/server/status.html:44` does.
- `scripts/syntax-check.sh:174`'s hardcoded `MODULES` list gains `Queue`
  (Phase 0 C9).

### §3.2 The seam suite — `scripts/queue-check.pl` (R10)

Real: `Queue.pm`'s `handler`, `API/Async.pm`, `API.pm`, `Match.pm`,
`Ownership.pm`, and `Schema.pm`'s migrations against a temporary SQLite file.
Stubbed only at LMS's boundary:
- `SimpleAsyncHTTP`: the corrected shape from `sync-check.pl` (stub audit
  §0a): 2xx via `onBody` with code and headers set; non-2xx via the error
  callback with the response as the third argument.
- `Slim::Utils::Prefs`: the faithful `StubPrefs` from `settings-check.pl` (stub
  audit §0b): no-op suppression and `setChange` dispatch.
- `Library->eachAlbum` / `ownershipArtists`: fixture albums.
- `Slim::Web::Settings::handler`: a render marker.

Asserts, at least:
1. `rematch` issues identity + pages requests; the rendered choices are the
   title matches first, then the full list, with R6's fields; a release owned
   twice appears twice; nothing is written to `discogs_match` except by the
   pass.
2. `link` writes a `manual` / `confirmed` row with both ids, the snapshot, and
   `review_reason` NULL; `ownership` untouched.
3. A second sync (the same fixture) runs the real pass and sets `ownership =
   'exact'`; the album leaves the review list.
4. A 401 on `rematch` renders the unauthorized string and writes nothing.
5. `rematch`, `link` and `reject` are refused while scanning.
6. A `saveSettings` alongside any action does not swallow it.
7. `reject` on a computed item deletes nothing; on a manual orphan it deletes
   exactly that row.
8. A relink from the orphan list lands on an album whose reason-only row is in
   the way (R13).

String tokens: `settings-check.pl:1001-1003` widens its template path from
`settings.html` to `glob(".../HTML/EN/plugins/SqueezeWax/*.html")`, so
`queue.html` is covered by the existing plugin-wide scan rather than a second
copy of it (Phase 0 C10).

**Caveat, carried from TODO 2026-09-24:** three seam defects is a pattern, not
a law. This suite is aimed at step 8's own joins, not a claim that the next
defect will be there.

### §3.3 The discogs.com link

Collection entries carry no `uri` (`basic_information` keys: `artists,
cover_image, formats, genres, id, labels, master_id, master_url, resource_url,
styles, thumb, title, year` — **verified**, `collection-page1.json`;
`resource_url` is the API address, not a page). The link is built from the
release id as `https://www.discogs.com/release/{id}`.
- **Observed** by the user 2026-09-24: `https://www.discogs.com/release/14590709`
  redirects to `https://www.discogs.com/release/14590709-Depeche-Mode-Violator?redirected=true`,
  so Discogs itself canonicalises the id-only form.
- **Corroborated** by the API: captured release payloads carry `uri` =
  `https://www.discogs.com/release/{id}-{slug}` (`release-14590709.json`,
  `release-2516.json`, **verified**).
- **Not documented** as a stable address. If it ever stops resolving, the fix
  is one format string. TODO records the basis.

---

## §4. Model and phasing for Claude Code

- **Model:** Opus. A new writer and a new deletion on the one table that is
  not disposable.
- **Phase 0:** done (§0.5).
- **Phase 1**, one commit each, suites green after each:
  - P — this plan, decisions §15.16, the TODO and design-list edits (§5.1).
  - A1 migration 4 (+`schema-check.pl`).
  - A2 importer-side writes, `_prePass`, `relinkOrphan` (+`match-check.pl`).
  - A3 `recordManual`, `rejectRow` (+`match-check.pl`).
  - B1 the pass (+`ownership-check.pl`, including §2.1's changed assertions).
  - B2 the sync keeps three fields and hands its list (+`sync-check.pl`).
  - C1 `Queue.pm`, template, strings, settings link, `syntax-check.sh`.
  - C2 `scripts/queue-check.pl` (picked up by `check-all.sh`'s glob, `:42`) and
    the `settings-check.pl` template glob.
  - D — docs: design §3/§9/§10, `CLAUDE.md` build order, TODO ticks.
- **Phase 2:** report per-commit assertion counts, deviations, and §6.

## §5. Doc and TODO edits

### §5.1 In commit P

- **Decisions §15.16**, from §0.1–§0.4.
- **TODO.md:**
  - Tick or re-point: the review-queue marker (A1/B1, noting six values, not
    four); the conflict incumbent item (B1, R4); the ownership-only row
    blocking relink (A2); the ambiguous relink (C1); reject/dismiss (A3, C1);
    the build-order obligation (C2); the 3 orphans (C1).
  - The all-tags read → "Deferred by decision" (R8); stub-audit #5's
    revisit trigger no longer fires at step 8.
  - The relink-for-manual-only-users item → "accepted, future feature" (R11).
  - **New:** clear & rebuild — decided, unbuilt, owned by a later step (R12).
  - **New:** the discogs.com link format (§3.3) — observed and corroborated,
    not documented; revisit if it stops resolving.
  - **New, future feature:** a field picker for the re-match list (R6).
  - **New:** whether collection images may be shown — unverified against the
    terms (R6).
  - **New:** a zero-fit orphan can only be rejected (D4).
  - **New:** pre-migration incumbent conflicts are unfindable (D3).
  - **New:** `Plugin.pm:90-97` — a comment about the removed interval pref's
    floor, with no code under it.
  - **New, minor:** `SqueezeWax/Settings.pm:47` cites
    `Slim/Web/Settings.pm:135-176`; the save loop runs to `:182`.
  - Design §9's "review-queue behaviour (auto-open? notification?)" → not v1.

### §5.2 In commit D

- Design §3: re-match wording (R6); states; the queue's three contents.
- Design §9: the queue page; the badge-waits-for-sync note.
- Design §10: `review_reason`, its writers and precedence.
- Design §11 or a future-features list: relink for manual-only users (R11);
  the field picker (R6).
- `CLAUDE.md`: step 8 → code complete, hardware checks open in TODO.

## §6. Hardware checks (after merge, on the reference server)

0. **Before upgrading:** run Phase 0's SQL and orphan script; record fresh
   conflicts, manual rows and orphans.
1. **Upgrade:** `user_version` 3 → 4; 507 rows unchanged; the column NULL on
   every row.
2. **First sync:** reasons written match the summary; expect ambiguous 5,
   artist-disagree 2, gated 0 (TODO 2026-09-22 figures); orphans 3, including
   the manual row 888888.
3. **Queue page:** lists exactly those, plus D3's fresh conflicts; none of the
   305 unowned candidates.
4. **Re-match** on one FSOL album (3124 or 3127): requests = 4; choices
   include `The Future Sound Of London`'s entry with year, format and label;
   confirm → manual row; **next** sync → `exact`, and it leaves the list.
5. **Reject** the three test-data orphans (release ids 999999, 77777, 888888)
   from the orphan list; rows gone; nothing else changed (full `SELECT *`
   diff).
6. **Relink** an ambiguous orphan (two copies of one album folder, as step 4
   check 6) from the orphan list.
7. **Conflict:** retag one owned album with two different ids; scan →
   `conflict`; sync → no promotion, badge only via the title route; fix the
   tags; scan → reason cleared.
8. **Scanning:** every queue action refused mid-scan.
