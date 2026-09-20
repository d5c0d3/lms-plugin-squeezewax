# Build-order steps 6–7: migration 3 and the ownership pass

**Status:** plan, approved in the design chat 2026-09-19; amended 2026-09-20
after Claude Code's Phase 0 report (§0.5). Code: none yet. Checked against
`d5c0d3/lms-plugin-squeezewax` `v1-buildout` at `589ed6e`, and slimserver
`a670a38c2b14ad42b86a39884bcb842121b35571` (the same pin as every prior step).

**One plan file, two commit groups.** Migration 3 stays reviewable on its own,
but its table definition depends on step-7 rulings (§0.1 R4, R5 and R10), so
there is no clean seam for two plans. Per decisions §15.9, the two groups ship
together and group A is never merged ahead of group B.

Every claim below carries a tag: **verified** (read in source, cited),
**observed** (run, with the environment named), or **inferred** (reasoned from
reading, not run).

---

## §0. What this plan rests on

### §0.1 Rulings taken in this session (2026-09-19)

Recorded as decisions §15.13 (Appendix A). Each was put to the user as
multiple choice, and they chose the recommended option every time.

| # | Question | Ruling |
|---|---|---|
| R1 | How the pass gets the collection | **One fetch, handed over.** The completed sync passes the ownership pass an in-memory list, de-duplicated by `instance_id`. The pass runs only if the sync completed **and** that list's size equals `pagination.items`. `discogsLastSynced` advances only after the pass commits. Nothing persists. |
| R2 | Q10: which LMS artist | **The measured rule**: first ALBUMARTIST (role 5) by contributor id, else first ARTIST (role 1) by contributor id, else `albums.contributor`, read by raw SQL and decoded to characters. Never `Slim::Schema::Album::artists` (§15.12). |
| R3 | How far artists are normalised | **L2** (trim, collapse whitespace, case-fold), after Discogs' trailing ` (N)` strip, plus §15.7's Various rule. Not L5 as the measurement used. Re-run the split at this rule before step 7 ships (§5). |
| R4 | How step 8 finds queue items | **Step 7 stores no marker.** Step 8 adds a nullable reason column via `ADD COLUMN`. Until then an ambiguous or artist-disagreeing album is `absent` if tagged and has no row if untagged. |
| R5 | Rows whose ownership lapses | **A second permitted delete**, for rows that carry neither a decision nor a snapshot. Amends §2a invariant 2. |
| R6 | Importer vs ownership-only rows | **The importer ignores them.** Its lookups filter on `match_tier IS NOT NULL`. §2a invariant 1 is reworded to cover identification rows only. |
| R7 | §13.5's all-tags read | **Moves to step 8.** Step 7 reads no files. |
| R8 | Q9 | **Ship gated, Q9 stays open.** A match whose artists agree only through the Various equivalence does not badge (§15.7/§15.11). |

### §0.2 Defaults this plan applies, derived rather than decided here

The user saw each of these in the survey and did not object. The plan records
where each comes from.

- **Manual rows** get `ownership` written and `state` never touched. Design §3
  says a manual link "is not subject to the collection cross-check that governs
  Strict".
- **Conflict rows with a NULL release id** keep their state. There is nothing
  to promote.
- **Nodes D/F** (tagged albums): owned `exact` if the release id is in the
  collection; `version` if the row's `discogs_master_id` is defined, non-zero
  and in the collection. TODO 2026-09-07's two sentinel items say both the `0`
  and the undefined forms must be guarded.
- **The same release owned twice** (two instances) counts as one collection
  entry for the title route. Otherwise it forms a queue item where no choice
  changes anything, against §13.4. Page 1 of the fixture has no case of it
  (checked: no duplicate release or instance ids across 100 rows). Two
  *different* releases sharing a title still count as two: that is §13.10.3's
  ambiguous direction.

### §0.3 Two new items, approved by the user 2026-09-19

- **N1 — `ownership` gets `DEFAULT 'absent'`.** Without a default, the
  NOT NULL column makes both importer INSERTs fail: `_recordMatch`
  (`Match.pm:546-569`) and `_recordConflict` (`:616-630`) don't name the
  column. That failure is loud, not silent, but it would stop identification
  entirely. `absent` is §15.3's own value for a row no sync has concluded on.
  This is not §14.8's `DEFAULT 'candidate'` hazard: that default put albums
  into the queue, while this one only withholds a badge until the next sync,
  the same window §15.3 accepts. Alternative: the importer names
  `ownership = 'absent'` in both INSERTs, so a forgotten column in a future
  writer fails rather than defaults.
