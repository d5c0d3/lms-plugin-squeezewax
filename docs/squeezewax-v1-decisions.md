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

- **Ordered list of tag names** in Settings, precedence by position. Stored as
  an arrayref pref (LMS supports these natively; `mediadirs` is one).

  **Position determines which tag name is *reported* as the source of a clean
  hit — it does not resolve a disagreement.** An earlier draft of this bullet
  said "first hit wins", which contradicts the "Disagreement is not Strict"
  bullet below and the whole of §3a. The shipped behaviour is the latter: when
  every configured tag that is present agrees, the highest-placed one is
  recorded as `match_tier`'s source; when they disagree, none of them wins and
  the row goes to the review queue with a NULL `discogs_release_id`.
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
- **Capture the master release ID** while the file is open, from a conventional
  tag name. Free, and it serves master-release resolution (§6) without a later
  re-read. It has a column: `discogs_match.discogs_master_id`.

  **The artist ID is deliberately *not* captured** (build-order step 3, commit
  3). This bullet originally said to capture it alongside, justified as saving
  a later re-read — but there is nowhere to put it. Migration 1 has no artist
  column, nothing reads one before the v3 artist badge, and step 2's finding 8
  is the precedent for not carrying a column nothing reads. With no column
  there is no re-read saved, only a variable that is discarded. Recorded in
  TODO.md under *Deferred by decision* so the v3 work knows to add both the
  column and the capture together.

---

## 3a. Conflicting Discogs tags — what the row records

**Decided 2026-08-29 (design chat), during build-order step 3 planning.**
Implements §3's "disagreement is not Strict".

Two configured tags parsing to different release IDs, or a configured tag
whose value does not parse, writes a row in `discogs_match`:

- `match_tier = 'strict'` — provenance is honest; strict tag reading is the
  mechanism that ran.
- `state = 'candidate'` — auto-confirm is withheld, and the album is in the
  review queue.
- **`discogs_release_id = NULL`.**
- `source_timestamp` and `lms_album_id` set as normal.
- `snapshot_*` left NULL — the snapshot is captured at confirm time and
  nothing has been confirmed.

The competing values are logged once at `warn`, naming the album and every
value found. The row's `source_timestamp` means this does not re-warn on
every subsequent scan; fixing the tags moves the file mtime, the album is
re-examined, and the row is updated in place.

### Why NULL rather than the highest-precedence tag's ID

Writing the top-precedence ID is first-wins by another name, and §3 rejects
first-wins explicitly. The `candidate` state stops it *acting*, but the
column would still assert a release that nothing adjudicated — available to
any future query that reads `discogs_release_id` without also checking
`state`. NULL records what actually happened: strict ran and produced no
decidable answer.

It is also the more durable discriminator. Step 2's finding 9 established
that the orphan-recovery ambiguous branch carries an existing row's values
forward into the review queue, which can produce `(match_tier, state) =
('strict','candidate')` for reasons having nothing to do with tags. The pair
is therefore not a reliable conflict marker; a NULL release id on a
candidate row is.

So the review queue reads:

- `state='candidate' AND discogs_release_id IS NULL` → we examined and could
  not decide; show the user their competing tag values.
- `state='candidate' AND discogs_release_id IS NOT NULL` → we have a
  proposal; ask the user to confirm it.

### Why no `conflict_note` column

The file tags are the source of truth and can change between the scan that
would write the note and the review that reads it, so a stored copy needs
invalidating on `source_timestamp` change to stay honest. Re-reading is
simpler and always current: step 5's review queue calls
`Slim::Formats->readTags` (`Slim/Formats.pm:153`) on the album's primary and
fallback tracks when the user opens the entry — server process, user-
initiated, one or two reads, bounded. If the files are gone the queue
degrades to "conflict recorded, tags no longer readable", which is the
truth.

This also follows step 2's finding 8: do not add a column nothing reads yet.

### Why not a fifth `match_tier` value

`match_tier` is defined as provenance — which mechanism established the link
(design §3). A conflict is a state, not an origin, and this row's origin
genuinely is strict tag reading. A fifth value would require amending the
four-value vocabulary in design §3 and §10, the CHECK in migration 1, and
every future reader, to express something `state` already expresses.

### Why not fall through to Structural

Rejected outright, and more strongly than "it contradicts §3". At step 4 a
Structural search could auto-confirm a *third* release over the top of two
tags the user wrote deliberately, producing a silently wrong badge with no
trace of the disagreement that caused it.

### v1 invariant, and the trigger to revisit

`state='candidate' AND discogs_release_id IS NULL` means "examined, could not
decide". Step 4 must not produce a NULL-id candidate for any other reason —
~~Structural's partial-multi-disc candidate and Fuzzy's master-release
candidate both carry a proposed id.~~ — **Amended 2026-09-07 (decisions §8).**
This was written assuming Structural resolves a specific pressing. It cannot:
pressings of one edition share a tracklist, verified against master 3855547,
whose LP variants are indistinguishable by track count or duration.
Structural therefore writes `discogs_master_id` with a NULL
`discogs_release_id` by design.

The invariant is restated rather than dropped. A row with a NULL
`discogs_release_id` must carry one of:
  - a strict conflict context (`match_tier = 'strict'`, `state =
    'candidate'`) — §3a's original case; or
  - a `discogs_master_id` (`match_tier = 'structural'`) — an
    edition-level match.
A NULL-id row carrying neither is a defect.

What this does NOT change: `Match.pm::_recordNoMatch`'s delete
predicate stays exactly as written. It is scoped to
`match_tier = 'strict'`, so a structural NULL-id row is already
outside it. Structural needs no delete path of its own, and the
predicate must not be widened or parameterised by tier — see §2a
invariant 2.

The alternative considered and rejected: writing the master's
`main_release` as a nominal `discogs_release_id` to preserve the
original invariant. That asserts a pressing we did not determine,
which is the failure the tier design exists to prevent.

**If a later tier genuinely needs a
NULL-id candidate, that is the trigger to reopen `conflict_note`** — not a
reason to overload this one silently.

### What a conflict does to an existing row

The record above covers *establishing* a conflict row. The transition it does
not cover is reachable the first time anyone edits their tag list: an album is
`strict` / `confirmed` / r123 from `DISCOGS_RELEASE_ID`, the user adds
`RELEASE_ID` to the list, §3b NULLs `source_timestamp`, the next scan
re-examines, and the two configured tags now disagree.

Read literally, the rules above would write `state = 'candidate'` and
`discogs_release_id = NULL` — wiping an adjudicated answer, which §2a's
governing rule exists to prevent. Keeping the row while destroying what the
rule protects is not compliance with it.

**Decided: demote to `state = 'candidate'`, keep the incumbent
`discogs_release_id`, and log every competing value at `warn`.**

The badge join is `state = 'confirmed'`, so the badge stops immediately and the
user gets a visible signal rather than a silent one. The album lands in the
review queue *with* a proposal, which is what a review queue is for. And it does
not contradict the NULL rule above, whose actual argument is that taking the
top-precedence tag's id would be first-wins under another name: preserving an
incumbent is not choosing between the competing tags. That choice was already
made, and §2a says a decision survives.

The v1 invariant is unchanged. `candidate` + NULL id still means "we examined
this and could not decide"; `candidate` + non-NULL id means "we propose this,
confirm it".

**Rejected — NULL it as the rules above read.** The badge vanishes with nothing
to explain it beyond one `warn` line, and the album enters the queue with no
proposal.

**Rejected — refuse to overwrite a confirmed row and only log.** That preserves
the decision but leaves a badge standing on evidence we now know is contested,
with no user-visible signal. Silent is the wrong failure direction here.

A `match_tier = 'manual'` row is outside all of this, per the write path's first
rule: it is never overwritten, and only its `source_timestamp` and
`lms_album_id` are refreshed.

### `matched_at` is deliberately preserved on a demotion

A demotion does not touch `matched_at`, so a demoted row carries the timestamp
of the match it still holds, while a *fresh* conflict carries its discovery
time. The two mean different things in the same column.

That is the correct trade, but it has a consequence worth stating rather than
discovering: **`matched_at` does not answer "when did this become a problem".**
A review queue sorted by it would place last night's demotion among rows from
years ago — wrong information rather than missing information.

Overwriting it is not the fix. The row still carries the incumbent
`discogs_release_id`, and when *that* was established is genuinely useful and
genuinely unrecoverable if stamped over. The only real alternative is a new
`state_changed_at` column, and that is not being added now: only the conflict
path would ever write it, so the rows that benefit are identical whether it
lands now or later — NULL before the first demotion either way — and adding it
speculatively is the pattern step 2's finding 8 rejected. `checked_at` was the
exception because step 4's staleness policy is a named, certain consumer; "step
5's queue might sort by date" is not, and a queue of thirty albums may well sort
by artist.

The information is not lost meanwhile: the conflict is logged at `warn` with the
album label and every competing value, and `scanner.log` is timestamped. The
discovery time is on record, just not queryable — a much smaller claim than
"nothing records it". If step 5 wants it queryable it ships migration 3 with a
nullable column, which finding 8 itself calls the cheap kind of migration, and
by then the requirement is concrete.

---

## 3b. Changing the configured tag names invalidates the strict answer

**Decided 2026-08-30 (design chat), during build-order step 3 review.**

Both skip caches — `discogs_match.source_timestamp` and every
`discogs_no_match` row — key on file state alone. The strict answer also
depends on `discogsTagNames`, which is not in that key. Without explicit
invalidation, changing the tag-name list changes nothing on the next scan:
every album is skipped because no file moved.

Three failures follow, all silent:

