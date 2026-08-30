# SqueezeWax — v1 Scope & Design Decisions

Record of the design session covering build-order step 2 (SQLite schema) and
the matching preconditions. Supersedes the relevant parts of
`docs/squeezewax-design.md` §3, §10, §11, §13 and
`docs/implementation-plan.md` §4.3, §4.6.

Everything below was checked against `LMS-Community/slimserver` at commit
`50e5b725` (2026-08-25, v9.2.0) and against named third-party plugins.
Items marked **UNVERIFIED** are explicitly not confirmed and must not be
treated as settled.

All twelve `refs/slimserver`-sourced citations in this document were
re-verified by symbol against branch `public/9.1` on 2026-08-28; one
correction was made (§3, `DATE`/`MUSICBRAINZ_ID` attribution below). Line
numbers elsewhere in this document remain as cited against `50e5b725`/
v9.2.0 — resolve by symbol, not line, on `public/9.1`.

---

## 1. v1 scope (final)

**In:**

1. Plugin skeleton + `install.xml` that LMS loads — *done*
2. `<importmodule>Plugins::SqueezeWax::Importer</importmodule>` added to
   `install.xml` — **not yet present; blocking, see §6**
3. `Schema.pm` — plugin-owned attached SQLite database (§2)
4. Configurable Discogs tag names, ordered list, with detection (§3)
5. Strict-tier matching
6. Structural-tier matching
7. Review queue + manual re-match
8. OAuth + Collection sync (needed for the owned badge)
9. Owned badge (grid + Now Playing) + badge context menu
10. On-demand marketplace lookup

**Deferred out of v1:**

- **Triage / library-health page** → v2. A settings page listing only
  *problematic* releases so the owner can fix tags at source. Read-only about
  ownership; tagging is done elsewhere. Problem classes to show are listed in
  §5.
- **Completeness / misalignment detection** ("you have 9 of 12 tracks") → v2.
  Requires one release fetch per matched album; see §4.
- **"Add to Wantlist" action** → v2, alongside Wantlist sync.
- **Any write to the Discogs Collection** → **not planned.** Rationale in §5.

Unchanged from the existing roadmap: Fuzzy tier, Flow 1, Flow 2, statistics
dashboard, artist-level badge, currency conversion.

---

## 2. Storage — replaces spec §10 and implementation-plan §4.3

### Survival findings

- `Slim::Schema::wipeAllData` → `wipeDB` (`Slim/Schema.pm:2346`, `:363`) runs
  `SQL/SQLite/schema_clear.sql`, which `DELETE`s LMS's own tables by name and
  `DROP`s exactly two plugin tables (`fulltext`, `fulltext_terms`). Unknown
  plugin tables are **not** touched.
- Schema upgrades run `DBIx::Migration` over `SQL/SQLite/schema_N_up.sql`
  (`Slim/Schema.pm:436`); those only alter named LMS tables. A schema bump
  sets `schemaUpdated`, which fires a `wipecache` request
  (`slimserver.pl:987`) — i.e. the wipe path above.
- `library.db` is deleted outright by `cleanup.pl:197-199` (cleanup tool) and
  by `Slim/Schema/Storage.pm:56-66` (corruption recovery).

**Conclusion: tables survive; `albums.id` does not.**

### Album identity — the design-changing finding

- `albums.id` is `INTEGER PRIMARY KEY AUTOINCREMENT`
  (`SQL/SQLite/schema_1_up.sql:112-113`). A wipe deletes and reinserts every
  album row, so every album gets a new id.
- Tested: `DELETE FROM` without `WHERE` does **not** reset `sqlite_sequence`
  for an `AUTOINCREMENT` table (SQLite 3.45.1, autocommit and transactional).
  So within one file ids are never reused — matches dangle harmlessly. But if
  the file is deleted, the sequence restarts at 1 and ids *are* reused for
  different albums → silent wrong badges.