- **N2 — obligation (g)'s EXPLAIN QUERY PLAN check has nothing to check.**
  *Verified:* no SQL anywhere in `SqueezeWax/` filters on
  `snapshot_track_count` through the orphan index. The relink loads every row
  and matches in Perl (`Match.pm:259-268`, `Importer.pm:355-359`), and the two
  statements that name the column (`Match.pm:412-416`, `:662-672`) are keyed on
  the primary key. The plan rebuilds the index as (g) requires. The
  query-plan assertion becomes a recorded finding: "no current query uses this
  index". The alternative is dropping it, which (g) as written does not allow.
  This is the (d)/(g) defect shape again: an obligation written against a
  query that was never built as SQL.

### §0.4 What earlier steps established that this plan must honour

Each item names the symbol that enforces it.

1. `_writeOk` / `_writeRefusal` (`Match.pm:43-85`) gate every write. The pass
   is a server-side writer, so it is refused while a scan runs.
2. The manual guard is rule one of the importer's write path
   (`Match.pm:506-514`). The pass never changes `state` on a manual row (§0.2).
3. §2a's governing rule: never delete a row carrying a decision or a recovery
   snapshot (`Match.pm:644-672`). R5 adds a predicate that passes that test and
   widens nothing else.
4. The skip contract (`Importer.pm:397-408`). The pass never writes
   `source_timestamp`.
5. Snapshots are captured at identification only (§15.4). The pass never
   writes a `snapshot_*` column.
6. The relink is an UPDATE of `album_key` and `lms_album_id` only
   (`Match.pm:447-473`), and orphans are keyed on identification plus snapshot
   (`Importer.pm:355-359`).
7. Server DDL only, and the scanner checks the schema version
   (`Schema.pm:165-171`, `:366-378`).
8. The single exit in `Async.pm::_finish` (`:480-513`) is where "never advance
   the timestamp for an incomplete sync" is enforced. R1 keeps `_finish` the
   only exit and adds one more condition before the timestamp advances: the
   pass must have committed (§2.5). Corrected 2026-09-20: this said "does not
   add a second exit", which Phase 0 read, reasonably, as also forbidding
   `_finish` from making any decision.
9. The calling convention (`CLAUDE.md`): public subs are class methods,
   `_`-prefixed helpers are plain functions.

### §0.5 Phase 0 results (Claude Code, 2026-09-20, read-only, at `589ed6e`)

**Verified on the reference server** (copies of `squeezewax.db` and `library.db`,
queried read-only):

- **(a)** 0 rows with `match_tier IN ('structural','fuzzy')`.
- `discogs_match` holds 481 rows: 478 strict/confirmed, 2 strict/candidate, 1
  manual/confirmed. None has a NULL `discogs_release_id` (no conflict rows);
  every row has a snapshot.
- Exactly the 3 known orphans, all carrying an identification and a snapshot,
  so R5's predicate cannot touch them.
- **(h)** Nothing in `SqueezeWax/` writes `'structural'`; `discogs_no_match`
  holds 100 rows, all `strict`.
- **(i)** 11 references, zero readers, and no writers in `SqueezeWax/` beyond
  `_migration_1`'s DDL. The table exists with 0 rows.
- The fixture has one real §13.10.3 ambiguous case: *Ciao Monkey*, twice, as
  two different releases. Use it in §2.7.
- **SQLite 3.46.1** is bundled (§1.2 step 3).

**Settled in response** (the design chat's answers; each follows from rulings
already made, so none is a new decision):

- **W1.** The completeness check stays in `_gotPage` and replaces its warning;
  `_finish` is still the only exit (§2.5). This follows from R1.
- **W2.** An unknown `items` fails the sync (`count_unknown`), the same as a
  mismatch. This follows from §13.7 and R1: completeness that can't be shown
  is treated as not shown.