- The common one. A user ticks the wrong tag first, gets 4,800 no-match rows,
  corrects the list, rescans — and nothing happens. Finding 4's
  `matched == 0 && examined > 0` warning cannot catch it, because `examined`
  is zero.
- Removing one of two conflicting tag names leaves the album's
  `(strict, candidate, NULL)` row in place, so it stays in the review queue
  with a conflict that no longer exists.
- Adding a tag name that outranks the configured one can change which ID wins
  on an already-`confirmed` album, or create a conflict where there was none.
  Those albums skip too.

**"Alters the list" means the SET of names changed, compared
case-insensitively.** Added or removed names invalidate; a pure reorder or a
change of case does not. Position only decides which tag name is *reported* as
the source of a clean hit, and no column stores that — so making a reorder cost
a full cold pass over every local file would be a real cost for no benefit.
Case is excluded because `_lookup` already folds it, so a re-cased name matches
exactly the same tags.

**On a Settings save that alters the list**, and only then:

```sql
DELETE FROM squeezewax.discogs_no_match WHERE tier = 'strict';
UPDATE squeezewax.discogs_match SET source_timestamp = NULL
 WHERE match_tier = 'strict';
```

`DELETE` on `discogs_no_match` because it is regenerable in full (§2a); the
rows cost re-reads, never a match.

`UPDATE` rather than `DELETE` on `discogs_match` because every row this
predicate touches may carry a decision — `state = 'confirmed'` is one, and any
non-NULL `discogs_release_id` is a proposal something adjudicated — and §2a's
rule is *never delete a row that carries a decision or a recovery snapshot*.
NULLing `source_timestamp` forces re-examination without discarding anything.
Where re-examination then finds no tag at all, §2a's narrow delete predicate
applies at that point, in the importer, not here: the two mechanisms compose,
and invalidation is never the thing that removes a row. `match_tier = 'manual'`
rows fall outside the predicate entirely and are untouched, consistent with the
write path's first rule.

The write is safe because the settings page already refuses to save while
`Slim::Music::Import->stillScanning` is true (finding 2b).

**Cost:** one cold pass over local files on the next scan. That is the correct
price for a rare, deliberate user action, and it is predictable.

Three alternatives were rejected, ordered by how likely each is to be proposed
again.

**Rejected — `$prefs->setChange`.** It is the obvious way to catch the change
wherever it happens, and in-tree plugins use it
(`Slim/Utils/Prefs/Namespace.pm:148`; callers at
`Slim/Plugin/PreventStandby/Plugin.pm:47-48`,
`Slim/Plugin/UPnP/MediaServer.pm:52`). But
`Slim::Utils::Prefs::Base::set` dispatches onchange on
`!defined $old || !defined $new || $old ne $new || ref $new` — and
`ref $new` is always true for an arrayref pref, so the callback fires on
*every* save, changed or not. The scalar "no change" short-circuit earlier
in `set` is likewise gated on `!ref $new`. A `setChange` implementation
would therefore force a full cold re-read pass on every settings save,
including one that only toggled a checkbox. `set` does pass an
undocumented fourth argument (`$func->($pref, $new, $obj, $old)`) that
would allow a comparison, but the POD documents three, and building this on
undocumented behaviour buys nothing the handler does not already give.

There is in-tree precedent *for* the handler approach, not merely against the
alternative: `Slim/Web/Settings/Server/Basic.pm:118-121` compares the old
`mediadirs` against the new inside the handler to decide whether to trigger a
rescan, rather than hooking an onchange callback.

**Rejected — partial invalidation.** Clearing no-match rows and NULLing only
the `(candidate, NULL)` conflicts, leaving confirmed rows alone, is cheaper.
Its failure mode is chosen rather than accidental: a newly-added tag name
would never revisit an album that already matched, so it could never correct
a wrong pressing or surface a conflict that now exists.

**Rejected — a tag-list fingerprint per row.** More schema and more code for
an identical outcome. Recorded so it is not re-proposed.

**Coverage gap, accepted.** Hooking the handler misses a change made outside
the settings page — the CLI, or a hand-edited prefs file. Both require
deliberate action, and design §9's "clear & rebuild matches" is the escape
hatch. Recorded rather than solved.

**Step 4 note.** Structural does not read tag names, so `tier = 'structural'`
rows are correctly outside both statements. If a later tier ever derives its
answer from a pref, it needs its own invalidation clause here.

---

## 4. API request budget — corrects spec §13

Endpoint facts:

- **Collection sync** returns `instance_id`, `rating` and a
  `basic_information` block per item. **No tracklist.** Paginated at a maximum
  of **100 per page** (confirmed by Discogs staff on the equivalent inventory
  endpoint). ~~A 2,000-item collection is ~20 requests.~~ — **corrected,
  measured 2026-09-07: cost is `ceil(items / 100)`; 3 requests for a
  203-item collection.**
- **`GET /releases/{id}`** is the only endpoint returning a tracklist.
- **Search results** carry id, title, year, country, format, label and
  catalogue number — but no durations.

Consequences:

| Operation | Cost |
|---|---|
| Strict match | **0 requests** — the tag names the release |
| Owned badge | ~~~20 requests per collection sync~~ — **`ceil(items / 100)`; measured 2026-09-07: 3 requests for a 203-item collection** |
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

## 6a. Build & repository distribution — drops the renamed dev-build package

Testing had used a "SqueezeWaxDev" arrangement: a fully renamed duplicate
package, its own `repo-dev.xml`, hosted via `raw.githubusercontent.com`,
alongside — never in place of — a hypothetical real install. Dropped in
favor of one package, `SqueezeWax`, shipped as itself on every branch, with
a single `repo.xml` whose `<url>` differs by branch (raw GitHub content) vs.
release (GitHub Pages, once one exists). Full rationale and the replacement
workflow are in `docs/dev-repo-workflow.md`; the findings that drove the
decision are recorded here because they're evidence, not process.

**The rename never isolated the database.** `Schema.pm`'s `DB_NAME =>
'squeezewax.db'` and `DB_SCHEMA => 'squeezewax'` are bare strings the old
rename table never touched (it substituted the package namespace, web
paths, string-token prefix, prefs namespace, and progress-name prefix —
none of which is the string `squeezewax`). A dev build and a real install
would have shared one database file and attached schema name while running
under separate prefs namespaces: shared data, split configuration. A dev
build carrying a newer migration would push `user_version` past what the
real plugin's `_migrate` expects and hit the downgrade guard. Never
observed, because nobody ever ran both at once — which is exactly the
condition the isolation was supposed to make safe.

**Nothing hardware-tested was ever the shipping package.** Every
build-order step-2/step-3 hardware test ran a build transformed by the
rename script, and that transform produced three defects of its own — an
`HTML/` directory needing a second manual rename pass, a progress-name
mismatch that left the scan UI unlabeled, and the `DB_NAME`/`DB_SCHEMA` gap
above — none reachable by the offline suites. The risk this left was
asymmetric: a bug present only in the un-renamed form could not be caught
by anything that only ever ran the renamed one.

**One package name is what the update mechanism expects.**
`Slim::Utils::ExtensionsManager::findUpdates` (`Slim/Utils/ExtensionsManager.pm:366`,
branch `public/9.1`) keys candidates by plugin name (`$res->{'name'}`,
`:378`) and keeps whichever result has the higher version
(`Slim::Utils::Versions->compareVersions`, `:382`) regardless of which
configured repository it came from. The merge across repositories happens
one level up, in `appsQuery` (`:261`): its `getAllPluginRepos` `stepCb`
(`:281-284`) flattens every configured repository's results into one array
before `findUpdates` ever runs (`:286`). The rule this implies is not "give
the test build a different name" but "never configure a production
repository and a branch repository at once" — LMS cannot tell which one was
meant and silently prefers the higher version either way. Confirmed as the
reference project's (`d5c0d3/filtermusic_sb`) own documented operational
rule, fetched directly from its README rather than assumed:

> "Never configure both production and branch repositories simultaneously.
> LMS aggregates all repositories into a single list and silently keeps
> whichever entry has the highest version number, regardless of which repo
> it came from."

That README cites `Slim::Plugin::Extensions::Plugin::findUpdates`; the
symbol has moved on `public/9.1` — corrected to
`Slim::Utils::ExtensionsManager::findUpdates` above, per working-agreement
§6 (citations crossing sides are re-verified by symbol, not line number).

**The Pages/release URL split is confirmed, not inferred.** GitHub Pages
serves only the default branch — confirmed from `filtermusic_sb`'s own
README (its branch-testing section uses a raw-content URL for exactly this
reason) — so a release `repo.xml` on Pages and a branch `repo.xml` on
`raw.githubusercontent.com` must be different documents with different
`<url>` values, generated as distinct, explicit script steps rather than
one hand-maintained file. Also confirmed directly: GitHub Pages is not
currently enabled for `lms-plugin-squeezewax`
(`https://d5c0d3.github.io/lms-plugin-squeezewax/` returns 404; no
`_config.yml` at the repo root, unlike `filtermusic_sb`, which has one).
SqueezeWax has never released, so the Pages/release variant of `repo.xml`
is deferred to first release rather than invented now — tracked in
`TODO.md`.

**Corollary, applied the same day it was written down.** The
`packaging-rewrite` branch's own test build (`repo.xml` + `dist/*.zip`,
committed to make the branch raw-fetchable for hardware verification) was
deliberately **not** merged into master once that verification passed.
Master already held the validated packaging code from the commit
`packaging-rewrite` branched from; the build commit added nothing but a
branch-scoped manifest and a zip, which is exactly the kind of dev artifact
this section's rationale already argues doesn't belong on master. `master`
picked up the branch's non-artifact commits directly instead. This is the
same reasoning generalized in `docs/dev-repo-workflow.md`'s "What actually
merges at release" — a release's `repo.xml`/zip come from the release
script, never from merging a branch's accumulated build output.