- Non-wipe rescans: `_createOrUpdateAlbum` (`Slim/Schema.pm:932`) looks up by
  title / musicbrainz_id / extid / disc / discc / contributor / compilation
  (deliberately not year), so ids are stable while those tags are. But
  `Slim::Schema::Album->rescan` (`Album.pm:383-405`) does
  `DELETE FROM albums WHERE id = ?` when an album's last track goes, called
  from `Slim/Utils/Scanner/Local.pm:1105-1107`. **Re-tagging an album title or
  album artist therefore produces a new album id even without a wipe** — which
  is precisely the §3 "tags changed" re-match trigger.
- Precedent: LMS's own `tracks_persistent` (`SQL/SQLite/schema_6_up.sql`,
  header comment: *"This data survives a rescan"*) lives in a separate file
  and keys on `url` / `urlmd5` / `musicbrainz_id`, never `tracks.id`. Erland's
  TrackStat does the same. slimserver issue #397 records the Music and Artist
  Information plugin making exactly the mistake of caching on changing
  artist/album IDs.

### Decisions

**Location.** A plugin-owned file, `squeezewax.db`, created at runtime in the
LMS **preferences** directory — resolved by calling LMS's own accessor,
`sqlHelperClass->dbFile($name, $persistent)` (`SQLiteHelper.pm:556-566`),
rather than reimplementing its body. The second argument is a plain boolean;
in-tree callers pass different truthy values (`'persistent'` at `:345`,
a regex result at `Slim/Schema/Storage.pm:62`). Its persistent branch is
`Slim::Utils::Prefs::dir() || Slim::Utils::OSDetect::dirsFor('prefs')`.
Attached as schema `squeezewax`.

Not `library.db` (dies with the cache). Not `persistentdb` (squatting in a
file LMS owns). **Never inside the plugin directory** — installed plugins live
under `cache/InstalledPlugins/Plugins/<Name>/` and are replaced wholesale on
every plugin update, which under the dev-repo workflow is several times an
hour.

**Attach point.** Inside a `postDBConnect` handler registered via
`Slim::Utils::OSDetect->getOS()->sqlHelperClass()->addPostConnectHandler(...)`
(`SQLiteHelper.pm:390-402`, documented in-file as intended for plugins; sole
in-tree user is `Slim/Plugin/FullTextSearch/Plugin.pm:199`). An `ATTACH` is
per-connection, which is why LMS attaches `persistentdb` from `postConnect`
(`SQLiteHelper.pm:345-355`) rather than once at startup. This also re-asserts
the schema after the post-scan reconnect at `SQLiteHelper.pm:626-628`.

**Registration.** Both `Plugin.pm::initPlugin` and `Importer.pm::initPlugin`
call `Plugins::SqueezeWax::Schema->init()`, which does the registration.

**Versioning.** `PRAGMA squeezewax.user_version`. Verified working
schema-qualified on an attached file and persisting across close/reopen.
Chosen over `$prefs->migrate` (`Slim/Utils/Prefs/Namespace.pm:354-375`)
because prefs and the database file are destroyed independently, so a
prefs-held version can claim v5 against a database that doesn't exist.

**Migration.** An ordered list of Perl subs in `Schema.pm`, each bumping
`user_version`, run from the `postDBConnect` handler, every step idempotent.
Not shipped `.sql` files, and not TrackStat's feature-detection probes
(`lms-trackstat/src/Storage.pm:147-340`).

**DDL process.** Server only. The scanner assumes the tables exist and fails
loudly otherwise. Basis: a CustomScan forum log showing
`database is locked [for Statement "DROP TABLE customscan_track_attributes"]`.
Old evidence, prudent rule — see §6.

**No foreign keys into LMS tables.** LMS sets `PRAGMA foreign_keys = ON`
(`SQLiteHelper.pm:99`). A `FOREIGN KEY (lms_album_id) REFERENCES albums(id)
ON DELETE CASCADE` — the obvious thing to write, and what LMS's own `tracks`
table does — would be silently emptied by `schema_clear.sql`'s
`DELETE FROM albums`. Verified empirically. Using a separate attached file
makes the constraint impossible to create at all (SQLite resolves FK targets
within the same database), which is a further argument for the layout.

### Keying — replaces `lms_album_id` as identity