- **W3.** The pass runs only after `_finish`'s superseded check. A superseded
  run must not touch shared state (`Async.pm:483-493`'s own rule).
- **Corrections applied:** three `title-agreement.pl` citations, the
  `snapshotRows` wording in §2.4, the explicit copy list, the (e) assertion
  widened to all copied columns, DELETE precedence in §2.3, the `:172-185`
  comment, and the `Schema.pm:387` citation fix in A1.

---

## §1. Group A — migration 3 (step 6)

### §1.1 Preconditions (Phase 0, read-only, reported by Claude Code)

- **(a)** Count rows with `match_tier IN ('structural','fuzzy')` in the
  reference database. Expected 0; **not verified**. The migration refuses on
  a nonzero count regardless (§1.2).
- **(h), first sub-item:** grep for anything writing `'structural'` to
  `discogs_no_match`.
- **(i), first sub-item:** confirm zero readers or writers of
  `discogs_collection` in `SqueezeWax/` other than `_migration_1`'s DDL and
  comments. Account for every hit in `scripts/`. The design chat found
  `schema-check.pl:231`, `:288` and `:293`, and a comment at
  `sync-check.pl:410`. Claude Code reports its own count; it does not confirm
  this one.
- Report the row count of `discogs_match` and the per-`state` breakdown before
  the upgrade. TODO says to expect 481 rows and the 3 known unrelinked orphans.
  Report what is found, not whether it matches.

### §1.2 `_migration_3`, in `Schema.pm`, appended to `@MIGRATIONS`

In this order:

1. **Shape check first.** If `pragma_table_info('discogs_match')` already has
   an `ownership` column and no `snapshot_total_duration`, skip the rebuild
   (steps 2–7) and go straight to step 8. This follows `_migration_2`'s pattern
   (`Schema.pm:520-528`).
   *Why:* `_migrate` bumps `user_version` only after the migration sub returns
   (`Schema.pm:339-348`). A rebuild that commits and then dies before the bump
   would otherwise re-run its copy against the new shape and fail on the
   dropped column. The plugin would then be dead on every start.
2. **Refuse loudly (a).** Count `match_tier IN ('structural','fuzzy')`. If it
   is nonzero, die with the count; nothing has been changed yet.
3. **One transaction** for steps 4–7 (`$dbh->begin_work` / `commit`, rollback
   on error). *Verified:* the server handle is `AutoCommit => 1`
   (`Slim/Schema.pm:274`). *Observed on SQLite 3.45.1, which is not LMS's
   bundled build:* DDL on an attached schema rolls back with the transaction.
   *Verified 2026-09-20 (Phase 0):* LMS bundles DBD::SQLite 1.76 with SQLite
   **3.46.1** for perl 5.32–5.42 (`refs/slimserver/CPAN/arch/*`), and the
   reference server runs perl 5.38. Perl 5.20–5.30 trees carry 3.22.0.
   `ALTER COLUMN ... DROP NOT NULL` (3.53.0) is therefore not available, so
   the 12-step rebuild is required, not a choice.
4. **Create `squeezewax.discogs_match_new`:**

   ```sql
   album_key            TEXT    NOT NULL PRIMARY KEY CHECK (length(album_key) = 32),
   mb_album_id          TEXT,
   lms_album_id         INTEGER,
   discogs_release_id   INTEGER,
   discogs_master_id    INTEGER,
   match_tier           TEXT    CHECK (match_tier IN ('strict','manual')),
   state                TEXT    CHECK (state IN ('candidate','confirmed')),
   ownership            TEXT    NOT NULL DEFAULT 'absent'
                                CHECK (ownership IN ('exact','version','absent')),
   matched_at           INTEGER,
   snapshot_artist      TEXT,
   snapshot_album_title TEXT,
   snapshot_track_count INTEGER,
   source_timestamp     INTEGER
   ```

   This carries (b) (nullable, narrowed tier), (c) (no default on `state`), (f)
   (no `snapshot_total_duration`), the `ownership` column (§13.3, §15.3) and N1.
   The comments say NULL `match_tier` and NULL `state` mean "no identification"
   (§14.1, §14.8).
5. **Copy (e).** Name the 12 columns of the new table other than `ownership`,
   explicitly, in both lists: `album_key, mb_album_id, lms_album_id,
   discogs_release_id, discogs_master_id, match_tier, state, matched_at,
   snapshot_artist, snapshot_album_title, snapshot_track_count,
   source_timestamp`. `INSERT INTO ..._new (<those 12>) SELECT <those 12> FROM
   discogs_match`. `snapshot_total_duration` is simply not selected (f).
   `ownership` takes `'absent'` on every row; `state` and `match_tier` are
   copied unchanged.
6. **Assert (e) inside the transaction.** The row counts before and after are
   equal, and an `EXCEPT` both ways over **all 12 copied columns** returns zero
   rows. That is wider than obligation (e) strictly requires, so that a
   column-order slip in the copy cannot pass (Phase 0 finding). On failure,
   die, which rolls back.
7. **Swap.** `DROP TABLE squeezewax.discogs_match`, then `ALTER TABLE
   squeezewax.discogs_match_new RENAME TO discogs_match`. Recreate the indexes
   `discogs_match_release`, `discogs_match_lms_album`, `discogs_match_mb_album`
   and **(g)** `discogs_match_orphan ON (match_tier, snapshot_track_count)`.
   `discogs_match` has no foreign keys, so the 12-step procedure's FK steps
   don't apply; LMS turns `foreign_keys` on (`SQLiteHelper.pm:102`), but no
   plugin table declares one (`Schema.pm:380-389`).
8. **(h)** `DROP TABLE IF EXISTS squeezewax.discogs_no_match`, then recreate it
   as in `_migration_2` with `CHECK (tier IN ('strict'))`. **(i)**
   `DROP INDEX IF EXISTS squeezewax.discogs_collection_release`, then `DROP
   TABLE IF EXISTS squeezewax.discogs_collection`. All idempotent.

*Log at info:* rows copied, the per-`state` counts, and the tables dropped.

### §1.3 Group A commits

- **A1** `Schema.pm`: `_migration_3`, and the migration-1 comments that are now
  stale (the "captured at confirm time" snapshot comment, and the orphan-index
  comment). Also fix `Schema.pm:387`'s citation of `SQLiteHelper.pm:99` for
  `PRAGMA foreign_keys = ON` to `:102` (Phase 0).
- **A2** `scripts/schema-check.pl`, working from a grep for
  `discogs_collection`, `structural`, `fuzzy`, `state` and `DEFAULT`:
  - (b) NULL `match_tier` accepted; `'structural'` and `'fuzzy'` now
    **rejected** (flip the `for my $tier (qw(strict structural fuzzy))` loop);
    `'Strict'` rejected; `'manual'` accepted.
  - (c) an insert omitting `state` yields NULL.
  - N1: an insert omitting `ownership` yields `'absent'`; `'Exact'` and `'owned'`
    are rejected.
  - (f) the column set equals the expected set, exactly.
  - (g) the index exists on `(match_tier, snapshot_track_count)`.
  - (h) `'structural'` is rejected in `discogs_no_match`; the
    "second row under a different tier" case changes shape, since no second
    valid tier exists.
  - (i) every `discogs_collection` hit is accounted for, and the table is
    absent after migrating.
  - Upgrade path: build a version-2 database with rows (including a
    `confirmed` row, a conflict row and a manual row), migrate, and assert (e).
  - Re-run safety: run migration 3 twice, and run it with `user_version` forced
    back to 2 after a completed rebuild. Both must succeed and change nothing.
  - (a) seed a `'structural'` row in a version-2 database and assert that the
    migration dies and leaves the table unchanged.
- **A3** `TODO.md`: tick obligations (a)–(i) with their commit, and record N2's
  finding against (g).

---

## §2. Group B — the ownership pass (step 7)

### §2.1 The artist source (R2) — `Library.pm`

Add a new accessor, **`ownershipArtists()`**: one query over `albums`,
returning `{ album_id => bytes }`. It takes the measurement's three-way choice
verbatim from `scripts/title-agreement.pl`: the subqueries at `:236-245` and
the selection loop at `:281-291`. That is role 5 by `c.id`, then
role 1, then `albums.contributor`, taking the first that is defined and not
blank. Don't change `$ALBUM_TRACKS_SQL`: the importer and the snapshot keep
`albums.contributor` (§15.12). A separate query also keeps the per-track
statement free of subqueries. The pass joins on `album_id` in memory.

- *Verified:* ARTIST = 1 and ALBUMARTIST = 5 (`Slim/Schema/Contributor.pm:78-83`).
- *Verified:* this never calls `variousArtistsObject` (§11.3(d)).
- *Inferred:* the result is deterministic for a given library. `c.id` can
  change after a library wipe, so a multi-ALBUMARTIST album's chosen name may
  change then. That is acceptable, because the same collection and the same
  library still give the same answer (§13.2).

### §2.2 Comparison — new `SqueezeWax/Ownership.pm`

Pure functions, covered offline, ported from `scripts/title-agreement.pl` and
not re-derived:

- `_decode($bytes)`: as in `_decode_bytes` (`:310-325`). Titles or artists that
  won't decode are counted and treated as no match. Never repaired.
- `_titleKey($s)`: `_normalise($s, 2)` (`:151-164`): trim, collapse
  whitespace, `lc`. No bracket, punctuation or article rules (§13.10.4).
- `_artistKey($s)`: `_strip_discogs_disambiguator` (`:169-177`), then **L2**
  (R3). *This deliberately differs from the script's `_normalise_artist`,
  which calls rung 5 at `:184`).*