---

## 8. Structural matching targets the master, not the release

**Decided 2026-09-07 (design chat), during build-order step 4 planning. All API
behaviour below was verified against a live Discogs account with a personal
access token on that date; each measurement names its sample.**

Structural resolves an LMS album to a Discogs **master** (edition), writing
`discogs_master_id` and leaving `discogs_release_id` NULL. It does not identify
a pressing, and cannot.

### Why not the release

Design §3 originally had Structural fingerprint a specific pressing, and
walkthrough 2 claimed it *"identified the specific pressing, not just the
album."* Both were falsified.

Master 3855547 (*Escape The Chaos*) has 15 versions. Its LP variants —
Worldwide, UK & Germany, Europe, White Label, Numbered — **share a tracklist**.
Track count and durations cannot separate them, and nothing else available can
either. Any design implying Structural resolves a pressing was promising
precision the signal does not carry.

This gives `match_tier` a meaning beyond provenance: **Strict knows the pressing
because the tag names it; Structural knows the edition; `manual` is whatever the
user chose.**

### Why the master level is not merely a retreat

Enumerating a master's versions to find the right pressing is not just useless,
it is unbounded. *Violator* has **529 versions**, and the owned release was not
in the first 100 under default sort. A negative answer requires exhausting every
page, so "not this one" is the expensive case. Master-level matching never
enumerates versions at all.

### The flow

```
search type=master, artist + title              1 request
  → local title normalisation and ranking       0 requests
  → GET /masters/{id} for the top N             1 request each
  → compare track shape
  → write discogs_master_id
```

**1 + N per album, N small.** A `type=master` search for Depeche Mode /
*Violator* returns 7 masters, of which 1 is the album; the others are *Violator
Live*, *Violator 2000*, *Violator / Black Celebration*, *Violator Remixes 2024*,
*Violator | The 12" Singles*, *Music For The Masses / Violator*. Local title
normalisation reduces 7 to 1–2 before any fetch is paid for.

Artist plus title is **not** sufficient identification on its own — those six
wrong masters are why the track-shape fingerprint is retained rather than
dropped. Dropping the `artist=` parameter is worse still: a bare
`release_title=Violator` search returns 20 results across 9 unrelated artists.
Search quality therefore depends on LMS's album artist being clean.

`main_release` is **not** present in `type=master` search results. This is moot:
masters carry their own tracklist, so there is no hop to make.

### Ranking, never gating

Format was originally an exclusion filter and that was falsified: digital
releases (FLAC/ALAC/download), USB-delivered concert recordings and unofficial
releases are all objects a user can own. **Format, country, released and title
are ranking signals only.**

`community.have` / `community.want` arrive free in search results (154,916 /
209,807 on master 18080) and are the strongest available prior.

The only gate that holds is `local_tracks == 0` — no local files means no
evidence about a physical object. It is Structural's own rule, not inherited
from Strict, and needs its own test.

### The comparison

1. Filter Discogs tracklist entries to `type_ == "track"`.
2. Compare counts. Unequal rejects immediately.
3. Sort both duration lists; compare element-wise within the margin (design §9's
   pref, default ±2–3 s).
4. Any duration outside the margin rejects.

**The `type_` filter is an allowlist, deliberately.** At least three values occur
— `track`, `heading`, `index` — where the documentation shows only `track`. An
allowlist ignores an unknown fourth value; a denylist would silently count it as
a track. Two of 40 sampled releases (5%) contain non-track entries, so
`.tracklist | length` is wrong for them.

**Position is not parsed.** Disc membership appears as `D-T` (`1-1` … `2-8`) on
the one multi-disc release examined, but that is one sample and one convention —
vinyl `A1`/`B2` and other formats are unsurveyed. Building a position parser on a
single observation is the error this session made five times in other forms.

### Multi-disc, without parsing position

Design §9 requires all discs to match for auto-confirmation. **Album-level
multiset equality delivers exactly that.** If every disc matches, the
album-level vector matches; if any disc differs, the count or the vector differs
and the album falls to the review queue — design §3's walkthrough 3, reached
without a disc decomposition.

This is safe because **LMS groups multi-disc sets into one `albums` row**,
verified three ways: whole-set track counts (*Die 100 besten Ostsongs*,
`discc = 6`, 100 tracks in one row); no title appearing once per disc (the only
duplicated `titlesort` values at `discc >= 2` are two complete copies,
`discs = 2,2`, not halves); and `albums.disc` always equalling `albums.discc`
where non-null.

**Trap, recorded because it will bite someone:** `albums.disc` is *not* a disc
index on a grouped album. It equals the disc *count*. A filter reading `disc = 2`
as "the second disc" would silently drop albums.

Headings are sub-sections, not disc boundaries — release 14772 has four headings
spanning `1-1..1-4`, `1-5..1-8`, `2-1..2-4`, `2-5..2-8`, two per disc.
Discarding them loses no structure.

Accepted weakening: multiset equality would also accept an album with its discs
transposed. That is the same album.

Incompletely-ripped sets already exist in the reference library (*Akasha*,
`discc = 2`, 7 tracks; *Fourteen Pieces*, `discc = 2`, 14 tracks). They correctly
fail count equality and reach the review queue.

### Confirm versus candidate

**Duration availability is a property of the Discogs entry, not of the
endpoint.** Master 18080 carries durations; master 3855547 and its main release
33986376 both carry none. Fetching the release does not recover what the master
lacks.

Measured over 40 releases from the reference collection, after filtering to
`type_ == "track"`:

| | count | share |
|---|---|---|
| Complete durations | 36 | 90% |
| No durations at all | 3 | 7.5% |
| Zero countable tracks | 1 | 2.5% |

So:

- **Durations present both sides and matching** → `(structural, confirmed)`.
- **Durations absent Discogs-side** → `(structural, candidate)` for step 5's
  review queue.
- **Zero countable tracks** → candidate skipped, not compared.

Count and title alone is **Fuzzy-grade evidence**, and Fuzzy is review-gated by
design (§3) precisely because it is. Structural auto-confirms silently.
Confirming on count alone would ship Fuzzy's evidence quality under Structural's
behaviour, which is the one combination the tier design exists to prevent. The
expected cost is a review queue holding roughly 10% of albums — a usable feature
rather than a chore.

### What is written

`discogs_master_id` set, `discogs_release_id` NULL. **`main_release` is never
written as `discogs_release_id`** — it is a release we might have compared
against, not the pressing the user owns, and writing it would assert a fact we
did not determine.

No migration is required: `Schema.pm::_migration_1` declares
`discogs_release_id INTEGER` with no NOT NULL, consistent with §3a's conflict
rows and with `Match.pm::_recordNoMatch`'s `discogs_release_id IS NULL`
predicate.

### Consequences this creates elsewhere

- **§3a's v1 invariant must be amended.** It forbids Structural producing a
  NULL-id candidate, on the stated grounds that *"Structural's
  partial-multi-disc candidate and Fuzzy's master-release candidate both carry a
  proposed id."* That was written assuming Structural resolves a pressing. It
  cannot. Amending §3a is correct; writing a nominal id to satisfy it is not.
- **The narrow delete predicate must not widen.** `Match.pm::_recordNoMatch`
  deletes `match_tier = 'strict' AND state = 'candidate' AND
  discogs_release_id IS NULL AND snapshot_track_count IS NULL`. A structural
  NULL-id row must never become collateral. Structural needs no delete path of
  its own.
- **The badge test is a disjunction**, corrected in design §10:
  `release_id in owned_releases OR (master_id present and not the no-master
  sentinel AND master_id in owned_masters)`.
- **The no-master sentinel is endpoint-dependent** — `0` in collection
  `basic_information` (5 of 100 sampled, zero nulls), `null` in the release
  payload (release 9701013). Both must be guarded. Fixtures need **two**
  masterless releases, because the failure is that distinct masterless ones
  collide on `0`.
- **An edition-level match has no pressing to show** in §4's context menu.
  Product decision, recorded not taken.

### Unverified, carried forward

- Whether long tracks use `H:MM:SS`. All observed durations are `M:SS`, longest
  `9:10`. The parser must handle both; mis-parsing `1:02:33` would silently
  poison a comparison.
- `data_quality` is **not** usable as a pre-fetch signal. Base rate over 40
  releases: 20 `Correct` (0 missing durations), 20 `Needs Vote` (3 missing).
  Real direction, but 85% of `Needs Vote` entries are fine, the split is 50/50,
  and the field is absent from search results so it cannot rank candidates
  before the fetch is paid for. Usable only as a tiebreaker between
  already-fetched candidates and as a confidence note in the review queue.
- Whether the per-album fetch cap is needed given N is small after title
  normalisation. §13's rewrite decides it.

---

## 9. Discogs API access: authentication, limits, caching and attribution

**Decided 2026-09-07 (design chat), during build-order step 4 planning.**
Sources: the Discogs API documentation at <https://www.discogs.com/developers/>,
the API Terms of Use at
<https://support.discogs.com/hc/articles/360009334593-API-Terms-of-Use>, and the
Application Name and Description Policy at
<https://support.discogs.com/hc/articles/360009207054-Application-Name-and-Description-Policy>,
all read on that date. Measurements were taken against a live Discogs account
with a personal access token and are labelled as such.

### 9.1 Authentication: a user-supplied personal access token

v1 uses **BYOK** — the user generates a personal access token in their own
Discogs Developer Settings and pastes it into LMS. SqueezeWax ships no
credential of any kind.