- `album_key` — hash over the album's tracks' `urlmd5`, sorted. `urlmd5` is
  real and indexed (`SQL/SQLite/schema_12_up.sql:11-12`) and is LMS's own
  cross-wipe key.
- `mb_album_id` — `albums.musicbrainz_id` where present, as a secondary
  resolution path.
- `lms_album_id` — retained as a denormalised cache column, refreshed on
  rescan-done, **never** trusted as identity.
- A resolution miss means "unmatched, re-run the cascade": fails to no badge,
  never to a wrong one.

Rejected: directory-hash keying (two LMS albums can share a directory →
collision → wrong badge, incompatible with §4's per-edition requirement);
anchor-track keying (deleting one specific file orphans an intact album);
content-fingerprint keying (cannot distinguish two editions with identical
track shape, again incompatible with §4).

### Orphan recovery

Store an identity snapshot alongside each confirmed match: artist, album
title, track count, total duration, `discogs_release_id`.

On a key miss, before running the cascade, look for an orphaned confirmed
match whose snapshot fits. Exactly one exact fit → relink automatically (the
same confidence bar Structural already auto-confirms on, applied to something
the user personally confirmed). Ambiguous → review queue, pre-filled with the
previous answer.

This turns "reorganised my music folders, lost every match and every manual
confirmation" into "reorganised my music folders, got a short review queue."

### Additional table

`discogs_release_cache`, keyed on `discogs_release_id`. Untouched by anything
LMS does to its own database, so relinks and completeness checks cost no API
calls once populated. Add to §10 explicitly rather than leaving it implied by
§3's "cached in a local SQLite table."

### The optimize step reaches into our file

Content is untouched, but the file itself is not fully hands-off:
`SQL/SQLite/schema_optimize.sql` ends with a bare, schema-unqualified
`ANALYZE;` (`refs/slimserver/SQL/SQLite/schema_optimize.sql:15`), run by
`Slim::Schema->optimizeDB` against `$class->storage->dbh`
(`Slim/Schema.pm:393-411`) — the same connection our `postDBConnect` handler
has attached `squeezewax` to. Per SQLite's own semantics, `ANALYZE` with no
schema-name analyzes every attached database, not just `main`. Confirmed on
the real server: `squeezewax.db` contains a `sqlite_stat1` table nobody here
created.

Harmless — it improves our own query planning and touches no row we own —
but it means LMS's post-scan housekeeping does write into `squeezewax.db`.
Worth knowing before treating an unexpected table there as a sign of
corruption or foreign access.

---

## 2a. `discogs_no_match` — the examined-and-found-nothing record

**Decided 2026-08-29 (design chat), during build-order step 3 planning.**

Migration 2 adds a second table alongside `discogs_match.source_timestamp`:

```
discogs_no_match
  album_key        TEXT NOT NULL CHECK (length(album_key) = 32)
  tier             TEXT NOT NULL CHECK (tier IN ('strict','structural'))
  source_timestamp INTEGER
  checked_at       INTEGER NOT NULL
  PRIMARY KEY (album_key, tier)
```

A row means: this tier was attempted for this album at this source state and
produced no candidate.

### Why a row at all

Without one, an album with no Discogs tag gets nothing written, so every
rescan re-reads one or two of its files forever. At step 3 that is disk
rather than API — but LMS reads *no* audio files on a no-change rescan, so
we would be adding one read per unmatched album where there were none. On a
mostly-untagged 5,000-album library on slow storage that is minutes per
rescan for no result. At step 4 the same albums would re-run a Discogs
search every scan, which is not merely slow.

### Why a separate table rather than a `'none'` tier in `discogs_match`

Three reasons, in order of weight:

- `discogs_match` is the one table that is **not** disposable (§2, design
  §10). Negative rows are pure regenerable cache; mixing them in couples
  cache lifetime to durable state.
- They would pollute the `(state, snapshot_track_count)` orphan-recovery
  index, whose whole population is meant to be confirmed matches with a
  snapshot.
- Every review-queue and badge query would need a new exclusion predicate,
  and forgetting one degrades to a wrong badge rather than an error.

`match_tier` is also defined as the provenance of *a match* (design §3).
There is no match here.

### Why now rather than at step 4

Nothing has shipped past `user_version` 1, so this rides migration 2 instead
of needing a migration 3; commit 5's skip logic is written once against both
tables instead of written and then rewritten; and step 4's strict negatives do
not need rebuilding (its own structural negatives are still built from
scratch, since `tier` is part of the key). The table is
entirely regenerable, so a wrong guess costs `DROP` and recreate — the same
argument design §10 makes for `discogs_collection`, and the reason deciding
early is safe here and would not be for `discogs_match`.

### Shape notes

- **PK `(album_key, tier)`, not `album_key`.** Strict-negative ("don't
  re-read the file") and Structural-negative ("don't re-run the search") are
  different facts with different costs, and step 4 needs both to be true of
  one album simultaneously.
- **`tier` carries a CHECK**, matching the `match_tier` convention and its
  reasoning: a typo'd value degrades to "not examined", which is
  indistinguishable from correct behaviour and therefore silent.
- **`'fuzzy'` is deliberately absent.** Fuzzy is v2. Widening the CHECK means
  `DROP` + recreate on a regenerable table, which is the cheapest migration
  available.
- **Skip semantics are identical to `discogs_match`**: skip when a row exists
  *and* `source_timestamp` equals the album's current `MAX(tracks.timestamp)`.
  A NULL `source_timestamp` therefore never skips, which is the correct
  behaviour for an album whose timestamp cannot be established (see the
  online-library case in TODO).
- **`checked_at NOT NULL`** is inert for Strict and load-bearing for
  Structural, where a search that found nothing today may find something in
  six months. The staleness policy itself is **step-4 scope and not decided
  here**; the column exists so step 4 can add one without a migration.

### Invariants

1. An album never has a row in both `discogs_match` and `discogs_no_match`
   for the same tier. Enforced in `Match.pm`; asserted in the offline suite.
   No constraint can express it — foreign keys are banned (§2) and SQLite
   has no cross-table CHECK.
2. A tag **conflict** is not a no-match. It writes to `discogs_match` per
   §3a. A `discogs_no_match` row means nothing was found at all.
   Where an album that already has a conflict row later loses its tags
   altogether, the conflict row is **deleted** and a `discogs_no_match` row
   written as normal, so invariant 1 holds without a special case and
   "no tag found → write a no-match row" has no exception. The deletion is
   permitted for exactly
   `match_tier = 'strict' AND state = 'candidate' AND
   discogs_release_id IS NULL AND snapshot_track_count IS NULL`.
   The governing rule is **never delete a row that carries a decision or a
   recovery snapshot** — that predicate is the rule written out, not an
   exemption from it. Refreshing the row in place instead was considered and
   rejected: it leaves the album in the review queue permanently advertising a
   conflict that no longer exists and that step 5 cannot render, since §3a
   stores no `conflict_note` and re-reads tags that are now absent.
   Narrowing a never-delete rule does create a boundary someone can widen, so
   the test to apply is the reason above, never resemblance to this row shape.
3. The table is entirely regenerable. Orphan recovery must never read it,
   and design §9's "clear & rebuild matches" action must clear it.
4. Rows orphaned by an `album_key` change are **not** swept in v1. Growth is
   bounded by library churn and the maintenance action is the escape hatch.
   Recorded in TODO rather than built.

---

## 3. Tag reading — new, v1

### Finding: LMS discards custom tags

Format readers return every tag found — `Slim::Formats::FLAC::_getStandardTag`
hands back the whole hash and only *renames* known ones (`FLAC.pm:220-265`) —
but the scanner writes only known columns. MusicBrainz IDs survive because LMS
special-cases them (`FLAC.pm:50`). A Discogs release ID has no column and does
not survive.

`Importer.pm` must therefore re-read tags from the file. The API is
`Slim::Formats->readTags($url)` (`Slim/Formats.pm:153`), used by AF-1's
actively maintained Custom Tag Importer
(`CustomTagImporter/Common.pm:492`).

### Finding: there is no standard tag name

foo_discogs stores the ID as a custom tag and its documentation states that
flexible tag mapping lets the user write what they want where they want.
`DISCOGS_RELEASE_ID` and `DISCOG_RELEASE_ID` (no S) both appear in Discogs'
own forum threads; some setups store the full release URL.

Worse, the key *shape* differs by format. Custom tags reach LMS keyed by the
tagger's label, uppercased: the Vorbis field name for FLAC, the `TXXX` frame
description for MP3. LMS's own tables show the consequence — the same
MusicBrainz tag is `'MUSICBRAINZ_ALBUMID'` in `FLAC.pm:50` and
`'MUSICBRAINZ ALBUM ID'` (spaces) in `MP3.pm:46-49`. A single configured tag
name would silently fail on half a mixed-format library.

### Decisions

- **Ordered list of tag names** in Settings, precedence by position, first hit
  wins. Stored as an arrayref pref (LMS supports these natively; `mediadirs`
  is one).
- **Detection rather than guessed defaults.** A Settings action samples albums,
  reads them with `readTags`, and reports every tag key found whose value
  looks like a Discogs ID or URL, with counts. The user ticks what they want.
  This also serves as the coverage report, so silent failure is impossible.
- **One parser for all matched tags.** Accept a bare number, a
  `discogs.com/release/123456-Title` URL, and `[r123456]` markup. Values may
  arrive as a scalar **or an arrayref** — LMS special-cases this per format,
  not in one place: `MUSICBRAINZ_ID` in `MP3.pm:343-344`, `DATE` in
  `FLAC.pm`'s `doTagMapping` (~247-251). Another instance of this section's
  format divergence — FLAC and MP3 don't even special-case the same tags in
  the same file, let alone present them the same way.
- **Disagreement is not Strict.** Two configured tags present with different
  IDs, or a value that doesn't parse → review queue, not first-wins. Strict's
  justification is "no ambiguity"; the moment there is ambiguity it isn't
  Strict.
- **Read one track per album**, not all. A compilation assembled from
  per-track tagging is not a maintained collection and isn't worth paying 12×
  the file reads to accommodate. If the first track has no configured tag, try
  one more before falling through to Structural.
- **Capture the neighbours** while the file is open: master release ID and
  artist ID. Free, and they serve master-release resolution (§6) and the v3
  artist badge without a later re-read.

---

## 4. API request budget — corrects spec §13

Endpoint facts:

- **Collection sync** returns `instance_id`, `rating` and a
  `basic_information` block per item. **No tracklist.** Paginated at a maximum
  of **100 per page** (confirmed by Discogs staff on the equivalent inventory
  endpoint). A 2,000-item collection is ~20 requests.
- **`GET /releases/{id}`** is the only endpoint returning a tracklist.
- **Search results** carry id, title, year, country, format, label and
  catalogue number — but no durations.

Consequences:

| Operation | Cost |
|---|---|
| Strict match | **0 requests** — the tag names the release |
| Owned badge | ~20 requests per collection sync |
| Structural match | 1 search **+ 1 release fetch per candidate pressing** |
| Completeness check (v2) | 1 release fetch per matched album, cacheable forever |

**§13's "1–2 search requests per album" is too low for Structural.** An album
with eight pressings on Discogs costs nine requests, not two. A library with
1,000 untagged albums is closer to two hours than thirty minutes.

**Mitigation, and it belongs in the spec:** filter search candidates on
format, year and country *before* fetching any tracklists. A CD rip does not
need the vinyl pressings fetched. This is free — the fields are already in the
search response.

Net effect for a well-tagged (Strict-dominant) library: cold matching is
**disk-bound, not rate-limit-bound**. Much of §13's caution about batching and
throttling was sized against a constraint that mostly does not apply.

---

## 5. Ownership model — clarifies §3/§4, no code change

Confirmed sound as designed, and worth recording because it looks like a gap
and isn't:

A CD ripped from a library and tagged with a Discogs release ID gets a
**confirmed match** but **no badge**, because §4 derives the badge by asking a
second, separate question — is that release in `discogs_collection`? It isn't.
The match records *which release this is*; the Collection records *whether you
own it*. The match is still useful for cross-browsing, marketplace lookup,
credits and pressing details.

Selling a record and removing it from Discogs makes the badge disappear at the
next sync. Self-maintaining, nothing to remember in LMS.

**No local "owned" flag, and no write to the Discogs Collection.** Rationale:
adding to the Collection is a record-in-hand act performed on the Discogs
website, where the pressing is chosen by inspecting the physical object; LMS
cannot see the object and has no advantage. A local flag would create a second
source of truth with no defined winner at sync time, and could not feed
collection value or statistics, which need a real instance with condition,
folder and acquisition date.

**Wantlist is different and is in scope for v2.** Wanting something happens
from the armchair, has no physical object, and happens exactly where §6 puts
the user — browsing pressings of an album they just heard. The alternative to
a button is forgetting. It is also far lower risk: a want is a release ID plus
optional notes and rating, against a collection instance's condition, sleeve
grading, folder, date and custom fields.

Endpoint: **`PUT /users/{username}/wants/{release_id}`**. Two Discogs forum
threads report `POST` on the same path returning *"That release does not exist
in the user's wantlist"* — POST updates an existing want, PUT creates one.

For reference if ever revisited, collection add is
`POST /users/{username}/collection/folders/{folder_id}/releases/{release_id}`
with a non-zero `folder_id` (0 is the read-only "All" view, 1 is
"Uncategorized").

### Triage page (v2) — problem classes to surface

Read-only about ownership. Show only rows with a problem, plus a summary line
("1,847 matched, 112 need attention"); do not render the whole library.

- No Discogs tag found
- Multiple configured tags present, disagreeing
- Tag present but unparseable
- Release ID present but Discogs returns nothing (deleted release)
- Structural search found candidates but couldn't decide
- Partial multi-disc match
- Matched, but the release is in neither Collection nor Wantlist
- Incomplete — fewer local tracks than the Discogs tracklist

---

## 6. Process and lifecycle facts

- **Server:** `Slim::Schema->init()` at `slimserver.pl:437` precedes
  `PluginManager->load()` at `:482`, so the schema is ready in all three
  passes (`preinitPlugin` / `initPlugin` / `postinitPlugin`,
  `Slim/Utils/PluginManager.pm:387`).
- **Scanner:** `Slim::Music::VirtualLibraries->init()` (`scanner.pl:256`)
  reaches `Slim::Music::Import::_checkLibraryStatus`
  (`Slim/Music/Import.pm:793-797`), which calls `Slim::Schema->init()` before
  `PluginManager->load('import')` at `:284`. Schema is ready there too.
- **The scanner is a separate OS process** (`Slim::Music::Import->launchScan`),
  with its own connection to the same files, communicating back over HTTP
  (`SQLiteHelper.pm:74-79`). `checkDataSource` and `beforeScan` are now empty
  stubs whose bodies read `# No longer needed with WAL mode`
  (`SQLiteHelper.pm:277-289`) — both processes write `library.db` live under
  WAL.
- **The scanner never loads `Plugin.pm`.** `load('import')` skips any plugin
  without an `<importmodule>` and initialises only that class
  (`PluginManager.pm:204`). Anything the importer needs — schema attach,
  migration, log category, prefs — must be registered from
  `Importer.pm::initPlugin`.
- **`SqueezeWax/install.xml` currently has no `<importmodule>` element.**
  Without it the plugin is absent from every scan. Fix before step 2.
- **Transactions:** `scanner.pl:295` sets `AutoCommit = 0` once and never
  restores it, so per-track work runs inline in one long-lived transaction
  (`Local.pm:1135-1139`). Commits are `Slim::Schema->forceCommit`
  (`Schema.pm:2365-2390`) at intervals (`Local.pm:357, 472, 556, 638`), at each
  `endImporter` (`Import.pm:746`), and at cleanup (`scanner.pl:450`). There is
  **no rollback anywhere in the scan path**.
  - Good: an aborted scan cannot discard already-committed matches. §8's
    promise holds mechanically.
  - Required: `Importer.pm` must call `forceCommit` on a cadence, or an
    interrupted run loses every match since the last commit.
- **Rescan change detection (closes implementation-plan §4.6):**
  `Slim::Utils::Scanner::API` provides `onNewTrack`, `onChangedTrack`,
  `onDeletedTrack`, `onNewPlaylist`, `onDeletedPlaylist`, `onFinished`, with a
  POD synopsis at the top of the file. Firing sites: `Local.pm:946` and `:1273`
  (new), `:708` (deleted), `:1130` (changed), `:1190` (finished). In-tree
  users: `Slim/Plugin/FullTextSearch/Plugin.pm:215-217`,
  `Slim/Plugin/MusicMagic/Plugin.pm:202-204`. Options are
  `{ cb => sub {...}, want_object => 0|1 }`; the POD warns against
  `want_object` on scanner-performance grounds. These are **track**-level —
  accumulate affected album ids and do the deduped work at the end.

  **Correction (implementation, build-order step 2): `onFinished` is the wrong
  hook for the `lms_album_id` cache refresh.** Use the server-side
  `['rescan','done']` notification via `Slim::Control::Request::subscribe`,
  debounced — the hook `Slim::Schema` itself uses (`Slim/Schema.pm:243-248`)
  and `FullTextSearch` uses (`:204-209`). Three reasons:
  - **Wrong process.** For an external scan `onFinished` fires inside the
    scanner; the cache column is a server-side convenience.
  - **Too early.** `markDone` ends the media-folder phase only. `runScan`
    (`Import.pm:371`) returns, and `runScanPostProcessing` (`:432-460`) then
    runs the `post` importers — `ReleaseTypes`, `VirtualLibraries` — which
    still touch `albums`.
  - **Incomplete coverage.** It fires only if `Scanner::Local::rescan` ran.

  `['rescan','done']` also demonstrably fires where the plugin can write: in
  `SQLiteHelper::_notifyFromScanner` the post-scan
  `Slim::Schema->disconnect; Slim::Schema->init;` is at `:626-628` and the
  notification at `:638`, so the reconnect — and our re-ATTACH — happens
  first. It fires more than once per logical scan (six sites:
  `SQLiteHelper.pm:638`, `Import.pm:238`, `:741`, `Local.pm:391`, `:663`,
  `:1224`), hence the debounce.

  The track-level hooks are still the right mechanism for the *re-match*
  trigger, but they have no route from the scanner process to the server —
  see TODO.md, open design question.

---

## 7. Open items

**UNVERIFIED — needs a real server or a real answer:**

1. **Material Skin.** Whether a plugin settings page renders in Material Skin,
   and whether a custom page via `Slim::Web::Pages->addPageFunction`
   (`Slim/Web/Pages.pm:119`) does. This now blocks two features — the §4 badge
   overlay and the v2 triage page — so it is worth answering early. A settings
   page is the likely skin-safe choice, but this is not confirmed.
2. **`addPostConnectHandler` from a third-party plugin.** One in-tree caller
   and it is bundled. Registration forces a disconnect/reconnect
   (`SQLiteHelper.pm:396-402`); the interaction with plugin load ordering has
   been read, not observed.
3. **DDL during a scan.** Only evidence is a 2016 CustomScan log. WAL and
   `sqlite_use_immediate_transaction` (`SQLiteHelper.pm:357`) have both changed
   since. Treat "no DDL from the scanner" as prudent, not proven.
4. **Album-id stability on a normal rescan.** Read from source, not observed.
   Testable in ten minutes: record some album ids, rescan, compare; then edit
   an album title and rescan again.
5. **Plugin-owned attached database as a pattern.** No LMS documentation
   exists on this at all — `DEVELOPERS.md` in the 9.2.0 tree has nothing.
   A forum question is drafted; **not blocking**, because an own-file layout
   cannot collide with or corrupt anything LMS owns, and migrating a v0.x
   plugin's own file later is cheap.

**Carried forward unchanged from spec §12:**

- FX-rate source for the optional currency conversion (v3, not v1).
- Multi-disc edge cases validated against real Discogs release data.