- `_artistsAgree($lms, \@discogs)`: returns one of `agree`, `various`,
  `disagree`, `lms-absent` or `discogs-absent`. It follows `_artists_agree`
  (`:373-390`) and adds the §15.7 check, which is consulted **only when plain
  equality fails**:
  - The LMS side equals `lc(Slim::Music::Info::variousArtistString())` after L2.
  - Some Discogs artist, after ` (N)` strip and L2, is `various` or
    `various artists`.
  - Never a literal on the LMS side (§15.7).
  - `variousArtistString` is passed in as an argument, so the function stays
    pure.

### §2.3 The decision per album (design §3, C–K)

Inputs:

- **The entry list.** Build `ownedReleases`, `ownedMasters` (masters that are
  defined and non-zero only) and `byTitle`, keyed on `_titleKey` and holding
  **distinct release ids** (§0.2).
- **Every current `discogs_match` row**, loaded whole (as `snapshotRows` does).
- **`eachAlbum`** (all albums, all-remote included — §15.11) plus
  `ownershipArtists`.

For each album, with `row` its existing row, if any:

1. **C.** If `row` has `match_tier` defined **and** `discogs_release_id`
   defined, it is tagged:
   - **D:** the release is in `ownedReleases` → `exact`. If the tier is
     `strict`, state becomes `confirmed`.
   - **F:** else the row's `discogs_master_id` is in `ownedMasters` →
     `version`. If the tier is `strict`, state becomes `candidate`.
   - Otherwise, if the tier is `strict`, state becomes `candidate`, and fall
     through to H.
   - **Manual rows never change state** (§0.2).