The documentation offers four modes:

| Credentials | Rate limit | Image URLs | Authenticated as user |
|---|---|---|---|
| None | Low tier | No | No |
| Consumer key + secret | High tier | Yes | No |
| Full OAuth 1.0a access token/secret | High tier | Yes | Yes, any user |
| Personal access token | High tier | Yes | Yes, token holder only |

#### Why not a shared consumer key embedded in the plugin

- The documentation is explicit: *"It's important that you don't disclose the
  Consumer Secret to anyone."* SqueezeWax ships as a zip unpacked into a
  readable directory from a public repository. There is no mechanism by which a
  secret in a `.pm` file is not disclosed to every user. Obfuscation would be
  worse — a deliberate attempt to appear compliant.
- The TOU's prohibited commercial uses include *"Selling or giving to any third
  party Our API, the Content, or access to Our API or the Content."*
- **The technical failure is worse than the legal one.** Every installation
  worldwide would draw on one 60-requests-per-minute budget. Two users scanning
  concurrently would both fail.
- **Single point of revocation.** *"If You violate the TOU or any of Our
  policies, we may revoke Your API access or Your account privileges."* One
  misconfigured install would stop every installation simultaneously, with no
  recovery except shipping a new secret, which has the same problem.
- *"We reserve the right to charge for access to, or use of, Our API in the
  future."* Under a shared key that cost falls on the developer, scaled by other
  people's libraries.

#### Why not OAuth 1.0a

**OAuth does not avoid the shared-secret problem — it requires one.** Its
documented step 1 is *"Obtain consumer key and consumer secret from Developer
Settings"*, and every handshake request carries `oauth_consumer_key` and
`oauth_signature="your_consumer_secret&"`. Choosing OAuth means shipping the
secret anyway, plus a browser redirect.

OAuth also needs a callback URL registered per application, and an LMS install
lives at whatever host and port the user chose. One registered callback cannot
serve all of them. The no-callback path exists (*"they will receive a verifier
key to use as verification"*), but it is strictly more friction than pasting a
token, in exchange for a secret we cannot ship.

For a self-hosted, single-user plugin, OAuth's only advantage — acting on behalf
of arbitrary users — is worth nothing. There is one user, and it is the person
configuring the server.

#### Application registration

Register `SqueezeWax` at <https://www.discogs.com/settings/developers>, obtain
the consumer key and secret, and **commit neither**. Registration is worth doing
solely for breaking-change notices: *"For larger, breaking changes, we will send
out an email notice to all developers with a registered Discogs application."*
That is the only push channel that exists.

The name is compliant. The Application Name and Description Policy prohibits
*"Combin[ing] any part of 'Discogs' with your name, marks, or generic terms"*
and lists "My Discogs", "Discogs Collector" and "Catalog by Discogs" as
unacceptable; "SqueezeWax" contains no part of the mark. Accurate functional
descriptions such as *"View your Discogs Collection"* are explicitly permitted,
which covers settings-page copy. The same policy confirms design §4's existing
choice of a generic vinyl glyph over the Discogs logomark: marks may not be
presented *"in a way that make them the most distinctive or prominent feature of
what you're creating."*

#### Token storage — a risk we transfer to the user

A personal access token is an **unscoped bearer credential** for the entire
Discogs account. Documented endpoints reachable with it include creating
Marketplace listings, editing orders and uploading inventory CSVs. Discogs
documents no scoping mechanism for either token type, so OAuth would be no
better here — this is not a reason to reconsider the decision, but it is a
reason to handle storage honestly.

The token will sit in LMS's prefs file in plaintext, frequently on a NAS with
permissive defaults. We cannot make that safe. The settings page must therefore
state what the token can do and link to where it is revoked. A bare "Discogs
token" field with no warning would be transferring a risk we understood and the
user did not.

### 9.2 Rate limits

**Verified 2026-09-07:** a personal access token yields
`x-discogs-ratelimit: 60`.

The documentation states 60 requests per minute authenticated and 25
unauthenticated, tracked as *"a moving average over a 60 second window. If no
requests are made in 60 seconds, your window will reset."* Three response
headers report state: `X-Discogs-Ratelimit`, `X-Discogs-Ratelimit-Used`,
`X-Discogs-Ratelimit-Remaining`. The documentation instructs that *"Your
application should take our global limit into account and throttle its requests
locally."*

**The unauthenticated tier of 25 is documented but not verified by header.**

#### Search does not require authentication — a documented claim, falsified

The Search endpoint states *"Authentication (as any user) is required."*
**Measured 2026-09-07: an unauthenticated search returns 200.**

The consequence is that requiring a token for Structural is a **choice, not a
technical necessity**: 2.4× throughput, and the user needs a token for ownership
anyway so it is not additional setup. Discogs' own guidance supports it —
*"Your application should identify itself to our servers via a unique user agent
string and with a form of authentication in order to achieve the maximum number
of requests per minute."* The `use` gate condition is unchanged; only its
rationale is.

### 9.3 The User-Agent requirement

Mandatory and independent of authentication. *"Your application must provide a
User-Agent string that identifies itself"*, following RFC 1945, with documented
examples of the form `AppName/0.1 +http://example.com`.

The penalty is silent: *"Please don't just copy one of those! Make it unique so
we can let you know if your application starts to misbehave — the alternative is
that we just silently block it, which will confuse and infuriate your users."*
The FAQ confirms the symptom: *"Why am I getting an empty response from the
server? This generally happens when you forget to add a User-Agent header."*

Ours must be unique, carry a contact URL, and include the plugin version.

### 9.4 Pagination

*"By default, 50 items per page … To browse different pages, or change the
number of items per page (up to 100), use the page and per_page query string
parameters."* This confirms at source the 100-per-page figure that decisions §4
had sourced only to a forum statement about the inventory endpoint.

**Collection sync costs `ceil(items / 100)` requests. Measured: 3 requests for a
203-item collection.** §4's earlier "~20 requests" was pessimistic.

**Pagination hazard.** The collection listing defaults to
`sort=label&sort_order=asc`, and `/masters/{id}/versions` has its own default
order. Paging over a mutable, non-unique sort key can shift rows between pages,
silently dropping or duplicating them. Pin an explicit stable sort on every
paged endpoint, or document the accepted risk.

### 9.5 Caching: store conclusions, not Content

The TOU's API USE AND RESTRICTIONS item 5 contains two distinct rules:

> *"The Content within Our API is dynamic and is quickly outdated. You may not
> display in any format or to any audience the Content if it is more than six (6)
> hours older than the information on Our online properties and applications. You
> may not cache or store the Content longer than is necessary to provide a
> service to Your application's users."*

The first is a **display** rule and is not a six-hour TTL: it triggers on
divergence from Discogs' copy, not on age. But divergence is unknowable without
asking Discogs, which is the request being avoided, so in effect it means
"refresh within six hours or have an independent way to know the data is
unchanged." We have no such way. Conditional requests do not provide one:
`If-Modified-Since` and 304 are documented only on the Inventory Export
endpoint, nothing in `/releases/{id}` mentions ETag or 304, and a 304 would still
consume a request against the rate limit — saving bandwidth, not budget.

The second is a **necessity** test, deliberately elastic, and it is what governs
long-term storage.

#### The CC0 tension, stated and deliberately unresolved

The TOU names as CC0 Data *"Release titles, notes, dates, format, track
listings, barcodes and other identifiers, credits, versions, URL links"* and
says *"CC0 Data is made available under the CC0 No Rights Reserved license."*
Track listings — exactly what Structural consumes — are named CC0.

Item 5 nonetheless says "the Content" unqualified, and the preamble defines that
as all data made available through the API. Literal reading: item 5 reaches CC0
Data. The counter-argument is that CC0 is a rights waiver Discogs cannot
un-waive; the counter-counter-argument is that the TOU is a contract for *API
access*, not a copyright licence, and a contract may impose obligations
copyright would not.

**This is a contract-interpretation question, not a technical one, and it is not
resolved here.** No part of the design depends on the permissive reading. If it
ever needs settling, the TOU itself invites the question: *"If You have
questions about whether Your intended use will violate the TOU, please contact
Us."*

#### The design principle

**Store conclusions, not Content.**

- `discogs_match` — a decision plus a bare identifier. Not Content in any
  meaningful sense. **Unconstrained; kept indefinitely.**
- `discogs_no_match` — our own observation that a search found nothing.
  **Unconstrained.**
- `discogs_release_cache` — raw payload. Content, unambiguously.

**Consequence: `discogs_release_cache` is not written in v1.** Structural holds
candidate payloads in memory for the duration of one album's decision; once
decided, the tracklist was the *evidence*, not the answer. Cross-album reuse
within a scan is marginal — only when two LMS albums resolve to one Discogs
object. The table remains in the schema, unwritten, commented as v1-unused
(dropping it would cost a migration and a `schema-check.pl` edit for no
behavioural gain, and it is regenerable either way).

This corrects three documents that spoke as if there were one cache. Rescans are
cheap because **`discogs_match` and `discogs_no_match` are permanent**, not
because payloads are. `Schema.pm`'s "worth keeping indefinitely" comment, design
§10's "relinks and completeness checks cost no API calls" claim, and §13's
"cacheable forever" row were all superseded on 2026-09-07.

#### Live rather than cached

The rule: **request count bounded by user actions → live; bounded by library
size → background job writing a conclusion.**

- Context menu and review queue: live fetches. Data is seconds old, nothing is
  stored, and the payload carries `uri`, which supplies the mandatory
  attribution hyperlink for free.
- Triage page and any overview computed from `discogs_match` plus local
  ownership state: zero Discogs requests.
- v2's completeness check: one release fetch per matched album is
  library-size-bounded, so it becomes a background job storing its *comparison
  result* — our observation, indefinitely storable — not the payload.

### 9.6 Attribution — two mandatory notices

Neither was previously in the design doc. Both are requirements, not niceties.

1. *"This application uses Discogs' API but is not affiliated with, sponsored or
   endorsed by Discogs. 'Discogs' is a trademark of Zink Media, LLC."* —
   displayed prominently; may live in usage documentation.
2. *"Data provided by Discogs."* — displayed **directly next to any data used**,
   including a hyperlink to the discogs.com page containing that data, and the
   link must not be `nofollow`.

(2) is a live constraint on the badge and on step 5's review queue. Live-fetch
paths get the hyperlink free from the payload's `uri`. **A grid badge has no
natural place for the notice** — whether it appears per tile, once per page, or
only in the context menu the badge opens is a step-6 UI decision that must be
taken before step 6 begins, not discovered during it.

### 9.7 Endpoints used in v1

| Purpose | Endpoint | Notes |
|---|---|---|
| Token sanity check | `GET /oauth/identity` | Returns the username the collection path needs |
| Structural candidate search | `GET /database/search?type=master` | Carries `community.have/want`, `barcode`, `catno`, `user_data` |
| Structural comparison | `GET /masters/{id}` | Tracklist with durations where the entry has them |
| Ownership | `GET /users/{username}/collection/folders/0/releases` | Folder 0 is the read-only "All" view; `basic_information` carries `master_id` |

`GET /releases/{id}` is used by Strict and by the context menu, not by
Structural.

### 9.8 Recorded, not designed

- **Monthly CC0 data dumps** (<https://data.discogs.com/>) would remove the
  caching question and the rate limit at once, and would make Structural
  matching offline and free. They are also a different plugin: multi-gigabyte
  compressed XML and a local index to build and refresh, frequently on a NAS.
  **v2/v3.** Recorded because it is the kind of idea that returns in six months
  looking new.
- **`discogs_price_snapshot` versus item 5 (v2/v3).** The value-history feature
  necessarily stores and displays historical Restricted Data. The reading that a
  dated historical observation is not stale current Content is defensible but is
  an *interpretation, not a citation*. If built, snapshots must be labelled with
  their observation dates rather than presented as current pricing.

### 9.9 Unverified, carried forward

- The unauthenticated rate tier — is the header actually 25?
- Whether unauthenticated search results are content-degraded (the docs state
  image URLs are withheld without credentials).
- Whether `user_data.in_collection` / `in_wantlist` on search results is
  documented anywhere. It is observed to work per token holder and is treated as
  a cross-check only; the collection sync remains the ownership mechanism.
- Discogs responses now come via Cloudflare (`cf-ray`, `cf-cache-status`). The
  documentation's example headers show lighttpd and Varnish and are a 2014
  snapshot. Do not reason about caching behaviour from them.

---

## 10. "Clear & rebuild matches" preserves manual rows and nothing else

**Decided 2026-09-07 (design chat).** Resolves the open question carried since
step 3 and named as a precondition in
`plans/build-order-step-4-structural-matching.md` §2.1.

Design §9's maintenance action deletes every row in `discogs_match` whose
`match_tier` is not `'manual'`, and **every** row in `discogs_no_match`
regardless of tier. Manual rows survive untouched.

### 10.1 Why this must exist before step 4 ships

It is not a convenience. Three separate decisions depend on it as their only
escape hatch, and the dependency count is itself the argument:

- **§3b's accepted coverage gap.** Hooking the settings handler misses a
  `discogsTagNames` change made via the CLI or a hand-edited prefs file.
- **§0.6's duration-margin gap.** Same mechanism, same miss.
- **§0.5's 30-day structural TTL.** A user who adds a release to Discogs
  themselves waits up to a month unless they can force a re-match.

Three decisions leaning on one unbuilt action is a pattern, not a coincidence.
Each was accepted on the basis that this escape hatch exists. Shipping step 4
without it would mean three accepted gaps with no way out, and the current
workaround is hand-editing SQL against `squeezewax.db`, which is not a feature.

### 10.2 What is deleted

| Table | Deleted | Kept |
|---|---|---|
| `discogs_match` | every row where `match_tier <> 'manual'` | `match_tier = 'manual'` |
| `discogs_no_match` | **every row, both tiers** | nothing |

**`discogs_no_match` is wiped entirely, and this is the part most likely to be
got wrong.** Clearing `discogs_match` alone would leave a structural no-match
row in place, which then skips the album for the remainder of its 30-day TTL —
the escape hatch would fail to escape, silently, for exactly the albums the user
invoked it to fix. Both tiers go.

Not affected:

- **`discogs_release_cache`** — not written in v1 (§9.5). Nothing to clear.
- **`discogs_collection`** — v1 holds no collection mirror. Ownership is derived
  and refreshed on its own trigger, which this action does not touch.
- **Preferences** — tag names, margin, TTL, tier selector. This action clears
  results, not configuration.

### 10.3 Manual rows survive intact, including their cheap columns

A manual row keeps its `discogs_release_id`, `source_timestamp` and
`lms_album_id`. It is not NULLed, not re-examined, not rebuilt. There is nothing
to rebuild: the answer came from the user, not from evidence that could have
changed.

Leaving `source_timestamp` intact means the album skips on the next scan, which
is correct — and is the same reason `invalidateStrict` scopes itself to
`match_tier = 'strict'`, leaving manual outside the predicate entirely.

This follows §0.2's rule without exception: **nothing overwrites manual.** A
bulk maintenance action is not a licence to make one.

### 10.4 Why this does not violate invariant 2

Decisions §2a invariant 2: *never delete a row carrying a decision or a recovery
snapshot.* This action deletes confirmed matches, which are decisions by
definition, and deletes their `snapshot_track_count` values, which are orphan
recovery's index material. On its face that is exactly what invariant 2 forbids.

**Invariant 2 governs automatic deletion inside the write path.** It is the
reason `Match.pm::_recordNoMatch`'s delete predicate is narrow: a matcher
running unattended must never destroy something a human decided or something
another mechanism depends on. This action is neither automatic nor unattended —
it is invoked explicitly by the user, from a settings page, with confirmation,
and its entire purpose is to discard results.

**This must be stated in the record because the alternative readings are both
harmful.** Read one way, invariant 2 forbids the feature outright. Read the
other way, this action becomes precedent for widening the narrow delete
predicate — "we already delete decisions elsewhere." Neither is correct. The
predicate stays exactly as written (§0.3), and this action remains the only
place decisions are deleted, precisely because the user asked.

Orphan recovery loses its snapshots until the next scan regenerates them. That
is acceptable here and only here: the action's premise is that everything
derived is about to be rebuilt from scratch, so there is nothing for orphan
recovery to recover *to*.

### 10.5 A wrong manual row is not fixable by this action

That is the intended trade-off — manual is the user's own choice, and a bulk
button should not destroy it — but the consequence must be recorded rather than
discovered.

A user who confirmed the wrong pressing, or promoted the wrong candidate, has
**no recovery path** until step 5's review queue offers reject / dismiss. Clear
& rebuild will not help them, and the settings copy should not imply otherwise.

This is the **fourth** dependency on step 5's reject/dismiss, after the demoted
incumbent row (§0.4), the phantom-conflict case, and the edition-level context
menu. Step 5's review queue must offer a way to say no; that is now recorded
four times over.

### 10.6 Execution

**The action goes through `_writeOk`, not around it.** It runs server-side from
a settings page, and `_writeRefusal` already answers the question that matters:
a scan holds `BEGIN IMMEDIATE` across its whole duration, so a maintenance
delete issued mid-scan would contend with the scanner. Reusing the existing
policy is correct; adding a second, parallel check of scan state is not.

Both deletes execute in **one transaction**. A partial clear — `discogs_match`
emptied, `discogs_no_match` intact — is the exact failure 10.2 describes, and an
aborted scan is known to commit (§0.8), so partial states persist rather than
rolling back on their own.

The action reports counts back to the user: rows deleted per table, and manual
rows preserved. A destructive action that reports nothing gives the user no way
to tell it worked from no way to tell it ran.

Invariant 1 cannot be violated by this action: wiping both tables removes rows,
never creates a pair.

### 10.7 Deferred: what "rebuild" means mechanically

Whether the action triggers a rescan itself or clears and waits for the next one
is **not decided here**, because it runs into the scanner→server handover item
that remains open in `TODO.md`.

Recorded as deferred rather than left ambiguous. For v1, the safe reading is
that the action clears, and the rebuild happens on the next scan the user
initiates — which the settings copy must say plainly, or a user will click it,
see nothing happen, and click it again.

### 10.8 Confirmation

The action is destructive and irreversible. It requires an explicit
confirmation step that states what will be deleted, what will be kept, and that
rebuilding costs Discogs requests — a full structural rebuild on a large library
is measured in hours at 60 requests per minute (§9.2), not seconds.

---

## 11. Structural does not detect various-artists albums

**Decided 2026-09-10 (design chat).** Unblocks build-order item 4, which was
blocked on a various-artists policy recorded in `TODO.md`.

Structural searches artist plus title. **If that returns zero results, it
retries title-only.** There is no various-artists detection, no signal to
compute, and no threshold to tune.

### 11.1 Why the problem looked hard

Compilations are 12.4% of the reference library — 95 of 765 albums, measured
2026-09-10. Not an edge case.

The difficulty is that **LMS and Discogs catalogue compilations under different
conventions, and neither is wrong.** For one real object:

- LMS: album 3359, *Atmospheric Drum & Bass Volume 3*, `compilation = 1`,
  album artist `Various`.
- Discogs: release 132512, `artists_sort` `Nick Ashcroft` — the compiler, with
  no "Various" anywhere in the payload.

An artist-plus-title search for this album searches for the wrong artist against
a catalogue that files it under a third name. Decisions §8 already records that
Structural's search quality depends on LMS's album artist being clean; a
compilation's is not clean, it is a placeholder.

### 11.2 The decision

```
search type=master, artist + title
  → 0 results?  retry: search type=master, title only
  → rank, fetch, compare as normal
```

**Measured 2026-09-10**, on the album above:

| Query | Result |
|---|---|
| `type=master&artist=Various&release_title=Atmospheric+Drum+%26+Bass+Volume+3` | `items: 0`, empty |
| `type=master&release_title=Atmospheric+Drum+%26+Bass+Volume+3` | `items: 1`, master **1861554** |

Master 1861554 is the same master id carried by the pinned fixture
`scripts/fixtures/release-132512.json`, so both sides of the object agree.

**The load-bearing property is that the failing search returns zero, not wrong
results.** A placeholder artist that Discogs does not recognise yields nothing,
which is a clean trigger. Had it returned confident garbage, the retry could
never fire and this design would not work.

Cost: one extra request, only for albums whose first search found nothing —
compilations plus genuinely-absent albums. Bounded, and paid only where the
alternative was no match at all.

**No new confirmation rule is needed.** Decisions §8's confirm/candidate rule
already applies: title agreement alone never confirms, the track-shape
fingerprint decides. A title-only search that surfaces the wrong album fails the
fingerprint exactly as an artist-plus-title search would.

### 11.3 Four approaches rejected, and what killed each

Recorded because each is plausible, each was proposed, and without this they
will be proposed again.

**(a) Match the album artist against the literal string "Various".**
Dead on arrival: the reference library holds *two* Various-ish contributors —
id 9597 "Various Artists" (79 albums) and id 10001 "Various" (23 albums). Any
literal is already wrong on one of them, before considering that
`Slim::Music::Info::variousArtistString` (`Slim/Music/Info.pm:1540-1543`) falls
back to `string('VARIOUSARTISTS')`, which is localised — `strings.txt` carries
translations for sixteen languages.

**(b) Count distinct track artists per album.**
Measured, and it separated cleanly with a real gap: normal albums stop at 3
distinct role-1 contributors, compilations resume at 6, nothing at 4 or 5.

Then it collapsed. **497 of 765 albums have no role-1 contributor row at all.**
The cause is verified in source: `Slim/Schema.pm:3117-3132` **deletes**
`ARTIST` and rewrites it as `TRACKARTIST` whenever a non-compilation track
carries both `ARTIST` and `ALBUMARTIST`. Picard writes `ALBUMARTIST` on
essentially every release, so Picard-tagged local albums lose their role-1 rows
wholesale. A signal unavailable for two thirds of the library is not a signal.

(The inverse held for online albums, which is how this was found: all 186
online-library albums *do* have role-1 rows, because TIDAL's
`Importer.pm:326-330` and Spotty's `Importer.pm:474-493` set `ARTIST` and never
set `ALBUMARTIST`, so the transform's guard is false.)

**(c) Route on `albums.compilation`.**
Wrong in both directions, measured: 11 albums carry a Various-ish album artist
but `compilation = 0`, and 4 albums are `compilation = 1` with a real, usable
artist (Miles Davis, Yann Tiersen). Roughly 2% of the library misrouted, and
the failures are not symmetrical — eleven albums would be searched as "Various",
four would be denied a perfectly good artist.

The `compilation = 0` cases are explained in source:
`Slim/Schema.pm:2206-2294` (`mergeSingleVAAlbum`) auto-detects compilations by
grouping **role-1** rows. An album whose role-1 rows were consumed by (b)'s
transform has nothing to group, so detection is silently inert and
`compilation = 0` is written *and cached*. **`compilation = 0` on a
Picard-tagged local album means "not detected", not "not a compilation."**

**(d) Compare the album's contributor id against the VA object.**
This one nearly worked. The comparison is sound — every in-tree caller compares
by numeric id, never by name (`Slim/Control/Queries.pm:367`, `:920`, `:1844`,
`:3347`, `:6425`; `Slim/Control/Commands.pm:3499-3514`). And the object resolves
correctly here: language is `EN`, `variousArtistsString` is unset, so the
fallback string is "Various Artists", whose `ignoreCase` form `VARIOUS ARTISTS`
matches contributor 9597's stored `namesearch` exactly.

It fails on coverage and on safety.

*Coverage:* contributor 10001 ("Various", `namesearch` `VARIOUS`) is an ordinary
tag-derived contributor with no special status, and it carries 23 albums. An id
comparison misses every one.

*Safety:* **`Slim::Schema->variousArtistsObject` is not side-effect-free.**
`Slim/Schema.pm:2096-2100` creates a contributor row when no `namesearch`
matches, and `:2105-2111` renames an existing one when the stored name no longer
matches the currently-resolved string. A plugin merely *asking* for the id would
write to the user's library — on a library with no compilations, it would create
a contributor that describes nothing.

**This trap survives the decision and must not be forgotten.** Anyone later
needing the VA object should use the read-only half of the same logic —
`Slim::Music::Info::variousArtistString()` for the string, then
`Slim::Schema->first('Contributor', { namesearch =>
Slim::Utils::Text::ignoreCase($vaString, 1) })` — where no match simply means no
VA object exists. Never `variousArtistsObject` itself.

### 11.4 What Structural still needs from LMS

An album artist for the first search. `Library.pm`'s iterator does not currently
supply one.

**Use `Slim::Schema::Album::artists` (`Slim/Schema/Album.pm:293-327`)**, or the
`albums.contributor` column it builds on, rather than joining
`contributor_album` by role. That accessor already encodes the priority order —
`ALBUMARTIST`, then `BAND` if the `bandInArtists` pref is set, then `ARTIST`,
then the various-artists object for compilations — and `albums.contributor` is
assigned unconditionally by `_createOrUpdateAlbum` for every album. Role
integers (`ARTIST` 1, `COMPOSER` 2, `CONDUCTOR` 3, `BAND` 4, `ALBUMARTIST` 5,
`TRACKARTIST` 6 — `Slim/Schema/Contributor.pm:76-84`) are LMS's business, not
ours.

This means the first search will sometimes be `artist=Various Artists`. That is
fine and is the design: it returns zero, and the retry fires.

### 11.5 Consequences and open items

- Build-order item 4 gains the zero-result retry. `plans/build-order-step-4-structural-matching.md`
  §3 item 4 and §4's test coverage both need it.
- **The retry doubles the search cost for albums that genuinely do not exist in
  Discogs**, since a title-only retry on a truly absent album also returns zero.
  This is the correct behaviour but it belongs in §13's request-budget rewrite,
  which already awaits measured requests-per-album from the hardware pass.
- **Unverified:** whether a placeholder artist *always* yields zero rather than
  wrong results. One album was measured. A non-English install whose placeholder
  is, say, "Verschiedene" has not been tested, and neither has a compilation
  whose LMS album artist happens to be a real Discogs artist name. The
  fingerprint is the backstop in both cases — a wrong search result fails the
  comparison — so the risk is a missed match, not a wrong one.
- **Unverified:** whether `type=master` search treats an unrecognised `artist=`
  as a hard filter in all cases, or only where the term matches no artist entity
  at all.

### 11.6 Note on refs/ drift

The source citations above were checked against `refs/slimserver` at commit
`a670a38c2b14ad42b86a39884bcb842121b35571`, branch `public/9.1`, dated
2026-06-19. Earlier records in this document cite `50e5b725`. Nothing found at
`a670a38c` contradicts the earlier citations, but the drift is recorded per
working-agreement §6.

---

## Appendix — Open items

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

---

## 12. Two rulings on evidence quality in the Structural comparison

**Decided 2026-09-11 (design chat), during build-order step 4 items 4–5
planning.** Both rulings concern what the track-shape comparison does when the
evidence on one side is incomplete. Neither introduces a new principle; each
applies §8's existing confirm/candidate rule to a case §8 did not name.

Source claims below were checked against a slimserver clone at
`4015c6a826420cacedb7223a42da81c70b78c300` (`public/9.1`, 2026-09-07), which is
**newer** than `refs/`'s pin `a670a38c` (2026-06-19). Per working agreement §6,
Claude Code re-verifies by symbol against refs/'s actual pin. The refs/ citation
drift already recorded in `TODO.md` now runs in both directions.

### 12.1 The `type_` allowlist does not recurse into `sub_tracks`

§8 specifies "filter Discogs tracklist entries to `type_ == "track"`". It does
not say whether to descend into nested entries, because `sub_tracks` was not
known when it was written.

**Verified, from the pinned fixture.** `scripts/fixtures/release-2516.json`
holds one top-level tracklist entry with `"type_" : "index"`, carrying a
`sub_tracks` array of five entries, each `"type_" : "track"` and each with a
non-empty duration (`10:50`, `3:15`, `7:11`, `5:12`, `3:54`). The string
`sub_tracks` appears nowhere in `docs/`, `plans/` or `TODO.md` before this
record.

**Decided: count top-level entries only. Do not recurse.**

Release 2516 therefore yields **zero countable tracks**, the candidate is
skipped rather than compared (§8, "Confirm versus candidate"), and the album
reaches the review queue if no other candidate survives.

#### Why, and it is not the obvious reason

The obvious argument — "an `index` entry is not a track" — is weak, because the
nested entries genuinely are tracks and genuinely carry durations. Recursing
would probably have produced a correct match for this album.

The real argument is **calibration**. §8's confirm/candidate rule rests on a
measurement over 40 releases: complete durations 36 (90%), none at all 3
(7.5%), zero countable tracks 1 (2.5%). That measurement counted release 2516
in the third bucket, which means it was taken **top-level-only**. An
implementation that recurses moves albums between buckets that the measured
split was drawn from, so §8's expected ~10% review-queue figure would no longer
describe the code that produced it. Changing the counting rule silently
invalidates the evidence base for the rule that consumes the count.

#### Why this is safe to defer rather than solve

The failure direction is benign. Not recursing costs 2.5% of albums (n=40) a
trip through the review queue. It cannot produce a wrong badge — a skipped
candidate is not a match. The review queue is precisely the mechanism for
albums whose evidence does not support auto-confirmation, so this is the system
behaving as designed, not degrading.

This is the asymmetry that decides it: recursion buys a small number of
automatic confirmations and risks miscalibrating a rule; not recursing costs a
small number of manual confirmations and risks nothing.

#### Revisit trigger, and what would count

**v2.** Reopen if the step-4 hardware pass (plan §5) shows index-only releases
materially above the measured 2.5% of the reference library. "Materially" is
deliberately not given a threshold here — the 2.5% is n=1 of 40 and does not
support one.

**Unverified, carried forward:**

- Whether `sub_tracks` occurs on any entry whose `type_` is something other
  than `"index"`. One shape has been observed, on one release.
- Whether a `sub_tracks` entry can itself nest further.
- Whether any Discogs release expresses a *whole* album as sub-tracks such that
  top-level counting yields a non-zero count that is wrong rather than zero.
  This is the case that would make the ruling unsafe rather than merely
  conservative, and it has not been looked for.

### 12.2 A NULL local duration yields a candidate, never a confirmation

§8 rules on durations being absent **Discogs-side**: `(structural, candidate)`
for step 5's review queue. It is silent on the LMS side, because the LMS side
was assumed complete. It is not.

**Verified in source.** `SQL/SQLite/schema_16_up.sql`, inside
`CREATE TABLE tracks`, declares `secs float` with no `NOT NULL`.
`grep -rn "CREATE TABLE tracks" SQL/SQLite/` returns only `schema_1_up.sql` and
`schema_16_up.sql`, so no later migration redefines the column.

**Reachable, not merely nullable.** `Slim/Schema/Album.pm`, `sub duration`,
contains `return if !defined $_->secs;` — LMS's own album-duration accessor
abandons the whole computation if any single track's duration is undefined.
That is LMS treating the case as ordinary, which is stronger evidence than the
DDL alone.

**Decided: if any local track of the album has a NULL `secs`, the verdict is
`(structural, candidate)`. Count equality is still evaluated and can still
reject; it is confirmation specifically that is withheld.**

#### Why this is application of §8, not a new rule

A NULL local duration puts us in the same epistemic position as a missing
Discogs duration: the track count is known, the duration vector is not. §8
already rules on that position. Deciding it differently depending on which side
the gap is on would mean the tier's confidence depends on where the ignorance
sits rather than on how much of it there is.

#### The failure mode this prevents

An unhandled NULL reaches the comparison one of two ways. Under `use warnings`
a numeric comparison against `undef` warns and the sort order is unreliable —
the same bug `Library.pm::_finish`'s timestamp loop already carries a comment
about, for the same reason. Worse, an implementation that coerces `undef` to 0
produces a duration of zero that falls **within the ±2–3 s margin of any
sufficiently short Discogs track**, yielding a spurious element-wise match.
Structural auto-confirms silently (§8), so that surfaces as a wrong badge with
no trace of the disagreement that caused it — the outcome the tier design
exists to prevent, and the one step 5's reject/dismiss was recorded three times
over to recover from.

A skipped confirmation is visible and recoverable. A wrong confirmation is
neither.

**Rejected — treat a NULL as "this track has no duration" and compare the
remaining vector.** It changes the length of one side of a comparison whose
first step is count equality, so it would either reject every affected album on
count (indistinguishable from a genuine mismatch, and misleading in the queue)
or require the count to be taken before the filter and the vector after, which
is two different track counts in one comparison.

**Rejected — fall back to count-and-title agreement.** §8 already names that as
Fuzzy-grade evidence and refuses to ship it under Structural's auto-confirming
behaviour. The argument is unchanged here.

#### Consequences

- **Float, not integer.** `secs` is a `float`; Discogs durations are integer
  `M:SS`. The comparison is float-to-integer and the margin absorbs it. Stated
  so it is not rediscovered as a defect.
- **`Library.pm` must supply the durations at all.** Its iterator currently
  does not — see `TODO.md` and plan §3. That is sequencing, not a decision, and
  is tracked there.
- **Frequency is unmeasured.** How many of the 764 reference albums carry any
  NULL `secs` is unknown and needs the real server. It feeds the review-queue
  sizing question in `TODO.md`, not this ruling — the rule is correct at any
  frequency; only its cost varies.

**Unverified, carried forward:**

- Whether NULL `secs` correlates with a content type, an importer, or with
  remote rows specifically. Nothing has been measured.
- Whether `Slim::Schema::Album::duration`'s guard was written for NULL `secs`
  on local tracks or for some other case. The guard's existence is verified;
  its motivating case is inferred from its shape.

### 12.3 What these two rulings share, recorded because it will recur

Both cases are the same shape: **Structural's evidence quality varies per
album, and v1's answer to weak evidence is always the review queue.** Neither
ruling tries to rescue an album by finding additional evidence or by relaxing a
threshold.

That is deliberate and should stay the default. The instinct to shrink the
queue by widening what counts as sufficient evidence trades a visible
inconvenience for an invisible wrong badge, which is the wrong direction. The
correct response to a large queue is better queue tooling — bulk actions in
step 5 — not a laxer matcher. Recorded in `TODO.md` so it is not invented under
pressure after the hardware pass.

---

## 13. Collection-first identification, and what auto-confirmation means

**Decided 2026-09-12 (design chat).** This record reverses the direction of v1's
matching. It supersedes the flow in §8, narrows §11, makes most of §12
inoperative, and amends §3's two-track read rule. Those consequences are set out
in 13.8 rather than left to be discovered.

The change came from re-reading what the plugin is for. Design §2's first core
concept is **ownership awareness** — see which albums in LMS you own physically.
§8 answered a harder question than that: *which Discogs release is this album*,
searched against the whole Discogs database. Ownership only needs the narrower
one, and the narrower one is answerable against a few hundred rows instead of
seventeen million.

### 13.1 The reversal: match against the collection, not against Discogs

**Decided: identification for ownership purposes runs against the user's own
Discogs collection, fetched by sync, not against `/database/search`.**

| | §8 as written | This record |
|---|---|---|
| Question | which Discogs release is this album | do I own this album |
| Search space | the Discogs database | the user's collection |
| Requests | 1 search + 1–N fetches **per album** | `ceil(items/100)` **per sync** |
| Scales with | library size | collection size |
| Comparison | track counts and duration vectors | title, then artist to disambiguate |
| Re-run cost | hours | seconds |

Measured collection sync cost is already recorded in §9.4: **3 requests for a
203-item collection.** Against a 764-album library, §8's flow was measured in
hours at 60 requests per minute (§10.8).

**What this costs.** §8's flow could identify albums the user does *not* own.
This one cannot — an album absent from the collection gets no Discogs identity
from this path. Design §2's other two core concepts, marketplace lookup and
cross-browsing, need one.

**That is recovered without a background sweep**, using §9.5's own rule:
*request count bounded by user actions → live.* A marketplace lookup or a
"view on Discogs" action on an unowned album is one context-menu click, so it
searches live at that moment. The capability moves from scan time to on demand;
it is not lost.

### 13.2 Match during the sync; store conclusions, not Content

**Decided: the sync holds each collection page in memory, matches it against LMS
albums there, writes only the conclusion, and discards the payload.**

No Discogs-owned data persists. This is §9.5's "store conclusions, not Content"
applied directly, and it is why **TODO's 2026-09-07 ruling against a
`discogs_collection` mirror stands** rather than being reversed by this record.
An earlier draft of this session proposed storing the collection; that proposal
was wrong and is recorded here so it is not re-proposed.

`basic_information` carries `title` and `artists` — which is what the match
consumes — plus `id`, `master_id`, `formats`, `labels`, `year`, `genres`. Held
for one pass, dropped.

**Consequence: matching must be deterministic.** The payload is gone, so a
re-sync re-derives every conclusion. The same collection against the same
library must produce the same answers, or badges will change between syncs with
no visible cause. This is a requirement on the matching rule, not an
implementation note.

**The `snapshot_*` columns are LMS-side and stay.** `snapshot_artist` and
`snapshot_album_title` hold the *local* album's identity for orphan recovery
(§2), not Discogs' copy. **Inferred, not previously documented**, from three
converging facts: §2 describes the orphan lookup as finding a snapshot that fits
a *new local album*; the index is `(state, snapshot_track_count)`, commented in
`Schema.pm::_migration_1` as "confirmed rows whose snapshot might fit a new
album"; and `basic_information` carries **neither a track count nor durations**,
so the Discogs side cannot populate `snapshot_track_count` or
`snapshot_total_duration` at all. Stated explicitly here because it is the one
place in the schema where stored text could plausibly have been Discogs Content,
and nothing said otherwise.

### 13.3 Identification and ownership are different columns

**Decided: `discogs_release_id` continues to mean identity — which release this
album *is*. Ownership is recorded separately and is never expressed by NULLing
the release id.**

The case that forces the split, and it is the common one: a file carries
`DISCOGS_RELEASE_ID=123`, the collection holds release **456**, both resolve to
master 50841. The user owns a version, not that pressing. Making
`discogs_release_id` mean ownership would require NULLing 123 — destroying an
identification the user supplied themselves.

| Column | Question | Source |
|---|---|---|
| `discogs_release_id` | which release this album is | tag (Strict) |
| `discogs_master_id` | which edition | tag, or the collection's `master_id` |
| ownership label | what the user owns | collection sync |

Ownership takes one of: **exact** (that release id is in the collection),
**version** (a different release under the same master is), or absent.

**No new schema surprise.** TODO, 2026-09-07 already specifies the ownership
column landing in migration 3, "in the step that reads it". This record makes
migration 3 the next schema step rather than a later one.

**§3a's NULL-id invariant is untouched.** A NULL `discogs_release_id` still
means either a strict conflict or an edition-level match, and neither is
overloaded by this record.

This closes the pressing-versus-edition conflation that TODO has carried as
*Deferred by decision* since 2026-09-07, and settles §8's "an edition-level match
has no pressing to show — product decision, recorded not taken."

### 13.4 Only Strict auto-confirms, and only with collection agreement

**Decided: `state = 'confirmed'` requires a Discogs release id read from the
user's own tags AND that same release id present in the collection.**

Everything else is a candidate. Nothing that *infers* identity ever
auto-confirms.

The principle, in the user's words: a real release is only identified for an
album that was ripped, tagged, and added to Discogs by the user themselves. A
tag is the user asserting identity — there is no inference to get wrong.
Structural inferred identity from track shape, and §8 let it auto-confirm
silently; that combination is what this record removes.

**Rejected — Structural auto-confirming on a matching duration vector (§8).**
Pressings of one edition share a tracklist (verified against master 3855547,
whose LP variants are indistinguishable by track count or duration), so a
matching vector never established a pressing. §8 already knew this and wrote
`discogs_master_id` with a NULL release id because of it. This record goes
further: an edition-level conclusion is not a confirmed pressing and should not
be presented as one.

**Required, and not optional: the review queue must not fill with albums the
user does not own.** An album correctly identified from a tag but simply absent
from the collection needs no human decision — there is nothing for the user to
do about it. Against a few-hundred-item collection and a 764-album library, most
albums are unowned; a candidate predicate that catches them turns the queue into
noise and reproduces the "chore" §8 was trying to avoid. The queue holds albums
where a human choice would change something.

### 13.5 All tags are read — for collection-matched albums only

**Decided: for an album that matched the collection, read the Discogs tag from
every local track, not just the primary and fallback. For every other album, the
existing two-track read stands.**

This **amends §3's rule** and `Importer.pm::_examine`'s "never all", whose
comment reads: *"A compilation assembled from per-track tagging is not a
maintained collection and is not worth paying 12x the file reads to
accommodate."* The reasoning was sound against the population it considered —
every album in the library. Scoped to collection-matched albums only, the
arithmetic inverts: 12x on a few hundred owned albums is **cheaper in absolute
terms** than the rule it replaces was on 764.

It also puts the expensive check where the stakes are. Tags disagreeing on an
owned album means a badge is about to be wrong. On an unowned album, nothing
depends on it.

Tags disagreeing across an owned album's tracks → candidate, into the review
queue, where the user retags or rejects. That is the queue doing real work on a
small set.

`Library.pm` currently caps `candidates` at two urls (`splice(@sorted, 2)`), so
this needs a second accessor rather than a change to that one — the two-track
path remains correct for its own case.

### 13.6 Ownership is its own pass, and does not use the file-state skip

**Decided: ownership determination runs as a pass triggered by a collection sync
completing, not inline in the importer's per-album loop.**

**The failure this avoids, which is not obvious from the importer's code.**
`Importer.pm::_canSkip` returns true when the album's stored `source_timestamp`
equals the current `MAX(tracks.timestamp)` over its local tracks. Buying a record
and adding it to Discogs changes nothing on disk, so the album is skipped before
anything examines it — and no badge appears.

**A full rescan does not help either.** The skip key is derived from file
mtimes; LMS rebuilds its database from the same files and writes back the same
timestamps, so `album_key` and `source_timestamp` are unchanged and the album
still skips. **Inferred** from the skip predicate and `source_timestamp`'s
definition, both read; **not observed on a real server.** It is on the hardware
list, and if it turns out false the reasoning here needs revisiting rather than
the conclusion — the separate pass is right either way.

So: **identification skips on file state, because tags only change when files
change. Ownership does not skip, because ownership changes when the user buys a
record.** For most albums the ownership pass is a local comparison between stored
conclusions and the freshly-synced collection, costing no file reads at all;
13.5's all-tags read touches only the matched subset.

### 13.7 Sync triggers, and the rule that stops badges vanishing

**Decided: three triggers — the start of a music scan, the interval pref, and a
manual "Sync collection now" button.** The interval and the button were already
specified in TODO, 2026-09-07; a scan is added because reaching for rescan when
something has changed is what LMS users already do, and a plugin needing its own
separate ritual is one users will forget.

**Decided, and this is the important half: a failed or partial sync leaves the
previous ownership conclusions untouched.** Ownership is recomputed only from a
sync that completed. Anything else logs at `warn` and changes nothing.

Without that rule, a network failure, a revoked token, a Discogs 500 or a
rate-limit stall during a scan-triggered sync recomputes ownership against an
empty or partial collection and **every badge silently disappears** — files
unchanged, no error the user sees. This project's named worst outcome is a
silently wrong badge; a silently vanished one is the same failure wearing a
different coat, and it is *more* likely now that a sync rides along with every
scan.

Pair it with the last-synced timestamp on the settings page, already specified
in TODO, so "the badges look wrong" has a visible first thing to check.

Two consequences that follow rather than needing separate decisions: the sync
must work from both the scanner and the server process, which `_writeOk` /
`_writeRefusal` already govern; and an aborted scan commits rather than rolling
back (§0.8), so "aborted mid-sync" is reachable and lands under the rule above.

### 13.8 What this supersedes, and what survives

**Superseded:**

- **§8's candidate-enumeration and comparison flow**, in full — the
  `type=master` search, ranking on `community.have`, the per-album fetch cap,
  the duration-vector comparison as a *verdict*, and the 90/7.5/2.5 confirm
  calibration built on it.
- **§8's auto-confirmation**, per 13.4.
- **§11's zero-result title-only retry**, which existed to make a
  whole-database artist+title search work for compilations. There is no such
  search now. §11's underlying finding — that LMS and Discogs catalogue
  compilations under different conventions, and that an LMS compilation's album
  artist is a placeholder rather than a name — **survives and still governs**
  how the collection match handles them.
- **§12.1 and §12.2 become inoperative**, one day after being recorded. Both
  ruled on what yields `(structural, confirmed)` versus `(structural,
  candidate)`. Nothing is structurally confirmed now. Their *reasoning* stands
  and §12.3's principle is reaffirmed by this record; their operative clauses
  have nothing to govern. Left in place rather than deleted — reading why a rule
  existed is what stops it being reinvented.

**Survives unchanged:**

- §2 and §2a in full — keying, orphan recovery, the invariants, the narrow
  delete predicate.
- §3a, including the NULL-id invariant (13.3).
- §3b's invalidation-on-settings-change.
- §9 in full — auth, rate limits, pagination, caching policy, attribution.
- §10's clear & rebuild.
- Strict tier as built, extended by 13.4 and 13.5.

**Open, and deliberately not decided here:**

- **What `match_tier` value a collection-derived match carries.** The CHECK
  allows `strict`, `structural`, `fuzzy`, `manual`. A title-plus-artist match
  against the collection is a genuinely different *origin*, which is the thing
  `match_tier` records — so unlike §3a's conflict case, a fifth value is
  defensible here rather than expressing something `state` already expresses.
  Against it: a new value means a migration, an amendment to design §3 and §10,
  and every future reader. **Decide before migration 3.**
- **Whether duration comparison survives as a disambiguator.** The candidate set
  is now tiny, so it is rarely needed — but a collection holding two pressings of
  one album is exactly where title and artist cannot separate them. The
  comparison code from step 4 items 4–5 would serve, if written as a ranker
  rather than a verdict. Not v1 unless the hardware pass shows the case is real.
- **Whether the badge shows one state or two** — exact versus version as two
  colours, or one badge with the distinction only in the context menu. Design §9
  already has configurable badge colours for owned and wantlist; this would be a
  third axis. UI decision, not a data one; the data supports either.

### 13.9 Unverified, carried forward

- **That a full rescan cannot recover a newly-bought record's badge** (13.6).
  Inferred from source, not observed.
- **That `https://www.discogs.com/release/{id}` resolves without a title slug.**
  The context-menu link is constructed from the stored id rather than kept from
  the payload, because `basic_information` carries only `resource_url`
  (`api.discogs.com/...`), which is not the web page §9.6's attribution
  requirement names. `Tags.pm`'s own parser documents `/release/<id>` as
  canonical and accepts it, but `Tags.pm`'s header also records that discogs.com
  returns 403 to automated fetches, so this was never confirmed against the live
  site. One browser click settles it; it is on the hardware list.
- **The proportion of the 764 reference albums that match the collection at
  all.** Every cost estimate in 13.5 and 13.6 rests on "a few hundred", which is
  the collection's size, not the measured overlap.
- **Whether LMS album titles and Discogs `basic_information.title` agree often
  enough for title-led matching to work**, and what normalisation is needed.
  §8 recorded that title normalisation cut 7 search masters to 1–2; nothing
  measures it against a collection. This is the single largest unmeasured
  assumption in this record.