2. **H.** Look up `byTitle{ _titleKey(title) }`:
   - No candidates → `absent`.
   - Two or more candidates → `absent`. This is a queue item, but step 7
     stores no marker for it (R4).
   - Exactly one candidate: `agree` → `version`. `various` → `absent` (the
     gate, R8). `disagree`, `lms-absent` or `discogs-absent` → `absent` (R4).
   - A tagged album that reaches H keeps its identification (design §3).
3. **Conflict rows** (strict tier, NULL release id) skip C and go to H. Their
   state is never written (§0.2).

Then work out the write:

| Row exists? | Result | Write |
|---|---|---|
| no | `absent` | nothing (§14.8) |
| no | `exact`/`version` | INSERT `album_key`, `lms_album_id`, `ownership`; everything else NULL |
| yes | any | UPDATE `ownership`, plus `state` where the rules above set it, **only if the value changed** |
| yes, R5 predicate true, result `absent` | — | DELETE |

**DELETE takes precedence** over the UPDATE row when both apply.

**R5's predicate, exactly:** `match_tier IS NULL AND discogs_release_id IS
NULL AND snapshot_track_count IS NULL`. The same predicate deletes such rows
whose `album_key` is no longer in the library. Orphans that carry an
identification are not touched, and keep their last ownership (they have no
tile, so no badge can show).

**No writes happen until every album has been decided.** Then `_writeOk` is
checked, and all writes go in one transaction. This covers design-fix item
(b) (TODO) and §13.7.

**Summary at info:** albums walked, exact, version, absent-with-row, inserted,
deleted, promoted, demoted, gated (Various), ambiguous, artist-disagree,
undecodable. The last four are what step 8's queue will hold, and they are
counted now so the queue's expected size is known before it is built.

### §2.4 The importer ignores ownership-only rows (R6) — `Match.pm`, `Importer.pm`

- `$STATE_SQL`'s `discogs_match` half gets `AND match_tier IS NOT NULL`.
- `_recordNoMatch`'s surviving-row count (`:675-677`) gets the same filter.
- `snapshotRows` is left as it is. The orphan filter in `_prePass`
  (`Importer.pm:355-359`) already requires `match_tier`.
- **The relink pre-pass is not changed.** `_prePass` treats any row as "not a
  key miss" (`Importer.pm:321-336`), so an ownership-only row on a new album
  blocks a relink onto it. *Inferred:* this only happens when the relink did
  not happen at the scan that moved the files. At that scan the new key has no
  row yet, and the pass runs only after the scan. So it takes an ambiguous fit,
  or a user with no tag names (TODO 2026-09-19, the relink `use`-gate item),
  followed by a sync. Both are step 8's (§15.5 part 4). Treating the row as a
  miss would make `relinkOrphan`'s UPDATE hit the primary key and die in the
  scanner. Recorded in TODO for step 8, not built. Claude Code confirms the
  timing claim in Phase 0.
- `_recordMatch` / `_recordConflict` upserting over an ownership-only row keeps
  `ownership`, because neither update list names it (*verified*,
  `Match.pm:553-563`, `:622-626`). An offline assertion pins this down.

### §2.5 Wiring (R1) — `API/Async.pm`, `Plugin.pm`, `Settings.pm`

Settled 2026-09-20 after Phase 0 (§0.5, W1–W3):

- **`_gotPage`** pushes `{ instance_id, id, master_id, title, artists }` per
  release onto the run's list, in place of `counted +=`. `counted` becomes the
  count of distinct `instance_id`s.
- **The completeness check stays where it is**, in `_gotPage` after the last
  page (`Async.pm:435-441`), and **replaces** the existing warn-and-continue
  (W1). It is not duplicated in `_finish`. On the last page:
  - `items` undefined (no pagination block, `Async.pm:404`) → `_fail` with
    `count_unknown` (W2). Completeness can't be shown, and §13.7 recomputes
    only from a sync that completed.
  - `counted != items` → `_fail` with `count_mismatch`.
  - Otherwise `_finish` with ok and the entry list.
- **`_finish`** stays the single exit. Order (W3):
  1. The superseded-run check (`:483-493`) comes first, unchanged. A
     superseded run never reaches the pass.
  2. On the ok path, call `Plugins::SqueezeWax::Ownership->apply(\@entries)`.
     It returns ok, `refused` (write refused, e.g. a scan started) or
     `failed`. Anything but ok turns the result into a failure with that error.
  3. Only then are prefs set as today: `discogsLastSynced` and
     `discogsLastSyncItems` advance only if the pass returned ok.
  4. The list is dropped when `_finish` returns.
- **Comments to correct:** the header at `:15-20` ("step 7, which
  re-fetches"), the `_gotPage` comment, and the return contract at `:172-185`
  (which calls a count disagreement non-fatal and describes `counted` as rows
  seen). Step 5's plan (:18) is annotated.
- **Retry for a refused pass** (§15.2 obligation 1): no new mechanism. The next
  `['rescan','done']` re-arms a sync through `_scheduleSync`'s kill-then-arm
  debounce (`Plugin.pm:137-163`), which brings a fresh fetch, since the
  collection was discarded. *That the rescan-done event always arrives is the
  unobserved check (d).*
- **`Plugin::_syncDone`**: `refused` → info level; `count_mismatch`,
  `count_unknown` and `failed` → warn.
- **`Settings::_syncResultString`** gets four strings, as `strings.txt`
  tokens `PLUGIN_SQUEEZEWAX_SYNC_*`.
- **§9.4 note:** `count_mismatch` makes the residual tie risk from pinning
  `sort=added` (TODO Housekeeping) fail safe. A reshuffle aborts the pass
  instead of dropping a badge.

### §2.6 Group B commits

- **B1** `Library.pm` `ownershipArtists` + `library-check.pl`.
- **B2** `Ownership.pm` pure functions + a new `scripts/ownership-check.pl`.
- **B3** `Ownership->apply` + the write rules + R5 + assertions.
- **B4** Importer changes (§2.4) + `match-check.pl` assertions.
- **B5** Wiring (§2.5) + `sync-check.pl` assertions + strings.
- **B6** `CLAUDE.md` build-order status, and the TODO ticks in §4.2.

The rulings do not wait for code. Decisions §15.13 (Appendix A) and the TODO
edits in §4.1 land in **commit P**, together with this plan, before A1.

### §2.7 Offline assertions (minimum set)

- **Each path gives the right `ownership`, state change and row effect:** D
  (strict → confirmed), D (manual → state untouched), F, F with master `0`, F
  with master undefined, H none / several / agree / various-gated / disagree /
  lms-absent / discogs-absent, and a conflict row.
- **One entry, two albums** (the rip and the stream): both get `version` (§13.10.3).
- **Same release, two instances:** one candidate, badges.
- **Two releases, same title:** ambiguous, `absent`.
- **The *Substrata* / *Substrata²* pair** does not collide at L2.
- **No row is written for an absent untagged album; nothing is ever written
  with NULL/NULL/absent** (§14.8). Run the pass twice over the same inputs:
  the second run writes nothing (determinism, §13.2).
- **R5:** deletes an ownership-only row that lapsed, and one whose album is
  gone; **never** deletes a manual, strict, snapshotted or conflict row.
- **The pass never writes** `source_timestamp`, `snapshot_*`,
  `discogs_release_id`, `discogs_master_id` or `match_tier`.
- **Refused write:** nothing changes and the result is `refused`.
- **Count mismatch:** the pass isn't called and the timestamp doesn't advance.
- **R6:** an ownership-only row plus a no-match row gives no error and the
  row is ignored; a tag hit over an ownership-only row keeps `ownership`.
- **`variousArtistString` is honoured:** a customised value works and a
  literal `'Various Artists'` on the LMS side does not agree.

---

## §3. Model and phasing for Claude Code

- **Model:** Opus. Migration 3 is irreversible on the reference server's real
  rows, and the pass is a new writer on the one table that isn't disposable.
- **Phase 0 (read-only report):**
  - Re-verify every cited `file:line` in this plan against HEAD, independently.
  - Run the §1.1 counts and report the figures Claude Code finds.
  - Report on §2.4's relink timing claim: confirmed, or contradicted.
  - Report any internal contradiction in this plan or in obligations (a)–(i)
    rather than resolving it silently.
  - **Stop and wait.**
- **Phase 1:** P, then A1–A3, then B1–B6, one commit each, with the suites green after
  each commit.
- **Phase 2:** a report giving per-commit assertion counts, anything that
  deviated from this plan, and the hardware checklist (§5).

## §4. Doc and TODO edits

### §4.1 In commit P, with this plan (pasted verbatim from the hand-off)

- **Decisions:** §15.13 appended (Appendix A).
- **TODO.md:**
  - Q10 → `RESOLVED 2026-09-19 — decisions §15.13 part 2`.
  - Q9 keeps `Not decided.`, with a note that step 7 ships with the gate.
  - The sequence item: step 7 no longer carries §13.5 (R7).
- **New TODO items:**
  - **Step 8:** add a nullable reason column via `ADD COLUMN`, and have the
    pass write it (R4). `ADD COLUMN ... CHECK` is safe: observed on 3.45.1,
    and LMS bundles 3.46.1 (verified 2026-09-20).
  - **Step 8:** §13.5's all-tags read (R7).
  - **Step 8:** an ownership-only row on an album blocks a later relink onto
    it (§2.4). The ambiguous-relink work must delete that row (R5 predicate)
    before the UPDATE, or the primary key collides.
  - **Step 8:** a conflict row with an incumbent id can't be told apart from a
    tagged candidate, and the pass may promote it (§2.3). The queue must
    handle this.
  - **Measure:** re-run the auto-badge split with R2's source and R3's L2
    artist rule, on the reference `library.db` and the page-1 fixture, before
    step 7 ships.
  - **Measure:** the pass's run time on the reference library. It is
    synchronous in the server; *inferred* to take well under a second, but
    not measured.
- **Old numbering:** the 2026-09-07 items "decide before step 6 starts" (the
  attribution notice) and "A UI question for step 6" → re-point both to
  **step 9**.

### §4.2 In B6, after the code

- **CLAUDE.md** build order: steps 6 and 7 → code complete, hardware checks
  open in `TODO.md`.
- **TODO.md:**
  - Tick migration-3 obligations (a)–(i), and the "ownership pass must not
    write a row per album" item, each naming its commit.
  - Add §5's hardware checks under "Waiting — needs a real server".

## §5. Hardware checks (after merge, on the reference server)

1. **Upgrade.** `user_version` goes 2 → 3; row count equals the Phase 0 figure;
   no state changed; `discogs_collection` is gone; the log shows the counts.
2. **First sync.**
   - Requests = pages + 1.
   - `discogsLastSynced` advances only after the pass logs its summary.
   - Report exact/version/gated/ambiguous against 13.10's page-1 figures (they
     won't match exactly: the rules differ per R2/R3 and the full collection is
     203 items).
   - **Expect a large demotion on this first sync.** Phase 0 found all 478
     strict rows `confirmed` (written by step 3, before §13.4). Every one whose
     release is not in the collection drops to `candidate`, which could be
     most of them. That is §13.4/§15.3 working as designed, and it closes
     §15.3's accepted window. Record the promoted and demoted counts. Check 1's
     "no state changed" applies to the upgrade only.
3. **Second sync with nothing changed:** zero writes.
4. **Start a scan mid-sync:** the pass is `refused`, and the next rescan-done
   brings a sync that applies. This inherits step 5's checks (d) and (e).
5. **An untagged local album that is owned:** an ownership-only row appears; the
   next scan logs no invariant-1 error.
6. **Remove a record from the Discogs collection:** after a sync, its
   ownership-only row is deleted and a tagged row goes to `absent` /
   `candidate`.

---

## Appendix A — decisions §15.13 (text for B6)

### 15.13 Eight rulings for migration 3 and the ownership pass

**Decided 2026-09-19 (design chat)**, on the survey for
`plans/build-order-step-6-7-ownership.md`. Each was put as a choice; the reason
the chosen option won is recorded, and the plan carries the detail.

1. **One fetch, handed over.** The completed sync hands the pass its entry list
   in memory. The pass runs only if the list, de-duplicated by `instance_id`,
   matches `pagination.items`. The last-synced time means "ownership last
   derived". A re-fetch was rejected: it doubles §14.7's per-sync cost and
   contradicts §13.2. Running the pass on a count mismatch was rejected: a row
   dropped by pagination would silently remove a badge, which is §13.7's named
   failure.
2. **Q10: the LMS artist is the measured rule.** First ALBUMARTIST, else first
   ARTIST (each by contributor id), else `albums.contributor`, by raw SQL. It is
   what §13.10's split was measured with. `albums.contributor` alone was
   rejected: never measured against Discogs, and it depends on scan order for
   mixed-artist albums.
3. **Artists normalise at L2**, after the ` (N)` strip, plus §15.7's rule.
   §13.10.4 is read as applying to every text comparison with Discogs. The
   measurement script used L5 for artists, and that is recorded as a divergence
   between the script and the record, not as a rule. The change can only move
   albums from badge to queue (inferred), and the split is re-measured before
   shipping.
4. **Step 8 owns the queue marker.** Step 7 stores none: the collection is
   discarded, so an ambiguous untagged album leaves no trace until step 8 adds
   a nullable reason column. `ADD COLUMN` needs no rebuild (observed on SQLite
   3.45.1; LMS bundles 3.46.1, verified 2026-09-20), so the rule that a column lands
   in the step that reads it (TODO 2026-09-07) costs nothing here.
5. **A second permitted deletion in `discogs_match`**: `match_tier IS NULL AND
   discogs_release_id IS NULL AND snapshot_track_count IS NULL`, applied when
   the pass concludes `absent` or the album is gone. It passes §2a's governing
   rule (no decision, no snapshot), and without it §14.8's invariant cannot
   hold. **Amends §2a invariant 2's "the one place".**
6. **§2a invariant 1 covers identification rows only.** The importer's
   lookups filter `match_tier IS NOT NULL`, so an ownership-only row and a
   strict no-match row may coexist for one album. They answer different
   questions.
7. **§13.5's all-tags read moves to step 8.** Its only product is a queue item.
   Accepted gap until then: an album whose later tracks carry a different tag
   can badge `exact`.
8. **Step 7 ships with Q9 open.** Matches reached only through the Various
   equivalence stay unbadged per §15.7/§15.11 until the pages 2–3 measurement
   reports.

**Two further items, approved with the plan.**

- **`ownership` carries `DEFAULT 'absent'`.** Without a default, the importer's
  two INSERTs, which don't name the column, would fail and stop
  identification altogether. `absent` is §15.3's own value for a row no sync
  has concluded on. This is not the hazard §14.8 removed with `state`'s
  default: that default put albums into the review queue, while this one only
  withholds a badge until the next sync.
- **Obligation (g)'s EXPLAIN QUERY PLAN check is replaced by a finding.** No
  query in `SqueezeWax/` uses the orphan index (the relink matches in Perl),
  so the index is rebuilt as (g) requires and the check is recorded as having
  nothing to check (`TODO.md`, 2026-09-19).
