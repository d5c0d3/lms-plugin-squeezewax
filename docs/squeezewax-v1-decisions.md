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
  §5. — dropped 2026-10-17, see §5 note.
- **Completeness / misalignment detection** ("you have 9 of 12 tracks") → v2.
  Requires one release fetch per matched album; see §4. — dropped 2026-10-17 (owner).
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

**Superseded 2026-10-18 by §15.46 (settled), part 8.**

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
   **Amended 2026-10-18 (§15.46 part 9):** a second permitted delete,
   `match_tier = 'strict' AND state = 'candidate' AND
   review_reason = 'conflict'`, when the album's files carry no Discogs tag.
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

**Superseded 2026-10-18 by §15.46 (settled), part 6.**

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
| Completeness check (v2) — dropped 2026-10-17 | 1 release fetch per matched album, cacheable forever |

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

**2026-10-17 (owner):** no per-pressing add from LMS; see GitHub #11 for the master idea.

Endpoint: **`PUT /users/{username}/wants/{release_id}`**. Two Discogs forum
threads report `POST` on the same path returning *"That release does not exist
in the user's wantlist"* — POST updates an existing want, PUT creates one.

For reference if ever revisited, collection add is
`POST /users/{username}/collection/folders/{folder_id}/releases/{release_id}`
with a non-zero `folder_id` (0 is the read-only "All" view, 1 is
"Uncategorized").

### Triage page (v2) — problem classes to surface

**Superseded 2026-10-17 (owner):** no separate page; see `TODO.md` (#6). Of the
eight classes: disagreeing tags are in the review queue; unparseable → #6;
deleted release → recorded only; no tag found → out of scope; Structural → gone
(§13.8); "neither Collection nor Wantlist" is not a problem under
collection-first ownership (§13); incomplete → dropped (part 3); partial
multi-disc → not identified in today's code.

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

**Superseded in operative part 2026-09-12 by decisions §13.** The flow described
here — type=master search, ranking, per-album fetch, duration-vector
comparison as a verdict, and auto-confirmation — is not what v1 does.
Identification now runs against the user's own collection (§13.1) and
only Strict auto-confirms (§13.4). The findings below stand as
evidence and several still govern: duration availability is a property
of the Discogs entry; pressings of one edition share a tracklist; LMS
groups multi-disc sets into one albums row; albums.disc equals the disc
count, not an index.

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
~~vinyl `A1`/`B2` and other formats are unsurveyed~~ — **corrected 2026-09-12,
Phase 0.** vinyl A1/B2 positions occur in four of eight fixtures (42 of 98
tracks), the most common format in the corpus. What is unsurveyed is
multi-record vinyl disc membership: both vinyl fixtures are
`format_quantity: 1`. Building a position parser on a single observation is
the error this session made five times in other forms.

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
  normalisation. The design §13 rewrite decides it.

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

**Answered 2026-09-29, §15.25** ("step 6" was the 2026-09-07 numbering for what
is now build-order step 9). There is no grid badge. The menu shows no Discogs
data, only our conclusion and a link. Both notices go on the settings page, the
second linked to the user's collection page.

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

### 9.10 Considered and rejected: reusing the Music and Artist Information (MAI) plugin's Discogs client

**Decided 2026-09-27 (design chat).** Checked against
`michaelherger/MusicArtistInfo` `master` @ `a5ea399` (2026-09-21), by reading
`Discogs.pm` and `Common.pm`. It was not run.

MAI has a working Discogs client with rate limiting and caching
(`Plugins::MusicArtistInfo::Discogs`). **SqueezeWax will not call it, copy it
or depend on it.**

1. **Different calls, different credentials.** MAI's `_call` only reaches
   `database/search`, `artists/{id}` and `artists/{id}/releases`. It signs them
   with MAI's own app key, stored base64-encoded in `Common.pm`'s `__DATA__` and
   returned by `getHeaders('discogs')`. SqueezeWax needs `/oauth/identity` and
   the user's collection, sent with the user's personal token (§9.1, §9.7). MAI
   has no collection code to reuse. Its credential model is the one §9.1
   rejects: an app secret shipped inside the plugin, where encoding it is the
   "obfuscation" §9.1 calls worse. *Verified.*
2. **Its caching breaks §9.5 and §13.2.** `_call` forces a 60-day cache of
   whole responses (`expires => '60d'`). §9.5 quotes the terms: Content more
   than six hours older than Discogs' copy may not be displayed, and may not be
   stored longer than necessary. §13.2 keeps no Discogs payload at all.
   *Verified.* A 60-day-old collection would also give wrong badges.
   *Inferred.*
3. **Its rate limiting only runs in the scanner.** The token bucket is created
   only `if (main::SCANNER)`. Backoff on a 429 error exists only in `Common.pm`
   `call`'s scanner branch. SqueezeWax's sync runs on the server side (§15.2),
   where MAI does neither. `API/Async.pm` already does its own rate-limit
   accounting. *Verified by reading.*
4. **It would tie SqueezeWax to another plugin.** The package is MAI's internal
   code, not a published interface. Using it would require MAI to be installed,
   and MAI's refactors could break SqueezeWax. Copying it instead has an
   unclear licence: no LICENSE file in the repo root, and none is mentioned in
   `README.md` or `install.xml`. *Unverified beyond those three places.*

**Nothing is taken from it.** Its one notable detail is a comment in
`Common.pm` `call` about using a specific User-Agent to comply with Discogs'
terms. SqueezeWax already meets that requirement its own way (§9.3,
`API.pm:79`).

**Related, already recorded:** slimserver issue #397. MAI cached on album/artist
ids that change, a mistake §2 and `TODO.md` cite as a precedent to avoid.

---

## 10. "Clear & rebuild matches" preserves manual rows and nothing else

**Superseded 2026-10-17 by §15.46** (no manual rows remain to preserve; GitHub #5 closed).

**Superseded 2026-10-18 by §15.46 (settled), part 6.**

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
- **Preferences** — tag names, ~~margin, TTL, tier selector~~ — **corrected
  2026-09-18: the duration margin and the no-match TTL belonged to Structural
  and were never built; the tier selector is removed by §15.8. What survives is
  the tag-name list and the access token** — this action clears results, not
  configuration.

### 10.3 Manual rows survive intact, including their cheap columns

**Superseded 2026-10-18 by §15.46 (settled), part 6.**

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

**Superseded 2026-10-18 by §15.46 (settled), part 6.**

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

**Narrowed 2026-09-12 by §13.** The zero-result title-only retry
existed for a whole-database artist+title search, which v1 no longer
performs (§13.1). The finding that LMS and Discogs catalogue
compilations under different conventions — and that an LMS
compilation's album artist is a placeholder rather than a name — still
governs how the collection match handles them. §11.3's prohibition on
calling variousArtistsObject and §11.4's rule that LMS owns contributor
roles both stand unchanged.

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

**Corrected 2026-09-19 (§15.12), from source at slimserver `a670a38`.** Two
claims in the paragraph above are false. `Album::artists` does **not** build on
`albums.contributor`: it reads role rows (`ALBUMARTIST`, then `BAND` if the pref
is set, then `ARTIST`) and falls back to `Album::contributors` — every
contributor via `contributor_album` (`Slim/Schema/Album.pm:95-100`) — never the
`albums.contributor` column, which is the separate `belongs_to` at `:44`. And
`Album::artists` can call `Slim::Schema->variousArtistsObject` for a compilation
with no usable artist, which §11.3(d) forbids because it writes to the library.
**So the recommendation to use `Album::artists` is withdrawn; the
`albums.contributor` column stands as the source**, read by raw SQL. That column
is set per track by `_createOrUpdateAlbum` from the primary contributor
`_postCheckAttributes` passes it (`Slim/Schema.pm:1283-1296`, `:3060-3091`), so
the last track written wins. Where the choice matters — the ownership pass,
comparing against Discogs — it is `TODO.md` Q10.

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

**Inoperative from 2026-09-12, one day after being recorded — see §13.**
Both rulings governed the boundary between (structural, confirmed) and
(structural, candidate). Nothing is structurally confirmed under §13.4,
so neither clause has anything to govern. The reasoning stands and
§12.3's principle — weak evidence goes to the review queue rather than
being rescued by a laxer matcher — is reaffirmed by §13. Retained
rather than deleted: reading why a rule existed is what stops it being
reinvented.

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
- **Frequency is unmeasured.** How many of the ~~764~~ — **corrected
  2026-09-12: 765** — reference albums carry any NULL `secs` is unknown and
  needs the real server. It feeds the review-queue sizing question in
  `TODO.md`, not this ruling — the rule is correct at any frequency; only its
  cost varies.

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
203-item collection.** Against a ~~764~~ — **corrected 2026-09-12: 765** —
album library, §8's flow was measured in hours at 60 requests per minute
(§10.8).

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

**Amended 2026-10-17 by §15.45** (owned release ids are kept).

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

**Corrected 2026-09-12 — see 13.10.2 and 13.10.3.** A title-and-artist
match against the collection is sufficient to badge version ownership,
with no tag and no local file. The rule below conflated identification
with ownership, which 13.3 already separates.

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
do about it. Against a few-hundred-item collection and a ~~764~~ — **corrected
2026-09-12: 765** — album library, most albums are unowned; a candidate
predicate that catches them turns the queue into
noise and reproduces the "chore" §8 was trying to avoid. The queue holds albums
where a human choice would change something.

### 13.5 All tags are read — for collection-matched albums only

**Population amended 2026-09-12 — see 13.10.1.** The local_tracks == 0
gate is removed; all albums are in scope. The cost arithmetic below was
written against 579 local-bearing albums, not the full 765.

**Decided: for an album that matched the collection, read the Discogs tag from
every local track, not just the primary and fallback. For every other album, the
existing two-track read stands.**

This **amends §3's rule** and `Importer.pm::_examine`'s "never all", whose
comment reads: *"A compilation assembled from per-track tagging is not a
maintained collection and is not worth paying 12x the file reads to
accommodate."* The reasoning was sound against the population it considered —
every album in the library. Scoped to collection-matched albums only, the
arithmetic inverts: 12x on a few hundred owned albums is **cheaper in absolute
terms** than the rule it replaces was on ~~764~~ — **corrected 2026-09-12:
579** — since a two-track tag read needs local files, so the old rule's real
population was local-bearing albums, not the library's full 765 (13.10.1).

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

**Corrected 2026-09-15 — see 15.2.** The scan trigger fires when a scan
completes, in the server, not at scan start. The completed-sync rule below is
unchanged.

**Superseded in part by §15.18.** "In the server" is now the fallback: the scan
trigger runs inside the scan itself, from our own importer, and the server's
`['rescan','done']` sync runs only for scans that one did not. The
completed-sync rule below is unchanged and governs both paths.

**Decided: ~~three triggers — the start of a music scan, the interval pref, and a
manual "Sync collection now" button.~~** **Corrected 2026-09-22 — see §15.2 and
§15.15.** Two triggers: a music scan **finishing** (`['rescan','done']`,
debounced), and the manual "Sync collection now" button. The scan trigger was
corrected to scan-finish by §15.2; the interval pref was removed by §15.15. The interval and the button were already
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
  and every future reader. ~~**Decide before migration 3.**~~ — **Decided 2026-09-13, see §14.1:
  `match_tier` becomes nullable and NULL is what a collection-derived match
  carries. Neither a fifth value nor an existing one — the column records the
  provenance of an *identification*, and a collection match makes none.** The
  reasoning above is preserved because one of its premises was wrong in a way
  worth keeping: "a new value means a migration" treated a migration as the cost
  of the fifth value specifically. It is not. SQLite cannot alter an existing
  CHECK constraint at all (verified, `sqlite.org/lang_altertable.html`, the ALTER
  TABLE page's §8), so **every** option here required the same 12-step table
  rebuild, and the objection did not distinguish between them.
- **Whether duration comparison survives as a disambiguator.** The candidate set
  is now tiny, so it is rarely needed — but a collection holding two pressings of
  one album is exactly where title and artist cannot separate them. The
  comparison code from step 4 items 4–5 would serve, if written as a ranker
  rather than a verdict. Not v1 unless the hardware pass shows the case is real.
- **Whether the badge shows one state or two** — exact versus version as two
  colours, or one badge with the distinction only in the context menu. Design §9
  already has configurable badge colours for owned and wantlist; this would be a
  third axis. UI decision, not a data one; the data supports either. — **Decided 2026-09-13, see §14.5: one badge, with
  the exact-versus-version distinction in the context menu only. Revisit after
  the hardware pass.** The deciding argument is not in the text above: version
  ownership is the *main* path under §13.10.2, not an exception, so two colours
  would teach a distinction that is almost always one value.

### 13.9 Unverified, carried forward

**Partly answered 2026-09-12 by measurement — see 13.10.** Title
agreement was the largest unmeasured assumption here; it was measured
and it holds. 13.10.6 carries what remains unverified.

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
- **The proportion of the ~~764~~ — corrected 2026-09-12: 765 — reference
  albums that match the collection at all.** Every cost estimate in 13.5 and
  13.6 rests on "a few hundred", which is the collection's size, not the
  measured overlap.
- **Whether LMS album titles and Discogs `basic_information.title` agree often
  enough for title-led matching to work**, and what normalisation is needed.
  §8 recorded that title normalisation cut 7 search masters to 1–2; nothing
  measures it against a collection. This is the single largest unmeasured
  assumption in this record.

### 13.10 Amendments of 2026-09-12, after measurement

**Five corrections to this section, taken together because they are one
decision.** Four were decided in the design chat while specifying the title
agreement measurement; the fifth follows from the measurement's results. The
measurement is recorded in `plans/title-agreement-measurement.md` and its script
is `scripts/title-agreement.pl`.

The original text of 13.4, 13.5 and 13.9 is left standing. What was believed and
why it was wrong is the useful part (working agreement §7.7).

#### 13.10.1 The `local_tracks == 0` gate is removed

**Decided: all albums are in scope, including all-remote ones.**

The gate exists in `Importer.pm` and is stated in §8. Its reason was Structural's
duration fingerprint: you cannot read durations from an album with no local
files. 13.1 replaced that flow with title-and-artist matching against the
collection, which needs no local file at all. The gate's rationale evaporated and
nobody noticed, because it was inherited from a tier that no longer runs.

On the reference library this excluded **186 of 765 albums, 24%** — measured
2026-09-12. Streaming an album you own on vinyl is arguably where the badge is
most useful: the record is on the shelf and you are streaming it because pulling
it out is a faff.

**Measured consequence:** removing the gate matched **10 additional owned
records**. Modest in absolute terms, but 9 of the 11 direction-(b) groups are
exactly those stream halves, so the gate was systematically dropping the second
copy of records the user demonstrably owns.

~~`Importer.pm`'s gate and the comment above it now contradict this record and
must be changed by the build order.~~ — **corrected 2026-09-19 by §15.11: the
decision above stands and is carried by the ownership pass, which must iterate
every album. `Importer.pm`'s gate is a different gate with a different reason —
"nothing to read tags from", in its own comment since `cec7a46` — and it stays.
This record merged it with §8's Structural gate; the reasoning here is right
about that one only.**

#### 13.10.2 Correction to 13.4 — a title match is sufficient to badge

**13.4 as written was wrong.** It said only Strict auto-confirms. That was
reasoned about *identification* — which release this album is — where inference
genuinely is dangerous, because a duration vector cannot distinguish pressings.

But the badge does not read identification. 13.3 put ownership in its own column
precisely so it would not. The two claims are different sizes:

- **Identification:** "this LMS album *is* Discogs release 456." Needs evidence
  about the object.
- **Version ownership:** "you own a record called *Violator* by Depeche Mode."
  Needs only that title and artist agree.

The collection is ground truth about what the user owns. There is no inference to
get wrong in the way 13.4 was guarding against.

**Decided: a title-and-artist match against the collection is sufficient to badge
version ownership, with no Strict tag and no local file.** Strict-confirmed
*exact* ownership is unchanged.

As written, 13.4 also violated its own hard constraint. It required that the
review queue not fill with items where no human choice changes anything — and
then routed every all-remote album into it. On the reference library that was up
to 186 unclearable items.

This correction was surfaced by Claude Code reading 13.4 against the measurement
population and asking what happens to albums that can never carry a tag. The
question was better than the record it questioned.

#### 13.10.3 The unambiguous-match guard

A wrong version badge is still a wrong badge, so 13.10.2 needs a bound.

**Decided: version ownership auto-badges only on an unambiguous match — exactly
one collection entry agreeing on both title and artist.** Everything else is a
review-queue item: several candidates, artist disagreeing, or artist absent on
either side.

**Consequence: artist is load-bearing, not decorative.** It gates every
auto-badge rather than only breaking ties among collisions.

**The two collision directions are different problems and must never be summed:**

- **One LMS album → several collection entries.** Ambiguous. Queue.
  **Measured: 1 of 765**, and artist did not resolve it (two pressings, same
  artist). One album does not justify designing a tiebreak; the queue handles it.
- **One collection entry → several LMS albums.** Legitimate and expected — a rip
  and a stream of one record are two albums for one owned item, and **both should
  badge**. ~~**Measured: 11**, of which 9 are exactly that shape.~~ —
  **corrected 2026-09-12, re-measured at L2: 10, of which 9 are exactly that
  shape.** The L5-era count of 11 included the Biosphere *Substrata* /
  *Substrata²* pair, which only collided because L3's punctuation-stripping
  destroyed the distinguishing superscript (13.10.4); at L2 it does not
  collide and the pair is not in this direction at all. Removing the gate
  (13.10.1) increases this direction by construction, so a rise here is the
  expected consequence of that decision, not a regression.

~~Measured auto-badge split at the time of the amendment: **88 of 97 matches
auto-badge, 8 queue on artist disagreement, 1 queues as ambiguous.**~~ —
**corrected 2026-09-12, re-measured at L2: 87 of 96 matches auto-badge, 8
queue on artist disagreement, 1 queues as ambiguous.** The one-match, one-badge
difference from the L5-era figure is exactly the *Substrata²* mismatch
(13.10.4); it stopped matching at all once L2 became the analysis rung.

#### 13.10.4 The normalisation ladder stops at L2

**Decided: normalise no further than case-folding and whitespace collapse.
Punctuation-stripping, article-stripping and bracket-suffix-stripping are not
used.**

The measurement applied a fixed six-rung ladder and reported each rung. Across
100 collection entries and 765 albums:

| Rung | Rule | LMS gain | Collection gain |
|---|---|---|---|
| L0 | exact, after decode | 95 | 85 |
| L1 | + case-folded | +1 | 0 |
| L2 | + whitespace collapsed | 0 | 0 |
| L3 | + punctuation removed | +1 | 0 |
| L4 | + leading English article removed | 0 | 0 |
| L5 | + trailing bracket suffix removed | 0 | 0 |

**The entire ladder buys two albums and zero collection entries.** Titles already
agree. §8's title-normalisation apparatus was measured against *search results*
and does not transfer to this population — a finding about the corpus, not a
failure of the ladder.

**L3 is removed because it is net-negative, not merely useless.** It gained one
album and caused one **wrong badge**: release 15775 *Substrata* (Biosphere)
matched both album 2969 *Substrata* and album 2971 *Substrata²*, which are
different records — the second is the sequel. The superscript `²` is Unicode
category No and therefore not `\p{Alnum}`, so punctuation-stripping deletes it
and collapses two distinct titles onto one key. Artist cannot separate them; both
are Biosphere. Both badge, one wrongly.

Trading one missing badge for one wrong badge is a bad trade at 1:1 under this
project's stated risk posture, and would remain bad at 10:1.

**Measured 2026-09-12, confirmed:** re-running `scripts/title-agreement.pl`
with the collision analysis, auto-badge split, overlap figures and example
failures moved to run at L2 shows the *Substrata* wrong badge is gone.
*Substrata* and *Substrata²* no longer share a
normalised key at L2, so album 2971 does not match release 15775 at all — it
drops out of the auto-badge split entirely rather than landing in a "wrong
badge" bucket. The L0–L5 ladder table above is unchanged from the run that
produced this decision, confirming the library and fixture did not change
under us. Recomputed at L2: 96 title matches (down from 97 at L5 — the one
match *Substrata²* only picked up via L3's punctuation-stripping), split 87
auto-badge, 8 queue on artist disagreement, 1 queues as ambiguous. Direction
(b)'s collision count drops from 11 to 10 correspondingly (13.10.3). Zero
groups produce a wrong badge at L2.

L4 and L5 are removed for gaining nothing. L2 is retained despite gaining nothing
as cheap defensive hygiene against a leading or trailing space.

A side effect worth recording: the measurement had to apply enabled rules
bracket-strip-first rather than in table order, because L3 destroys the brackets
L5 exists to strip and would have forced L5's gain to zero by construction. With
L3 and L5 both gone, that ordering problem disappears.

#### 13.10.5 The review-queue formula, corrected

The design chat stated two formulas one message apart and they disagreed by 8
items. Caught by Claude Code in the measurement report. The badging rule is
correct; the formula omitted a route it had itself just specified.

**The queue holds, and only holds:**

- ambiguous matches — one LMS album, several collection entries (13.10.3)
- matches where artist disagrees or is absent on either side (13.10.3)
- tag disagreements across an owned album's tracks (13.5)
- Strict conflicts (§3a)

**It does not hold** one item per unowned album, nor one per streamed album.
Measured: **9 items from one collection page**, scaling to roughly 18 across the
collection against 765 albums — assuming pages 2 and 3 behave like page 1, which
the label sort makes shaky. Tag disagreements and Strict conflicts are
**unmeasured**; they need the importer and have not been estimated.

15 of 100 collection entries matched nothing. Those are owned records with no
LMS album — expected, and they generate no queue work.

#### 13.10.6 Unverified, carried forward

- **Pages 2 and 3 of the collection have not been measured.** The fixture is page
  1 of 3, 100 of 203 items, sorted by label and therefore not a random sample.
  Every figure in 13.10 is a one-page figure.
- **The `Various` / `Various Artists` vocabulary difference is unresolved, not
  absent.** LMS names compilation artists `Various Artists`; Discogs uses
  `Various`. ~~It measured **zero impact on page 1 only because no compilation
  matched there**~~ — with 95 LMS compilations and 7 `Various` entries on that page
  alone, pages 2–3 could move the auto-badge rate materially.
  **Corrected 2026-09-22:** six compilations matched on page 1 (albums 3345, 3347,
  3351, 3355, 3356, 3358). The zero is the number of times the equivalence fired,
  not the number of matches: all six carry the literal `Various` on the LMS side
  and agree with Discogs without the mapping. An equivalence rule
  was deliberately not added mid-measurement. If it is added later it is a
  **vocabulary mapping between two catalogues**, the same class as stripping
  Discogs' trailing ` (N)` disambiguator, and must be justified on that ground
  rather than on improving a number. §11's finding — that an LMS compilation's
  album artist is a *placeholder* rather than a name — bears directly on whether
  artist agreement carries real evidence for compilations at all.
- **The 8 artist disagreements have not been examined individually.** Eight
  unrelated cases are noise the queue absorbs; one repeated pattern would be a
  data-format fact deserving a declared rule. The distinction is unmeasured.
- **The artist figures rest on an SQL approximation** of
  `Slim::Schema::Album::artists`, exact for 763 of 765 albums on this server
  (`bandInArtists` off; `variousArtistAutoIdentification` on, so only
  compilations without an ALBUMARTIST diverge — albums 3589 and 3596). Exact
  *for this server's prefs*, not in general.
- **Generic titles are a live hazard.** *Greatest Hits* (release 49747, Depeche
  Mode) matched four LMS albums by four different artists. Artist correctly
  eliminated all four, so no wrong badge — but it shows the failure shape, and
  artist is the only thing standing between it and one.
- **The library is 765 albums, not 764.** 13.5 and `TODO.md` both say 764.
  Measured 2026-09-12. Reconciling the cited figure is its own defect.

---

## 14. Rulings taken to unblock the design reconciliation

**Decided 2026-09-13 (design chat).** ~~Seven~~ **Ten** rulings, taken because
`docs/squeezewax-design.md` could not be reconciled against §13 without them.
Six close gaps the reconciliation survey found; one (14.1) was scheduled for
migration 3 and was pulled forward because design §3 and §10 cannot be written
around it. **Three more — §14.8, §14.9 and §14.10 — were added 2026-09-13
during the rewrite itself.** None was findable by comparing two documents: each
surfaced only when a sentence had to name a specific column value, a specific
button's behaviour, or a specific screen's contents. A survey bounds the work it
can see, and writing the replacement text is itself a second survey.

The survey is `plans/design-reconciliation-survey.md`. Section references name
their document, per `docs/working-agreement.md` §2.

### 14.1 `match_tier` carries no value for a collection-derived match

**Decided: `match_tier` becomes nullable. NULL means "no identification was
made". The CHECK narrows to `strict | manual`.**

**Superseded 2026-10-18 by §15.46 (settled), part 10.** `'manual'` stays allowed by the CHECK and is never
written.

This settles §13.8's "Decide before migration 3" and `TODO.md`'s item of the
same name.

#### Why NULL rather than a fifth value

`match_tier` records **how we know which Discogs release this album is** —
provenance of an identification (design §3; build-order step 2, finding 9).
A collection match establishes no identification. It establishes that the user
owns a record with this title by this artist (§13.10.2), and never says which
pressing. There is therefore no provenance to record, and the honest value is
the absence of one.

A fifth value such as `collection` was considered and rejected: it would put an
**ownership** fact into an **identification** column, which is the precise
confusion §13.3 exists to prevent. Reusing `strict` was also rejected — a
`strict` row asserts that a tag in the user's own file named the release, and
for a collection-derived row no tag exists. Both alternatives cost the same
migration as NULL (see below), so neither buys anything for its dishonesty.

**Rejected on a different ground: deriving the tier from other columns.**
Nothing else in `discogs_match` records *who decided*. `strict` and `manual`
rows are otherwise identical in shape — both set `discogs_release_id`, both may
be `confirmed`, both carry the same snapshots. Re-reading file tags to infer it
would need a file read at query time, which is exactly what `source_timestamp`'s
skip contract exists to avoid; it is ambiguous when a user manually picks the
release the tag already names; and the value is load-bearing in **write** logic
before any file is opened — `manual` is never overwritten by any tier, and
`invalidateStrict` NULLs `source_timestamp` only `WHERE match_tier = 'strict'`.
Recorded because build-order step 2 killed a proposed `match_confidence` column
on exactly this test and the test gives the opposite answer here.

#### Why the CHECK narrows

`structural` and `fuzzy` are no longer produced (§13.8). A schema permitting
values nothing writes is a trap for the next reader, and a stray value degrades
to a silently misclassified row rather than an error.

#### What this costs, and it is not what §13.8 assumed

**Verified, `sqlite.org/lang_altertable.html` (page dated 2026-06-04):** SQLite
cannot modify an existing CHECK constraint. the ALTER TABLE page's §8 lists the only
directly supported schema changes as rename table, rename column, add column and
drop column, and names the 12-step create-copy-drop-rename procedure as the way
to change a CHECK. that page's §6 records that `ALTER TABLE ... ALTER COLUMN ... DROP NOT
NULL` was added in SQLite 3.53.0 (2026-04-09) — that covers the nullability half
only, not the CHECK.

**Where the evidence is thin.** The syntax diagram on that same page shows
`ADD CONSTRAINT <name> CHECK (expr)` and `DROP CONSTRAINT <name>`, neither of
which the prose mentions and neither of which appears in that §8 list. The diagram
appears newer than the text. It does not change the outcome: our CHECK is
written inline and unnamed, so there is nothing to `DROP CONSTRAINT`, and CHECK
constraints combine conjunctively, so adding one narrows rather than widens.

~~**Unverified:** which SQLite version is bundled with the DBD::SQLite in `refs/`.
Not checked.~~ → 2026-10-17: 3.46.1 for perl 5.32–5.42 and 3.22.0 for 5.20–5.30 in
LMS's own tree, but a server on perl 5.32 can run 3.22.0 (piCorePlayer), so 3.22.0
is the floor (decisions §15.42). It does not change the outcome either, since the CHECK forces the
rebuild regardless of what `ALTER COLUMN` supports.

**Consequence: migration 3 is a 12-step table rebuild of `discogs_match`, not an
`ALTER TABLE ADD COLUMN`.** The ownership column (§13.3) rides along in the new
CREATE TABLE. Deciding this now rather than later costs the same rebuild and
runs it before any user has rows.

#### Two obligations on the migration

1. **Count `structural` and `fuzzy` rows before copying, and refuse loudly if
   any exist.** The narrowed CHECK would otherwise fail mid-copy on the one
   table that is not disposable. **Inferred, not verified:** none exist, because
   build-order step 4 stopped after item 3 and the comparison code that writes
   them was never built. Inference is not sufficient for a destructive
   migration; the count is the check.
2. **Assert in the offline suite that a NULL `match_tier` is accepted by the
   narrowed CHECK.** Standard SQL treats a CHECK evaluating to NULL as not
   violated, so `CHECK(match_tier IN ('strict','manual'))` should admit NULL
   without an explicit `OR match_tier IS NULL`. **This is expected behaviour,
   not verified here** — assert it rather than assume it, alongside the existing
   assertions that the CHECK rejects `'Strict'` and accepts `'manual'`.

### 14.2 Token revocation

**Decided: revocation is surfaced, not survived silently.**

- A sync failing because the token is rejected logs at **`error`**. Transient
  sync failures — network, a Discogs 500, a rate-limit stall — continue to log
  at **`warn`** per §13.7. Two levels, deliberately: a revoked token is not
  transient and will not clear itself.
- The settings page shows an **authentication-failure state beside the
  last-synced timestamp**, which stops advancing. Both the timestamp and the
  manual sync button are already specified (§13.7; `TODO.md` 2026-09-07), so
  this adds a state, not a feature.
- **On-demand actions fail with the re-enter-token prompt.** Nothing degrades to
  cached data, because §13.2 leaves no cache.
- Previous ownership conclusions are left untouched, per §13.7. Badges persist
  unchanged until a sync completes.

#### The reason the settings-page state is not optional

Design §8 promised the user would notice. Under §13.7 they will not: existing
badges stay, existing browsing works, and the only symptom is that a record
bought *after* revocation never badges — an absence indistinguishable from a
week in which nothing was bought. Logs are then the sole signal, which is the
outcome §13.7 already argued against when it paired the rule with a visible
timestamp.

#### What is deliberately not promised

`/database/search` returns 200 unauthenticated — **verified**, recorded in
`TODO.md` 2026-09-07 as a falsification of the documentation. Read-only browsing
could therefore keep working after revocation at the documented 25/min tier.
v1 does not promise this. An unauthenticated code path at a different rate limit
has not been designed or measured, and building one is v2 shape. Design §8's
"matching and read-only browsing (which work with app-level auth) continue" is
removed rather than half-rescued: there is no app-level auth in v1 (§9.1).

### 14.3 The Fuzzy tier comes off the roadmap

**Decided: Fuzzy is deleted from design §11's v2 list. Wantlist sync and the
wantlist badge remain v2, unchanged.**

Fuzzy was a batch matcher against the whole Discogs database, and §13.8 removed
the search underneath it. What it existed for has two homes already: all-remote
albums are v1 through the collection (§13.10.1), and identifying an album the
user does *not* own is v1 through on-demand marketplace lookup (§1 item 10;
§13.1, "moves from scan time to on demand; it is not lost"). Nothing is left for
a tier to do.

**Marketplace lookup stays in v1.** Design §7 is not rewritten by the
reconciliation — the survey lists it as surviving untouched, and that list is
binding. Scoping it to a minimum is recorded in `TODO.md` as a separate
question.

#### A clarification the reconciliation must not get wrong

"Not in the collection means not owned" is correct and is the whole ownership
rule. It does **not** follow that an unowned album records nothing. Three things
are still recorded for it:

- **its identification**, when a tag supplies one — `discogs_release_id` means
  identity regardless of ownership (§13.3; §5's ripped-CD case);
- **the ownership label `absent`**, which is one of three values, not an empty
  row (§13.3);
- **the negative**, in `discogs_no_match`, so the album is not re-examined every
  scan.

**Consequence: the review queue must not key on `state = 'candidate'`.** Under
§13.4 a tagged, unowned album is a candidate, and most albums are unowned. The
queue holds only §13.10.5's four contents. Already recorded as a constraint on
step 5's predicate (`TODO.md` 2026-09-12); restated here because the
reconciliation writes the prose that could reintroduce it.

### 14.4 No recovery path for a wrong version badge in v1

**Decided: v1 ships no "not my copy" action and no suppression column.**

§13.10.2 auto-badges version ownership with no confirmation step, so a wrongly
auto-badged album never enters the review queue and the user has no way to
reverse it. `TODO.md`'s reject/dismiss item loses its ground (c), "a wrong
Structural auto-confirm", with Structural itself — the failure shape moved to
the title-and-artist route rather than disappearing.

**Why nothing is built.** Measured zero wrong badges at L2 on page 1
(§13.10.4). v1 assumes a well-tagged library and a maintained Discogs
collection; a user whose collection does not reflect their shelves is outside
what this plugin can help with. **That assumption is stated in design §11 as
part of the reconciliation** rather than left implicit, so the next reader does
not re-litigate every gap a messy library would open.

**The bill being accepted, named.** Reusing manual re-match would not work —
`match_tier = 'manual'` is about identification, and §13.3 puts ownership in a
different column, so a manual identification would not clear a version-ownership
label derived from title and artist. Any later fix needs the ownership recompute
to honour an override, which is a rule and a column, i.e. a migration on
`discogs_match`. This ruling also overrides build-order step 2's finding 8
("don't add a column nothing reads yet") in the opposite direction from usual:
finding 8 is honoured here, at the price of a later migration if the case turns
out to be real.

**Revisit trigger:** the pages 2–3 measurement (§13.10.6) producing any wrong
badge, or the generic-title hazard recorded there materialising on the hardware
pass.

### 14.5 One badge state, not two

**Decided: a single badge for owned. The exact-versus-version distinction
appears only in the badge context menu.**

§13.8 raised this as open and decided nothing, and both of design §3's and §4's
flowcharts terminate in a node that cannot be drawn without an answer.

Version ownership is now the main path, not an exception (§13.10.2), so two
colours would teach the user a distinction that is almost always one value. The
badge's claim — you own this record — is true either way. Design §9's
configurable colours are untouched (survey, List 2); the wantlist colour remains
v2's.

**Revisit after the hardware pass.** This is a UI decision with no schema
consequence; the data supports either rendering (§13.8).

### 14.6 The badge context menu drops collection metadata in v1

**Decided: date added, acquisition date and condition/grading are not shown in
v1. The menu shows pressing details, credits, on-demand value and the Discogs
link.**

§13.2 persists nothing, so these would need a live fetch. **Unverified:**
whether Discogs exposes a per-release lookup of the caller's own collection
entry, as opposed to paging the collection. Not checked against the API
documentation, and nothing in §9 covers it. Design does not assert a mechanism
that has not been verified; the fields are dropped rather than promised.

These fields feed collection value and statistics, which are v2 and v3 anyway.
Recorded in `TODO.md` as an endpoint question to settle before they are wanted.

### 14.7 The rewritten request budget has two parts

**Decided: design §13's table is rewritten as two sections — per sync, and per
user action.**

- **Per sync:** `ceil(items / 100)` requests. **Measured 3 for a 203-item
  collection** (§9.4, §13.1). This is the whole recurring budget.
- **Per user action:** marketplace lookup and "view on Discogs" cost one search
  or one fetch at the moment of the click, **deliberately unbudgeted** under
  §9.5's rule that a request count bounded by user actions goes live.

The Structural row, the "an album with eight pressings costs nine requests"
note, and the "needs a full rewrite" note asking for corrected per-album figures
all describe a flow that no longer runs (§13.8). The 60 req/min rate limit and
the single-threaded async/sync rule above the table are untouched (survey,
List 2).

**Why the second part is not merely a footnote.** With only the sync figure, the
next reader concludes the plugin's entire Discogs cost is three requests, which
stops being true the first time anyone clicks "check availability".

### 14.8 `state` becomes nullable, for the same reason `match_tier` did

**Decided 2026-09-13 (design chat), added after §14.1–§14.7.** Found while
writing design §3's flowchart against the schema.

**Decided: `state` becomes nullable. NULL means no identification was made. The
`DEFAULT 'candidate'` is dropped. The CHECK is otherwise unchanged —
`candidate | confirmed` remain the only non-NULL values.**

#### The case that has no representation

**Verified**, `SqueezeWax/Schema.pm::_migration_1`:

```
state TEXT NOT NULL DEFAULT 'candidate'
      CHECK (state IN ('candidate','confirmed')),
```

§13.10.2's main path is an album with **no tag and no local file** that
auto-badges version ownership from an unambiguous title-and-artist match. Its
row carries `ownership = 'version'`, a NULL `discogs_release_id` and, per
§14.1, a NULL `match_tier`. `state` then has to hold something, and neither
permitted value is true:

- `candidate` means awaiting user resolution in the review queue. This album
  needs no decision — it badged without one.
- `confirmed` means the album is linked to a specific Discogs release. Nothing
  is linked.

This is not an edge case. 87 of 96 matches auto-badged on page 1 (§13.10.4).

#### Why NULL rather than an `unmatched` value

The alternative was widening the CHECK to `candidate | confirmed | unmatched`,
keeping NOT NULL. Its argument is readability: a reader seeing NULL may suspect
an unset column rather than a deliberate absence.

Rejected because it says one thing in two idioms. §14.1 has just established
that a NULL in an identification column means "there is no identification".
`match_tier` NULL beside `state = 'unmatched'` invites the reader to look for a
distinction between them, and there is none — both columns describe an
identification that was never made, and they are always empty together. The
readability concern is answered by a comment, not by a second vocabulary.

Keeping `candidate` was rejected outright: it would overload the one value whose
meaning the review queue depends on, at the same time as `TODO.md`'s standing
constraint that the queue must not key on `state = 'candidate'`.

**This costs nothing extra.** Migration 3 is already a full table rebuild for
§14.1, and this rides it.

#### Three consequences

1. **The `DEFAULT 'candidate'` must go.** With it retained, any insert omitting
   `state` writes `candidate` instead of NULL and drops an auto-badged album
   into the review queue — a silently wrong result rather than an error, which
   is the failure mode this schema guards against everywhere else. **Assert in
   the offline suite** that an insert omitting `state` yields NULL.
2. **Design §3's "Unmatched" state is redefined.** It meant *no row*. It now
   also covers a row that exists to carry ownership and identifies nothing —
   NULL `state`, NULL `match_tier`, NULL `discogs_release_id`. Design §3 states
   the new form.
3. **A row must be worth its existence.** Since absence of a row already means
   "nothing known", a row carrying NULL `state`, NULL `match_tier` and
   `ownership = 'absent'` asserts nothing and must never be written. A row
   exists only where there is an identification, or an ownership conclusion
   other than `absent`. **This invariant is new here, not carried from §13** —
   it follows from the columns but was never stated, and without it the
   ownership pass would write a row per album in the library.

#### Unverified

The orphan-recovery index is `(state, snapshot_track_count)` and recovery
selects `state = 'confirmed'`, so NULL rows should be excluded by the predicate
and no index change should be needed. **Inferred from the predicate, not
verified against the query plan.** Confirm when migration 3 is written.

### 14.9 "Clear & rebuild matches" does not trigger a collection sync

**Decided 2026-09-13 (design chat).**

**Decided: the action warns that badges will be dark until the next sync, and
does not trigger one.**

#### The problem it answers

The maintenance action clears `discogs_match` and `discogs_no_match` (§2a
invariant 3). Under §13.3 the `ownership` column lives in `discogs_match`, so
the action now clears **every badge in the library** — a consequence it did not
have when that table held identifications only.

Identification rebuilds on the next scan. Ownership rebuilds only when a sync
completes, and §13.7's triggers are scan start, the configured interval, and the
manual button. None of them is this action. A user with a long sync interval
therefore loses every badge for an unbounded period, from a button whose name
promises a rebuild.

#### Why not make the action sync

Two alternatives were considered: the action triggers a sync itself, or any
clearing of the match table becomes a fourth sync trigger.

Both were rejected for the same reason: they would make a maintenance action
spend API requests, which nothing else in §9 does, and they would couple a
local-database operation to network availability. An offline user clicking
"clear & rebuild" would then get a failure rather than a rebuild.

"Rebuild" already implies a wait. What was missing was not the sync but the
warning — the user could not see how long the wait would be, or that it depended
on something other than the rescan they were about to run.

#### What this requires

The action states, before it runs, that badges will be absent until a collection
sync completes~~, and that a scan alone does not restore them~~. Design §9 carries
the requirement.

**Corrected 2026-09-22 (§15.2, §15.15): a scan alone DOES restore them.** When
this was written the scan trigger was believed to fire at scan start; §15.2
established that it fires on `['rescan','done']`, so a finished scan runs a sync.
After clear & rebuild, badges return **at the next scan or a press of "Sync
collection now"** — unless no token is set, or the token is rejected, in which
case §15.15 part 2 pauses scan-triggered syncs and the button is the only remedy.
The ruling is unchanged: the action still spends no API requests of its own.

**The manual "sync collection now" button (§13.7) is the user's remedy**, and it
is in the same settings page — so the wait is bounded by one click for anyone
who reads the warning.

### 14.10 v1 does not retain the release id of the owned collection entry

**Reversed 2026-10-17 by §15.45.**

**Decided 2026-09-13 (design chat).**

**Decided: the sync stores the ownership label and nothing more. Context-menu
items that need a resolved pressing are absent for an album owned by version
alone.**

#### What this costs, stated first

Design §4's badge context menu offers pressing details, credits, current
estimated value and a Discogs link-out. All four need a Discogs release id. An
album owned by *version* with no tag has none — `ownership = 'version'`, NULL
`discogs_release_id`, NULL `match_tier` (§14.8) — so its menu says the user owns
the record, does not say which pressing, and offers nothing further.

**That is the majority case.** 87 of 96 matches auto-badged on the measured
page, most by title and artist with no tag (§13.10.2, §13.10.4). For most owned
albums in v1, the badge is the whole feature and the menu behind it is one line.

#### The information exists and is deliberately discarded

`basic_information` carries `id` and `master_id` for every collection entry
(`plans/title-agreement-measurement.md`), and the ownership conclusion is drawn
by comparing against that entry. §13.2 then discards the payload. The release id
that would populate the menu is in hand at the moment of the decision and thrown
away one line later.

Recovering it afterwards means paging the collection again — the same problem
§14.6 declined to solve for date-added and condition.

#### Why not store it

The alternative was a new column holding *the release the user owns*, distinct
from `discogs_release_id` holding *what this album is*. It is a good design. It
was rejected on three grounds, none of which is that it would not work:

1. **§9.5's permission was written about something else.** It calls
   `discogs_match` "a decision plus a bare identifier… unconstrained; kept
   indefinitely", reasoning about identifications. A second stored Discogs
   identifier, retained for a different purpose, should be examined against that
   reasoning rather than inheriting it by resemblance.
2. **It reopens §13.2 by inference.** §13.2 ruled that the sync stores
   conclusions and discards the payload. Whether an owned release id is part of
   the conclusion or part of the payload is arguable — and an argument is not
   what §13.2 says. Amending it deserves its own examination, not a corollary
   drawn in the last section of a reconciliation.
3. **It surfaced in the last section of the rewrite.** A new column proposed at
   that point, in a session whose scope is reconciliation, is the drift this
   session has otherwise held the line against.

**Reusing `discogs_release_id` for the owned release was rejected outright**: it
conflates ownership with identification, which is what §13.3 exists to prevent,
and would make an album claim to *be* a pressing nothing identified it as.

#### The bill

A later fix is a migration on `discogs_match`, the one table this project treats
as expensive to change — the same bill §14.4 accepted, for the same reason.
Design §2 and §4 are written to promise only what v1 delivers.

**Revisit in v2, alongside wantlist**, which needs collection-entry data of its
own and will force the same question about what a sync may keep. Recorded in
`TODO.md`.

#### How this was missed until now

Under the pre-§13 model every badged album was confirmed and therefore carried a
release id, so the menu's contents were guaranteed. §13.10.2 severed the link
between badging and identification, and nothing re-examined what had depended on
it. The reconciliation survey did not flag it because the menu items are not
contradicted by §13 — they are merely no longer reachable. Same shape as the
token-revocation degradation path, and worth recording as a second instance: a
removed guarantee leaves no trace at the sites that relied on it.

---

## 15. Build-order rewrite rulings

Rulings taken while rewriting the build order from step 4 onward, after design
was reconciled against §13 and §14.

### 15.1 Master-id tag keys stay a fixed list

**Decided 2026-09-15 (design chat).**

**Decided: the master-id keys remain the fixed conventional list in `Tags.pm`
(`@MASTER_KEYS`). They are not added to `discogsTagNames` and get no Settings
list of their own.**

#### What was found

Read from `SqueezeWax/Tags.pm` and `scripts/tags-check.pl`, not observed
running:

- `discogsTagNames` defaults to `[]`, set at file scope, per §3's choice of
  detection over guessed defaults. Order and precedence are specified in §3,
  invalidation in §3b. The detection action is built in `Settings.pm` over
  `Tags::candidateKeys` (build-order step 3).
- Master keys are `DISCOGS_MASTER_ID`, `DISCOGS MASTER ID` and
  `DISCOGS_MASTER_RELEASE_ID`. They are matched case-insensitively with no
  separator folding, read by `_masterId` only on `decide()`'s clean-hit path,
  and written by `Match::_recordMatch` into `discogs_master_id`.
- Design §3 describes flowchart node F's master as coming "from a configured
  master tag". None exists. That wording is a defect in design, not a behaviour
  to build.

#### Why not make them configurable

§3 refused guessed defaults for release ids because a silent miss there loses an
identification. A silent miss on a master key costs much less: the album drops
from node F to node H (title and artist), which usually still badges it. Making
the keys configurable would reopen hardware-verified step-3 code — the UI, the
detection action and §3b invalidation — for a benefit nobody has measured.

#### What this does not settle

- Node F's reach is **unmeasured**. Custom tags never reach `library.db` (§3),
  so measuring it needs file reads on a real server. See `TODO.md`.
- `Tags.pm`'s stated reason for fixed keys, "no user-visible effect", no longer
  holds: node F makes master tags affect badges. The comment is corrected when
  that file is next touched. The decision stands on the cost-of-miss argument
  above, not on that comment.

**Revisit** if the node F measurement shows tagged albums that node H fails to
badge but node F would.

### 15.2 The collection sync and the ownership pass run in the server, after a scan

**Decided 2026-09-15 (design chat).** Corrects §13.7's first trigger.

> **Superseded in part by §15.18 (2026-09-26).** The sync and the pass now also
> run inside the scan, from our own second importer, and the server-side path
> described here survives as the fallback for scans our importer did not run.
> §15.18 answers this record's four reasons one by one; its `['rescan','done']`
> trigger and its refusal while another process holds the write lock stand.
> This section records what was decided then and is not rewritten.

**Decided: all three sync triggers run the sync and the ownership pass in the
server process, over asynchronous HTTP. The scan trigger fires on
`['rescan','done']`, debounced, not at scan start.**

#### What was verified

Checked against slimserver `a670a38c2b14ad42b86a39884bcb842121b35571`
(`public/9.1`, 2026-06-19), the same pin as `refs/`:

- `Slim/Networking/SimpleSyncHTTP.pm` `new` logs a backtrace outside the
  scanner: "DO NOT USE SYNCHRONOUS CALLS IN THE SERVER! Use SimpleAsyncHTTP
  instead!"
- `runScanPostProcessing`'s only live caller is `scanner.pl`. Single-directory
  rescans driven inside the server never reach it.
- `['rescan','done']` fires at six sites: `Slim/Utils/SQLiteHelper.pm`
  `_notifyFromScanner` on scanner exit, clean or aborted; three in
  `Slim/Utils/Scanner/Local.pm`, each inside `!main::SCANNER`;
  `Slim/Music/Import.pm` `stillScanning`'s crash cleanup; and
  `Slim/Music/Import.pm` `abortScan`. Five follow `setIsScanning(0)`.
  `abortScan` clears it only when no external scanner is running.
- No plugin-facing scan-start notification was found by grepping for
  `notifyFromArray` with `'rescan'`. Other event mechanisms were not searched.

#### Why not at scan start

The server cannot write while a scan runs (build-order step 3, finding 2b;
`Match::_writeRefusal`). A pass run at scan start would also read
identifications the scan has not yet refreshed. §13.7's reason for adding a scan
trigger — users already rescan when something changes — holds equally for the
end of a scan.

#### Why not in the scanner

- ~~The interval and manual triggers have no scanner process~~ — **corrected
  2026-09-22 (§15.15): the interval no longer exists.** The manual trigger has no
  scanner process, so the server needs its own sync anyway; the argument is
  unchanged and now rests on the button and on `['rescan','done']`, which the
  server also handles. Doing it in the scanner too means two sync
  implementations under a rule (design §3) that the pass be deterministic.
- In-server rescans never reach the importer.
- A Discogs stall would stall the scan: `API.pm` allows three 60-second
  backoffs per request.
- The importer's `use` gate is tied to tag names.

#### Obligations

1. A pass whose write is refused stays pending for the next notification. It is
   never dropped, and debouncing must not suppress the retry. Otherwise an
   aborted scan silently skips a sync.
2. Tag reads in the pass (§13.5) use a Scheduler task, as `Settings.pm`'s
   detection does, not a blocking loop.
3. The rate-limit wait is non-blocking. `API.pm`'s pure functions are reused;
   its `sleep`-based `get` is not.

**Unverified:** that a later `['rescan','done']` always follows an aborted
external scan. Inferred from `_notifyFromScanner`'s `exit` branch in
`Slim/Utils/SQLiteHelper.pm`, not observed. On the hardware list in `TODO.md`.

### 15.3 Existing identifications keep their state; the ownership pass is the only writer of `state`

**Decided 2026-09-15 (design chat).** Settles Q1 of the build-order rewrite.

**Decided: migration 3 copies `state` and `match_tier` forward unchanged, and
sets `ownership = 'absent'` on every copied row. The ownership pass is the sole
writer of `state` after identification: it promotes to `confirmed` where the
tagged release id is in the collection (design §3 node E), and demotes to
`candidate` where it is not.**

#### What was verified

From `SqueezeWax/Schema.pm::_migration_1` and `SqueezeWax/Match.pm`, read, not
observed running:

- `state` is `TEXT NOT NULL DEFAULT 'candidate' CHECK (state IN
  ('candidate','confirmed'))`. Obligation (c) on migration 3 already drops the
  default.
- `_recordMatch` writes `'strict','confirmed'` on any clean tag hit, with no
  collection check — the gap recorded in `TODO.md` 2026-09-15. Existing rows on
  the reference server are therefore `confirmed` regardless of ownership.
  **Inferred**, not observed in the database.
- The orphan-recovery index is commented "confirmed rows whose snapshot might
  fit a new album", and recovery selects `state = 'confirmed'` (§14.8,
  inferred from the predicate).

#### Why the pass rather than the migration

1. **The pass needs demotion logic anyway.** A user who sells a record must see
   that row leave `confirmed` at the next sync. Demoting in the migration adds a
   second mechanism for a job the pass already does.
2. **One writer.** Identification writes `candidate`; the pass alone promotes
   and demotes. Two writers of one column, on different triggers in different
   processes, is the shape that produces states nobody can account for.
3. **Demoting in the migration would empty orphan recovery** until a sync
   completes, since recovery selects `state = 'confirmed'`. A library
   reorganised in that window changes `album_key` and the matches become
   unrecoverable. It is the only irreversible loss available in this choice.
4. **Nothing user-visible turns on `state` in the window.** The badge reads
   `ownership` directly (design §4, §10) — no join, no render-time test — and
   `ownership` is `absent` until the first sync under either option.

#### Why `ownership = 'absent'` for copied rows

`ownership` is NOT NULL and `absent` is an answer rather than a missing one
(§13.3). No sync has run, so strictly the value is unknown rather than absent,
and `absent` overstates it ~~for one sync interval~~ **until the next scan or
press of "Sync collection now" (corrected 2026-09-22, §15.15 — there is no
interval).** The alternative is a fourth
value for "not yet synced", which would have to be handled at every read site
forever to buy accuracy in a window that closes by itself. §14.9 already accepts
this exact shape: badges are dark until the next sync completes.

#### The cost, recorded rather than hidden

~~Steps 4 and 5 of the build order land before the sync exists at step 6.~~ —
**corrected 2026-09-18 by §15.9: the order is identification, sync, migration 3,
ownership pass, so this window spans three steps rather than two.** In that
window `discogs_match` holds old rows saying `confirmed` under the pre-§13.4
rule and new rows saying `candidate` under the current one, and nothing can
reconcile them until step 7 runs. This is accepted because the affected database
is the reference server's, "Clear & rebuild matches" is an escape hatch, and no
badge derives from `state`. **If builds from this branch reach other users
before step 7, this ruling should be revisited** in favour of demoting in the
migration.

#### What this does not settle

- Orphan recovery's reach under §13.4 (`TODO.md`, its own item).
- When the recovery snapshot is captured, now that confirmation and
  identification happen in different processes (`TODO.md`, Q6).

### 15.4 The recovery snapshot is captured at identification, and never on a conflict row

**Decided 2026-09-15 (design chat).** Settles Q6 of the build-order rewrite.

**Decided: the orphan-recovery snapshot is captured when an identification is
written, not when a row is promoted to `confirmed`. A conflict row never carries
a snapshot. The ownership pass neither captures nor refreshes snapshots.**

#### Why this is a ruling and not a change

Design §10 says the snapshot is "captured at confirm time". That was one instant
while `_recordMatch` both identified and confirmed. §15.2 and §15.3 split those
into two processes on two triggers, so the phrase now names two different
moments and the code follows neither by design — it follows identification,
because that is where it always was.

**Verified by reading, not observed running:** `Match.pm::_recordMatch` writes
~~the `snapshot_*` columns~~ — **corrected 2026-09-15: `snapshot_album_title`
and `snapshot_track_count` only. Nothing in the code writes `snapshot_artist`
or `snapshot_total_duration`; see §15.5** — in the same upsert as the
identification.
`_recordConflict` names only `album_key`, `lms_album_id`, `discogs_release_id`,
`match_tier`, `state`, `matched_at` and `source_timestamp` — no snapshot
columns.

So the decision is to keep what the code does, for reasons the code does not
state.

#### Why identification rather than promotion

- The scanner has the album's LMS-side data open already. The pass would have to
  re-read it per promoted album, in the server process, for a value that cannot
  have changed since identification.
- The snapshot is LMS-side (§13.2): local artist, title, track count, total
  duration. Nothing about it depends on ownership, so nothing about it belongs
  to the ownership pass.
- A snapshot written only on promotion would leave every unowned identified
  album without recovery material, compounding the reach problem recorded
  against §13.4.

#### Why a conflict row must never carry one

`Match.pm::_recordNoMatch` holds the one permitted deletion in
`discogs_match`, predicated on `match_tier = 'strict' AND state = 'candidate'
AND discogs_release_id IS NULL AND snapshot_track_count IS NULL` (§2a invariant
2). It exists to clear a phantom conflict row whose tags have since been
removed. **A snapshot on a conflict row would make that deletion unreachable**,
and the row would advertise a conflict forever in a queue that cannot render it
(§3a stores no conflict note). This is now a rule rather than a property of the
current code.

**Obligation on the build order:** assert in the offline suite that a conflict
row's `snapshot_*` columns are NULL, and that the narrow delete still fires on a
conflict row whose tags were removed. Neither assertion exists today.

#### One consequence, feeding the recovery-reach question

Because snapshots ride identification rather than confirmation, `candidate` rows
do carry recovery material. A recovery predicate keyed on `state = 'confirmed'`
therefore skips rows that have everything it needs. That strengthens the case
recorded in `TODO.md` for keying recovery on the presence of an identification
instead, and it is not decided here.

**Design §10's "captured at confirm time" is a wording defect**, recorded in
`TODO.md`'s design-fix item.

### 15.5 Orphan recovery: what it is for, what it compares, and which rows it sees

**Decided 2026-09-15 (design chat).** Settles Q5, Q7 and the snapshot-column
question of the build-order rewrite, and writes down the fit predicate §2 left
as a phrase.

**Decided, in four parts:**

1. **Columns.** `snapshot_artist`, `snapshot_album_title` and
   `snapshot_track_count` are written and kept. `snapshot_total_duration` is
   dropped in migration 3.
2. **The fit predicate.** Exact equality on artist, album title and track
   count, with no normalisation. One fit relinks. Zero fits falls through to
   identification. Two or more goes to the review queue, pre-filled (§2).
   **Superseded 2026-10-18 by §15.46 (settled), part 8.** (the queue branch: an ambiguous orphan stays
   orphaned.)
3. **Reach.** Recovery considers any orphaned row that has an identification
   and a snapshot — `match_tier IS NOT NULL AND snapshot_track_count IS NOT
   NULL` — not rows selected on `state`.
4. **Ownership.** Recovery belongs to the identification step: it runs in the
   scanner, on a key miss, before the tag read. The unambiguous relink is built
   there; the ambiguous branch is an obligation on the review-queue step.

#### Why: recovery exists for manual rows

**Superseded 2026-10-18 by §15.46 (settled), part 8.**

Design §3 states v1's premise: a well-tagged library and a maintained Discogs
collection. Under that premise, **a well-tagged album does not need recovery at
all.** Files move, `album_key` changes, no row matches, identification runs
again, reads the same tag, produces the same release id; ownership re-derives at
the next sync (§13.4). The match rebuilds itself, and recovery is at most an
optimisation that saves re-reading two files.

**A manual row is the case that genuinely loses work.** The user chose that
release precisely because the tags were absent, wrong or contradictory, so
re-identification produces nothing and the choice is gone. A conflict-demoted
row is the same shape: it keeps its adjudicated `discogs_release_id` and its
snapshots (§3a) while dropping to `candidate`, and current tags cannot reproduce
it.

That reordering is what settles the other three parts.

#### Why these three columns

- **`snapshot_artist` is needed and is never written.** Nothing in the code
  writes it: one grep hit, the DDL in `Schema.pm::_migration_1` (verified
  2026-09-15 by Claude Code). Recovery as designed therefore cannot work today.
  This is a defect, not a column question, and it is recorded in `TODO.md`
  against the identification step.
- **`snapshot_album_title` and `snapshot_track_count`** are written by
  `Match.pm::_recordMatch` and are the pair that identifies a local album
  cheaply; the orphan index is built on the count.
- **`snapshot_total_duration` loses its only stated justification.** §2 admits
  it under "the same confidence bar Structural already auto-confirms on", and
  that bar was track count plus per-track durations. Structural is gone
  (§13.4, §13.8).

  The design chat first defended it as a tiebreak between two local copies of
  the same album — an original and a remaster with the same artist, title and
  track count. **That argument was wrong and is recorded so it is not
  re-proposed:** under v1's well-tagged premise those are different releases
  carrying different tags, so identification separates them without recovery;
  and where they are *not* tagged that way, the library is the badly-tagged one
  v1 does not serve (§14.4). Nothing that remains in v1 reads the column.

  Migration 3 is a full table rebuild already (§14.1), so dropping it now is
  free. Dropping it later costs another rebuild of the one table that is not
  disposable.

#### Why exact equality, and no normalisation

Both sides of this comparison are LMS strings: the snapshot was taken from an
LMS album, and the candidate is an LMS album. L2 normalisation exists for
comparing Discogs' text against LMS's (§13.10.4) and has no work to do here.
Exact equality also keeps the predicate deterministic and cheap, which matters
because it runs on every key miss during a scan.

**Failing safe:** ambiguity goes to the queue, never to a guess. Zero fits costs
nothing beyond the re-identification that would have happened anyway.

#### Why reach is keyed on identification, not on `state`

Selecting on `state = 'confirmed'` would skip conflict-demoted rows, which are
exactly the rows whose tags can no longer reproduce their identification.
Including `strict` `candidate` rows is harmless: a relink is cheaper than
re-reading files and produces the same release id, and where it would not,
identification overwrites it in the same scan.

**This changes the orphan index** from `(state, snapshot_track_count)` to a form
matching the new predicate. Migration 3 can do that for nothing.

#### Why the identification step owns it

Recovery runs on a key miss, in the scanner, before tags are read — §2's own
placement. It has nothing to do with ownership or with the sync, so it does not
belong to the pass (§15.2). The ambiguous branch needs a review queue that does
not exist until the queue step, so until then an ambiguous orphan stays
orphaned: no loss, no automatic relink.

#### What this does not settle, and one hole worth naming

- **A retagged album title defeats recovery.** If the user changes the album
  title, no snapshot fits, and a manual row's work is lost even though recovery
  ran. Tagged albums self-heal through identification; manual ones do not.
  Recorded in `TODO.md` rather than solved: the alternatives (two-of-three
  matching, or normalising the comparison) both trade a fail-safe predicate for
  a guess.
- **The premise is stated, not measured.** "Well-tagged library, maintained
  collection" is design §3's assumption about this user's library, not a
  measurement of it. If it proves optimistic, what degrades is recovery's
  coverage of tagged albums, and §14.4's answer applies: fix the tags.

### 15.6 `discogs_no_match.tier` narrows to `strict`, by DROP and recreate

**Decided 2026-09-15 (design chat).** Settles Q2 of the build-order rewrite.

**Decided: the CHECK narrows to `CHECK (tier IN ('strict'))`. The `tier` column
and the PK `(album_key, tier)` both stay. The change is made by dropping and
recreating the table inside migration 3, not by copying it.**

#### What was verified

- `Schema.pm::_migration_2`: `tier TEXT NOT NULL CHECK (tier IN
  ('strict','structural'))`, `PRIMARY KEY (album_key, tier)`.
- `scripts/schema-check.pl` asserts that `'structural'` is **accepted** ("the
  same album_key takes a second row under a different tier") and that `'fuzzy'`
  and `'Strict'` are rejected.

Read, not observed running.

#### Why narrow

§14.1 made this argument for `match_tier` and it transfers unchanged: a schema
permitting values nothing writes is a trap for the next reader, and a stray
value degrades to a silently misclassified row rather than an error. Structural
no longer exists (§13.8), so `'structural'` is now exactly such a value.

#### Why DROP and recreate rather than copy

§2a records the table as entirely regenerable (invariant 3) and says widening
the CHECK costs "DROP + recreate on a regenerable table, the cheapest migration
there is". Narrowing is the same operation.

It also avoids migration 3 obligation (a)'s problem in miniature. A copy-based
narrow would fail mid-copy on any surviving `'structural'` row; a DROP discards
those rows, which is correct, because they are cache and nothing else. The cost
is one rescan's worth of re-reads for albums with no Discogs tag — the cost §2a
introduced the table to avoid, paid once.

`DROP TABLE IF EXISTS` followed by the CREATE keeps the migration idempotent, as
`Schema.pm`'s migration contract requires: a migration that dies partway leaves
`user_version` at the last completed step and re-runs from there.

#### Why the column and the composite PK stay

`tier` becomes near-constant in v1. It stays because §2a's invariant 1 is
phrased per tier, `Match.pm`'s skip logic reads it, and v2's fuzzy negatives
would want it back. Collapsing to `PK (album_key)` would churn the skip path for
no v1 benefit, and restoring it later costs this same DROP and recreate.

#### What must never be added here

**No `'collection'` tier, or any other negative row for the ownership pass.**
Ownership is recomputed only from a completed sync (§13.7) and is derived rather
than stored. A cached per-album "not owned" is precisely the local owned flag
design §5 rejects, and it would go stale silently the moment the user's
collection changed. The ownership pass costs no per-album request (§13.1), so
there is nothing for such a cache to save.

Recorded because the table's shape invites it: a second tier looks cheap, and
the reason this one is safe — a file read avoided, a fact that cannot go stale
while `source_timestamp` is unchanged — does not hold for ownership.

#### Where the evidence is thin

That nothing currently writes `'structural'` to this table is **inferred** from
step 4 having stopped after item 3, the same inference migration 3 obligation
(a) refuses to rely on. The obligation below requires the grep.

#### Scope

v2's fuzzy negatives are noted and not designed: widening the CHECK then is this
same DROP and recreate.

### 15.7 `Various` and the LMS various-artists label are the same artist

**Decided 2026-09-15 (design chat).** Settles Q4 of the build-order rewrite, and
the `Various` / `Various Artists` item carried forward unresolved in §13.10.6.

**Decided: the ownership pass treats Discogs' various-artists name and LMS's
various-artists label as agreeing. The Discogs side is `Various` or `Various
Artists`, case-folded, after the ` (N)` disambiguator strip. The LMS side is
whatever `Slim::Music::Info::variousArtistString()` returns, case-folded — never
a hardcoded English string.**

#### Why this is a vocabulary mapping and not a number

§13.10.6 sets the test: an equivalence added later "is a **vocabulary mapping
between two catalogues**, the same class as stripping Discogs' trailing ` (N)`
disambiguator, and must be justified on that ground rather than on improving a
number."

It passes that test, and it visibly does not improve a number. ~~**Measured on
page 1: zero impact**, because no compilation matched there (§13.10.6).~~

**Corrected 2026-09-22.** Six compilations *did* match on page 1 — albums 3345,
3347, 3351, 3355, 3356 and 3358. Every one carries the literal `Various` on the
LMS side, which agrees with Discogs' `Various` by plain equality and needs no
mapping. So the measured zero is real, but it is the number of times **the
equivalence fired**, not the number of compilations that matched. The ruling is
unaffected: an equivalence that never fires neither improves nor worsens a
number. The two
catalogues simply name the same entity differently — Discogs calls it `Various`,
LMS calls it by its own configurable label — and neither name is evidence about
which record the user owns.

The exposure it removes is on pages 2 and 3: **7 of 100 page-1 collection
entries are `Various`, against 95 LMS albums with `compilation = 1`**. Without
the equivalence, a matched compilation queues for a purely lexical reason.

#### The LMS side is not a literal string

**Verified in slimserver `a670a38c2b14ad42b86a39884bcb842121b35571`
(`public/9.1`, 2026-06-19):** `Slim::Music::Info::variousArtistString` returns
the `variousArtistsString` server pref, which defaults to `undef`, falling back
to the localized string `VARIOUSARTISTS`. The pref is user-editable
(`Slim/Web/Settings/Server/Behavior.pm`), and core itself compares through this
accessor (`Slim/Schema.pm`, `Slim/Schema/Album.pm`,
`Slim/Schema/Contributor.pm`).

**So `'Various Artists'` must never appear as a literal in the comparison.** A
hardcoded English string fails silently on a translated or customised install —
the album queues, no error, nothing in the log. This is the whole reason the
ruling names an accessor rather than a value.

The measurement script's own use of a literal was correct in its context: a
standalone script cannot call LMS accessors (§11.4), and it reported its
divergence set rather than hiding it — 5 of 765 albums, 2 actually diverging.

#### `albums.compilation = 1` is deliberately NOT sufficient

Treating the flag alone as agreement would let an LMS album with a specific
album artist agree with a Discogs `Various` entry on title alone. Combined with
§13.10.6's generic-title hazard — "Greatest Hits" and its kind — that is a route
to a wrong badge, which §14.4 says has no recovery path in v1.

The flag is not needed anyway: `Slim::Schema::Album::artists` already falls
through to the various-artists object for a compilation with no ALBUMARTIST when
`variousArtistAutoIdentification` is on (measured on: `server.prefs:642`), so the
pass sees the label without consulting the flag.

#### What carries the weight instead, and the risk this raises

§11's finding is that an LMS compilation's album artist is a **placeholder
rather than a name**. So for compilations, artist agreement carries almost no
evidence either way once this equivalence is in place: nearly every compilation
on both sides reads "various". What actually bounds a compilation badge is
§13.10.3's requirement of exactly one collection entry agreeing on title.

**That is a real increase in exposure to §13.10.6's generic-title hazard**, and
it is accepted here rather than hidden: two different compilations sharing a
normalised title now differ only in a field that says "various" on both sides.
The bound is unchanged — several candidates still queue — but the *class* of
album that reaches the single-candidate path has grown.

**Revisit trigger:** the pages 2–3 measurement. Any wrong badge on a compilation
reopens this record together with §14.4.

#### The gate: compilation auto-badging waits for the pages 2–3 measurement

**This equivalence lands now; auto-badging a compilation on it does not ship
until the pages 2–3 measurement reports.** The identification and ownership work
proceeds; the ownership pass must not auto-badge an album ~~with
`albums.compilation = 1` on a title-plus-various match~~ **whose artist agreement
is reached only through this equivalence — corrected 2026-09-19 by §15.11, since
§11.3(c) measured the flag as wrong for 11 Various-ish albums** until that measurement
answers four questions, listed against it in `TODO.md`: how many compilations
match at all, whether any normalised compilation title collides, whether
`albums.year` agrees with Discogs' `year` on the matches, and whether
`albums.label` or a LABEL tag is reachable without a per-album file read.

Until then a matched compilation queues, which is the behaviour before this
record — so the gate costs nothing that was not already being paid.

**Why a gate rather than confidence.** §13.10.4 fixed this project's posture:
"trading one missing badge for one wrong badge is a bad trade at 1:1 … and would
remain bad at 10:1." A queued compilation is not a lost badge — the user
confirms it and it badges. So this equivalence buys convenience and pays in
wrong-badge exposure on the one class §14.4 gives no recovery path. Both sides of
that trade are unmeasured: ~~page 1 showed **zero** compilations matching, so even
the queue-flood it was meant to prevent is a projection.~~

**Corrected 2026-09-22.** Page 1 showed **six** compilations matching, not zero;
what was zero is the number of times the equivalence fired, because all six carry
the literal `Various` on the LMS side. The queue-flood the equivalence was meant
to prevent remains a projection, for the different reason that no page-1
compilation needed the mapping at all.

#### What is not designed here

Adding a **confirmation test** — label, catalogue number or year checked against
the single remaining candidate — would catch the wrong-compilation case this
record exposes. It is not designed here, and it is not a build-order matter: it
adds a field to the badging rule and therefore amends §13.10.3.

Two findings bound it, both verified against slimserver
`a670a38c2b14ad42b86a39884bcb842121b35571`:

- **`albums.label` exists and is dead.** `SQL/SQLite/schema_23_up.sql` adds it;
  a repo-wide grep finds nothing in 9.1 that writes or reads it, no LABEL or
  ORGANIZATION tag mapping, and `Slim/Schema/Album.pm` does not declare the
  column, so DBIC cannot reach it. Comparing label therefore means a per-album
  file read — the cost §13.1 removed and §15.2 keeps out of the server.
- **`albums.year` and Discogs' `year` are different facts.** The LMS value comes
  from the file's YEAR tag, commonly the original release year; Discogs' is that
  pressing's year. Requiring agreement would queue matches for a reason as
  incidental as the vocabulary difference this record removes.

Recorded as a question in `TODO.md`, to be decided from the measurement rather
than from either of these guesses.

#### Scope

No general synonym table, and no user-editable mapping. This is one fixed
equivalence between two catalogues' names for one entity. A second such mapping
needs its own record and its own justification on §13.10.6's ground.

### 15.8 The `discogsMaxTier` pref is removed; design already required it

**Decided 2026-09-18 (design chat).** Settles Q8 of the build-order rewrite.

**Decided: `discogsMaxTier` is removed — the pref, its entry in `sub prefs`, and
the selector in the settings template — by a `$prefs->migrate` step in the
identification rework. The importer's `use` gate is left exactly as it is.**

#### This is compliance, not a choice

Design §9, live spec since the reconciliation, reads: *"Matching itself is not
configurable. Which tag names are read is a setting (§3), but the comparison is
not."* The reconciliation deleted the maximum-tier bullet along with the
duration margin and the multi-disc auto-confirmation bullet.

`Settings.pm` still initialises `discogsMaxTier` and lists it in `sub prefs`,
and `HTML/EN/plugins/SqueezeWax/settings.html` still offers a `structural`
option. **The code contradicts the live spec**, and `docs/working-agreement.md`
§2 makes design win. Removing the pref brings code into line; keeping it would
need a change to design.

The question was framed in `TODO.md` as a choice with a cost on the removal
side. That framing was wrong, and is recorded here rather than quietly
abandoned: the cost is real but small (below), and it is the price of compliance
rather than of a preference.

#### The failure mode in user terms, which is the stronger argument

With the pref left in place, a v1 user opens Settings, selects Structural, saves,
and **nothing happens** — no matching changes, no error, no log line. They have
configured a tier that does not exist. The likely next step is a bug report
about a plugin that ignores its own settings.

§14.1 refused to leave a schema permitting values nothing writes, on the ground
that it is "a trap for the next reader". A settings control that can only be set
wrong is the same trap, pointed at the user instead of the maintainer.

#### The mechanism, verified

Read at slimserver `a670a38c2b14ad42b86a39884bcb842121b35571` (`public/9.1`,
2026-06-19), the same pin as `refs/`. Not observed running.

- **`Slim::Utils::Prefs::Base::remove( list )`** deletes each named key and its
  `_ts_`-prefixed timestamp twin, then saves the namespace.
- **`Slim::Utils::Prefs::Namespace::migrate( $version, $callback )`** runs the
  callback when the namespace's `_version` is below `$version`, and sets
  `_version` to `$version` if the callback returns true. This is the in-tree
  house pattern, not an improvisation: `$prefs->migrate(1, sub {…})` appears in
  Podcast, DateTime, CLI, iTunes, xPL, PreventStandby, FullTextSearch, Rescan,
  AudioScrobbler and RandomPlay.
- **The edge case that would otherwise have surfaced on hardware.**
  `Namespace::new` sets `_version => 0` **only when the prefs file does not
  exist**. On the reference server `squeezewax.prefs` does exist and was written
  before this plugin ever called `migrate`, so the key is *absent* rather than
  zero. `$version > undef` evaluates true, which is the behaviour wanted, and
  `Slim/Utils/Prefs/Namespace.pm` carries `use strict` **without** `use
  warnings`, so it is silent. The migration therefore runs correctly on a fresh
  install and on the reference server alike.

#### The `use` gate does not change, and that is a finding

The importer's `use` gate is `scalar @{discogsTagNames}`. Identification is
tag-driven and nothing else runs in the importer, so gating on tag names is
exactly right and needs no revision. (True of the identification importer class
only since §15.18: the scan-time sync is a second importer class with its own
gate on the token, and §15.18 part 9 reaffirms this gate unchanged.)

`plans/build-order-step-4-structural-matching.md` §0.7 prescribed
`@discogsTagNames || ($maxTier ne 'strict' && $token)`, and `TODO.md` carried an
item saying the current gate "becomes wrong the moment step 4 lands". Both exist
to let a user with no tag names run Structural. There is no Structural, so the
gate is correct as written. That `TODO.md` item is closed as superseded by this
record, and the work it described is removed from the identification step's
scope.

#### What goes with it

- `HTML/EN/plugins/SqueezeWax/settings.html`: the selector and its options.
- `Settings.pm`: the `$prefs->init` entry and the `discogsMaxTier` element of
  `sub prefs`, which becomes `discogsToken` alone.
- §10.2's list of preferences that survive "clear & rebuild matches" names a
  "tier selector"; corrected in place.
- §3b's note that "a pref-derived tier needs its own invalidation clause" had
  been provisionally pointed at `discogsMaxTier` when the two obsolete
  Structural items were closed. The pref does not survive, so that note has no
  v1 subject at all.

#### Scope

If a tier concept ever returns in v2, the pref name is free to reuse. A user's
prefs file will simply not carry it, which is the normal state for a new pref
and needs no further handling.

### 15.9 Migration 3 runs immediately before the ownership pass, and ships with it

**Decided 2026-09-18 (design chat).** Fixes the position of migration 3 in the
build-order sequence, which §15.3 and the `TODO.md` sequence item had put
earlier.

**Decided: the order from step 4 is — identification rework, collection sync,
migration 3, ownership pass. Migration 3 and the ownership pass ship together:
the migration is reviewable as its own step but is not merged ahead of the code
that exercises it.**

#### What this replaces

The sequence recorded in `TODO.md` ran identification, then migration 3, then
the sync, then the pass. That put the one irreversible operation in this build
three steps ahead of anything that reads its result.

#### Why this is the lower-risk order

Migration 3 is a 12-step rebuild of `discogs_match`, the one table this project
treats as expensive to change (§14.1). **Three of its eight obligations rest on
claims the record itself marks as unverified:**

- (b) — that a NULL `match_tier` passes `CHECK(match_tier IN
  ('strict','manual'))` is "expected, NOT verified".
- (d) and (g) — the orphan-index predicate is "INFERRED from the predicate, not
  verified against a query plan".
- (e) — the row-count and state-preservation assertions run once, at rebuild
  time, with nothing downstream reading the result.

Run early, a wrong obligation sits latent on the reference server's real rows
across three steps before anything touches it. Run immediately before the
ownership pass, it is exercised within the same step by code that writes
`ownership`, reads the rebuilt index, and depends on both the nullable
`match_tier` and the dropped `state` default. **The failure surfaces where
someone is looking.**

**It also follows a rule already recorded rather than overriding one.**
`TODO.md`, 2026-09-07: the ownership column "lands in migration 3, in the step
that reads it — NOT step 4 (step 2 finding 8: don't add a column nothing reads
yet)." The earlier sequence set that aside; this one obeys it.

**And it keeps the rebuild to one.** Q9 is open and may add a column to
`discogs_match`; it is gated on the pages 2–3 measurement, which must report
before compilation auto-badging ships in the ownership pass. Deferring migration
3 past that point means it is designed knowing Q9's answer.

#### What step 4 does not need from migration 3

Checked item by item against the schema as `Schema.pm::_migration_1` and
`_migration_2` leave it. Read, not observed running:

- Writing `state = 'candidate'` instead of `'confirmed'` — the existing CHECK
  admits it.
- Writing `snapshot_artist` — the column already exists.
- The relink predicate `match_tier IS NOT NULL AND snapshot_track_count IS NOT
  NULL` — under the current schema `match_tier` is `NOT NULL`, so the first
  clause is trivially true and the predicate reduces to "has a snapshot". The
  rows it would additionally admit under the new schema, collection-derived rows
  with a NULL `match_tier`, do not exist until the ownership pass. **Identical
  behaviour, not merely compatible.**
- Removing `discogsMaxTier` (§15.8), ~~removing the `local_tracks == 0` gate
  (§13.10.1),~~ redefining `hasAnyStrictMatch`, and the detection bare-master
  fix — none touches the schema. **Corrected 2026-09-19: the gate is not
  removed; see §15.11.**

**The one cost:** the relink runs against the old `(state, snapshot_track_count)`
index until migration 3 rebuilds it. That path fires only on an `album_key`
miss, against a 765-album reference library. A performance matter, not a
correctness one, and it is the whole price of this ordering.

#### Rejected, and why

- **Migration 3 early, before the identification rework.** Lets step 4 be
  written once against the final schema and gives the relink its final index
  immediately. Rejected: it buys convenience with the latency described above,
  and it overrides the 2026-09-07 principle rather than following it.
- **Splitting into two migrations** — the Structural cleanup early, the
  ownership column late. Conceptually the cleanest fit, and it costs a second
  full rebuild of `discogs_match`. §14.1 chose a single rebuild deliberately;
  this would spend exactly what that decision saved.

#### One consequence, stated rather than left to be found

§15.3 accepted a window in which `discogs_match` holds old `confirmed` rows
beside new `candidate` ones, and warned: "If builds from this branch reach other
users before step 7, this ruling should be revisited." **This ordering lengthens
that window** from two steps to three. The caveat is unchanged in substance and
now applies for longer. §15.3's sentence naming the steps is corrected in place.

#### A defect found while settling this

Migration 3's obligations (d) and (g) contradict each other. (d) says to
**confirm the orphan index needs no change**; (g) says to **rebuild it** to
§15.5's predicate. (d) was written under §14.8, when recovery still keyed on
`state = 'confirmed'`; §15.5 moved the predicate off `state` and (g) followed,
but nobody went back for (d). An implementer working top to bottom would confirm
the index at (d) and rebuild it at (g).

(g) is correct. (d) is corrected in place rather than deleted — the same shape
as the §13.8 defect corrected in `9f27ac9`, and worth recording as a second
instance: **a superseding obligation added at the end of a list does not by
itself retire the one it supersedes.**

### 15.10 Migration 3 drops `discogs_collection`

**Decided 2026-09-18 (design chat).** Promotes a "should" recorded in `TODO.md`
on 2026-09-13 to a ruling, and puts it where migration 3's implementer will
find it.

**Decided: migration 3 drops the `discogs_collection` table and its index. The
drop is an obligation on the migration, not a neighbouring note. It is
conditional on confirming that nothing in `SqueezeWax/` reads or writes the
table, and it carries the offline-suite edit with it.**

#### Why this is a ruling rather than a restatement

§13.2 forbids a collection mirror in v1, reaffirming `TODO.md`'s 2026-09-07
position. `TODO.md` then recorded on 2026-09-13 that "migration 3 should drop
it — but CONFIRM ZERO READERS AND WRITERS FIRST", **as its own item, not as an
obligation on the migration**. Migration 3's obligation list runs (a) to (h) and
does not mention the table.

`CLAUDE.md` now states the drop as fact. Two documents, one of them loaded at
the start of every session, describing a step the migration's own checklist does
not contain — the defect shape §15.9 recorded for obligations (d) and (g), one
document further out.

#### Why a plain DROP, and not the treatment `discogs_match` gets

`discogs_collection` caches Discogs' own data and holds nothing the user
entered; design §10 and `Schema.pm`'s own comment both call it entirely
regenerable. There is nothing to copy forward and nothing to preserve. This is
the opposite of `discogs_match`, where §14.1's 12-step rebuild exists precisely
because the table carries decisions.

The index `discogs_collection_release` goes with it. Its comment names "the
badge-derivation join in design §4" — a join §13.3 replaced with a column read,
so it has had no purpose since that record.

#### The confirmation is not optional, and it is already partly answered

`TODO.md`'s 2026-09-13 item requires confirming zero readers and writers before
a destructive migration, because "collection sync was never built so there are
almost certainly none" is an inference. That requirement stands.

**One writer is already known: `scripts/schema-check.pl` inserts into the table**
(verified 2026-09-18 by Claude Code, two insert sites) — **note 2026-09-19: a
2026-09-18 edit struck "two insert sites" as wrong and replaced it with "three
sites". That correction was itself wrong. This sentence counts writers, and there
are two: the inserts. The suite's third reference, the "expected tables exist"
loop, writes nothing — it asserts presence — and belongs in obligation (i)'s
update list, where it now is, not in a count of writers.** It is a test rather than
plugin code, so it does not block the drop — but it does mean the suite fails
the moment the table is gone unless the same edit removes those assertions.
Recorded so the confirmation step is not reported as "zero found" when the
answer is "zero in `SqueezeWax/`, two in the suite".

#### Scope

Wantlist (v2) will need collection-entry storage of some kind, and `TODO.md`
carries a struck v2 item about rekeying this table. Dropping it now does not
prejudge that: a v2 table would be designed against v2's requirements rather
than inheriting an `instance_id` primary key that cannot hold wants.

### 15.11 The importer keeps its `local_tracks` gate; §13.10.1 lands on the ownership pass

**Decided 2026-09-19 (design chat).** Corrects where §13.10.1 applies, not what
it decided. Also corrects the gate in §15.7.

**Decided, in two parts:**

1. **The `local_tracks` gate in `Importer.pm` stays.** §13.10.1's decision —
   all albums, all-remote ones included, are in scope — is unchanged and is
   carried by the **ownership pass** (build-order step 7), which must iterate
   every album. It is not carried by the identification importer, which since
   §15.2 does identification only; since §15.18 the pass also runs in the
   scanner, from the second importer, and still covers every album there.
2. **§15.7's gate keys on the equivalence having fired, not on
   `albums.compilation`.** An album whose artist agreement is reached only
   through the `Various` mapping does not auto-badge until the pages 2–3
   measurement reports, whatever its compilation flag says.

#### Part 1 — two gates were merged into one

Decisions §8 stated a gate for Structural: "The only gate that holds is
`local_tracks == 0` — no local files means no evidence about a physical object.
It is Structural's own rule, not inherited from Strict." `Importer.pm` has
carried a *different* gate since `cec7a46` (2026-09-04), with a different
reason, in its own comment: **"Nothing to read tags from."**

§13.10.1 treated these as one: "The gate exists in `Importer.pm` and is stated in
§8. Its reason was Structural's duration fingerprint." Its reasoning is right
about §8's gate and wrong about the importer's. Structural's reason went with
Structural; the importer's reason is a property of Strict and still holds.

**Verified by reading, at `285e312`, not observed running:**

- `Library::_finish` builds `candidates` from local tracks only, and takes
  `source_timestamp` as the maximum over local tracks only.
- So with the gate removed, an all-remote album reaches `_examine` with no
  candidates, gets `{}` back, and is recorded by `_recordNoMatch` as a
  `discogs_no_match` row with a NULL `source_timestamp`.
- `Importer::_canSkip` never skips a NULL, so that row is rewritten on every
  scan — 186 albums on the reference library, every scan, reading nothing,
  recording a "no tag found" for an album that has no files to carry one.

**Where §13.10.1's measured gain actually comes from.** "Removing the gate
matched 10 additional owned records" was measured by
`scripts/title-agreement.pl` — title-and-artist matching against the
collection, which is **ownership**. §15.2 moved ownership out of the importer
into a server-side pass, and that pass walks `Library::eachAlbum`, which already
does not filter remote tracks. Its own comment anticipated this split: "remote is
selected, not filtered on … The Strict caller decides, not the iterator."

So the obligation moves to step 7, where it does what §13.10.1 measured, and the
importer keeps a gate that is correct for what the importer now does.

**This was caught by reading the code, after the wrong instruction had already
been written into `CLAUDE.md`, `TODO.md` and §15.9 by this same session.** It is
the pattern the session's calibration note names: a step treated as
transcription — carrying §13.10.1's instruction forward — rather than checked
against the artifact it instructs about.

#### Part 2 — the compilation flag cannot carry the gate

§11.3(c) measured `albums.compilation` as wrong in both directions: **11 albums
carry a Various-ish album artist with `compilation = 0`**, and 4 are
`compilation = 1` with a real artist. The cause is in source —
`Slim::Schema::mergeSingleVAAlbum` groups role-1 rows, and Picard-tagged albums
lose theirs — so `compilation = 0` on such an album means "not detected", not
"not a compilation".

§15.7 already says the flag is "deliberately not sufficient on its own" for
artist agreement, then used the flag to define the gate. Keyed on the flag, the
gate would let those 11 albums auto-badge through the `Various` equivalence
ungated — the exposure the gate exists to hold back.

**The gate keys on the mechanism, not on a proxy for it:** an album whose artist
agreement depends on the `Various` mapping is gated; one whose artists agree by
ordinary case-folded equality is not. On the reference library the second group
includes the 23 albums whose LMS album artist is literally `Various` (§11.3(a),
contributor 10001), which agree with Discogs' `Various` without the mapping.

#### What changes

- `CLAUDE.md` step 4 no longer says to drop the gate; step 7 carries the
  all-albums obligation. Same in `TODO.md`'s sequence.
- `TODO.md`'s 2026-09-12 gate item is closed as corrected, not as done.
- §13.10.1, §15.7 and §15.9 are corrected in place.
- The pages 2–3 measurement's question (i) is widened to count albums matched
  through the equivalence, not only `compilation = 1` albums.

### 15.12 Four step-4 rulings: artist backfill, one-to-one relink, where the pref migration runs, master keys

**Decided 2026-09-19 (design chat), ruled on the draft of
`plans/build-order-step-4-identification-rework.md`,** which carries the detail
(§2.5 to §2.8). Each was put as a choice between options; the chosen option and
the reason the others lost are recorded here.

#### 1. Existing snapshots are backfilled with the artist

During the identification pre-pass, a row that has a snapshot
(`snapshot_track_count` non-NULL) and a NULL `snapshot_artist`, and whose album
is current, gets `snapshot_artist` filled from that album's
`albums.contributor` name. That column only, no file reads, through `_writeOk`,
and idempotent because it fills only NULLs.

**Why it is needed at all.** Nothing wrote `snapshot_artist` before step 4, so
every existing snapshot has NULL there, and §15.5's fit is exact equality — NULL
fits nothing. The skip contract means an unchanged album is never re-examined,
so the normal write path would never fill them in either. Without a backfill,
recovery would cover nothing that exists on the reference server today.

Rejected: **no backfill** — the largest silent gap, and it hides itself, since a
failed relink looks exactly like an album with no match. **Relaxing the fit to
title and track count when the artist is NULL** — recovers old rows without
writing to them, but weakens the predicate for exactly those rows and adds a
second predicate to test and reason about.

#### 2. A relink needs a unique fit in both directions

An orphaned row and a key-miss album are paired only when **the orphan fits
exactly one miss and that miss fits exactly one orphan**, decided on the whole
library in a pre-pass before the main loop. Every other orphan and miss is left
untouched and counted as unresolved.

Rejected: **uniqueness on the orphan side only** — one new album could claim two
orphans, and the outcome would depend on scan order. **Deferring the relink to
step 8** — lowest risk now, but recovery would do nothing at all until the review
queue ships. The ambiguous branch remains a step-8 obligation (§15.5 part 4).

#### 3. The `discogsMaxTier` migration runs from `Plugin.pm`, at file scope

`Plugin.pm` loads `Settings.pm` only under `main::WEBUI`, so a migration placed
there would never run on a headless server. File scope in `Plugin.pm` is the
core plugins' pattern (`Slim/Plugin/Podcast/Plugin.pm:40` at `a670a38`), and the
scanner never loads `Plugin.pm`, so one process writes the prefs file.

Rejected: **`Settings.pm`** — the dead key would survive forever on headless
servers. **No migration** — harmless, since nothing reads the key, but it leaves
exactly the kind of orphan §15.8 set out to remove.

#### 4. Detection excludes master-id keys entirely

A key naming a master — case-insensitively in `Tags.pm`'s `@MASTER_KEYS`, or
matching `/MASTER/i` — is not offered by detection at all, as a master URL
already is not. A master id is known not to be a release id, so the demoted list
("other numeric tags that might be one") is the wrong place for it.

Rejected: **demoting** them — inconsistent with the master-URL behaviour.
**Offering them with a warning** — most UI work, and still lets a user tick the
wrong key.

#### The artist source, and a finding against §11.4

The snapshot artist is `contributors.name` for `albums.contributor`, read by raw
SQL in the iterator, and stored and compared **as bytes on both sides**: no
`sqlite_unicode` or `sqlite_string_mode` is set anywhere in slimserver's
`Slim/`, and LMS decodes contributor names by hand
(`Slim/Schema/Album.pm:239`). Decoding one side only would make every
non-ASCII artist silently fail to fit.

Reading `Album::artists` at `a670a38` to confirm §11.4 found its rationale
false; §11.4 carries the correction in place. The snapshot is unaffected — it
compares LMS with LMS — but the ownership pass compares LMS with Discogs, and
must choose its artist source knowingly. That is `TODO.md` Q10.

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

### 15.14 The compilation gate holds every Various-to-Various match, however it is spelled

**Decided 2026-09-20 (design chat).** Amends §15.11 part 2 and §15.13 part 8.
Found by Claude Code while building step 7 (`TODO.md`, the Q9 seam note).

**Decided: until the pages 2–3 measurement reports, the ownership pass does not
auto-badge any match where the Discogs artist is a various-artists name AND the
LMS artist is a various-artists name, whether the two agree by plain equality
or only through §15.7's equivalence.**

- **Discogs side:** `various` or `various artists`, after the ` (N)` strip and
  L2. Unchanged from §15.7.
- **LMS side:** the configured label
  (`Slim::Music::Info::variousArtistString()`) after L2, **or** the literals
  `various` / `various artists`.

#### Why

§15.11 part 2 keyed the gate on "the equivalence having fired", and exempted
the 23 albums whose LMS album artist is literally `Various` because they agree
with Discogs' `Various` without the mapping. That was a correct argument
against using `albums.compilation` as the key, and the wrong conclusion about
the gate. The gate exists because, for a compilation, artist agreement carries
almost no evidence (§11, §15.7). That holds whether the two sides say
`Various` / `Various`, `Various Artists` / `Various Artists`, or need the
mapping. Keyed on the mechanism, the outcome turned on which of Discogs' two
spellings a release carried. ~~Measured page 1 has no matched compilation, so
nothing about this is measured either way.~~

**Corrected 2026-09-22.** Page 1 has six Various-to-Various matches — albums 3345,
3347, 3351, 3355, 3356 and 3358, LMS album artist literally `Various`, Discogs
`Various` — and under the title route the gate holds all six
(`scripts/title-agreement.pl --step7`, `990ce2a`). On the first real run the gate
held **zero**: all six are tagged and are decided at design §3 node D or F, so they
never reach node H. The script measures the title route over every album; the pass
reaches the title route only for albums no tag resolved. The ruling stands. Its
measured cost on this well-tagged library is zero.

#### Why literals are acceptable on the LMS side here

§15.7 forbids a literal on the LMS side for **agreement**, because a literal
could badge a band genuinely called "Various Artists" on an install whose
label is something else. The gate only **withholds** a badge, so a literal
there fails safe: at worst such a band's album waits for the review queue.
That is the same direction as every other rule in §13.10.

#### Scope

The gate lifts, or changes shape, with Q9 and the pages 2–3 measurement, as
before. No other artist rule changes.

### 15.15 No scheduled sync; a rejected token is a stop; buttons act on the page

**Decided 2026-09-22 (design chat),** on the prompt-C hardware report. Amends §13.7's
three triggers and §15.2, and sharpens §14.2.

1. **The collection syncs only when a library scan finishes, or when the user presses
   "Sync collection now".** The interval timer and the startup sync are removed, along
   with the `discogsSyncInterval` setting. The plugin makes no unattended call to
   Discogs on a schedule.

   *The cost, accepted by the user and stated so it is not rediscovered:* a record
   added to the Discogs collection does not badge until the next library scan or a
   press of the button. A missing badge looks exactly like a record the user does not
   own, so staleness is silent; the settings page's last-synced time is the only
   signal. The design chat recommended keeping the timer with an off switch; the user
   chose removal, on the ground that a server plugin should not call a third party on
   its own schedule. Rescan-done stays: it follows an action the user took.

2. **A rejected token is reported as one, and stops automatic syncs.** Verified at
   slimserver `a670a38`: `Slim/Networking/SimpleAsyncHTTP.pm` `onError` passes the
   HTTP response to the error callback (`:96`) but never sets `code`; only `onBody`
   does (`:112`). Observed on the reference server: a sync with a wrong token was
   logged as `no_response`. §14.2 required the opposite. The status is now read from
   the error path, so `unauthorized` is reachable; it logs at error and pauses syncs
   triggered by a scan until the token changes or a manual sync succeeds. Retrying a
   token Discogs has rejected cannot succeed and only fills the log.

   **This applies to every non-2xx status, not only 401.** Phase 0 established the
   mechanism: `Slim/Networking/Async/HTTP.pm:434-436` routes any code not matching
   `[23]\d\d` to `_http_error`, which reaches the same error callback. Every branch
   of `API::classifyResponse` below its `!$code` test was therefore unreachable from
   the asynchronous side. The status **and the headers** are now read from the error
   callback's third argument, so `429` backs off, `5xx` is `server_error`, `404` is
   `not_found`, and `accountRequest` gets real rate headers on an error response
   instead of degrading.

   **Phase 0 finding, recorded because it was silent:** the rate-limit back-off was
   dead for the same reason. A `429` classified as `no_response` and aborted the sync
   rather than backing off — the one response the back-off exists for was the one it
   never saw.

   This is a stated exception to §15.2 obligation 1. While a token is rejected, syncs
   triggered by a scan are skipped, not kept pending. A pass whose WRITE is refused (a
   scan is running) still stays pending for the next notification, as before.

3. **The action buttons act on what is on the page.** The settings page's shared form
   carries a hidden save field on every submit (`settings/footer.html:39`), so every
   action button also saves. "Test token" already read the token from the field;
   "Sync collection now" read the stored one and then saved the field, so it synced
   with the old token and stored the new one. Both now use the field, both save, and
   the page says so. Changing the token clears the last sync error.

### 15.16 The review queue, manual re-match, and what the queue does not do

**Decided 2026-09-24 (design chat)**, on the survey and Phase 0 report for
`plans/build-order-step-8-review-queue.md`. Each part was put as a choice; the
plan carries the detail, the evidence and the tags. Parts marked DEFAULT were
not chosen by the user and are open.

1. **The queue is its own plugin web page**, a `Slim::Web::Settings` subclass
   with no `prefs()` that dispatches on its own action names — the shape of
   core's `Slim/Web/Settings/Server/Status.pm`. Not a section of the settings
   page, whose shared form has broken action dispatch twice. Not the LMS menu
   system. Web UI only.
2. **One nullable column, `review_reason`**, added by migration 4 with a
   guarded `ADD COLUMN` and no backfill. Values: `conflict` (written by the
   importer), and `ambiguous`, `artist-disagree`, `artist-absent`,
   `various-gated`, `orphan` (written by the ownership pass).
   **Superseded 2026-10-18 by §15.46 (settled), part 8.** (the `orphan` value: no longer written.)
3. **`conflict` is sticky.** Only the importer writes or clears it; the pass
   never overwrites it. A clean identification clears it. The importer also
   clears `orphan` when it relinks a row.
4. **A conflict row does not badge from its incumbent id.** The pass treats a
   `conflict` row as untagged: no node C, no `state` write, ownership from the
   title route only. Amends §15.3. For a fresh conflict (NULL id) this changes
   nothing; for an incumbent conflict (§3a's demotion) it stops the pass
   silently re-promoting a contested match, which is what §3a's demotion was
   for.
5. **Orphans are a separate list** on the same page. §13.10.5 stays the list
   for the review queue. Manual orphans are included: the rule that a manual
   row carries no review reason applies to albums still in the library, and an
   orphan is not a verdict on a live album.
   **Superseded 2026-10-18 by §15.46 (settled), part 8.**
6. **Manual re-match chooses from the user's own Discogs collection, never from
   a Discogs search, and never offers a release the user does not own.**
   Premise, as in §14.4: a well-maintained collection and well-tagged rips.
   Opening re-match runs a normal collection sync; the entry list is handed to
   the page for one render and dropped, the lifetime §15.13 part 1 gives the
   pass. Title-key matches first, then the whole collection with a client-side
   filter. Fixed fields: title, artists, year, format, label and catalogue
   number, release id, and the Discogs link. The sync keeps those three extra
   fields per entry, and nothing more. A release owned twice shows twice. The
   badge changes at the next sync, not at confirm. Amends design §3's
   "search-as-you-type against Discogs".
   **Superseded 2026-10-18 by §15.46 (settled), part 7.**
7. **Reject deletes the row**: a manual row, an incumbent conflict, a fresh
   conflict, or an orphan. It is the **third permitted deletion** in
   `discogs_match`, justified as §10.4 justifies clear & rebuild: §2a's
   invariant 2 governs automatic deletion, and this one is explicit, confirmed
   and single-row. The first deletion (`_recordNoMatch`'s narrow predicate) is
   unchanged. **There is no stored dismiss.** A computed item leaves the queue
   only through a manual link or a change in tags or collection, so the queue
   is not a recovery path for a wrong badge, which §14.4 rules out.
   **Superseded 2026-10-18 by §15.46 (settled), part 9.**
8. **§13.5's all-tags read is deferred past step 8, possibly for good.** v1's
   queue holds three contents: ambiguous matches, artist disagreement or
   absence, and Strict conflicts. Amends §13.5 and §13.10.5. §15.13 part 7's
   gap becomes v1's accepted gap. Revisit trigger: a wrong `exact` badge seen.
9. **A row carrying only an ownership conclusion and/or a pass-written reason
   is regenerable and may be deleted freely.** It carries no decision and no
   snapshot. §2a's governing rule and the three-NULL delete guard are
   unchanged. The pass deletes such a row when its new ownership is `absent`
   and its new reason is NULL. A relink deletes one standing on its target key.
   **Amends §14.8 invariant 3:** a row exists where there is an
   identification, an ownership conclusion other than `absent`, **or a review
   reason**. **Amends §15.13 part 5** accordingly.
10. **The seam test is queue → sync → link → pass**, in a new suite,
    `scripts/queue-check.pl`, with honest transport and prefs stubs. This
    discharges the stub audit's build-order obligation (TODO 2026-09-24).
    Three seam defects are a pattern, not a law.
    **Superseded 2026-10-18 by §15.46 (settled), part 7.** (the seam is now sync → pass → queue render.)
11. **Relink for users with manual links and no tag names is not built.** The
    importer's `use` gate is unchanged (§15.8). Such a user loses their manual
    links when a folder moves. Accepted for now and recorded as a possible
    future feature.
    **Dropped 2026-10-17 (owner):** not planned. Users with tags re-identify after
    a move (§15.5). The affected user (token, no tag names, manual matches) is
    outside the well-tagged premise (§14.4). The accepted gap stands as written.
    **Superseded 2026-10-18 by §15.46 (settled), part 8.**
12. **DEFAULT — clear & rebuild (§10)** is decided, unbuilt, and not step 8's.
    It is recorded in `TODO.md` for a later step.
13. **DEFAULT — an orphan that fits no current album can only be rejected.**
    Relinking it to an album of the user's choosing is future work.
    **Dropped 2026-10-17 (owner):** not planned. Users with tags re-identify after
    a move (§15.5). The affected user (token, no tag names, manual matches) is
    outside the well-tagged premise (§14.4). The accepted gap stands as written.
    **Superseded 2026-10-18 by §15.46 (settled), part 8.**

#### Where the evidence is thin

- **The discogs.com link** is built as `https://www.discogs.com/release/{id}`.
  Observed by the user to redirect to the canonical page, and corroborated by
  the `uri` field of captured release payloads. Not documented as a stable
  address.
- **Whether collection images may be shown** is unverified against Discogs'
  terms, so the re-match list shows none.
- **`ADD COLUMN` with a CHECK on SQLite 3.22.0** is confirmed from the SQLite
  documentation, ~~not from a run on a 3.22 build~~. Corrected 2026-10-17:
  migrations 1-7 ran on SQLite 3.22.0 in the repro container
  (`scripts/docker-sqlite322/`, `user_version=7`; §15.42).
- **Incumbent conflicts written before migration 4 cannot be found.** Nothing
  recorded them. They surface when their files next change.

### 15.17 Step 8 hardware findings: tags on demand, relink targets, a visible pause, artist before ambiguity

**Decided 2026-09-26 (design chat)**, on the step 8 hardware report
(reference server, 0.0.0.9). Checks 0–5, 7 and 8 passed. Check 6 exposed part 2.

1. **Conflict tags are re-read only when the user asks, one entry at a time.**
   The build re-read them on every list render, bounded at 25 rows. That was a
   deviation from the plan, recorded with its cost marked inferred small.
   Measured on the reference server's CIFS-mounted library: 19–137 ms per
   file, so up to about 7 s of synchronous I/O per page view. The list now
   reads no files, and a "Show tags" action reads at most two. The bound is
   removed with the behaviour it bounded. The plan's original "when opened" was
   right.
2. **An orphan may be moved onto a current album whose rows are all
   regenerable** — a no-match row, and/or an ownership-only or reason-only
   row, or none — and the relink deletes those rows first. An album with its
   own identification is not a target: its tags already rebuild its match
   (§15.5), so the orphan is rejected instead. Without this the page could
   never offer a relink after a scan, because the scan that creates the
   situation gives every album a row (report §2.2). §2a invariant 1 holds: the
   no-match row goes before the match row lands. Deleting a no-match row is
   within §2a invariant 3, since that table is regenerable.
   **Superseded 2026-10-18 by §15.46 (settled), part 8.**
3. **The page never says "no album fits" when one does.** It distinguishes "no
   album fits" from "albums fit, but their own tags already identify them".
4. **The rejection pause is shown on the queue page as well as in Settings.**
   §15.15 part 2 pauses scan-triggered syncs while Discogs rejects the token.
   New albums then stay unbadged indefinitely, and the only signal was the
   settings page's last error. Observed on the reference server, where a
   leftover wrong token 401'd every sync.

5. **The title route narrows by artist before calling a title ambiguous.**
   §13.10.3 badges on "exactly one collection entry agreeing on both title and
   artist". The pass counted title matches first, so owning two records with
   a title put every LMS album of that title in the queue, whoever it was by.
   On the reference server that was four "Greatest Hits" by four different
   artists. §13.10.3's single measured ambiguous case was two pressings by one
   artist, which is why the difference never showed. Now: two or more
   candidates agreeing on artist is ambiguous; exactly one badges; none
   agreeing with a single title candidate is "artist disagrees" (queue, as
   before, the spelling case); none agreeing among several title candidates is
   not owned, with no queue item, unless the LMS artist is absent. The Various
   gate (§15.14) is unchanged.
6. **Queue page fixes from the first look at it:** a template comment that
   leaked onto the page; non-ASCII titles and artists shown undecoded; a hint
   under the list that read like a stale status message; and the review
   queue's description covering the orphan list as well. Display only.

#### Recorded, not changed

- **A manual link on an all-remote album snapshots a track count of 0**, and
  a NULL `source_timestamp`. Correct for the data: all-remote albums are the
  pass's, not the importer's (§15.11). But the fit key becomes (artist, title,
  0), which every all-remote copy of that album shares. Low risk.

#### Observed on hardware, 2026-09-27 (0.0.0.10, reference server)

Everything §15.17 decided is now observed, with two exceptions named below.

- **Part 2 works, and it needed both deletes.** The relink removed the target's
  regenerable match row *and* its strict `discogs_no_match` row, landed the
  orphan's release id, cleared the `orphan` reason, and the next sync promoted
  the result to `strict` / `confirmed` / `exact`. Before E2 the same situation
  offered no target at all.
- **Part 5's rule 6 is the one that fired, on all four cases.** None of the
  four "Greatest Hits" albums badged `version`; all four were decided "not
  owned, no reason, no queue", because each shared its title with several
  collection entries and none of those entries agreed on artist. So the
  measured §13.10.3 case (two pressings by one artist) and the measured
  real-library case (one title, four artists) are genuinely different cases,
  which is the whole point of part 5. `ambiguous` went 4 → 0 in one sync,
  `updated=3 deleted=1`, and the diff was exactly those four rows.
- **§15.16 part 9's amended invariant, observed in the delete direction.**
  Three of the four kept their strict identification rows with the reason
  cleared. The fourth (Red Hot Chili Peppers) held a reason-only row, so once
  the reason lapsed the row asserted nothing and was deleted. That is the
  invariant working, not a data loss: nothing regenerable was in it.
- **Part 1 is observed as a non-cost.** A queue render takes 0.031–0.034 s
  whether or not a conflict is present, so the list really does read no files;
  "Show tags" on local files costs 0.033–0.037 s.
- **R3's stickiness, incidentally confirmed.** When a conflicted copy's album
  vanished, its row kept `review_reason = 'conflict'` rather than becoming
  `orphan`: the pass does not overwrite a conflict mark.

**Not exercised, and recorded as such in `TODO.md`:** part 4's rejection-pause
notice, because no 401 occurred and forcing one would have meant breaking a
working token; and the worst case of part 1, because a NAS-backed conflict
cannot be created on that server. The NAS figure behind part 1's reasoning was
re-measured at 58.6 ms min / 97.5 ms mean for two files, the same order as the
19–137 ms that decided it.

### 15.18 The collection sync and the ownership pass move inside the scan

**Decided 2026-09-26 (design chat)**, recorded 2026-09-27. **This reverses
§15.2's "why not in the scanner".** §15.2's other halves stand: the server-side
trigger is still `['rescan','done']` and not scan start, and the pass is still
refused while another process holds the write lock.

1. **The sync and the pass run inside SqueezeWax's importer**, after
   identification, in the scanner process. The reason is what the user expects
   of LMS: when a scan finishes, the library is finished, badges included. A
   badge that appears sixty seconds later, by a mechanism with no progress row
   and no completion line, reads as a bug. The streaming plugins call their
   services during the scan too — **inferred** from `CLAUDE.md`'s reference to
   `refs/lms-plugin-tidal/API/Sync.pm` being the scanner-side transport; not
   re-verified against that plugin's own importer in this session, and on the
   TODO list.
2. **A timeout bounds it, and it fails fast.** `API.pm`'s retry ladder
   (`MAX_RETRIES`, three waits of `WINDOW_SECONDS`) must not run in the
   scanner: up to four minutes stalled on one request is four minutes of a
   scan. `Slim::Networking::SimpleSyncHTTP` honours a caller-supplied timeout —
   **verified** at `Slim/Networking/SimpleHTTP/Base.pm:99-102`
   (`$params->{Timeout} || $params->{timeout} || $prefs->get('remotestreamtimeout')`)
   and `Slim/Networking/SimpleSyncHTTP.pm:84-91`, which passes it to
   `LWP::UserAgent->new( timeout => ... )`. The value and its scope are
   decided in the step 8b survey.
3. **A failure is logged only.** Nothing new on the settings page and nothing
   new on the queue page. The remedy is the next scan or the "Sync collection
   now" button. Rationale: the scan-time sync is an accelerator for something
   that already works, so its failure returns the user to the behaviour of
   §15.2 rather than to a broken state, and a second error surface for the same
   condition is a second thing to keep true.
4. **A rejected token during the scan-time sync is treated as a timeout is**:
   logged at error, retried at the next scan. A 401 answers instantly, so it
   costs the scan nothing, and the scanner is a fresh process each time and has
   nowhere to keep a pause. The in-memory rejection pause of §15.15 part 2
   therefore governs **only** the server-side fallback from now on, and §15.17
   part 4's notice on the queue page keeps describing exactly that.
5. **The server-side sync after `['rescan','done']` survives only as a
   fallback**, for scans in which our importer did not run. After a scan where
   it did, the server does nothing. How the server tells the difference is
   decided in the step 8b survey; it cannot be an in-memory flag, because the
   two are different processes.
6. **Built as step 8b, before step 9.**

#### Answering §15.2's four reasons against this

1. *"The manual trigger has no scanner process … two sync implementations under
   a rule that the pass be deterministic."* **Conceded, and accepted.** There
   will be two fetch paths and one matching path: `Ownership::apply` is called
   unchanged from both, and determinism is a property of the matching, not of
   the transport — a page fetch has no discretion to be inconsistent about.
   The cost is real: two transports to keep behaving alike, and a seam test is
   owed for the new one. It is also unavoidable rather than chosen, because of
   the next point.
2. *"In-server rescans never reach the importer."* **True, and it is now the
   reason the fallback stays** rather than a reason against the scanner. Two
   paths skip our importer, both **verified**: `rescan album|track <id>`
   (`Slim/Control/Request.pm:607`, `Slim/Control/Commands.pm:2745`; no caller
   in LMS's own `HTML/`, and whether third-party skins call it is
   **unverified**), and the automatic on-file-change rescan
   (`Slim/Utils/AutoRescan.pm:126`, `:205`; pref `autorescan` defaults to 0,
   `Slim/Utils/Prefs.pm:165`). Every ordinary rescan does run our importer:
   `Slim/Control/Commands.pm:2736-2743` launches the external scanner, and
   `:2719-2727` (Bug 17358) forces an external scan whenever any plugin
   importer is in use.
3. *"A Discogs stall would stall the scan."* **Answered by part 2 above.** The
   scan-side path takes a timeout and does not use `backoffFor`.
4. *"The importer's `use` gate is tied to tag names."* **Still true, and now a
   problem to solve rather than an argument.** A sync in the scan must run for
   a user who has a token, whatever their tag names say. Decided in the step 8b
   survey.

#### Verified in this session, and load-bearing for step 8b

Read at slimserver `a670a38c2b14ad42b86a39884bcb842121b35571`, the same pin as
`refs/`. Read, not observed running.

- **There is no event loop in the scanner.** `scanner.pl:498` is
  `sub idleStreams {}`, a no-op stub, and nothing in `scanner.pl` enters an EV
  or AnyEvent loop. So `Slim::Utils::Timers::setTimer` never fires there and
  `Slim::Networking::SimpleAsyncHTTP` cannot complete. `API/Async.pm` is built
  entirely on both. **A second, synchronous fetch path is therefore mandatory,
  not a preference** — which is what makes §15.2 reason 1 unavoidable.
- **The scanner cannot persist any preference.**
  `Slim/Utils/Prefs/Namespace.pm:303` — `save` returns immediately under
  `main::SCANNER`, before arming its write timer, so `savenow` is never
  reached either. A `$prefs->set` in the scanner changes the in-memory hash of
  a process that is about to exit. `scanner.pl:122` additionally marks the
  `server` namespace read-only. **Consequence: the scanner cannot write
  `discogsLastSynced`, and the settings page's "last synced" can only ever
  reflect the server-side sync.** Anything the server must learn from the scan
  has to go through `squeezewax.db`.
- **The scanner can read preferences.** `Namespace::new` loads the namespace's
  file (`Slim/Utils/Prefs/Namespace.pm:85`), which is how `Importer.pm:94`
  already reads `discogsTagNames`. `discogsToken` and
  `discogsTestExcludeReleases` are readable the same way.
- **`Ownership::apply` cannot run in the scanner as written.**
  `Ownership::_write` opens its transaction with `$dbh->begin_work`.
  `CPAN/DBI.pm:1716-1719` makes `begin_work` a `set_err` "Already in a
  transaction" when `AutoCommit` is already off, and `scanner.pl:295` sets
  `AutoCommit = 0` for the whole scan; `Slim/Schema.pm:273` has
  `RaiseError => 1`, so that `set_err` dies. `apply`'s own `eval` catches it,
  logs "the ownership pass failed" and returns `'failed'`. The failure is loud
  and writes nothing, which is the right direction — but the pass would never
  once succeed in the scan until this is changed. **Step 8b's first real code
  question.**
- **The rest of the pass is scanner-safe.** It reads no files:
  `Ownership.pm` has no `Tags::readTrack` call, so §15.2 obligation 2's
  Scheduler requirement has no subject on this path. `Library::eachAlbum`,
  `albumCount` and `ownershipArtists` go through `Slim::Schema->dbh` only, and
  `Slim::Music::Info::variousArtistString` (`Slim/Music/Info.pm:1540-1543`) is
  a pref plus a string lookup, with `Slim::Music::Info` loaded and initialised
  by `scanner.pl:84`, `:279`.
- **`Match::_writeOk` already permits the scanner**, unconditionally:
  `_writeRefusal` returns undef on `$isScanner` (`Match.pm:43-58`), and
  `_writeOk` does not call `stillScanning` in that process
  (`Match.pm:60-85`).
- **This plugin has never made an HTTP request from the scanner.** The only
  `buildRequest` callers are `Settings.pm:372` (server, own transport) and
  `API/Async.pm:389` (server, async). `API.pm`'s own file header still claims
  "the scanner's Strict identification (steps 3/4) calls buildRequest and
  classifyResponse directly"; that became false when §13.8 removed the
  per-album scanner search, and the comment is **stale**. Step 8b is the first
  scanner-side request, so nothing about HTTPS from that process — SSL support,
  proxy behaviour, `LWP` timeouts under the scanner's priority — has been
  observed. On the hardware list.

#### Where the evidence is thin

- That the reference streaming plugins sync **during** the scan is inferred
  from a `CLAUDE.md` sentence about which transport they use, not from reading
  their importer. It is the stated motivation for part 1 and it is the weakest
  claim in this record.
- `Slim::Networking::SimpleSyncHTTP` reaches `LWP::UserAgent`, whose `timeout`
  is documented as a per-operation limit rather than a whole-request budget.
  Whether one slow-but-alive response can exceed the timeout repeatedly and
  still not abort is **unverified**, and it is why the survey asks whether the
  bound is per request or for the whole sync.
- The two importer-skipping paths were found by grepping LMS's own tree. A
  third-party skin or plugin calling `rescan album <id>` would skip our
  importer without appearing in that grep.

#### Parts 7–16: decided 2026-09-27, on the step 8b survey and Phase 0

The survey's eight questions and Phase 0's five. Two of the survey's own
recommendations are answered against, and one is withdrawn outright; each says
so.

7. **The marker is a one-row table in `squeezewax.db`, and it becomes the single
   "last synced".** Migration 5 adds `discogs_sync_state (id, last_synced,
   items, source)`. Both sync paths write it, `API::Async->status` reads it, and
   `discogsLastSynced` / `discogsLastSyncItems` retire by `$prefs->migrate(3)`.
   *Why one source of truth rather than a marker beside the prefs:* the scanner
   cannot persist a pref at all (`Slim/Utils/Prefs/Namespace.pm:303`), so a
   settings page reading prefs would show "last synced" going stale on a server
   where syncing works perfectly. This also means the page keeps its existing
   meaning, "ownership last derived", because the marker is written only after
   the pass's writes commit. *Cost:* a migration and a pref migration, which is
   scope beyond "move the sync" and is named rather than discovered.
8. **The rule that decides whether the server's fallback still syncs is exact,
   not a time window.** `Plugin::_rescanDone` records when it fired, keeping the
   previous value; `_syncTick` skips only when the marker's `source` is `'scan'`
   **and** its timestamp falls between the previous rescan-done and this one.
   **This withdraws the survey's `time() - last_synced <= DEBOUNCE + grace`.**
   That rule cannot work: our importer runs at weight 130, and after it come the
   artwork importers, the artwork precache and `optimizeDB`
   (`Slim/Music/Import.pm:462-484`), an unbounded tail — so on a large library
   the marker is minutes old when the tick fires, and any fixed grace is a guess
   that fails on exactly the servers that need it. The `source` column is
   load-bearing: a **manual** sync also falls inside that window, and it must not
   suppress the fallback, because it derived ownership for the library as it was
   *before* this scan. *Failure bias, chosen deliberately:* a needless sync costs
   four requests and about 2.7 s; a wrong skip costs stale badges until the next
   scan. The rule errs toward syncing.
9. **`Importer.pm`'s `use` gate does not change.** §15.8 stands unamended.
   **This answers the survey's own recommendation against it**: the survey
   proposed `@tagNames || $token`, which was right only while the sync had no
   importer of its own. Under part 13 it would give a token-only user an
   identification importer with nothing to do — a dead progress row and an
   orphan "Starting … scan" pair, which `Importer.pm:83-95` exists to prevent.
   A consequence: the survey's restructuring of `startScan`'s four early returns
   is not needed either, so step 4's code is untouched by 8b.
10. **Timeouts: 15 s per request, 120 s for the whole sync.** 15 s is what
    `API/Async.pm:417` already passes and what the reference plugin uses
    (`refs/lms-plugin-tidal/API/Sync.pm:104-105`), so a slow response behaves
    alike on both paths. The whole-sync bound is **our own clock, checked
    between requests**: `LWP::UserAgent`'s timeout measures inactivity, not
    total time (`CPAN/LWP/UserAgent.pm:1565-1568`, documented and read), and
    nothing can interrupt a request already in flight. So one slow-but-alive
    response may still exceed 15 s, which no code of ours can prevent and which
    is on the hardware list. On exceeding either bound: log at error, abandon,
    let the scan finish.
11. **The scanner's rate-limit state starts cold, and a computed wait abandons
    the sync.** `accountRequest` returns a wait as well as a state
    (`API.pm:177`), and the server honours it with a timer
    (`API/Async.pm:369-375`). There is no timer in the scanner, so honouring a
    60 s wait would mean blocking the scan for 60 s. The check happens **before
    issuing the next request**, so a wait computed after the last page costs
    nothing. `backoffFor` is never called on this path, so a 429 fails the sync
    once. *Named cost:* a scan begun within a minute of a manual sync spends
    budget the fresh process cannot see; Discogs answers 429, the scan-time sync
    fails and logs, and the remedy is the fallback sixty seconds later.
12. **One progress row covers both halves** — `plugin_squeezewax_ownership`, the
    fetch ticking per request and the pass per album, with the total set once the
    page count is known (`Slim/Utils/Progress.pm:154-170`). **The survey's
    recommendation of a row for the pass alone is answered against**: the pass is
    40–48 ms measured and the fetch is 2.72 s, so a bar over the pass alone would
    show a flicker and hide the wait. *Consequences, both stated rather than
    discovered:* `update` is the abort mechanism in this process
    (`Slim/Utils/SQLiteHelper.pm:444-459`), so the pass acquires abort points it
    never had — safe only because they fall in the decide walk, before any write
    (part 13's ordering) — and there is **no** abort point inside a blocking
    request, so abort latency during the fetch is the request time plus up to 5 s.
13. **`Ownership::_write` commits the scanner's pending work first, writes, and
    leaves the commit to its caller.** The `$ownTxn` conditional of
    `Match::relinkOrphan` (`Match.pm:497-499`) is **not sufficient on its own**:
    on the scanner branch nothing is rolled back, so a pass that died halfway
    would be committed by the next `forceCommit` — §13.7's named half-applied
    pass. `relinkOrphan` gets away with it because its partial effect is a delete
    of regenerable rows; the pass's updates to `ownership`, `state` and
    `review_reason` are not. A leading `Slim::Schema->forceCommit` makes the
    pass's writes the only uncommitted work, so a rollback discards exactly the
    pass. The scan-time marker is written after the pass and before the commit,
    so the two share one fate — which matters because `forceCommit` swallows a
    failed commit (`Slim/Schema.pm:2380-2384`): if the commit is lost, the marker
    is lost with it and the fallback re-syncs. A SAVEPOINT would be the textbook
    answer and was rejected: there is none anywhere in `Slim/`, so it has no
    in-tree precedent and its behaviour with this DBD::SQLite is unverified.
    *What this does not claim:* the pass is not atomic against the scan as a
    whole. It never was — every `COMMIT_EVERY` boundary already commits
    identification work — and the plan says so rather than implying otherwise.
14. **A second `post` importer of our own, weight 130, gated on the token
    alone.** **Verified**, not assumed: `%Importers` is keyed by class name
    (`Slim/Music/Import.pm:551-556`), `use` is read per entry (`:573`), and
    `Slim/Plugin/OnlineLibrary/Importer.pm:30-35` and `:41-46` register two
    `post` importers from one `initPlugin`. 130 is free: in-tree `post` weights
    run 90–110 and ours is 120, nothing runs after `optimizeDB`, and a
    third-party post importer with no weight sorts at 1000, after us — other
    third-party weights are **unverified**. The class is loaded with a `require`
    inside an `eval`, not a `use`, so a compile error in it cannot take
    identification down with the whole plugin
    (`Slim/Utils/PluginManager.pm:323-327`); `Slim/Music/Artwork.pm:771` is the
    in-tree shape. `install.xml` does not change: the scanner loads only the
    `<importmodule>` class, so the second one is registered from
    `Importer::initPlugin`. *Cost:* a token holder now gets two
    "Starting … scan" / "Completed … Scan" pairs per scan, at error level
    (`Import.pm:578`, `:710-712`).
15. **Two new files, one new suite, and the shared parts move to `API.pm`.**
    `API/Sync.pm` fetches and nothing else; `ScanSync.pm` is the importer class
    and owns the progress row, the marker and the call into the pass. This makes
    the design doc's module table true. The pagination helpers, the
    `basic_information` → entry mapping and `_testFilter` move from
    `API/Async.pm` into `API.pm`, because two transports carrying two copies of
    the entry builder is exactly the drift §15.2 reason 1 warned about and a seam
    test could only ever cover one of them. The seam test is a new suite,
    `scripts/scan-sync-check.pl`, following step 8's shape — and it is the first
    suite in this project to open its handle with `AutoCommit => 0`, which is why
    no scanner transaction branch has ever been exercised offline.
16. **Scan modes: a playlist-only rescan skips the sync; an online-library-only
    rescan runs it.** The post-processing loop filters neither
    (`Slim/Music/Import.pm:452-459` against `:396-401`), and `Import`'s own flags
    are reset before it (`:409-410`), so the mode is read from the scanner's own
    `$main::playlists` / `$main::onlineLibrary` (`scanner.pl:112`, `:129-130`).
    A playlist rescan changes no album, so calling Discogs would be waste. An
    online-library rescan adds precisely the all-remote albums that only the pass
    can badge (§15.11), so it is the one mode where skipping would lose badges.
    Identification's behaviour in those modes is today's and is not changed here;
    it is recorded in `TODO.md`.

#### Two rulings taken without a question

- **LWP's self-made 500 is classified as `no_response`.** On a timeout, a DNS
  failure or a refused connection, `LWP::UserAgent` builds its own 500 carrying
  `Client-Warning: Internal response` (`CPAN/LWP/UserAgent.pm:205-219`,
  `:1131-1139`, documented at `:1569-1572`; read, not observed). Without reading
  that header, every timeout would be logged as "Discogs returned a server
  error" and part 10's "the two paths behave alike" would be false in the log.
- **The reach of the scan-time path is accepted as it is.** See the amendment to
  part 2 below.

#### Amendments to parts 1 and 2 of this record

- **Part 1's weakest claim is now verified.** The reference streaming plugin does
  sync inside its scan step: `refs/lms-plugin-tidal/Importer.pm:21`, `:24`,
  `:67`, `:90` call its sync from `startScan`, over `SimpleSyncHTTP` with
  `timeout => 15`. Read at the pinned `refs/`. The "evidence is thin" bullet
  about it is retired.
- **Part 2's "every ordinary rescan does run our importer" needs a
  qualification.** It runs only in scans that go through `scanner.pl`, and a
  plain `rescan` is sent there only when some importer registered **in the
  server** has `use` set (`Slim/Control/Commands.pm:2719-2727`). SqueezeWax
  registers none; on a default install FullTextSearch does
  (`Slim/Plugin/FullTextSearch/install.xml:13`, `Plugin.pm:190-196`). With FTS
  off and no virtual library and no streaming plugin, our importer never runs and
  only the fallback syncs. **Registering a server-side importer of our own to
  force external scans is refused**, though TIDAL does exactly that
  (`refs/lms-plugin-tidal/Plugin.pm:71`): it would make every rescan on every
  user's server fork an external scanner for our convenience. The fallback
  already covers that install, which is what the fallback is for.
- **The "evidence is thin" bullet about `LWP`'s timeout is resolved**, in the
  direction that was feared: the timeout is per operation, so the whole-sync
  budget of part 10 is not optional. It is replaced by a hardware item.

#### As built, 2026-09-27 (`7a8f8d7`..`5ce85a9`, 0.0.0.11)

Built in the plan's order, ten commits, 1181 → 1459 assertions. Four decisions
the plan did not make, and one interpretation of a rule it did.

- **"The previous rescan-done" means the previous *scan*, not the previous
  notification.** A scan notifies `['rescan','done']` two or three times within a
  few seconds, so read literally the rule of part 8 would shrink its window to
  those seconds and never skip. As built, a notification arriving while a tick is
  still armed moves only the window's upper end — the same treatment the debounce
  already gives a duplicate. **Reviewed and confirmed as the rule's intent**, not
  a deviation from it.
- **Named cost of that, which the rule cannot avoid:** when two scans'
  notifications both arrive before the tick runs, the window spans both. If the
  first ran our importer and the second did not, the first scan's marker
  suppresses the fallback, and the second scan's new albums stay unbadged until
  the next scan or the button.
  *Where that can come from, checked 2026-09-27:* **the auto-rescan**, which is
  in-process — `Slim/Utils/AutoRescan.pm:126` and `:205` call
  `Slim::Utils::Scanner::Local->rescan` directly and never launch the external
  scanner, so our importer does not run, and `Scanner/Local.pm:390-391`,
  `:662-663` and `:1223-1224` each notify `['rescan','done']` all the same. The
  pref defaults to 0 (`Slim/Utils/Prefs.pm:165`), so the gap exists only on
  servers that opted in. `rescan album|track` reaches the same in-process path
  (`Slim/Control/Request.pm:607`, `Slim/Control/Commands.pm:2745`) but is not a
  user action: nothing in LMS's own web UI calls it, and it is deliberately not
  designed around.
  **Accepted, and the alternatives are recorded so they are not re-proposed.**
  Closing the window per notification reintroduces the duplicate problem above,
  which is the common case rather than the rare one. Treating a notification as a
  duplicate only within ~10 s would fix this case but keeps a guessed number
  inside the correctness decision. Replacing the window with one remembered
  timestamp — skip only when a scan marker is newer than the last one the
  fallback accounted for — would close the gap and delete code, and was
  **declined on 2026-09-27** as not worth re-opening a mechanism that passes; it
  is the first thing to reach for if this is ever observed. **Not observed**;
  recorded in `TODO.md`.
- **The marker is reached only through `Schema->syncState` and
  `Schema->recordSync`.** One reader and one writer for a row two processes write,
  rather than SQL in three files.
- **A failed marker write is logged, not rolled back.** This does not contradict
  part 13: part 13 is about a *lost commit*, where the pass goes with the marker.
  If the marker's own write fails while the pass succeeds, the pass is still
  correct and the only consequence is that the fallback syncs again sixty seconds
  later — the same harmless duplicate the skip rule's failure bias already
  accepts. Rolling back a good pass to keep a bookkeeping row would be the worse
  trade.
- **`ScanSync::startScan` returns 1 or 0**, not a change count: `Ownership::apply`
  returns a status, and `runImporter`'s caller sums the value only to decide
  whether anything changed (`Slim/Music/Import.pm:404-406`).
- **The seam suite is spread across C1–C3** rather than added whole in C3, because
  each commit is required to test its own branches.

#### Observed on hardware, 2026-09-27 (0.0.0.11, reference server)

Eleven checks, nine run. `plans/build-order-step-8b-sync-in-scan.md` §9 has the
figures; what follows is what the run *settled*, and the three places it
corrected this record.

**Part 1's claim holds.** A scan that picked up a new album finished with the
badge already correct — read at the instant `rescan ?` first returned 0, the row
was `confirmed` / `exact`, and the marker was already written. No sixty-second
wait. The log shows both importers' Starting/Completed pairs, the sync's summary
line, two `['rescan','done']` notifications, and **one** `_syncTick` sixty seconds
later skipping with its reason. Reproduced on every scan of the run.

**The fetch sees a collection that changed.** Run by the owner by hand, the half
the server could not do for itself: adding a record on the Discogs site made the
next scan report **204** items, and removing it again made the one after report
**203**. Both directions, both visible the moment the scan finished.

**Part 3 holds exactly.** With a deliberately broken token, the scan-time sync
failed at the identity request, logged one error line in the scanner log, and
left the settings page and the queue page **byte-identical** to their captures
from before the break. The fallback then failed the same way sixty seconds later
and recorded its own error, as it always did. A user watching either page would
not have known the scan-time sync had failed.

**Parts 7 and 8 hold.** Migration 5 ran 4 → 5 in one step with every
`discogs_match` row byte-identical; `$prefs->migrate(3)` retired both prefs; the
absent marker row renders as "Last synced: Never"; a scan writes `source = 'scan'`
and the button turns the same row into `'server'`. An aborted scan wrote **no**
marker, and the next scan's pass rewrote all 765 albums.

**Part 16 holds.** `rescan playlists` issued no Discogs request at all;
`rescan onlinelibrary` issued one sync, and the pass covers the 186 albums with
no local track — §13.10.1 and §15.11 observed on real data.

**Step 8's open item is closed.** The rejection-pause notice (§15.17 part 4)
renders on the queue page when the fallback's 401 sets the pause, and the page
returns byte-identical to its baseline when the token is restored.

##### Three corrections to this record

1. **Part 2's amendment understates how many installs reach our importer.**
   `Slim/Control/Commands.pm:2719-2728` forces an external scan when **any**
   registered importer whose class matches `/(?:Plugin|Slim::Music::Virtual
   Libraries)/` has `use` set — not FullTextSearch specifically. On the reference
   server `Plugins::Spotty::Importer` forces it, and a plain rescan with FTS
   disabled still ran both our importers. So the amendment's direction was right
   and its size was wrong: almost any enabled plugin with a server-side importer
   is enough, and the FTS-off install it worried about is rarer than it implied.
   What has **not** changed, and was re-verified: **SqueezeWax registers no
   importer in the server.** `Plugin.pm` and `Settings.pm` never mention
   `Importer` or `ScanSync`, and `Slim/Utils/PluginManager.pm:196-207` loads
   import modules only in the scanner's pass. We depend on another plugin to
   force the external scan; we do not force one ourselves, and §0.1 ruling 12
   still refuses to.
2. **Part 12's progress row does not show what it was chosen to show.** While it
   runs, the row reads "0 of 0" for about three seconds, in both the default skin
   and Material; it then completes at 768 of 768 (1 identity + 3 pages + 764
   albums) and reads correctly. **The cause is not the five-second throttle**, as
   first reported: `Slim/Utils/Progress.pm:154-160`'s `total` writes to the table
   immediately and unthrottled. It is the scanner's uncommitted transaction —
   under WAL another connection cannot see our writes until a commit, which is
   the same problem `Importer.pm:165`'s comment already documents for this row.
   **Inferred from reading, not observed.** Decided 2026-09-27: **no code
   change.** A `forceCommit` after the total is set would make it read "n of 768"
   instead of "0 of 0" and still be nearly static, because the work is 2.5–3.3 s
   and the done counter is throttled to five. So the design chat's reason for
   choosing one row over both halves — that the 2.72 s fetch should be visible —
   **did not survive contact with the hardware**, and is recorded as wrong rather
   than quietly dropped. The row keeps its place for the reason that did survive:
   it is the only abort point during the fetch, and check 8 aborted through it in
   0.43 s. Dropping it (the survey's Q5(b)) would leave a fetch bounded at 120 s
   with no way to interrupt it.
3. **The rejection pause has two exits, and they do not cover the same case.**
   §15.15 part 2 says the pause lifts "until the token changes or a manual sync
   succeeds". Both are kept, and which covers what is now known:
   `Plugin.pm:67-72` clears the pause on any `discogsToken` change, and
   `Settings.pm:251-260` saves the pref **before** running a sync, so whichever
   button restores a token clears the pause first. `API/Async.pm:605-607`'s
   clear-on-success can therefore only ever lift a pause that was set while the
   token stayed the same — that is, after a **transient 401 from Discogs**.
   Reachable in principle, not provokable on demand, and **unobserved**. Recorded
   rather than claimed as tested.

##### A named cost this run exposed

**HTTPS from the scanner is platform-dependent, and its absence is quiet.** It
works here, but `IO::Socket::SSL` and `Net::SSLeay` come from the **Debian system
perl**, not from LMS's `CPAN/`, which bundles them for darwin only;
`LWP::Protocol::https` is the one of the three LMS supplies. On a platform whose
system perl lacks them, `Slim/Networking/SimpleSyncHTTP.pm:22-41`'s `hasSSL`
merely **warns**, so the scan-time sync would fail on every scan with nothing but
a warning in the scanner log, and the fallback would silently do all the work.
Not a defect of this step — it is LMS's behaviour — but it is the one condition
under which 8b does nothing and says almost nothing. Recorded in `TODO.md` as an
open question: whether `ScanSync` should check `hasSSL` itself and log at error.

> Correction 2026-10-14: 'merely warns' understates it. The warning is logged
> under network.http (slimserver eb59bbf,
> `Slim/Networking/SimpleSyncHTTP.pm:79`), default level ERROR
> (`Slim/Utils/Log.pm:897`), so by default nothing is logged at all. README fixed
> in fde4605.

> Decided 2026-10-19 (owner): `ScanSync` checks it. Before the collection request
> it calls `Slim::Networking::SimpleSyncHTTP->hasSSL` (`public/9.1` @ `a670a38`,
> `Slim/Networking/SimpleSyncHTTP.pm:24`). If that is false it logs once at error,
> "Scan-time collection sync skipped: this scanner cannot use HTTPS
> (IO::Socket::SSL missing). The server will sync after the scan.", and returns 0
> with no request, no progress row and no marker, so the fallback syncs after the
> scan. Once per scan: the check runs once in each scanner process. Offline only
> (`scan-sync-check.pl`); no scanner without `IO::Socket::SSL` has been tried.

### 15.19 Two findings from the title-route checks: rule 3 works, and node F cannot fire

**Found 2026-09-28** on the reference server (0.0.0.11), from two checks aimed at
§15.17 part 5. Neither is caused by step 8b; the first confirms a rule, the second
exposes a defect that has been present since the master arm was written.

#### Rule 3 is observed on real data, for the first time

§15.17 part 5 gave the title route five outcomes. Until now hardware had seen only
rule 6 — several title candidates, none by this artist, not owned — which is what
the four "Greatest Hits" albums took. Rule 3, "exactly one collection entry agrees
on both title and artist, so badge `version`", is the rule that produces a badge,
and it had never run outside the offline suite.

Method: a copy of an album on local disk, the NAS original left untouched as the
control, one variable changed. The copy reproduced the queue's `artist-disagree`
item first (the baseline), then its `albumartist` alone was changed from `Björk`
to the release's credited `Björk Guðmundsdóttir`. The next scan moved it to
`ownership = version`, cleared its `review_reason`, and left the queue; `version`
went 50 → 51 and `artist-disagree` 3 → 2. It was **`version` and not `exact`**,
because the tagged release is still not in the collection — so the decision came
from the title route, not from node D. `state` stayed `candidate`: the title route
never promotes. The control did not move through any of the three scans.

**The normalisation is not implicated.** The two keys are `björk` and
`björk guðmundsdóttir` — a shorter name, not a spelling difference — so no rung of
§13.10.4's ladder would or should merge them. §13.10.3 stands.

#### Node F cannot fire, and it is mislabelling albums the user owns

**Verified**, by reading: `discogs_master_id` is written in exactly two places,
`Match.pm:663` and `:910`, and both take it from a `DISCOGS_MASTER_ID`-family
**tag** (`Tags.pm:49-57`). Nothing anywhere resolves a release id to its master;
`API.pm:393` keeps `master_id` only for **collection** entries, which is the
index's other side. So node F (`Ownership.pm:377-381`) compares a column that is
NULL on all but 2 of 506 rows on the reference library. **Node F has never fired
there, and all 50 `version` badges came from the title route.**

The demonstrated case is *Gling-Gló*: the owner's collection holds release 28711,
the ripped files are tagged release 1990647, and **both are master 1884**. Design
§3 node F exists precisely for this — owning one pressing and ripping another —
and the correct answer is `version` with a badge. What the plugin produced instead
was `ownership = absent`, no badge, and a review-queue item asking the user to
adjudicate a question their own collection already answers. That is a **false
not-owned**, and it is the mirror of the failure `TODO.md` 2026-09-12 names.

Two things worth keeping from how it was found. The album needed **either** of two
routes to work: node F via the master, or the title route via the artist. Both
failed, for unrelated reasons, and retagging repaired only the second — which is
why rule 3 was finally observed on an album that should never have been in the
queue at all. And `TODO.md` 2026-09-07 already asserted that the master arm is
"required, not a fallback"; it has simply never had data to be required by.

#### Decided 2026-09-28: measure before designing

The scale is **unmeasured**. One case is confirmed; how many of the 305
`candidate` / `absent` rows are the same story is unknown, and a fix designed
without that number is a mechanism built for a guess. So: a one-off measurement
first, run as a script by the owner, looking up the master of each identified
album whose release the collection does not hold and counting how many share a
master with something owned. `TODO.md` carries it.

What the fix is **not** allowed to be, when it comes: it cannot live inside the
scan-time sync, which §15.18 part 10 bounds at 120 s, because the one-off pass
over this library alone is roughly 481 requests, or eight minutes at Discogs'
documented 60 a minute. It wants a throttled, resumable, server-side backfill
that stores **conclusions** — see the errata below, which corrects what this
paragraph first said about where they are stored. It is a step of its own, and its
decision record must answer §13.8 directly rather than around it: §13.8 rejected
a per-album lookup **per sync**, and this would be one lookup per release, once,
cached. That is a different trade, but it is close enough in shape that the
difference has to be argued rather than assumed.

#### Recorded, not decided: `anv`

The collection carries an `anv` — the artist name as credited on that release — in
`basic_information.artists[]`, which we already fetch and discard at
`API.pm:393-395`. It is non-empty on **11 of 203** entries in the owner's
collection, and nine of those are abbreviations or article drops: `The Orb` →
`Orb`, `The Future Sound Of London` → `FSOL`, `Aphex Twin` → `AFX`,
`Oliver Lieb` → `O. Lieb`. Keeping it would cost **no requests at all**.

It would **not** have helped *Gling-Gló*: `anv` is the empty string on both the
owned entry and the tagged release. What matches there is
`aliases = ['Björk']` on artist 517951, which costs one `/artists/{id}` per
artist — the expensive branch, not the free one. The same artist carries **48**
`namevariations`, all misspellings and transliterations, which is a caution in
itself: an alias is a distinct Discogs entity, a name variation is not, and
matching on the latter would widen the badge rule a long way.

So `anv` and aliases are **two separate decisions**, and this album argues only
for the second. Both are recorded in `TODO.md` and neither is taken here. Note
also that this run proved rule 3 for a *longer* name and abbreviated nothing, so
the family `anv` would serve is still untested.

### 15.20 Node F is fixed by caching the release, and an identification the release contradicts goes to the queue

**Decided 2026-09-28**, on the measurement §15.19 called for. Read that first:
this section is the answer to it, not a restatement.

#### What the measurement found

332 requests, 8 minutes, read-only, on a 506-row library with a 203-item
collection. The population — identified rows whose release the collection does
not hold — is 329 rows over 328 distinct releases.

| | |
|---|---|
| **node F would badge, we say `absent`** — the defect | **5** |
| node F would badge, the title route already did | 21 |
| node F could not help (master not owned, or no master at all) | 303 |
| population releases Discogs reports with no master | 29 |

Of the five, two are the case design §3 node F was written for — own one
pressing, ripped another. Two are one physical record filed as two LMS albums (a
2-LP set), which node F would badge twice; correct per album, and a caution for
any future count of "records I own that are in my library". **The fifth is not a
node F case at all**: a curated `Cover Versions/` folder holding three artists'
recordings of one song, strict-matched to a full album's release id because one
file carried that tag. Node F would give it a **wrong** badge.

#### The ruling: it must work

The design chat argued for deferral — five albums in 506, one of the five wrong,
and 303 of the population unhelpable — and was **overruled**. Recorded as a
disagreement rather than smoothed over, because the reasoning on the other side
is the one that should govern:

- the design has always said the master arm is required rather than optional
  (`TODO.md` 2026-09-07, "ownership test needs BOTH sets"), and a route that has
  never once fired is not a design, it is an intention;
- a wrong answer at 1% is still a wrong answer, and the user asked for the plugin
  to be correct rather than cheap;
- and the 21 in bucket 2 are the real argument: twenty-one correct badges
  currently rest on the title route happening to agree, on a library where the
  master arm has never run. One of the five — *Aphex Twin* credited as *AFX* — is
  a case **no** title-or-artist rule could ever reach.

#### The governing assumption, stated because everything below follows from it

**SqueezeWax assumes a well-tagged library and a well-maintained collection, and
flags what deviates rather than guessing at it.** That is the sentence behind the
review queue's existence, and it decides the two rulings below: we do not widen
matching rules to absorb bad data, and we do not silently discard an album whose
data we cannot make sense of — we say so and let the user decide.

#### Ruling 1: fetch the release, store only what is ours to store

The fix is one `/releases/{id}` per identified release the collection does not
hold. What is **kept** is the **master id** — a bare identifier of the same class
as the release id already in `discogs_match`, which §9.5 calls "not Content in
any meaningful sense. Unconstrained; kept indefinitely."

Everything else the response carries — the track count, the credited artists, the
tracklist — is compared **in memory, at fetch time**, and discarded with the
response. What survives that comparison is a **verdict**: our own observation
about whether the identification is plausible, which §9.5 makes indefinitely
storable.

`discogs_release_cache` stays unwritten, as §9.5 requires. Both conclusions land
on `discogs_match`.

*This ruling was rewritten on 2026-09-28; see the errata at the end of this
section for what it first said and why it was wrong.*

#### Ruling 2: an identification the release contradicts goes to the queue

With track count and artists in hand, the covers folder answers itself: three
tracks against ten, *Various Artists* against *The Police*. Such an album gets a
**review reason** rather than a badge — the plugin says it cannot reconcile the
tags with the release and lets the user re-match or reject, exactly as it does
for every other case it will not guess at. It is not silently badged, and it is
not silently dropped.

What "contradicts" means precisely — how far a track count may differ before it
is a contradiction, and what to do about artists on a compilation — is the new
step's survey, not settled here.

#### What is explicitly not being done

- **Reading every track of every album.** Rejected on measured cost: 19–137 ms
  per file on a NAS, roughly 9,000 reads over this library, ten to fifteen
  minutes added to every scan. `Library.pm:230-244`'s two-candidate rule and its
  citation of §3 stand.
- **Reading tracks until a mismatch appears.** Considered 2026-09-28 and
  rejected: a consistent album produces no mismatch, so it would read *every*
  track before concluding nothing is wrong. The well-tagged majority would pay
  the whole cost and the rare bad folder the least — the wrong distribution.
- **Matching on Discogs `namevariations`.** §15.19's caution stands: an alias is
  a distinct entity, a name variation is a misspelling, and 48 of them for one
  artist is a corpus, not a synonym list.

#### Cost, as measured rather than estimated

475 distinct release ids across all 479 identified rows; 328 of them are already
looked up and on disk from the measurement. A cold library of this size would pay
roughly 11.5 minutes of throttled requests, once. **It cannot live in the
scan-time sync**, which §15.18 part 10 bounds at 120 s; it wants a resumable,
throttled, off-scan backfill. §13.8 rejected a per-album lookup **per sync**;
this is one lookup per release, once, cached — a different trade, and the new
step's plan must make that argument explicitly rather than assume it.

#### Where the evidence is thin

One library, one collection, 203 items. Five albums is a small sample to design
from, and the three shapes they fall into were each seen once. The 2-LP
double-badge and the covers folder are single observations, not patterns.

#### Errata, 2026-09-28: this section first proposed caching Content

As first written, §15.19 and §15.20 both said the fix would cache release data —
master id, track count and credited artists — in `discogs_release_cache`. **That
contradicts §9.5**, which reads the Discogs TOU's "may not cache or store the
Content longer than is necessary" clause, declines to rely on the CC0 reading
that might excuse track listings, and concludes:

> **Store conclusions, not Content.** … `discogs_release_cache` — raw payload.
> Content, unambiguously. **Consequence: `discogs_release_cache` is not written
> in v1.**

§9.5 had also already prescribed the right shape, in advance and in terms:

> "request count bounded by user actions → live; bounded by library size →
> background job writing a conclusion" … "one release fetch per matched album is
> library-size-bounded, so it becomes a background job storing its *comparison
> result* — our observation, indefinitely storable — not the payload."

**The mistake was the design chat's**, made by proposing a cache shape without
re-reading §9.5 — which the table's own comment in `Schema.pm` points at. It was
caught while writing step 8c's survey, before any code existed. Recorded here
rather than fixed silently, because a decision record that quietly changes its
mind about a terms-of-use question is worth less than one that shows it did.

Nothing of substance is lost by the correction: the master id is storable, the
verdict is storable, and the evidence for the verdict was never needed after the
comparison. The corrected step is smaller than the one first proposed.

### 15.21 Ruling 2 is dropped, and the cross-track rule replaces it

**Decided 2026-09-28**, on two measurements. §15.20's ruling 1 — derive the master
id — stands unchanged. Ruling 2, the plausibility verdict built from release data,
is **dropped**, and the identification problem it existed for is solved more
cheaply and earlier.

#### The criterion, and the answer

Ruling 2 was held pending a measurement with the criterion stated in advance:
**how many albums carry consistent tags across their candidate tracks, yet name a
release the album cannot plausibly be?** If near zero, drop it.

**It is zero.** 475 requests over 11 minutes measured 464 consistently-tagged
albums against the release their own tags name:

| | albums | share |
|---|---|---|
| within 10% of the release's track count | 433 | 93.3% |
| half to 90% | 28 | 6.0% |
| below half | 2 | 0.4% |
| more local than release | 1 | 0.2% |

Both below-half albums are **correct**, and both are one *disc* of a multi-disc
release: *Best Of Blue Note 01* is 12 tracks against a 139-track, 15-disc box
whose **first disc holds exactly 12**, and *Isolar* is 6 against a 2-disc release
whose **second disc holds exactly 6**. Of 25 albums where no artist agrees, 22 are
artefacts of the L2 rung rather than disagreements about which record it is, and
the 3 genuinely unrelated ones all sit at a **perfect 1.000** track fit — which is
evidence the identification is right and the artist string unusual.

So a release-fit rule has nothing here to catch. Every threshold below 0.5 flags
exactly one album, and it is a false positive.

#### The cross-track rule, adopted instead

Measured the same day, with no Discogs requests at all: of 764 albums, **467 have
both candidate tracks telling the same story, 2 are tagged-then-untagged, 3 carry
two different release ids**, 82 carry no tag, 24 have a single local track and 186
are all-remote.

`Importer.pm:479-494` stops at the first candidate that answers, so cross-track
disagreement is invisible today. Comparing the two candidates — **both halves,
different ids and tagged-then-untagged alike** — costs five albums on this library
and catches, at identification time and at zero request cost, the case that
started this: the `Cover Versions/` folder (album 3421) carries **two different**
release ids, 793593 and 369197. All four `Cover - …` albums are reached by it.

The measurement's own script had a defect — two conflicting candidates compared
equal and would have counted as agreeing — found and corrected by Claude Code;
the corrected script measured zero conflicts and reproduced the original counts
exactly, so the numbers stand.

#### A premise that was wrong, and survived three hand-offs

Hand-offs 18, 20, 21 and 23 all describe the *Kinetik* discs as "2 and 3 tracks
against a full release", and treated them as the case any fit rule must not flag.
**Against the release their tags actually name, the fit is exact** — 2 of 2 and 3
of 3, ratio 1.000, surviving every threshold. The framing came from hand-off 18,
which compared those albums to the **collection entry** reached via a shared
master — a different object from the tagged release — and the design chat carried
it forward three more times without checking.

Recorded because this project's rule is that an inference must not become a fact
by repetition, and this one nearly did: it was the "must not flag" case around
which two hand-offs' rule design was built.

#### Releases disappear: 404 is an ordinary outcome

**New, and it binds step 8c.** Three of 479 identified albums (0.6%) name releases
Discogs no longer serves: `GET /releases/{id}` returns **404** for releases
1312977, 1688770 and 2944017, all on `strict` rows. Any release fetch in 8c must
treat a 404 as an ordinary answer — no master available, no retry, no error state,
and no reason to look again until the album's release id changes.

#### Two things measured against existing decisions

- **§13.10.4's L2 rung has a number now.** Its recorded cost — stopping below the
  leading-article rung — is **7 albums** on this library, whose files are tagged
  `Future Sound Of London, The` (verified as the user's own `contributors.name`,
  not an LMS artefact). They disagree on artist wherever the title route is
  consulted. Pre-existing and already accepted; M2 only priced it.
- **An all-remote album has no track count to compare.** Album 3533 is 18 remote
  tracks, 0 local, manually linked to a 10-track release, so its "fit" reads 0.00
  and means nothing. Any future rule keyed on track count must exclude all-remote
  albums (§15.11).

#### Where the evidence is thin

One library, 464 albums, one person's tagging with one tagger. It says ruling 2
earns nothing **here**; the failure it would have caught — tags consistent across
every track yet naming the wrong record — is narrower than "badly tagged" and was
never observed.

The deeper finding is structural rather than statistical: **the box-set disc is
the real shape in this data.** 3221, 2919 and both *Kinetik* discs are each one
LMS album standing for one disc of a larger release. Any rule keyed on track count
will meet them, and the test that distinguishes a disc from a mis-identification —
does some single disc of the release hold exactly this album's track count — needs
the **tracklist**, which §9.5 says we do not keep. So release-fit rules are
awkward for this project by construction, not merely unnecessary today.

### 15.22 Step 8c: how the master is derived, and what a cross-track disagreement does

**Decided 2026-09-28**, in the step 8c survey and the plan written from it
(`plans/build-order-step-8c-master-arm.md`). §15.19 establishes the defect,
§15.20 the ruling that it must be fixed, §15.21 what was dropped. This is how.

#### Three columns, because "we looked and there is nothing" must be storable

Migration 6 adds `derived_master_id`, `derived_from_release_id` and `derived_at`
to `discogs_match`. Three rather than one, because the pair of the first two
expresses four states and the middle one carries most of the weight:

- all NULL — never looked;
- both ids set — looked, found;
- `derived_from_release_id` set with a NULL master — **looked, and there is no
  master**. Without this state the 29 masterless releases on the reference
  library, and the three whose releases Discogs has deleted, would be re-fetched
  on every run forever;
- `derived_from_release_id` unequal to the row's `discogs_release_id` — stale,
  because the tags now name a different release. Re-derive.

The derived value is kept **separate from `discogs_master_id`**, which remains
tag-only. A tag is the user's assertion and ours never silently overwrites it,
and when tags change we need to know which of the two to re-derive. Both are
regenerable, so §2a is unaffected.

#### The job: bounded, yielding, and triggered by the sync

Server-side, in a new `Derive.pm`, because `API/Async.pm` is the collection
client and the ownership pass must stay request-free.

- **At most 30 requests per run**, one a second, re-armed a minute later while
  work remains — half Discogs' documented 60 a minute, leaving room for a manual
  sync.
  **Forward note (2026-10-20): amended by §15.50.** The pause between runs is
  15 s, the job keeps a reserve of 10, and a 429 waits one window.
- **It yields**: it never starts while a sync is running, and stops when the
  shared rate accounting reports nothing left.
- **Triggered from `_syncDone` on success and from nothing else.** No startup run
  and no interval: §15.15 part 1's rule that this plugin makes no unattended call
  to Discogs on a schedule holds, because the job's work is bounded by a library
  that only a scan changes, and a settled library makes it do nothing at all.
- **404 is an ordinary outcome** (§15.21): logged at info, recorded as "no master",
  never retried until the tags change. 401 stops the run and says nothing — a
  rejected token is the sync's to report (§15.15 part 2, §15.18 part 4).
- **One shared rate state.** `API/Async.pm`'s module-level `$rateState` moves to
  `API.pm` so both consumers share it. *Named cost:* it touches the sync and its
  assertions in a step otherwise not about the sync. Two independent throttles
  against one budget is how a 429 arrives that nobody can explain.

#### Node F uses the derived master only when it is not stale

`_decide` computes the effective master as the tag-derived one if present, else
the derived one **and only when `derived_from_release_id` matches the row's
current `discogs_release_id`**. The `$master != 0` guard is unchanged. **The pass
never writes the derived columns** — §15.4 stands: it derives ownership and a
review reason, nothing else.

#### A cross-track disagreement is a conflict, and the album loses its release id

`Importer::_examine` stops at the first candidate that answers, so an album whose
two candidate tracks name different releases is identified from whichever came
first. It now reads both and compares them. **Both halves count as disagreement**
— two different ids, and one tagged with the other untagged — as decided
2026-09-28 on M1's measurement of five albums in 764.

A disagreement routes to the existing `_recordConflict`, which already does the
right things: `review_reason = 'conflict'`, sticky until the tags are fixed, no
snapshot, and **a NULL release id on a fresh conflict** with an incumbent
preserved otherwise (§3a). The consequence is the point: with no release id the
album never reaches node C, so no ownership is derived from contested tags and
node F cannot badge it. The `Cover Versions/` folder that node F would have
badged wrongly becomes a queue item instead, at zero request cost, before
ownership is ever derived.

**One reason value, not two.** The column's job is "these tags are contested" and
the remedy is the same either way. What differs is the message, and that is
display: the queue must distinguish "these two files name different releases"
from "only some of these files carry a Discogs tag", and name which file said
what. §15.17 part 3 is the precedent — a message that tells the user something
untrue about their library is worse than a missing feature.

#### §9.5, in three parts, because two of them have been conflated

- **Reading every local file of an album** — rejected on measured cost
  (ten to fifteen minutes per scan), not on terms grounds.
- **Reading a Discogs payload in memory** — permitted, and this step does it once
  per release.
- **Storing it, or anything Content-shaped from it** — forbidden.

A master id is storable: §9.5 puts a bare identifier in the same class as the
release id already in `discogs_match`. And, recorded so it is not re-derived
wrongly: a **per-disc test is permitted at fetch time**, storing only its verdict.
§15.21's remark that such a test "needs the tracklist, which §9.5 says we do not
keep" is right about keeping and wrong if read as "cannot be computed". Ruling 2
was dropped because there was nothing to catch.

#### Why this is not what §13.8 refused

§13.8 replaced per-album Discogs searches with collection-first ownership. This
adds per-release lookups, which is that shape, so the difference is argued rather
than assumed: **once per release ever, not once per sync**; bounded by identified
albums rather than by the library; what is kept is a bare identifier, so it is
never re-fetched to stay fresh; and it buys what collection-first cannot — the
collection names the masters the user owns, and nothing in it gives the master of
a release they do **not** own, which is exactly node F's question. Measured: 475
requests, 11.0 minutes, on a cold library of this size; zero on a settled one.

#### Where the evidence is thin

Every figure here comes from one library of 764 albums and a 203-item collection,
tagged by one person with one tagger. Five albums justify the master arm and five
justify the cross-track rule. Both are small numbers, and the second rests on an
assumption stated in §15.20 — a well-tagged library, with deviations flagged
rather than absorbed — which a differently-kept library would not satisfy.

#### As built, 2026-09-29 (`2683f2a`..`b5c7f8a`, 0.0.0.12)

Seven commits plus a package, in the plan's order. Suites 1459 → **1754**. One
plan error, one narrowing, three decisions the plan did not make, and one
assumption that did not hold.

**The plan's trigger was wrong, and would have shipped group A dead.** The plan
said the job is armed "from `Plugin::_syncDone` on success, and from nothing
else". On any server where step 8b's scan-time sync works — the normal case —
`_syncDone` is **never reached**: the scan writes a `'scan'` marker, and
`_syncTick`'s §15.18 part 8 skip returns before a sync is started. So the job
would have run only where the scan-time sync had failed or never ran, which is
the opposite of the intent. It is now armed from **both** sites: `_syncDone` on
success, and that skip. The design chat wrote the rule without tracing the path
§15.18 part 8 had just created; Claude Code caught it while building.

**The manual button is deliberately not a third trigger.** Decided 2026-09-29,
with the cost named rather than discovered: on an already-scanned library, a
user who installs the plugin, enters a token and presses "Sync collection now"
gets badges immediately but **no derived masters until their next rescan** — so
roughly 1% of albums stay unbadged until then. Accepted because both arming
sites follow a scan, and a scan is what changes the library; the remedy, if it
ever matters, is a third call in `Settings.pm`'s success path, since arming is a
timer rather than work and the job already yields to a running sync.

**Re-arming is narrowed to pacing stops.** The plan said "re-armed a minute later
while work remains". As built it re-arms only when the run stopped for **pacing**
— the per-run cap, a sync in flight, or a spent budget — and not after an error
and not during a scan. A persistent 500 would otherwise become a one-a-minute
timer against a third party, which §15.15 part 1 forbids in spirit. A scan ends
in `['rescan','done']`, which reaches a sync, which arms the job.
**Forward note (2026-10-20): amended by §15.50.** A 429 is now a pacing stop
too: it re-arms after one window, at most twice in a row (§15.50 item 4). The
reserve is a pacing stop, and a spent budget or the reserve re-arms after the
rest of the window rather than after a fixed pause (§15.50 items 2, 3).

**Three decisions the plan left open:**

- **An unreadable file is not a voice.** `Tags->readTrack` returns an empty hash
  when a file cannot be read and a populated one for a readable file with no
  Discogs tag, so the two are distinguishable — and only the second counts as a
  candidate that disagrees. Without this, an album whose second file sits on an
  unmounted disc would become a `conflict` and lose its release id: a wrong
  answer produced by a mount point. Such an album is treated as the
  single-candidate album it has temporarily become.
- **A write refused after the request ends the run.** Otherwise the selection
  query hands back the same release — nothing was recorded — and the run spends
  all 30 requests re-asking one question whose answer it cannot keep.
- **Two outcomes beyond the plan's five are tested:** no response at all, and a
  200 whose body will not parse.

**What the plan assumed that did not hold.** §2.3 said the "Show tags" action
"already re-reads that album's candidates on demand and needs no change". It did
need one: `Queue::_readTags` carried its **own copy** of the candidate loop, and
that copy was already one revision behind the importer's — it stopped at
`last if %$decision` where the importer stopped at id-or-conflict. For the page
to show what the importer saw, the comparison moved into
`Tags::examineCandidates` and both callers now use it. The file's own comment
already said a second implementation was not an option; the second implementation
existed anyway, which is the more useful finding.

Also: `schema-check.pl`'s "a version-N+1 file refuses this plugin" assertion moved
with the schema version. That is the assertion following the version, not a
behaviour change.

### 15.23 Step 8c on hardware: node F fires, and a logic change has no way to say "re-decide"

**Observed 2026-09-29** on the reference server (0.0.0.12), nine checks, all
passing — one of them only after an invalidation the round had to ask the owner
to run. That requirement is the finding.

#### What worked

- **Node F fired for the first time in this project's history.** 2927, 2974, 3022
  and 3023 moved from `absent` to `version`; `version` 50 → 55, `absent`
  306 → 301. *Gling-Gló* — hand-off 18's proof that the master arm had never run —
  badges and left the review queue. All four kept `state = candidate`: node F
  badges, it never promotes.
- **The job armed from the skip path**, in the same millisecond as
  `_syncTick`'s "the scan already synced" line. Had the plan's original trigger
  shipped, that line would never have been followed by anything.
- **It finished and then stopped asking.** 475 distinct releases, 476 requests,
  18 runs, zero 429s; 442 rows with a master, 37 recorded as having none, **0
  pending** afterwards. A settled library costs one query and no request; one new
  album cost 0.39 s and a single request. One fetch settled every album naming
  that release, including the 2-LP set filed as two albums.
- **404 was quiet**, three times, exactly as §15.22 requires: an info line, a NULL
  master recorded, and never asked about again.
- **Nothing Content-shaped was stored.** `typeof()` over all 506 rows yields
  integers and nulls only, and `discogs_release_cache` held 0 rows all round.
- **The cross-track rule produced every shape this library can make**, on copies:
  two ids, tagged-then-untagged, both untagged, and an agreeing pair that stayed
  identified. Both message shapes render distinctly behind "Show tags".

#### The finding: group B could not reach the albums it was built to catch

`_canSkip` (`Importer.pm:466-474`) skips any album whose file mtimes are
unchanged, so an ordinary rescan re-examines **nothing** — `examined 0, skipped
764` on this library. Group B therefore applies only to new and changed albums,
and **every identification made before 0.0.0.12 is exempt from the rule that
would have rejected it**.

Measured consequence, and it is worse than a missing improvement: between
0.0.0.12 being installed and the invalidation being run by hand, **album 3421 was
badged `version` — reported as owned** — on the strength of tags the same build
recorded as contested on a copy of the identical files. Group A acted on an
identification group B was never allowed to look at. One album went from a wrong
`absent` to a wrong badge.

The only lever that forces re-examination is §3b's `Match->invalidateStrict`, and
it is reachable **only as a side effect** of changing the tag-name *set* on the
settings page. Once run, it settled everything in 63.9 s: five conflicts
recorded, 3421 back to `absent` with `review_reason = 'conflict'`, and `version`
55 → 54 with that one row the only mover.

**Decided 2026-09-29: a logic version, checked at startup.** A constant in the
code and a stored counterpart; when the code's is newer, `invalidateStrict` runs
once and the value is recorded. A migration was considered and rejected as the
*general* mechanism: it catches only logic changes that happen to carry a schema
change, and the common case carries none. The cost is one full re-examination per
logic change — 63.9 s over 578 albums here, of which the second candidate read is
about 30 s. Built as step 8c's follow-up.

#### Two things this plan got wrong

1. **§2.2's protection argument does not apply to the albums that matter.** The
   plan says a cross-track disagreement "leaves the album with no release id, so
   node C skips it". True of a **fresh** album only: on an existing one
   `_recordConflict` deliberately keeps the incumbent id (§3a), so the row still
   carries an identification derived from the very tags now marked contested, and
   its derived master besides. What actually removes the badge is
   `Ownership.pm:419-423` — a row whose `review_reason` is `conflict` is treated
   as **untagged**, skipping nodes C, D **and F**, leaving only the title route.
   That is **§15.16 part 4**, built at step 8 for TODO 2026-09-19, and it is what
   makes step 8c safe on a pre-existing library. Group B alone would not have
   been enough, and it would be easy to conclude otherwise from §2.2.
2. **§5's cost estimate is out by a factor of 2.3.** "475 requests, 11.0 minutes"
   counted request time and omitted the 60-second re-arm between runs. Measured:
   **25 min 18 s** over 18 runs. The shape is `runs × 90 s`, not `requests × 1 s`.

Also corrected: plan §6 check 5 says "all four `Cover - …` albums". **Five** carry
Discogs tags; one of the five has no tag on either candidate the importer reads,
so four conflicts is the right expectation for the wrong reason.

#### The manual button is not blocked during a derive run

Asked during the round and decided the same day: **no**. The round produced the
evidence — a press mid-run cost the job one re-arm cycle, the sync was served in
1.9 s, and no 429 occurred anywhere. The job takes about a third of the budget by
design, so there is nothing to serialise; the 429 guard is §15.22's shared rate
state, not mutual exclusion. Three further reasons: `Derive.pm` already declines
to make the button a *trigger* because "it has a user waiting on a page", which
argues equally against making the button wait; the button already refuses during
a scan, and a second refusal would leave it dead through exactly the half hour
after a large scan when someone would press it; and the job has no UI, so "busy,
try later" would name something the user cannot see, wait on or hurry
(§15.17 part 3).

**Recorded, not built:** a derive session is wholly invisible. On this library the
badges kept changing for 25 minutes after a scan with nothing on any page saying
why. An informational line — "deriving masters: 226 of 475" — would answer that
without taking the button away. `TODO.md` carries it.

#### Where the evidence is thin

One library, one round. The reachability gap was found because this library's NAS
is read-only, which made `_canSkip` impossible to work around — on a writable
library it might have gone unnoticed for much longer, which is an argument for
the finding rather than against it. Whether a wipe-and-rescan would re-examine
anything is **inferred from reading, not tested**: `album_key` and
`source_timestamp` both survive a wipecache, so it should not help.

### 15.24 The logic version: how a rule change says "re-decide"

Built 2026-09-29 as step 8c's follow-up, against §15.23's finding. Decided
there; this records the mechanism as built.

#### The shape

A version for the identification **decision rule**, stored beside the rows it
describes, and compared at every server start.

- `Plugins::SqueezeWax::Tags::LOGIC_VERSION` — a constant in the code. First
  value **2**; 1 is everything up to and including 0.0.0.11, before step 8c's
  cross-track comparison.
- `discogs_meta`, migration 7 — a two-column key/value table, `key TEXT PRIMARY
  KEY` and `value TEXT NOT NULL`, with two accessors on `Schema` and no third.
  The key in use is `logic_version`.
- `Plugin::_checkLogicVersion`, called from `initPlugin` immediately after
  `Schema->init` — after, because registering the postDBConnect handler is what
  forces the reconnect that runs the migrations
  (`Slim/Utils/SQLiteHelper.pm:396-400`), so `discogs_meta` does not exist
  before it.

Five cases, each asserted in `scripts/plugin-check.pl`:

| stored | `discogs_match` | what happens |
|---|---|---|
| absent | empty | record the current version, silently — a fresh install has nothing to re-decide, and an invalidation line would describe work that did not happen |
| absent | has rows | treat as 1: invalidate, then record |
| < current | — | invalidate, then record |
| = current | — | nothing at all: no write, no log. Every normal start |
| > current | — | nothing, and warn once. Its rows were decided by a rule this code does not have, and the marker is **not** overwritten with the lower number |

A sixth, added in the build and not in the hand-off: **the schema being unusable
is unknowable, not a fresh install.** `_checkLogicVersion` returns before
anything else when `Schema->isReady` is false. Without that test the fresh-install
branch would catch it — `meta` and `hasAnyRow` both answer undef — and while
`setMeta` would refuse the write anyway, the reasoning would be an accident
rather than a decision.

#### Why the constant is in Tags.pm

`Tags.pm` is the rule: `decide`, `candidateKeys` and `examineCandidates` are
what "how identification decides" means. `Schema.pm` owns storage, and
`user_version` already versions that; a logic version there would sit beside a
number that means something else entirely. Both processes load `Tags.pm`
already, so nothing is paid for the placement.

The constant's comment names what a bump is for — which files are read, how a
file's tags become a verdict, how several files' verdicts are combined, what
counts as a disagreement — and what it is not: a message, a log line, a
refactor that decides identically. Adding a tag *name* is not one either; that
is a pref, and `Settings.pm` already invalidates when the set changes. A
needless bump costs every user a full re-examination (63.9 s over 578 albums on
the reference library) and is recoverable; a missing one leaves wrong
conclusions with nothing to dislodge them, and is not.

#### Why the marker is in the database and not a pref

A pref would say "already done" beside a `squeezewax.db` restored from before
the logic change, leaving stale identifications that nothing would ever
re-examine. The marker has to travel with the rows it describes, and a
restored database carries its own.

`discogs_meta` is **ours**. A key we chose and a number we wrote are our own
conclusions, not Content, so §9.5 is not engaged — the same footing as
`ownership` or `derived_master_id`, and unlike anything a Discogs payload
carries. Like `discogs_sync_state` (§15.18 part 7), it is a table the design
doc's §10 does not list: §10 is v1's data model as designed, and these two are
mechanism added since, recorded here.

#### The rule that matters: record only on success

`Match->invalidateStrict` returns **undef** when `_writeOk` refuses — a scan is
running, or the schema is not usable (`Match.pm:105`). Recording the version
after a refusal would skip the invalidation **forever**: the same silent,
permanent wrong answer §15.23 describes, reached by one extra step. So a
refusal leaves the stored value alone, logs one info line saying it will be
retried, and the next start tries again. The suite drives exactly that
sequence — refuse, assert nothing was stored, allow, assert the invalidation
happens.

Zero rows is **not** a refusal. An invalidation that touched nothing still
happened, and its version is recorded; otherwise it would repeat at every start
for the life of the install.

#### What it does not do

**It does not start a scan.** Invalidation NULLs `source_timestamp` on strict
rows and deletes the strict no-match rows; the re-examination happens at the
user's next scan, exactly as a tag-name change behaves today. A plugin that
started a scan on the user's behalf would be a new behaviour of its own, and
this was not the place to introduce one. The consequence, stated: between a
logic-change upgrade and the next scan, the library is un-re-examined and its
badges are whatever the old rule concluded — better than §15.23's state, where
that was permanent, and worse than immediate.

It also does not run in the scanner. `Plugin.pm` is never loaded there
(`Slim/Utils/PluginManager.pm:204`), and repair is the server's job, as DDL
already is.

#### New this step

`Match->hasAnyRow` — every row of `discogs_match`, not the identified ones
`hasAnyStrictMatch` asks about, because the question is whether this plugin has
ever concluded anything here. An ownership-only row (`match_tier` NULL since
migration 3) answers yes and `hasAnyStrictMatch` answers no, which is why it is
a second sub rather than a reuse. undef when the schema is unusable: "cannot
tell", not "no".

#### Observed on hardware, 2026-09-29 (0.0.0.13, reference server)

Three checks, all passing, on the library §15.23 had left in a known state.

- **The upgrade did exactly one thing.** `user_version` 6 → 7, `discogs_meta`
  created, and a single `_checkLogicVersion` line naming both versions and the
  578 rows `invalidateStrict` returned — 47 ms from "plugin loaded". Afterwards
  `source_timestamp` was NULL on all 478 strict rows, `discogs_no_match` empty,
  and the marker stored at 2. It fired even though the tag-name trick had been
  run by hand earlier the same day, because the marker did not exist then.
- **The library came back to where §15.23 left it.** The re-examination took
  61.2 s (against 63.9 s), recorded the same five cross-track conflicts with the
  same incumbent ids, and ended at 506 rows, `exact` 150 / `version` 54 /
  `absent` 302, six queue items. A column-by-column diff of all 506 rows against
  the pre-upgrade capture found **one** changed column anywhere: `matched_at` on
  the 473 re-identified rows. `source_timestamp` came back byte-identical, as did
  every release id, derived column, ownership and reason. That is the property
  worth having — a forced re-decision that changes only what it must.
- **The second restart did nothing at all**: no migration, no invalidation, no
  log line, marker unchanged; and the next scan examined 0 of 764 in 0.079 s. The
  one-off is a one-off.

**The refusal path is unreachable on a settled install, by design.**
`_checkLogicVersion` reaches `invalidateStrict` only when the stored version is
older than the code's, so once the marker is current a restart during a scan
returns at the "nothing at all" branch and never attempts a write. Provoking it
would mean hand-writing the marker backwards in a live database. It stays covered
offline in `plugin-check.pl`, and that is the right and only home for it —
recorded so "not run" is not later read as "untested".

### 15.25 Step 9: ownership in menus and a library view, not on artwork

**Decided 2026-09-29 (design chat)**, on the step 9 survey. Evidence: Phase 0
(hand-off 34) and an options survey (hand-off 35), both read against slimserver
`a670a38`, Material `47e31ed`, Spotty `68fd614` and Listen Later `ecb3622`. Plan:
`plans/build-order-step-9-badge.md`.

#### The finding that reshaped the step

**No skin lets a plugin draw on album artwork.** Verified for the Default UI and
Material; other skins not read. Each draws one cover icon, keyed on
`albums.extid`: core's Default template calls
`OnlineLibrary::Plugin->getServiceIcon` (`HTML/Default/xmlbrowser.html`, block
`itemIcon`), and Material reads a fixed list shipped inside Material
(`emblems.js`, `emblems.json`). The icon means "which service this album came
from". Spotty supplies only an image for the Default UI
(`addLibraryIconProvider`). Writing our own `albums.extid` was examined at the
owner's request and **rejected**: `extid` is the album's address
(`Slim/Schema/Album.pm`, `url`), Online Library's local-only views exclude any
album carrying one, and it would overwrite a streamed album's own. Design §4's
"skin-independent by design" was an intent that the source does not support.

#### Considered and not taken (hand-off 35)

Recorded so they are not re-proposed as new:

- **Our own album list carrying `extid` + our icon.** It works in the Default UI
  (any browse item's `extid` gets the registered icon), and Listen Later uses the
  pattern. But it only works inside our list, a second album browser; it takes
  the single icon slot, so a streamed album loses its service logo; and Material
  shows nothing unless it adds us to its list.
- **Painting the badge into the cover image.** Dispatch allows it: a plugin's raw
  URL handler runs before core's artwork handler (`Slim/Web/HTTP.pm`,
  `getRawFunction` before the `music/…/cover` branch). But the only bundled image
  library is `Image::Scale`, which resizes and cannot draw, and it would put every
  cover in every skin behind our code.
- **A marker in the title format** (`Slim::Music::TitleFormatter::addFormat`):
  text, opt-in, and Material does not use title formats for display (inferred).
- **A Material user script** (`prefs/material-skin/custom.js`): overwrites the
  user's own, and breaks on Material updates.
- **A fake "Owned" genre:** writes LMS's own tables and mislabels music.

#### Rulings

1. **v1 shows ownership in the album menu, the playing track's menu, and a
   "Records I own" library view**, each built once for every skin
   (`Slim::Menu::AlbumInfo` / `TrackInfo->registerInfoProvider`,
   `Slim::Music::VirtualLibraries->registerLibrary`). No artwork badge. The
   request for a hook goes to `TODO.md`.
2. **The view is a library, not an app.** A SqueezeWax app (the Listen Later
   pattern) is recorded as a future forerunner of Flow 2, v3.
3. **The menu appears on owned albums only**, `exact` or `version`.
4. **The menu carries no Discogs data**: one ownership line and a link. Both
   §9.6 notices go on the settings page. The owner first asked for the notice on
   the settings page only while keeping pressing details in the menu. That
   **breaks the terms' "directly next to any data" rule**, was put back to them
   as such, and they chose to drop the data instead. **Named risk:** this rests
   on reading "you own this" as our conclusion rather than Discogs data, and the
   terms class the collection as Restricted "Discogs User Data". `TODO.md`'s
   2026-09-07 question on the derived label is now load-bearing.
5. **Links: `exact` → release, `version` → master, only where a master id is
   already stored** (`Ownership::_effectiveMaster`). No migration; §14.10
   stands. A master search is deferred to v2, with the wantlist.
6. **Value → step 10. Re-match → not in the menu. No new settings.**
7. **The derive status line** goes on the settings page. Closes `TODO.md`
   2026-09-29 "a derive session is invisible".
8. **Artist-level badge: v3** (design §11).
9. **The settings-page link goes to the user's collection page, with the
   username stored** in `discogsUsername`: written by the server's existing
   identity calls, cleared on a token change. It is Restricted "Discogs User
   Data", and keeping it is accepted by the owner as necessary for the link
   (§9.5's necessity test). First decided the same day as "fetched per page view,
   never stored", and superseded by the owner.

#### Defaults from the plan, accepted at the plan review

- **Identity by `album_key`, never `lms_album_id`.** Found while writing the plan:
  the importer's skip and all-remote paths (`Importer.pm`, `startScan` loop) never
  refresh `lms_album_id`, and the pass never writes it, so it goes stale when LMS
  reassigns `albums.id`. Design §10 said otherwise and is corrected. Keyed on it,
  the menu and the view would show **the wrong album as owned**.
- **"This album on Discogs"**, never "your version": the stored master is the
  identified release's, which need not be the owned one's.
- **A "Records I own" entry under My Music**, as core's `LibraryDemo` does.

#### Where the evidence is thin

- Default UI's library picker, Material's handling of a plugin My Music node,
  Jivelite, iPeng and Squeezer: not read.
- The owner reports online-library logos on Jivelite. Jivelite `d43a20b`
  (piCorePlayer's source) has no such code. Unsettled.
- `https://www.discogs.com/master/{id}` and `/user/{name}/collection` are
  inferred URL forms, hardware checks.
- One library, one collection.

**2026-10-14:** Feature request drafted for Material (claude/material-feature-request.md in the design project), filed as a GitHub issue at CDrummond/lms-material: https://github.com/CDrummond/lms-material/issues/1288. Asks for a generic per-album plugin badge. Checked Material e85a897 and slimserver eb59bbf. Any badge is still blocked on the Discogs Restricted Data and attribution items.

### 15.26 Step 9 on hardware, and step 9b: links for apps, a line for players

**Observed 2026-09-30** on the reference server (0.0.0.14, hand-offs 41 and 44);
**decided the same day** (design chat, hand-off 43). Plan:
`plans/build-order-step-9b-menu-links.md`.

#### Step 9 on hardware: every check passes

- **The menu**, album and track, in Material, the Default UI and SqueezePlay, for
  `exact`, `version` with a master, `version` without, and `absent`.
- **Both Discogs URL forms settled:** `/release/{id}` and `/master/{id}` redirect
  to their slug pages; `/user/{name}/collection` is the collection page.
- **The view** appears in Material (My Music → Other), the Default UI and
  SqueezePlay. It reconciles exactly (204 = 204), rip and stream both present
  (§13.10.3).
- **Rebuild without a rescan**, in both directions, via "Sync collection now".
- **Nothing asks Discogs:** with `network.asynchttp` at DEBUG, and proven live by
  14 request lines during a rescan, 16 menu opens made **zero** outbound requests.
- **D1 proven:** a wipe-and-rescan moved every album id. 480 of 481 rows kept a
  stale `lms_album_id`, and menu and view stayed right. Keyed on the id, every
  album would have shown another's ownership. The other half, an album *taking*
  an old id, could not be provoked: LMS never reused one.
- **The delete guard held under a destructive wipe** (Spotty's token failed, so
  186 albums vanished): 25 verdict-only rows deleted, 0 identifications lost, the
  manual row orphaned rather than deleted, and all of it back on the next scan.

#### A defect reported and withdrawn: the log, not the code

Report 41 concluded that `['rescan','done']` no longer reached `_rescanDone`. It
did (44, direct observation: `_rescanDone` → `View::_build` twice →
`_syncTick` skip → `Derive::arm` → `View::_build`). What had stopped was the
**log**: after startup, the server's running level for every plugin-registered
category (ours, Spotty's and four others) was `ERROR`, while `log.conf` said
otherwise and was never rewritten. Two pieces of evidence were unsound and are
recorded so they are not reused: **unchanged `library_track` rowids** (a
composite-key table that is emptied and refilled restarts its rowids at 1, per
SQLite's documented rule, so a rebuild and no rebuild look alike); and **absent
log lines**, read without first checking the running level. Why plugin categories
revert is **unexplained**. ~~It is LMS behaviour, not ours~~, and `TODO.md` carries
the test that separates install from restart.
**Corrected 2026-10-12 (§15.28):** the revert did **not** reproduce on two later
install-and-restart rounds (0.0.0.15 on 2026-10-01, 0.0.0.16 on 2026-10-12):
`plugin.squeezewax` came up at the `log.conf` value both times. "Plugin categories
revert, core categories keep theirs" was one observation, generalised. The
2026-09-30 observation stands as made; its cause, and whether it is LMS's, is
unknown.

#### Settled against the design chat

**Jive-family skins draw service emblems.** A SqueezePlay screenshot shows
Spotify emblems on streamed albums. Jivelite `d43a20b` was the wrong place to
look. §15.25's badge ruling is unchanged: it is the same one-per-album,
`extid`-keyed icon. The upstream request now names three UIs.

#### Step 9b rulings (owner's requests 1–8)

1. **Release and master links**, each only where its id is usable. Replaces
   §15.25 ruling 5.
2. **Labels say what is true.** The release is "your pressing" only for `exact`;
   for `version` it is "the pressing your files name", which the owner does not
   own (node F). The master is "all versions".
3. **Links for apps that can open them, one line for players**
   (`Slim::Utils::Misc::canFollowWeblinks`, with non-menu mode and no-client
   treated as link-capable). Where no link exists, the line shows everywhere, so
   ownership never shows as nothing. **Named limit:** the function reads the UA
   of the app that last controlled the player, not the one asking.
4. **Pressing details → step 10**, as a submenu that fetches `/releases/{id}` only
   when opened, with "Data provided by Discogs" inside it. The pattern is core's
   "View tags" (`TrackInfo.pm` `infoTagDump` → `tagDump($client, $callback, …)`).
   This reverses §15.25 ruling 4 inside the submenu only. It is also how players
   get release information.
5. **Settings: a plain discogs.com link** beside the collection-linked notice.
6. **Linking the release actually owned → v2**, with the wantlist. Several owned
   versions of one record are the ordinary case, so it is a table, a migration
   and a reversal of §14.10. The ingredient exists: `_indexCollection` holds
   `masters` as a presence set, and a map is a small change.

### 15.27 The "Records I own" menu icon

**Decided 2026-10-01** (build prompt 49, hand-off 50 for the hardware checks).

#### Decision
One icon path serves all three UIs, using the FilterMusic convention:

- `SqueezeWax/HTML/EN/plugins/SqueezeWax/html/images/owned_svg.png`: 512×512 PNG
  for the Classic web skin and Jivelite. Core tile style, rebuilt from core
  `albums.png`'s frame.
- `SqueezeWax/HTML/EN/plugins/SqueezeWax/html/images/owned.svg`: 24×24 vector
  for Material, colour `#000`.
- In `View.pm` `registerNode`, `icon` and `jiveIcon` both become
  `plugins/SqueezeWax/html/images/owned_svg.png`. This replaces
  `html/images/albums.png`.

**Change from the supplied SVG:** `stroke="currentColor"` became `stroke="#000"`.
Geometry is unchanged.

#### Evidence
Refs checked (not the pinned `refs/`): lms-material `1988d4e` (2026-10-01),
slimserver `public/9.2` `f0a77cd` (2026-09-23), filtermusic_sb `914d0e7`
(2026-09-19).

| Claim | State | Source |
|---|---|---|
| Material's My Music reads node `jiveIcon`, else `icon` | verified (read) | lms-material `MaterialSkin/Plugin.pm`, `browsemodes` branch (~L1287-1290) |
| An icon ending `/albums.png` gets Material's built-in "album" icon. Other icons go to `mapIcon` | verified (read) | `html/js/browse-resp.js`, `parseBrowseModes` (~L2884-2903) |
| A path ending `_svg.png` is swapped for a same-named `.svg` | verified (read) | `html/js/icon-mapping.js`, `mapIconType` (L142-147) |
| Plugin SVGs are served via `/material/svg/<path>` with a plugin-path fallback | verified (read) | `MaterialSkin/Plugin.pm`, `_svgHandler` (~L3013-3021) |
| Recolouring replaces literal `#000`, and `fill`/`stroke` values matching `[#0-9a-fA-F.]+` | verified (read) | `_svgHandler` (~L3026-3032) |
| `currentColor` is **not** recoloured. The regex can't match it | verified (read) | same lines |
| An un-recoloured `currentColor` icon renders black, so it would be invisible on dark themes | *inferred* (browser default for SVG in `<img>`), not observed | - |
| Jive menu `icon` = node `jiveIcon` | verified (read) | slimserver `Slim/Menu/BrowseLibrary.pm` ~L699-701 |
| Classic skin uses node `icon` via `addPageLinks('icons')` | verified (read) | `BrowseLibrary.pm` L342 |
| Core My Music icons are 512×512 PNG, light tile with dark glyph | verified (file inspection) | `HTML/EN/html/images/albums.png` |
| The `_svg.png` + `.svg` pairing works on a real server | *inferred*. FilterMusic ships it (`install.xml` `<icon>`), but via the plugin-icon path, not `registerNode` | filtermusic_sb `CHANGELOG.md` 2.0/2.1.1 |
| Jivelite shows a node's `icon` URL rather than an `iconStyle` derived from `id` | *unverified*. Core comment says default nodes get an `iconStyle` by id. Behaviour for a plugin node with `jiveIcon` was not read in Jivelite source | `BrowseLibrary.pm` ~L694 |
| Jivelite/server resize of a 512 px plugin PNG | *unverified* | - |

#### Where the evidence is thin
- The rendering in all three skins is read from source, not observed running.
- Jivelite source was not checked at all.

#### Side effect
Material currently shows its own "album" icon for this node, via the
`albums.png` match. After this change it shows the custom glyph. This is
intended.

#### Not asserted offline
No check script reads `View.pm` source (`plugin-check.pl` stubs the module,
`menu-check.pl` loads it and calls `_build`, neither inspects `registerNode`'s
arguments), so the icon-path-to-file assertion was not added; a new script for
one assertion was out of the prompt's scope.

### 15.28 0.0.0.16 on hardware: step 9b, the menu icon, and the first new LP end to end

**Observed 2026-10-01 and 2026-10-12** on the reference server (0.0.0.15, then
0.0.0.16). Design-chat hand-offs 48, 51 and 55; Claude Code reports 49, 52–54 and
56; the owner's own checks.

#### Step 9b: every check passes

- **Default UI and Material**: `exact` shows "On Discogs: your pressing" and, where
  a master is stored, "On Discogs: all versions". `version` with a release shows
  "the pressing your files name" and "all versions". `version` with nothing stored
  shows the line "You own a version". `absent` shows nothing. No `rel`, no
  `nofollow`. The owner opened the links; all landed right.
- **SqueezePlay** shows the one text line (owner).
- **The named limit is real, observed three times on one player id** (text line
  ~15:58, both links ~16:15, text line 16:39, 2026-10-12, one build). The variant
  follows the player's stored controller UA (`canFollowWeblinks`), not the asking
  app. So a player check has no fixed expected answer: record the variant together
  with what last controlled the player.
- **Nothing asks Discogs, proven three ways**: with `network.asynchttp` at DEBUG,
  20 menu opens across five albums, both menus and both client variants wrote **0
  lines**, inside one minute bracketed by an independent 36-line-a-minute LAN
  heartbeat. A synchronous request would have tripped core's unconditional
  root-logger error (`SimpleSyncHTTP.pm` `new`); none in the log. `discogs.com`
  occurs 0 times in the log.
- The plain discogs.com link and both notices are present on the settings page.

#### The menu icon (§15.27)

- Files served; Material recolours the SVG (`stroke` follows the theme, no `#000`
  left); Material's My Music entry and the Jive menu item both carry
  `owned_svg.png`, with no `iconStyle`; the Default skin draws a resized 25/50 px
  copy, so the 512 px source resizes cleanly.
- **Owner, by eye:** Material is right in light, dark and a coloured theme;
  SqueezePlay and the Classic skin show the new icon. This answers §15.27's
  "unverified" Jivelite row: the node's URL is honoured.
- **Unreconciled:** report 52 rendered Classic's home page and found no `<img>` at
  all; the owner sees the icon in Classic. Probably two different pages. It
  changes nothing.

#### The first new LP, from rip to owned, with no "Sync now"

*Various – X-Mix-1 - The MFS Trip*: ripped, tagged with `DISCOGS_RELEASE_ID`
198756 and `DISCOGS_MASTER_RELEASE_ID` 56108 on all 13 files, added to the
collection, then one ordinary rescan. Predicted in writing before the scan, and
right in every particular: node C → D, `exact`, `confirmed`, no queue item. The
Various gate was never reached, because a tagged release in the collection is
decided before any artist test. Both links were present immediately: the master
comes from the tag. View 204 → 205, then the whole chain:
`_rescanDone` → view rebuilt → `_syncTick` skip → `Derive::arm` → view rebuilt.
Scan 2 min 58 s.

**A design-chat prediction was wrong, and the build session caught it before the
scan:** hand-off 51 expected a different-pressing album to stay unowned until the
next sync. That holds only for an album tagged with a release and **no master**;
a master tag is used at once (`Ownership::_effectiveMaster`, tag first).

#### Derive fetches masters the tag already gives — kept, with a trigger

The derive job fetched release 198756 and got master 56108, which the tag had
already supplied and which `_effectiveMaster` never reads while the tag is there.
This is the documented choice in `Derive.pm` (the comment above `$UNSETTLED`: "Rows
carrying a tag-derived master are NOT excluded", decided at 2 of 506 rows). It is
now 3 of 507. **Kept, decided 2026-10-12 by the owner.** It costs one request per
master-tagged release, once ever. Revisit trigger in `TODO.md`.

#### Core deletes track rows when the music share is offline

With `/mnt/nas-music` unmounted, opening a **track** menu deleted that track's row:
`Slim::Schema::find` → `_checkValidity` → `_hasChanged` treats a missing file as
changed, and on Linux core cannot tell an unmounted share from deleted files
(`Slim/Schema.pm`, the `XXX: Linux/Unix` comment). Seven rows were lost and
restored by the next rescan with the share back. It is core behaviour, and it is
not triggered by our provider: any track menu does it. A rescan with the share
offline would cost the whole local library. Album menus and the view are safe; they
never ask for a Track object. This is now a hardware-session rule (working
agreement §4.1).

#### D1 in ordinary operation

That same rescan refreshed `lms_album_id` on 17 rows and changed nothing else on
any of the 506 existing rows (all identity and verdict columns diffed). Ids moved,
`album_key` held, no verdict changed.

#### Where the evidence is thin

One library, one player, one new LP, and it was the easy case (fully tagged, release
owned). The "release tag, no master tag" delay is still unobserved.

### 15.29 License, plugin name and display freshness

**Decided 2026-10-12**, design chat (`claude/research-license-name-freshness.md`).

#### License: GPL-2.0-or-later

`LICENSE` at the repo root is GNU GPL v2, fetched from
`gnu.org/licenses/old-licenses/gpl-2.0.txt`. It matches LMS (`slimserver`
`public/9.1`, `License.txt`, GPL v2; **verified**). The plugin ships no Discogs data
and no app key (§9.1), so no conflict with the API Terms of Use's licensing clause
is expected (**inferred**). Whether an LMS plugin must be GPL at all is a legal
question this sidesteps (**unverified**).

#### Plugin name

"SqueezeWax for Discogs" follows the "unique name + for Discogs" form in Discogs'
Application Name and Description Policy (effective 2019-12-11, **verified**
2026-10-12). **Not yet checked:** the name LMS actually displays, and any Discogs
logo use (`TODO.md`).

#### Display freshness (Terms of Use, API Use and Restrictions, item 5)

The stored ownership verdict (`discogs_match.ownership`) is the user's own
conclusion, not Discogs Content, so the 6-hour display rule does not apply to it.
Evidence, **verified by reading source, not run**:

- `View.pm` `_build`, `_ownedKeys`: "Records I own" is LMS's own album grid
  filtered by `ownership IN ('exact','version')`; no Discogs data is shown.
- `Menu.pm` `_itemFor`, `_links`: fixed plugin strings, or links to discogs.com
  release and master pages. `scripts/menu-check.pl` asserts that no menu item
  carries Discogs data.
- The only Discogs-origin values on screen are IDs in link URLs; the Terms list
  identifiers as CC0 Data.
- Consistent with §9.5 (store conclusions, not Content) and §15.15 part 1 (no
  scheduled calls).

**Where the evidence is thin.** The Terms list a user's collection as Restricted
Data (noted at step 9 phase 0), and Discogs has given no guidance on derived
verdicts. An optional confirmation through the Discogs Help Center was drafted
2026-10-12; date sent and answer to be recorded here. If Discogs disagrees, the
options are an "as of <last sync>" label, or a sync at most every 6 hours (which
reverses §15.15 part 1).

2026-10-12: asked Discogs Help Center, Request #1281019. Options offered if the verdict counts as Content: an 'as of <last sync>' label, or a sync at most every 6 h. Awaiting answer; the ruling above stands until then.

### 15.30 Settings during a scan; data left after uninstall

**Decided 2026-10-12**, design chat (`claude/records-0.0.0.17-strings-audits.md`).

#### Part 1 — settings actions during a scan stay refused (owner ruling)

All four actions (save tag names, Test token, Sync, Detect) stay refused while a
scan runs, as built: `Settings.pm:134`, `:228`, `:349`, `:458`, and
`settings.html` shows a notice instead of the buttons. Reasons:

- A sync started during a scan cannot write. Verified on hardware (TODO.md,
  step-8b check 4): `_writeOk` refused, "ownership pass declined".
- The scan runs its own sync (§15.18), so a manual one would spend requests for
  nothing.
- Test token would be harmless, but `Settings.pm:228` treats the refusal as a
  page convention, and a change is not worth it.

Correction for the record: the 2026-10-12 strings-round prompt said only saving
tag names was refused. The code refuses all four; the README follows the code.

#### Part 2 — no clean-up on uninstall (research, no change)

Read in `slimserver` `public/9.1` (local ref at `a670a38`; the design chat cited
`582a1b2`, which is not in the local ref), not run:

- **Verified:** uninstall is `Slim::Utils::PluginManager::_needsUninstall`
  (`PluginManager.pm:840-865`), at the next restart. It deletes the plugin's code
  folder (only under `InstalledPlugins`) and its `plugin.state` pref
  (`PluginManager.pm:31`, `:864`). Nothing else.
- **Verified:** LMS offers plugins no uninstall hook; the only lifecycle call is
  `shutdownPlugin`, at every server shutdown (`PluginManager::shutdownPlugins`,
  `PluginManager.pm:412-428`).
- **Verified (by the design chat; not re-read in this session):** MusicArtistInfo
  (`a5ea399`) stores its data in LMS's shared cache (`Slim::Utils::Cache`) and has
  no clean-up code.
- **Not checked:** TIDAL, Spotty and other third-party plugins. Evidence for
  "what most plugins do" is thin.
- **Inferred:** leaving data after uninstall is normal for LMS plugins, and a
  reinstall keeps all matches.

Consequence: SqueezeWax keeps `squeezewax.db` and its prefs (including the token)
after uninstall. No removal feature. Stored values are conclusions and
identifiers (§9.5), so no Discogs TOU issue. The sensitive leftover is the token;
users are told to revoke it on Discogs.

### 15.31 Step 10: release details and master details, fetched on open

**Decided 2026-10-12**, design chat (decision 61). Plan:
`plans/build-order-step-10-details.md`. Closes `TODO.md` 2026-09-13 "define the
minimum scope for on-demand marketplace lookup".

Phase 0, in five lines (full text: `plans/build-order-step-10-phase0.md`):

- `/releases/{id}` gives have, want, rating, `num_for_sale` and `lowest_price` in one call; `/masters/{id}` gives `num_for_sale` and `lowest_price`, and no have, want or rating.
- No endpoint gives sales history (last sold, low / median / high) or a highest price: checked across every documented read endpoint with a valid token.
- `lowest_price` on `/releases` and `/masters` comes in the account's currency, unlabelled, and ignores `curr_abbr`; `/users/{username}` with the token carries `curr_abbr` (T1).
- A personal token is enough for every call step 10 makes: no consumer key or secret (§9.1 unchanged).
- LMS does not cache a menu list holding code-backed items (`Slim/Control/XMLBrowser.pm:342-347`), so each open fetches live and no cache is needed; core's "View tags" (`Slim/Menu/TrackInfo.pm` `infoTagDump`) is the menu pattern.

Decision 61, verbatim. Rulings 12 and 14 are superseded and kept for the
record; ruling 13 sits after 17, as in the source.

Input: `claude/session-brief-step-10.md`, the owner's answers in this chat, two
screenshots of discogs.com (release and master "For Sale" + "Statistics" boxes,
Violator), and Phase 0 data (`claude/phase0-step-10.md`). Folds into a new
decisions §15.31 and design §4 / §7 / §9 / §11 edits. Closes `TODO.md`
2026-09-13 "define the minimum scope for on-demand marketplace lookup".

#### Rulings

1. **"Release details" submenu**, only on `exact` albums (the owned pressing).
   - It holds the pressing info plus the release **Statistics**: **Have, Want,
     Avg rating, Ratings, and "N for sale, from €X"**.
   - It fetches only when opened, with "Data provided by Discogs" inside it.
     This is §15.26 ruling 4 extended to include the statistics.
2. **"Master info" submenu**, on owned albums (`exact` or `version`) where a
   master id is usable (`_effectiveMaster`).
   - It holds basic master facts plus **"N for sale, from €X"**.
   - The same fetch-on-open and notice rules apply.
   - Which "basic facts" to show is picked from what `/masters/{id}` returns
     (Phase 0): title, year, artists, genres, styles, tracklist, main /
     most-recent release.
3. **Estimated value is removed.** It is not a separate item.
   - This supersedes decisions §15.25 ruling 6 and design §4's "moves to
     step 10".
4. **Dropped (owner: "better done at the Discogs site"):** design §7's
   expandable full listing, its filters and sort, and design §9 "Marketplace
   preferences". These are dropped outright, not deferred.
5. **This is the last v1 feature.** The public beta follows step 10 (`TODO.md`
   v1 release checklist).

#### Amended by Phase 0 (owner, 2026-10-12, after the full authenticated call set)

6. **Not shown, because the API doesn't provide them:** Last sold,
   Low / Median / High, highest price ("to €Y"), and master Have / Want /
   rating. Verified across every documented read endpoint with a valid token
   (`claude/phase0-step-10.md`).
   - This replaces ruling 3's earlier "Low / Median / High covers value".
7. **Master Have / Want are not added up from versions** (owner).
8. **Price suggestions are not in v1** (owner chose "API basics only").
   - The endpoint works for the owner's account. Not designed, not deferred.

#### v2 (record only, not designed)

- **Master info for albums the user does not own.** The owner first asked for it,
  then placed it in v2. → GitHub #9, owner undecided (2026-10-17).
- **Menus for owned versions.** This keeps step 9b ruling 4 (§15.26). Inferred
  blocker: the owned pressing id for a `version` album may not be stored
  (`claude/plan-step-9.md` §0.2 D2, citing §13.2). Not checked in code.
- **"Add to Discogs wantlist".** Owner, 2026-10-12. Design §11 already lists the
  wantlist and add-to-wantlist as v2/v3, and this places it in v2. Unverified:
  whether the personal token allows writing to the user's wantlist.

#### Binding and unchanged

On demand only, with link-out and no checkout (design §7). Nothing is stored
(§9.5). The notice sits next to the data (§9.6). The top-level menu never fetches
(§15.28). Personal token only, no shipped key or secret (§9.1): verified
sufficient for every call step 10 needs.

**§9.1 "Application registration" is done.** Owner-confirmed 2026-10-12: the
registered Discogs app is SqueezeWax's. Its key and secret are not used and not
committed; §9.1 needs them for nothing except Discogs' breaking-change emails.

#### Rulings after Phase 0 part 2 (owner, 2026-10-12)

9. **Budget spent → say so, don't wait.**
   - When `API->rateWait` is non-zero at open, the submenu shows one line:
     "Discogs is busy, try again in N s".
   - No Discogs request is made.
10. **Players get the notice plus the address as plain text.**
    - The notice is "Data provided by Discogs", followed by the page address
      (e.g. `discogs.com/release/593568`) as plain text. Apps that can open
      links get the real hyperlink (§9.6).
    - **Unverified** whether plain text meets the TOU's hyperlink requirement.
      Follow-up: add this question to Help Center request #1281019.
11. **No cache.** Design §7's "cache briefly" is dropped. LMS doesn't cache
    menus with code-backed items, so every open fetches live
    (`claude/phase0-step-10.md` part 2).

**[Superseded by ruling 14, itself superseded by ruling 15.]**

12. **Currency: always the label Discogs gives, never assumed.** Owner,
    2026-10-12.
    - **Release details:** 2 requests, `/releases/{id}` and
      `/marketplace/stats/{id}`. The price and its currency come from the
      stats call.
    - **Master info:** 2 requests, `/masters/{id}` and
      `/marketplace/stats/{main_release}`. The currency label is borrowed
      from the stats reply.
      - **Inferred:** both calls default to the user's currency (docs:
        `curr_abbr` "defaults to the authenticated users currency").
      - **Verified only for the owner's account:** EUR without `curr_abbr`,
        and the master's 1.33 equal to the labelled €1.33.
    - **Not done:** a currency hard-coded in the code, or a currency setting.
    - **Hardware check:** a second account whose currency is not EUR, if one
      is available.

**[Superseded by ruling 15.]**

14. **Supersedes ruling 12: one request per open, currency from Settings.**
    Owner, 2026-10-12: "I don't like a 30 seconds wait time for a menu."
    - Release details = `/releases/{id}?curr_abbr=C`.
    - Master info = `/masters/{id}?curr_abbr=C`.
    - The price is labelled with C. No `/marketplace/stats` call.
    - **C, from the Settings page:** a currency choice from the 12 codes the
      docs list (USD, GBP, EUR, CAD, AUD, JPY, CHF, MXN, BRL, NZD, SEK, ZAR).
      - **Default:** the user's own Discogs currency if it can be fetched,
        otherwise USD until the user sets one (owner).
      - **Fetchable? Unverified, but likely:**
        - ExDisco's docs (third-party, v0.1.0) list `curr_abbr` in the
          `/users/{username}` profile;
        - the TOU lists "currency for Our Marketplace" as Discogs User Data;
        - the official docs' Profile section was not retrievable;
        - `joalla`'s unauthenticated profile fixture has no `curr_abbr`.
        - **Inferred:** it is returned only when logged in as that user.
    - **Precondition T1 (owner, at a terminal): blocks phase A.**
      1. `/users/{username}` with the token: does it carry `curr_abbr`?
      2. `/releases/593568?curr_abbr=USD` and `/masters/63790?curr_abbr=USD`
         with the token: does `lowest_price` change away from 1.33?
      - **Why it blocks:** if Discogs ignored `curr_abbr`, the label would be
        silently wrong. There is a warning sign: an unauthenticated
        `/releases/593568?curr_abbr=EUR` returned 1.49, not the EUR 1.33. So
        the parameter was ignored, at least without a token. (Observed.)
    - **If the currency is fetched:** it's Discogs User Data (Restricted). It is
      kept only as the pref's default value, by the same necessity reasoning as
      the username (plan-step-9 D4). Not decided yet: whether it's read at token
      test or at sync.

15. **Supersedes ruling 14's currency setting: the label comes from the
    Discogs profile, stored at sync** (owner, 2026-10-12, after T1).
    - **T1 (verified, raw):**
      - `curr_abbr` is ignored by `/releases` and `/masters` (USD, EUR and JPY
        all gave 1.33);
      - `/users/{username}` with the token returns `curr_abbr: EUR`.
    - **So there is no currency setting.** It could only mislabel prices.
    - **Still one request per open**, with no `curr_abbr` parameter.
    - **Pref `discogsCurrency`** is written where `discogsUsername` already is:
      - `Settings.pm:406-413` (token test);
      - `API/Async.pm` `_gotIdentity` (`:424-447`).
      - In each, one extra `/users/{username}` request follows the identity
        call.
      - **A failed profile call never fails a sync or a token test.** The old
        value is kept.
    - **Cleared** with the username when the token changes (`Plugin.pm:64-78`).
    - **Not written by the scan-time sync** (`API/Sync.pm`). It does not store
      the username either. **Inferred:** prefs set in the scanner process may
      not reach the server. Unverified.
    - **No currency known yet:** the price is not shown, only "For sale: N".
      An unlabelled price is never shown.
    - **Terms, stated:** the TOU lists "currency for Our Marketplace" as
      Discogs User Data (Restricted). It is stored as the username already is,
      as necessary to label prices (plan-step-9 D4's reasoning).
      - **Accepted risk:** if the user changes currency on Discogs, the label
        lags until the next sync or token test. It is the same class of
        freshness question as §15.29 and the open Help Center request
        #1281019.

16. **Labels and order** (owner, 2026-10-12). The links stay at the top level
    (plan §1). Each link is followed by its own submenu.

    | | `exact` | `version` |
    |---|---|---|
    | 1 | Discogs: Browse your pressing (link) | — (ruling 17) |
    | 2 | Discogs: Show your pressing's details › | — (no release submenu, ruling 1) |
    | 3 | Discogs: Browse all versions (link) | Discogs: Browse all versions (link) |
    | 4 | Discogs: Show master details › | Discogs: Show master details › |

    - **Version wording keeps §15.26 ruling 2:** "your pressing" is said only
      for `exact`.
    - "pressing's" gets an apostrophe; the owner's draft read "pressings".
    - **Players** (no links): the ownership line ("You own a pressing" /
      "You own a version"), then the submenus in the same order.
    - **The "Discogs:" prefix** is a descriptive reference, like today's
      "On Discogs:" (§15.26, design §1). No logo.
    - **Replaces step 9b's link strings** `MENU_LINK_OWNED`, `MENU_LINK_FILES`
      and `MENU_LINK_MASTER`. The meanings are unchanged. Hardware rechecks
      the wording on screen.

17. **Version albums get no release link** (owner, 2026-10-12). This amends
    ruling 16 and §15.26 rulings 1–2.
    - **Owner's rule:** a link may name only a pressing the user owns.
    - **For `version` albums,** the release in the files is not owned, and the
      owned one is not stored. **Verified:** `API.pm:455-460`,
      `Schema.pm:625-631`, §13.2.
    - **So, for `version`:** "Discogs: Browse all versions" (link) and
      "Discogs: Show master details ›" only.
    - **Players, or no master:** the ownership line, as today. Ownership is
      never shown as nothing (§15.26).
    - **`MENU_LINK_FILES` ("the pressing your files name") is retired.**
    - **v2:** a link to the version the user owns, which needs that release id
      stored. It already exists as "menus for owned versions".

13. **Fields (owner, 2026-10-12):**
    - **Release details:** label + cat. no.; format, country, date; genre /
      style. Barcode and matrix lines are not shown.
    - **Master info:** year; genre / style. Number of versions is not shown,
      because it would cost a third request.

#### Still open for Phase 0 (not data)

- Whether Have / Want / rating count as Restricted Data, and how the six-hour
  rule applies to fetch-on-open.
- The menu pattern: core's "View tags" (`TrackInfo.pm` `infoTagDump`), read at
  the slimserver pin.
- ~~Requests per open (one or two).~~ Settled by ruling 14: one per open.
- The throttle: `API.pm` `rateWait` / `noteResponse`.

### 15.32 The rate wait counts down

**Decided 2026-10-13**, design chat (review of hand-off 62, owner's answers).

**The rate wait counts down.**
- `API->rateWait` returns the seconds left in the current window, measured
  from the last counted reply. It used to return a stored figure that only a
  new reply could change.
- Found in hand-off 62's report. A submenu that saw "busy" never cleared it,
  and Derive could re-arm forever on the same figure. That second case was
  inferred from code.
- Grounded in Discogs' documented window: it resets after 60 idle seconds
  (§9.2).
- `accountRequest` is unchanged.
- Also from that report:
  - the player notice shows `discogs.com/{release|master}/{id}`;
  - the README is brought up to step 10.


### 15.33 Hardware findings of step 10

**Decided 2026-10-13**, design chat (hardware report 64, owner's answers).

1. **A 2-minute in-memory hold for the details submenus.** Amends §15.31
   ruling 11, "no cache".
   - Report 64, check 6f: scrolling inside Release details in Material made 10
     Discogs requests in 13 s, and master details 3. LMS does not cache a list
     that holds code references (`Slim/Control/XMLBrowser.pm:342-347`), so each
     fetch Material makes calls the code again.
   - `Details.pm` holds the last **successful** reply per (kind, id), trimmed to
     the fields the lines use, with its arrival time, for `HOLD_SECONDS = 120`.
     Within the hold an open makes no request, even while `rateWait` is
     non-zero. After it, the next open fetches and replaces the held reply.
   - Labels, the currency and the player or link variant come from the current
     open, never from the hold. Errors, busy and no-token results are never
     held. At most 50 replies; the oldest is dropped at the 51st. The whole hold
     is emptied when the token changes (`Plugin.pm`'s `setChange` handler),
     because it may be another account. Nothing goes to disk.
   - **Terms reading, inferred:** a hold this short, in memory, serving the same
     user's open menu, is "necessary to provide a service" (TOU item 5), and far
     inside the six-hour display rule.
2. **A currency hint on the Settings page**, at the owner's request: "Prices are
   shown in EUR, your Discogs account's currency." with the stored code, or "The
   currency for prices is not known yet. Press Test token." when empty. Rendered
   from the pref; nothing is fetched for it.
3. **No username in the log.** The two "collection sync starting" INFO lines
   (`API/Async.pm`, `API/Sync.pm`) no longer name the Discogs user. No other log
   line in `SqueezeWax/` printed the username or the token.
4. **Check 10a's expectation was wrong.** Saving an unchanged token fires no
   change handler (`Slim/Utils/Prefs/Base.pm:95-98`), so the currency label
   correctly stays.
5. **The logging rule.** Never raise `network.asynchttp`, `network.http` or
   any logger that prints HTTP requests above ERROR while a Discogs request can
   happen: at DEBUG LMS logs the `Authorization` header with the token. Count
   requests with `ss` and our own log line. Recorded in working agreement
   §4.1.


### 15.34 Prices section on the Settings page

**Decided 2026-10-13**, design chat (hardware report 66, owner's request).

1. **The currency hint gets its own section**, "Prices", directly after the Sync
   section, out of the token block (`PLUGIN_SQUEEZEWAX_CURRENCY`, `_DESC`). The
   body reads "Currency: EUR" from the stored code, or "Not known yet. Press Test
   token, or Sync collection now." naming both, because both learn it (§15.31
   ruling 15). Rendered from the pref; nothing is fetched. This replaces item 2
   of §15.33's wording.
2. **Report 66 results (0.0.0.20):**
   - verified: the hold, the hint, and that no log names the user or token;
   - not run: the Material scroll check (the owner accepted the CLI evidence) and
     the §15.32 countdown check.

3. **Amended 2026-10-13, after a hardware test of 0.0.0.21:** with a correct
   token, Test token did not bring the currency back. The wording now requires a
   collection sync: the unknown line reads "Not known yet. Press Sync collection
   now." and the description names the sync alone. The Test token request is
   unchanged; why it does not store the label is open (`TODO.md`).


### 15.35 Test token no longer learns the currency

**Decided 2026-10-13**, design chat (inferred from reading, not run), owner's
choice.

1. **Cause** of §15.34 item 3. Test token stored the currency, and the page's
   own save then cleared it:
   - `_tokenTested` / `_testCurrency` set `discogsUsername` and
     `discogsCurrency`;
   - `_finishTestToken` calls `SUPER::handler`, and every submit carries the
     hidden `saveSettings=1`, so core saves `pref_discogsToken`
     (`Slim/Web/Settings.pm:156-162`);
   - a token that differs from the stored one fires the `discogsToken` change
     handler (`Plugin.pm:67-90`), which clears the username and currency just
     written. `_syncNow` avoids this because it saves the token first.
2. **Only the server sync learns the currency.** `_testCurrency` and its call
   are removed, so Test token is back to one request (the identity). This
   amends §15.31 ruling 15, which named both, and closes §15.34's open item.
   `API.pm`'s `_profilePath` and `_profileCurrency` stay: the sync uses them.
3. **Known and accepted** (the owner chose this knowing it): with a token that
   differs from the stored one, Test token still sets `discogsUsername` and the
   same save then clears it, so the "Data provided by Discogs" collection link
   falls back to discogs.com until the next sync. The fix would be to save the
   token first, as `_syncNow` does. Recorded, not built.


### 15.36 Public beta: channel, reset, reporting

**Decided 2026-10-13** (owner, design chat). Closes `TODO.md` "2026-10-12: a
public beta waits for step 10", items 1, 2 and 4.

#### Part 1 — testers use `master`; promotion merges a checked build

**Revised the same day** (owner): `master`, not a separate `beta` branch.

- **Testers' URL:**
  `https://raw.githubusercontent.com/d5c0d3/lms-plugin-squeezewax/master/repo.xml`
  One URL through the beta, and through v1 too if v1 is served from `master`
  (see "Pages" below).
- **Why not a `beta` branch:** testers would have to change their repository
  entry at v1; and `master` is the default branch (verified: `origin/HEAD` →
  `master`), so its README is the repo's front page, which today has none.
- **`master`'s role:** still hardware-checked only (working agreement §5's
  merge gate is unchanged); it now also carries the build testers install.
  Rollback = the previous promoted build's commit on `master`.
- **Promotion merges; it never rebuilds.** `package-build.sh` bumps the
  version on every run (`:101-115`, verified), so a rebuild ships an unchecked
  version. The zip is copied byte for byte: version and sha survive because both
  describe the zip's bytes (verified on 0.0.0.23: `sha1sum` = `repo.xml` `<sha>`).
- **Scripted:** `scripts/promote-master.sh <version> <report-no>`, run on
  `v1-buildout`. It merges the package commit for `<version>` (message
  `Package build SqueezeWax <version>`, `package-build.sh:220`) into `master`
  with `--no-ff`, then fixes the two paths that must differ (dev-repo-workflow
  §2 "What actually merges at release"): `dist/` keeps only promoted zips;
  `repo.xml` is the package commit's with only the `<url>` branch changed to
  `master`. `master` is an ancestor of `v1-buildout` (verified, 298 commits
  behind at `8acbbb6`), so the first merge has no conflicts. It refuses a
  version not above `master`'s current one. The owner pushes.
- **Guard:** `package-build.sh` refuses to run on `master`. Without it, a build
  on `master` would publish an unchecked zip to testers.
- **Forward only.** Migrations are one-way (`Schema::_migrate` refuses a newer
  file) and LMS offers only a higher version (dev-repo-workflow §1). A bad
  build is fixed by promoting a newer checked one.
- **Pages:** not needed now; raw URLs serve any branch. Whether v1 still moves to
  GitHub Pages (dev-repo-workflow §2) is **open**: doing so makes testers change
  URL once. Unverified whether LMS's official plugin list needs Pages.
- **Unverified:** how long GitHub's raw cache and LMS's repository cache delay a
  tester seeing a promotion (dev-repo-workflow §5 step 3).

#### Part 2 — the zip carries `LICENSE`

The zip had none (verified: `unzip -l` of 0.0.0.23). GPL-2 asks that recipients
get a copy with the program. `package-build.sh` adds the root `LICENSE` into the
packaged `SqueezeWax/`. Owner's choice; not legal advice. **Inferred** harmless
to LMS's loader; the next install on hardware confirms it.

#### Part 3 — manual reset, not Clear & rebuild

Clear & rebuild (§10) stays unbuilt for the beta. The README documents a manual
reset. What it rests on:

| Claim | State | Source |
|---|---|---|
| A missing `squeezewax.db` is created, then every migration runs | verified by reading | `Schema::postDBConnect` (ATTACH comment), `_migrate` |
| Fresh database records the logic version silently | verified by reading | logic-version table, "absent / empty" row |
| An album with no row is always examined, so one ordinary rescan re-reads all | verified by reading | `Importer::_canSkip` |
| The file sits in LMS's "Preferences Folder" | verified by reading | `Slim/Utils/SQLiteHelper.pm` `dbFile`; `Slim/Menu/SystemInfo.pm` `INFORMATION_PREFSDIR` |
| The prefs file (token etc.) is elsewhere: `plugin/squeezewax.prefs` | verified by reading | `Slim/Utils/Prefs/Namespace.pm` (`catdir($path, "$two.prefs")`) |
| `-wal` and `-shm` must go too | inferred (WAL mode; a stale `-wal` beside a new file is untested) | `Schema::_ensureWalMode`; working agreement §4.1 |
| Version badges return only after the next sync after Derive | **verified**, report 71 C5 (version stayed 50 until Sync collection now moved it to 54) | hand-off 71 |
| Whole reset is safe | **verified**, report 71 C–D | hand-off 71 |

**Lost:** manual links, review-queue decisions, "checked, no tag" records,
derived masters, last-sync marker, release ids kept on albums whose tags
conflict. **Kept:** token, username, currency, tag
names (prefs). Re-deriving masters costs one Discogs request per identified
release, rate-limited (measured 25 min 18 s for ~475, records-step-8c-hardware).

The reset is also the only way back after a downgrade (`_migrate` refuses a
newer file).

#### Part 4 — how testers report

GitHub Issues (enabled; verified by the owner 2026-10-13). Send: LMS version,
OS, SqueezeWax version, owned and queue counts, and only log lines from
`Plugins::SqueezeWax` (LMS prints the method name on each line,
`Slim/Utils/Log.pm` pattern `%M (%L)`), category `plugin.squeezewax`
(`Plugin.pm`) at INFO. Never the token. Never raise network logging (it prints
the token: working agreement §4.1). Other plugins' lines may hold secrets.

#### Part 5 — README names only the tester URL

The README names only the `master` URL; the dev URL stays in dev-repo-workflow
§5. A tester cannot pick the one-way dev channel by mistake.

#### Part 6 — Clear & rebuild moves to v2

Decided 2026-10-13 (owner). Of §10.1's three reasons, two are gone: the
duration margin and the 30-day expiry were never built (§10.2's 2026-09-18
correction). What remains — a tag-name change made outside the settings page
(§3b) not triggering a re-match — is rare, and the manual reset (part 3)
covers a bad state. Cost accepted: the reset loses hand-made matches, which
Clear & rebuild would have kept. **Unverified:** whether old "no match"
records still need clearing in today's code (`TODO.md` 2026-09-24 item).

#### Part 7 — single-folder rescans

Revised 2026-10-13: a single-folder rescan runs our importer and the scan-time
sync when tag names are set (`Slim/Control/Commands.pm` `rescanCommand` →
external `scanner.pl` run with `singledir` → `runScanPostProcessing`).
Observed, report 71 part E: `examined 0 … skipped 765`, sync 205 items in 4
requests, database unchanged. Inferred, not observed: a new album there would
be examined (nothing had changed, so nothing was). No README line needed. The
in-process `rescan album|track` path does not run it; not a user action
(records-step-8b).

#### Re-verification (Claude Code, 2026-10-13)

Each citation was located by symbol in `v1-buildout` and `refs/slimserver/`
(`public/9.1`). All hold except two, and one is a correction to part 7.

- **Held:** `package-build.sh` version bump (`NEW_VERSION`) and the commit
  message `Package build ${NAME} ${NEW_VERSION}`; `Schema::postDBConnect`,
  `_migrate` (the downgrade guard), `_ensureWalMode`; `Importer::_canSkip`;
  `SQLiteHelper` `dbFile`; `SystemInfo` `INFORMATION_PREFSDIR`;
  `Prefs/Namespace.pm` (`"$namespace.prefs"` under the prefs path); `Log.pm`
  pattern `%M (%L) %m%n`; `Plugin.pm` `category => 'plugin.squeezewax'`;
  `master` is an ancestor of `v1-buildout` (298 commits behind).
- **Default branch:** `origin/HEAD` is not set in this clone, so "`origin/HEAD`
  → `master`" does not resolve here. `git ls-remote --symref origin HEAD`
  reports `ref: refs/heads/master`, which is what the claim needed.
- **Part 7 does not hold as written.** The scanner does not skip post
  importers for a single-folder rescan. `Slim::Music::Import::launchScan` only
  appends the folder to the scanner's arguments (`$singledir`);
  `scanner.pl` then calls `runScan` and `runScanPostProcessing` unconditionally,
  and `runScanPostProcessing` runs every `post` importer. Our
  `Importer::startScan` reads neither `@ARGV` nor the folder, and its `use` gate
  is the token alone. So a single-folder rescan **reaches** our importer and
  examines every album, not only the folder's (inferred from reading, not
  observed on a server). In-tree support: `Slim::Plugin::OnlineLibraryBase`
  `initPlugin` returns early on a single-directory scan ("don't run importer if
  we're doing a singledir scan"), which it would not need to do if importers
  were skipped; `Slim::Control::Commands` `rescan` passes `singledir` to
  `launchScan`. The sentence "rescanning a single folder does not match
  albums" was therefore **not** added to the README or user guide; the decision
  needs revisiting in the design chat (`TODO.md`).

### 15.37 Branches, version numbers and channels — for all lines

> **Partly superseded by §15.43 (2026-10-15):** parts 1 (`v2-buildout` and
> `vN-buildout` rows), 2 (no minor series), 5 (migrations) and 6 (retirement).
> Parts 3, 4, 7 and 8 stand.

**Decided 2026-10-13** (owner). Replaces the open "v2 branch rules" question
(§15.36 TODO edit 6). Refines §15.36 part 1 (the tester URL is now the website).

#### Part 1 — branches

| Branch | Holds | Written by | Versions |
|---|---|---|---|
| `master` | what users install; the website | `scripts/promote-master.sh` only | copies of checked builds |
| `v1-buildout` | v1: betas, 1.0.0, then fixes | `package-build.sh` | `1.0.0bN` → `1.0.0` → `1.0.1`, `1.0.2` … |
| `v2-buildout` | v2; branched from `v1-buildout` when v2 work starts | `package-build.sh` | `2.0.0aN` (dev only) → `2.0.0bN` → `2.0.0` → fixes |
| `vN-buildout` | same pattern | | `N.…` |

#### Part 2 — version numbers

- `aN` = dev build, never promoted. `bN` = beta. Plain = release; the last
  digit counts fixes. No minor-version series: a milestone vN is `N.0.0`.
- **Never a hyphen.** `1.0.0-beta1` compares **equal** to `1.0.0` in LMS
  (verified), so an update would silently not be offered.
- Verified order: `0.0.0.24 < 1.0.0b1 < 1.0.0b9 < 1.0.0b10 < 1.0.0 < 1.0.9 <
  2.0.0a1 < 2.0.0a12 < 2.0.0b1 < 2.0.0`.
- Every build takes the next number (dev builds included), so gaps between
  promoted versions are normal.
- The version's first number must match the branch's line (`v1-buildout` →
  `1.…`), enforced by `package-build.sh`.

#### Part 3 — channels: files on `master`, served by the website

- **Website:** GitHub Pages from `master`, root folder. Enabled by the owner
  2026-10-13. **Verified (WebFetch 2026-10-13):** the README is the home page
  (`jekyll-readme-index`), its link to `docs/user-guide.md` resolves to
  `docs/user-guide.html` (`jekyll-relative-links`), `repo.xml` is served, and the
  owner installed from it. Plain on purpose; a designed page is later work.
- **`repo.xml`** = normal users. URL:
  `https://d5c0d3.github.io/lms-plugin-squeezewax/repo.xml`. During the v1 beta
  it carries the beta, so testers move to 1.0.0 with no URL change. This is the
  URL for the official plugin list at v1 (raw and Pages URLs are both accepted
  there: 32 raw and 16 Pages of 75 in `LMS-Community/lms-plugin-repository`
  `include.json` @ `91b3ffd`).
- **`beta.xml`** = beta testers, from the first beta after 1.0.0. When no beta
  is running it names the same release as `repo.xml`. Built when first needed,
  not now.
- A user configures **one** URL, never both.
- The zip `<url>` stays on `raw.githubusercontent.com/…/master/dist/` (works:
  0.0.0.24 installed from the website on 2026-10-13). Not moved to Pages.
- `_config.yml` excludes internal files from the website, so a Liquid-like `{{`
  or `{%` in them cannot break the site build. Inferred risk; `TODO.html` was
  being published on 2026-10-13.

#### Part 4 — merges

Only promotion writes `master`. A fix lands on the **oldest line still receiving
fixes**, then is merged forward into every newer line the same day. Never
backward. `master` is never merged into a build line.

#### Part 5 — database and prefs migrations

Only the **newest** line adds a migration (`Schema` `@MIGRATIONS`, `$prefs->migrate`).
Once `v2-buildout` exists, a v1 fix that needs one ships in v2 instead.
Why: one number would mean two different changes on different servers — one-way
and silent (`Schema::_migrate` refuses a newer file).

#### Part 6 — retirement

When `N+1.0.0` is promoted, line N gets no more fixes: `repo.xml` offers one version.

#### Part 7 — project knowledge

Follows `master` plus the newest active line.

#### Part 8 — test servers (recorded, not needed now)

A server that installed a newer line's build cannot run an older line again
(migrations are one-way). Once the reference server runs v2 dev builds, v1 fixes
need a reset ("Starting over") or a second LMS. `TODO.md` item.

#### Re-verification (Claude Code, 2026-10-13)

The verified order was re-run with `Slim::Utils::Versions->compareVersions` from
`refs/slimserver/` (`public/9.1` @ `a670a38`): every adjacent pair in
`0.0.0.24 < 1.0.0b1 < 1.0.0b9 < 1.0.0b10 < 1.0.0 < 1.0.9 < 2.0.0a1 < 2.0.0a12 <
2.0.0b1 < 2.0.0` compares -1, and `1.0.0-beta1` vs `1.0.0` compares 0. No pair
differs from the text above.

### 15.38 First-run help, live progress, scan labels, master-job recovery — before announcing

**Decided 2026-10-13** (owner). Ships as 1.0.0b2; the announcement waits for it.

1. **Empty tag names are shown.** While `discogsTagNames` is empty the settings
   page says so, at the top: only title-and-artist matching runs, so no exact
   pressing can be found; enter the tag name or press Detect. Why: production
   (a fresh install) ran with no tag names, nothing said so, and the importer was
   silently off (`Importer.pm` `use`, `Tags.pm` default list; report 74).
2. **A first-time hint.** Until the first collection sync has ever completed, the
   page shows the order of first steps: token, tag names, save, then a library
   rescan — LMS **Basic Settings → "Rescan Media Library" → "Look for new and
   changed media files"** (labels verified, slimserver `public/9.2` `strings.txt`
   `SETUP_RESCAN`, `SETUP_STANDARDRESCAN`; page `HTML/EN/settings/server/basic.html`).
3. **Status lines update without reloading.** While the "Master releases" line
   or the "scan is running" notice is shown, the page refreshes those lines (and
   the last-sync line) every 10 s by fetching the page itself in the background
   and replacing only those elements. It never reloads the page, never submits
   the form, and never touches what the user typed. It stops when neither line
   is shown. Owner: "progress is there but changed only when refreshing the page."
   No Discogs request: the page render issues none (Settings.pm comment at the
   derive block: "no request: it is one count"; Claude Code re-verifies the whole
   GET path).
4. **Scan labels carry the plugin name:** "SqueezeWax: Discogs matching",
   "SqueezeWax: Discogs collection sync".
5. **README "First-time setup"**: a numbered list (install, token, tag names or
   Detect, save, rescan, wait for "Master releases" to finish, press Sync
   collection now once — the last step because a version badge waits for a sync
   after Derive, verified report 71 C5). Tags move out of "For good results":
   they are needed for exact pressings. All "new and changed music" wording →
   LMS's own "Look for new and changed media files".

6. **"Sync collection now" also starts the master job** when its sync succeeds.
   **Reverses** the step 8c rule (comment above `Plugin.pm` `_deriveMasters`:
   "The manual button is deliberately NOT a trigger"). Why: on production
   (Docker, 2026-10-13) the job sat at "0 of 471 — waiting"; the button did not
   restart it (verified: code, and the owner's log shows a button sync at
   17:02:01 with no derive line); only a rescan did (observed by the owner).
   The reason for the old rule — a user waiting on the page — does not apply:
   the job starts after the button's sync has finished, and it already yields to
   syncs and scans (`Derive::_yieldReason`). §15.15 part 1 still holds: it runs
   only after a completed sync, never on a timer of its own.
7. **The "Master releases" line tells the truth.** "waiting" only while a
   re-arm timer is actually set (`Derive::_stop` with a `%REARM_ON` reason);
   otherwise "paused — resumes after the next library scan or Sync collection
   now". `Derive` exposes whether a resume is scheduled.
8. **Why the first run never started on production is unverified.** The owner's
   server log shows no SqueezeWax line after 17:02:26 although the job later ran
   at Info — the same symptom as report 71 and the open `TODO.md` item on missing
   info lines (decisions §15.26). Candidates, not established: the start-up tick
   met a running scan (three `_rescanDone` lines in 1.3 s, "library scan in
   progress"), or the first request failed. Items 6–7 make either recoverable
   and visible.

**Not done (recorded):** a settings-page button that starts a scan — a new
feature, v2 (`TODO.md`).

#### Re-verification (Claude Code, 2026-10-13)

- **The two LMS labels** were re-read in `refs/slimserver/` at `public/9.1` @
  `a670a38` (`slimserver.pl` `$VERSION = '9.1.2'`), not `public/9.2` as cited
  above: `strings.txt:6797`/`:6801` `SETUP_RESCAN` EN "Rescan Media Library",
  `:6872`/`:6876` `SETUP_STANDARDRESCAN` EN "Look for new and changed media
  files", `:14986`/`:14990` `BASIC_SERVER_SETTINGS` EN "Basic Settings". Same
  words as cited. `SETUP_STANDARDRESCAN` reaches the page through
  `Slim/Music/Import.pm:88` (`%scanTypes`) and `Slim/Web/Settings/Server/
  Basic.pm:150-151`; the select is `HTML/EN/settings/server/basic.html:84-92`.
- **Where a scan label is shown.** A progress row's label is never named in our
  code: `Importer.pm` and `ScanSync.pm` create rows named
  `plugin_squeezewax_match` / `plugin_squeezewax_ownership`, and LMS builds the
  label as `string( name . '_PROGRESS' )` (`Slim::Utils::Strings::string`
  upper-cases the token, `Strings.pm:526`). Two readers: the scan progress page
  (`Slim/Web/Pages/Progress.pm:37`, `HTML/EN/progress.html:3`,
  `HTML/EN/ajaxProgress.txt:4`) and `serverstatus`'s `progressname`
  (`Slim/Control/Queries.pm:3727`), which the web UI's scan status shows
  (`HTML/EN/html/SqueezeJS/UI.js:2127`); other skins were not read. Changing the two `_PROGRESS` strings changes both.
- **Item 3, the GET path.** A GET of the page with no parameters reaches
  `Settings::handler`, which tests `detectTagNames`, `syncNow`, `testToken` and
  `saveSettings` in turn; none is present, so it goes straight to
  `SUPER::handler`. There (`Slim/Web/Settings.pm:135-285`) the only branches
  that act are `doRescanNow` (`:139`), and `saveSettings` for each pref
  (`:156-171`, and the message at `:198`); neither parameter is sent. The
  rest builds page values and calls `beforeRender`, which reads prefs,
  `Tags->tagNames`, one `COUNT(*)` for the queue, `Async->status` (one marker read), `Derive->progress` (one count),
  `Derive->isRunning` and `->isResumeScheduled` - none issues a request or
  writes. One caveat, not new: `handler` calls (and the base class may call,
  `:189`) `Slim::Music::Import->stillScanning`, which, only if the external scanner
  process has died, cleans up and notifies `['rescan','done']`
  (`Slim/Music/Import.pm:736-743`), and that notification can lead to a
  fallback sync a minute later. Every load of this page already does the same,
  and so does LMS's own `serverstatus` (`Queries.pm:3719`), which the web UI
  polls, so the refresh adds no path that was not there.
  The refresh drops the page's own query string on purpose: a `doRescanNow=1`
  there would start a scan.

### 15.39 Settings page: always-live status, disabled buttons — 1.0.0b3

**Decided 2026-10-13** (owner). 1.0.0b2 is **not promoted**; 1.0.0b3 replaces it.
Why hold: nobody but the owner runs a beta yet, and b2's notice was not visible
in Material (report 76 A4 point 2), so b2 would be promoted with a known gap.

1. **The page polls whenever it is open and visible**, not only while something
   is pending. b2 polled only if the page loaded with the Master line or a scan
   notice (`settings.html` `if (active())`), so an idle page never noticed a scan
   starting (report 76 A4 point 1). Pause while `document.hidden`; resume on
   `visibilitychange`. Same request as b2: one GET of the page itself, every 10 s.
   - **Safe to poll while idle — verified by reading**: the GET path writes
     nothing and sends nothing to Discogs (report 75's reading, §15.38). The one
     side effect, `Slim::Music::Import->stillScanning` notifying `['rescan','done']`
     for a dead external scanner, fires **once**: it calls
     `scanningProcess(undef)` before notifying (slimserver `public/9.2` @
     `eb59bbf`, `stillScanning`). So polling cannot cause repeated syncs.
2. **During a scan, buttons are shown disabled (greyed), with the notice beside
   them**, instead of being removed. Owner preference (report 76 A4 point 4).
   The server-side refusal when an action is submitted during a scan stays.
3. **Detect's result appears without a reload**: its status/result area joins the
   refreshed regions, provided it holds no field the user types into.
4. **Notices must be visible in Material and in the Default skin.** b2's scan notice
   was in the template but not seen in Material; cause unknown. The no-tag-names
   and first-steps notices are rendered as a setting's *title* with an empty
   description (`settings.html` b2, `WRAPPER setting title=… desc=""`) — a long
   sentence in a title slot may also render badly. Render all notices as body
   text in a visible block; confirm in both skins on hardware.
5. **The "Refused to set unsafe header Referer" console lines are not ours**
   (report 76: SqueezeWax sets no Referer; probably Material's own script).
   Inferred, not confirmed; recorded, not acted on.

#### Re-verification and what was built (Claude Code, 2026-10-13)

- **`stillScanning` clears before it notifies — confirmed**, in `refs/slimserver/`
  at `public/9.1` @ `a670a38` (`slimserver.pl` `$VERSION = '9.1.2'`), not
  `public/9.2` @ `eb59bbf` as cited in item 1: `Slim/Music/Import.pm:736-741`.
  If the scanning process is blessed and not alive, it calls
  `scanningProcess(undef)` (`:737`) and `setIsScanning(0)` (`:738`), cleans up
  the progress rows (`:740`), and only then notifies `['rescan','done']`
  (`:741`). The next call finds no process object and skips the block, so the
  notification fires once per dead scanner whatever the number of GETs.
- **How Material shows this page** (read in CDrummond's `lms-material`,
  `master` @ `5ff153b3632a4766ef4f77f3193fe884f1696fef`, 2026-10-12):
  - In an **iframe** (`html/js/iframe-dialog.js`, `<iframe id="embeddedIframe">`),
    served under `/material/…`. Material's `skinconfig.yml` names **Classic** as
    its skin parent, so the page goes through the EN templates and the
    `setting` / `settingGroup` / `settingSection` blocks of
    `HTML/EN/cmdwrappers:383-405` — there is no Material or Classic override of
    them.
  - Inside the iframe it loads `html/css/classic-skin/mods.css` (via
    `skin.css`). Its rules that bear on this page: `#statusarea {display:none}`;
    `.msk-is-non-touch .hiddenDesc` hidden, with `addHelp()` turning each
    `setting` description into a help button; `input:disabled { opacity:0.7 }`
    (so a disabled button is greyed in Material by Material's own rule); and,
    from 1000 px up, `.settingGroup { padding-left:278px }` with
    `.settingGroup .prefHead { position:absolute; width:250px; text-align:right }`
    (wider breakpoints widen it to 350 px).
  - **What that explains:** b2's no-tag-names and first-steps notices sat in
    the `prefHead` title slot with an empty description, so on a desktop-width
    Material window each long sentence was laid out in a 250 px right-aligned
    column that takes no room in the flow. Fixed: both are now body text in a
    bare `settingSection` (core does the same, `settings/server/basic.html:46`).
  - **What it does not explain:** b2's invisible scan notice. It was a plain
    `<div>` inside `.prefs`, and no Material rule hides such a div — its colour
    and background rules (`mods.css` `.settingSection div` → `var(--text-color)`)
    keep it readable, and `hideSections()` removes only sections the user lists
    in Material's own `LMS_SETTINGS_HIDE` setting. **Unknown**; b3's hardware
    check decides (`TODO.md`).
- **What b3 builds** (`settings.html`; `Settings.pm` unchanged): the loop is
  armed on every load and re-arms after every fetch, failed ones included; a
  tick while `document.hidden` fetches nothing and stops the loop, and
  `visibilitychange` to visible fetches at once and restarts it (not while a
  fetch is in flight, which re-arms itself). The request and the region swap
  are b2's. The three buttons are always rendered, with
  `[% IF scanning %]disabled[% END %]` — core's form for its rescan button
  (`settings/server/basic.html:92`) — and the notice after them; Sync now is
  also disabled while a sync runs, beside the existing "sync is running" line.
  Detect's progress and result are a sixth region, `swxDetectResult`, which
  holds text and tables only.

- **2026-10-14 (owner): keep Test token and Detect disabled during a scan; item 2
  stands.** Enabling Test token would also need its own scan-time hint, removing
  the server refusal (`Settings.pm` `_testToken` ~l.354-356), and settling whether
  a token saved mid-scan affects the running scan (it saves `discogsToken` via
  `SUPER::handler`; `Slim/Web/Settings.pm:156-162`). Not worth it.

### 15.41 Promotion: TODO.md conflicts — 2026-10-14

- **Cause:** PR #1 (`site`, `84019ca`) edited master's `TODO.md`; the promotion of
  1.0.0b4 aborted on it (report 83 B), because `promote-master.sh` allowed
  conflicts only in `repo.xml` and `dist/`.
- **Rule:** `promote-master.sh` takes the package commit's `TODO.md` on a conflict,
  but only after a line check: every non-blank line added to master's `TODO.md`
  since master's last "Promote SqueezeWax" commit must appear verbatim in the
  package commit's `TODO.md`. Any missing line aborts the merge, is listed, and
  the script stops.
- **Rule:** any branch merged into master copies its `TODO.md` edits to
  `v1-buildout` first (as was done for `site`).
- **Verified 2026-10-14:** all lines master added at `84019ca` are present in
  `1585466`'s `TODO.md` (13 non-blank lines, plus one blank, 14 in all; the
  script prints "13 master lines confirmed present").

### 15.40 Settings page poll interval 5 s — 1.0.0b4 (2026-10-14)

- **Owner suggestion, report 78:** 10 s felt slow.
- **Verified by reading (fde4605):** the poll fetches the page path only, so the
  `Settings.pm` handler falls through to a plain render; Discogs is called only on
  `syncNow` / `testToken`. Each render runs one `COUNT(*)` (`beforeRender`). The
  poll runs only while the page is visible (§15.39).
- **Inferred:** load doubles on a negligible base; no Discogs impact.
- **Unverified:** cost on slow hardware (piCorePlayer); not measured.

### 15.42 SQLite 3.22.0 is the floor; no UPSERT — 1.0.0b5 (2026-10-16)

**Decided 2026-10-16** (owner). Trigger: a forum tester's scan aborted in the
importer on 1.0.0b4.

#### What happened

The tester's scanner log:

```
DBD::SQLite::db do failed: near "ON": syntax error
[for Statement " INSERT INTO squeezewax.discogs_no_match (album_key, tier, source_timestamp, checked_at) VALUES (?, 'strict', ?, ?)
ON CONFLICT(album_key, tier) DO UPDATE SET ..."]
```

Their server, as reported by the tester (2026-10-16):

| | |
|---|---|
| LMS | 9.2.0 - 1790144028 @ Thu Sep 24 03:48:16 UTC 2026 |
| OS / platform | piCore - DE - utf8 (aarch64-linux) |
| Perl | 5.32.1 - aarch64-linux-thread-multi |
| DBD::SQLite | 1.58 (sqlite 3.22.0) |

UPSERT (`INSERT ... ON CONFLICT(...) DO UPDATE`) was added in SQLite 3.24.0
(2018-06-04); multiple ON CONFLICT clauses and a target-less DO UPDATE in 3.35.0
(sqlite.org/lang_upsert.html, §4 History). 3.22.0 cannot parse it.

#### Correction to the recorded bundling claim

~~LMS bundles SQLite 3.46.1 (DBD::SQLite 1.76) for perl 5.32–5.42; perl
5.20–5.30 trees carry 3.22.0~~ (`TODO.md` step 6–7 Phase 0 item, `Schema.pm`
migration 3 and 4 comments, decisions §15.9's neighbourhood). **True of LMS's own
CPAN tree, false as a statement about what a server runs.** It was read as "a
server on perl 5.32+ has 3.46.1", and the tester's server is perl 5.32.1 with
3.22.0.

- **Verified** (design chat, 2026-10-16, slimserver `public/9.2` @ `eb59bbf`,
  2026-10-12): `CPAN/arch/5.32/DBD/SQLite.pm` is `1.76`; the SQLite inside
  `CPAN/arch/5.32/aarch64-linux-thread-multi/auto/DBD/SQLite/SQLite.so` is
  `3.46.1` (read from the binary's version strings). `CPAN/arch/5.30/DBD/SQLite.pm`
  is `1.58`, and `CPAN/arch/5.30/aarch64-linux-gnu-thread-multi/.../SQLite.so`
  carries `3.22.0`. So the tester's 1.58/3.22.0 pairing exists in LMS's tree only
  under perl 5.30, never under 5.32.
- **Inferred:** on piCorePlayer, DBD::SQLite comes from somewhere other than
  LMS's own `CPAN/arch/5.32` tree.
- **Unverified:** where. piCorePlayer packages LMS's CPAN modules as its own
  extension (`slimserver-CPAN.tcz` exists in pCP's repository); its contents could
  not be read from the design chat. Not needed for this ruling.

#### Rulings

1. **The minimum supported SQLite is 3.22.0.** Plugin SQL uses nothing newer.
   This is the oldest version *observed* on a real server running SqueezeWax, not
   a proven floor for every distribution; an older one, if reported, reopens this.
2. **No UPSERT anywhere in `SqueezeWax/`.** The four sites in `Match.pm`
   (`_recordMatch`, `_recordConflict`, `_recordNoMatch`, `recordManual`) become
   **UPDATE first, INSERT only if the UPDATE changed no row**:
   - The UPDATE sets **exactly** the columns of the old `DO UPDATE SET` list, to
     the values the old INSERT supplied for them, and no others. This is what
     preserves `_recordConflict`'s carried columns (incumbent
     `discogs_release_id`, `discogs_master_id`, the snapshots) and every
     column no writer names (`ownership`, `mb_album_id`, the `derived_*` columns).
   - The INSERT is the old INSERT without its ON CONFLICT clause.
   - Both statements run in one transaction: the scanner's long-lived one, or
     `Match.pm`'s existing `$ownTxn` pattern (`relinkOrphan`) when the handle is
     AutoCommit.
3. **`INSERT OR REPLACE` is rejected for `discogs_match`.** REPLACE deletes the
   conflicting row and inserts a new one (sqlite.org/lang_conflict.html), so
   every column the statement does not name resets: `ownership` to `'absent'`
   (badge gone until the next sync), and the snapshots and incumbent id that
   `_recordConflict` exists to carry. It would be equivalent for
   `discogs_no_match` (four columns, all written), but that site takes the same
   shape as the other three: one pattern, greppable, nothing to remember.
4. **The offline suites must pass on SQLite 3.22.0 as well as on the bundled
   3.46.1**, using a real DBD::SQLite 1.58 build. Reading the SQLite changelog is
   not a substitute: this bug existed while the repo already recorded that 3.22.0
   was in LMS's tree.
5. **A guard**: `scripts/syntax-check.sh` fails on UPSERT syntax in non-comment
   lines of `SqueezeWax/`. Cheap, and it catches the specific regression even on a
   machine that cannot run the 3.22.0 suites.

#### What does not change

- No schema change, so no migration (§15.37 part 5 is not engaged).
- No decision rule changes, so `Tags::LOGIC_VERSION` is **not** bumped (§15.23).
- Ships as the next number on `v1-buildout`, 1.0.0b5 (§15.37 parts 1–2).

#### Where the evidence is thin

- **Migrations 1–7 on 3.22.0 — verified 2026-10-17** in the repro container
  (`scripts/docker-sqlite322/`, commits `4a94146`, `75267f3`): LMS 9.2.0 at
  slimserver `eb59bbf`, perl 5.32.1 x86_64, LMS's Information page reading
  `DBD::SQLite: 1.58 (sqlite 3.22.0)`. `squeezewax.db` reached `user_version=7`,
  `discogs_collection` dropped. ~~Inferred from the tester's log~~ (the inference
  was right).
- **The crash reproduced on 1.0.0b4 — verified, same container.** With album A
  tagged first, the failing statement is `_recordMatch`'s UPSERT on
  `discogs_match` (`Match.pm` line 714, from `recordStrict` at `Importer.pm:283`),
  not the tester's `discogs_no_match` one: the importer aborts on the first
  album it writes, whichever writer that is. The log then shows `Failed when
  running scan post-process` and `Not updating lastRescanTime!`. So on SQLite
  older than 3.24.0, **every scan with tag names configured fails its
  post-process** — not only identification. The container is x86_64; the tester
  is aarch64 (inferred irrelevant: the failure is SQLite's parser).
- **DBD::SQLite loading — correction.** ~~LMS retries modules that fail from its
  own tree against the system perl~~ (design chat, from `bootstrap.pm`): the
  retry list (`Slim/bootstrap.pm:54`, `@default_required_modules`) does not
  include DBD::SQLite, which is loaded by a plain `use` (`Slim/Utils/DbCache.pm:10`)
  that searches LMS's own directories first. Found by the repro session's
  Phase 0. The container therefore overlays 1.58 into LMS's own `CPAN/arch/5.32`.
- **No concurrent writer between UPDATE and INSERT — inferred from reading.**
  `_writeOk` refuses server-side writes while a scan runs, and the scanner is one
  process. Not tested under contention.
- **The fix is not reproducible on the reference server**, which runs 3.46.1.
  Hardware confirmation comes from the reporting tester.

#### Re-verification (Claude Code, 2026-10-17)

- **The 3.22.0 test path.** The suites run unmodified on a real DBD::SQLite 1.58
  (SQLite 3.22.0) inside the repro container: `scripts/check-all.sh` starts each
  suite with `-I<container's CPAN/arch/5.32> -MDBI -MDBD::SQLite` (from
  `SQUEEZEWAX_DBD_INC`), so the module is already loaded when a suite's BEGIN puts
  `refs/slimserver` on `@INC`. `scripts/docker-sqlite322/check.sh` mounts the repo
  read-only and does that; `check-all.sh` calls it when the image exists and
  otherwise prints `3.22.0 pass skipped (no image)`. Each pass prints its driver
  (`DBD::SQLite 1.76 (sqlite 3.46.1)`, then `1.58 (sqlite 3.22.0)`). No perl 5.30
  binary exists on the development machine, and building 1.58 on the host was
  not attempted.
- **Finding A: `schema-check.pl` 9 and 10 depend on the SQLite version.** They
  asserted that SQLite reports a symlink-resolved path; 3.22.0 reports the path
  it was given. Resolved by accepting either, which is the contract `_samePath`
  already enforces (its own assertions are unchanged). Not skipped by version: no
  source says which version began resolving.
- **Finding B: `settings-check.pl` 186 and 190 were already red on HEAD**, on
  the bundled driver too: `8ddc0e0` (§15.40) moved the poll to 5 s and the two
  assertions still named 10000. A stale test; updated.
- **RED run.** Before the rewrite, on 3.22.0, exactly `match-check.pl` (dying at
  `_recordMatch`) and `queue-check.pl` (at `_recordConflict`) failed, each on
  `near "ON": syntax error`, and the guard named all four statements.
- **Order of this file.** §15.41 precedes §15.40 above (`### 15.41` is followed
  by `### 15.40`), so "the end of the file" is not "the highest number". §15.42
  is appended last; the pair is left as found.

### 15.43 Per-feature releases after 1.0.0 — 2026-10-15

**Decided in the design chat, 2026-10-15** (owner ruling on the model; rulings
3-9 confirmed by the owner 2026-10-17, ruling 10 added the same day). After 1.0.0, ship **one
feature per release**, tracked as GitHub issues. Supersedes parts of §15.37, as
marked on each ruling; parts 3, 4, 7 and 8 of §15.37 are unchanged.

Status keys: **verified** = checked in source or docs; **inferred** = read, not
run; **Owner ruling, 2026-10-17** = a design-chat proposal the owner confirmed.

#### Rulings

1. **No more "v2" bundle.** Every deferred item becomes a GitHub issue. A
   milestone = one release (`1.1.0`, `1.2.0`, …). Owner ruling.
2. **Version numbers: minor series allowed.** A feature release is `1.N.0`, its
   fixes `1.N.M`, betas `1.N.0bK`, dev builds `1.N.0aK`. `2.0.0` is kept for a
   change that breaks existing users. **Supersedes §15.37 part 2** ("there is no
   minor series"; "a milestone vN is `N.0.0`").
   - **Verified** with `Slim::Utils::Versions->compareVersions`,
     `LMS-Community/slimserver` `public/9.1` @ `582a1b2` (2026-10-11), each
     pair = -1: `1.0.9<1.1.0`, `1.1.0b1<1.1.0`, `1.0.0<1.1.0a1`,
     `1.1.0a1<1.1.0b1`, `1.1.0<1.2.0`, `1.9.0<1.10.0`, `1.10.0<2.0.0`,
     `1.0.0b4<1.1.0`. Note: `refs/` is pinned at `a670a38`, not re-run there.
   - **Inferred** (from `claude/build-version-scheme.md`, not the script):
     `package-build.sh --version 1.1.0b1` already passes its pattern and line
     guard, so no script change is needed.
3. **One development line: `v1-buildout`.** No `v2-buildout`. **Supersedes
   §15.37 part 1's `v2-buildout`/`vN-buildout` rows and part 6** (retirement
   when `N+1.0.0` is promoted). **Owner ruling, 2026-10-17.**
4. **Each feature on its own branch** `feature/<issue#>-<slug>`, merged into
   `v1-buildout` only when ready for beta. **Owner ruling, 2026-10-17.** Why: a fix to the
   released version must not ship half-finished work.
5. **Fixes to a released version** while a newer feature is in beta: a branch
   from the last promoted commit, version `1.N.M`, no migration, then merged
   forward. This is §15.37 part 4 applied to releases instead of lines.
   **Owner ruling, 2026-10-17.**
6. **Migrations. Supersedes §15.37 part 5** ("only the newest line adds a
   migration"). **Owner ruling, 2026-10-17.**
   - A migration number is taken at **merge** into `v1-buildout`, never on the
     feature branch.
   - Features that share a migration ship in one release. Known case: TODO
     2026-09-30 "link the release the user actually owns" goes with wantlist
     and master search.
   - Feature-branch builds are never published to `repo.xml`/`beta.xml`. A
     server that installed one needs "Starting over" afterwards.
   - **Failure mode this prevents:** two branches (e.g. two contributors) both
     adding migration N. Servers that installed either build are stuck,
     one-way and silent (§15.37 part 5's reason).
7. **Betas** go through `beta.xml` (already planned for after 1.0.0, TODO).
   At most one feature in beta at a time. **Owner ruling, 2026-10-17.**
8. **Decisions stay in the docs.** An issue links to its §, and the § is what
   closes it. A refused request gets a `wont-do` label and a link to the ruling
   that refused it (e.g. §15.31 ruling 4). **Owner ruling, 2026-10-17.**
9. **Issues replace TODO.md for feature items.** TODO.md keeps blocked items,
   items needing a real server, and process items. **Owner ruling, 2026-10-17.**

10. **Beta channel after the official listing. Owner ruling, 2026-10-17.**
    Verified by reading; not run.
    - **LMS side** (`LMS-Community/slimserver` `public/9.1` @ `582a1b2`,
      `Slim/Utils/ExtensionsManager.pm`): the official repository is always
      included (line 115). When several repositories name one plugin, the
      highest version wins (`getAllPluginRepos`, ~460; `findUpdates`, 382 and
      392). An update is offered only if it is higher than the installed
      version (392), so there is **no downgrade**. Local `refs/` is pinned at
      `a670a38`, where the same code sits at `:114`, `:460`, `:382`, `:392`.
    - **Listing side** (`LMS-Community/lms-plugin-repository` @ `e8fa6bd`): the
      official list is rebuilt every 6 hours
      (`update-extensions-repository.yml`); `buildrepo.pl` reads `include.json`.
    - **Rules.** (a) Once SqueezeWax is in the official listing, `repo.xml`
      carries **releases only**. (b) Betas appear only in `beta.xml`. (c)
      `beta.xml` never goes in `include.json`. (d) A tester who leaves the beta
      channel stays on the beta build until the next release, because LMS
      offers only a higher version.
    - **Why.** The official listing and `repo.xml` are both always read; a beta
      in `repo.xml` would reach every user of the listing.
    - Supersedes the §15.37 part 3 / §15.36 part 1 wording that `repo.xml`
      carries the beta: that holds only until the listing exists.

#### Closed: point on ruling 6 (owner, 2026-10-17)

The feature split (`claude/feature-split-proposal.md`) pushed back on "C1,
master search and wantlist share a migration, so ship together": the TODO items
share a **design question** (what a sync may keep; TODO 2026-09-13), not one
migration. **Ruled:** the C-group features (C1-C6) ship as individual features,
designed together where they share the "what may a sync keep" question. Each
takes its own migration number at merge (ruling 6). Ruling 6's "features that
share a migration ship in one release" applies only where a feature really
needs the same migration, and the TODO 2026-09-30 example no longer forces it.

#### Claude Code on the web and GitHub issues

- **Verified (docs):** cloud sessions route GitHub calls through a proxy that
  **rejects GraphQL**, so `gh issue create` gets a 403. REST via `gh api` works
  for attached repos; `gh` is pre-installed. Built-in tools are documented to
  "read issues … post comments" — creating is not listed.
  Source: code.claude.com/docs/en/cloud-environments, "GitHub proxy" and
  "Work with GitHub issues and pull requests" (fetched 2026-10-15).
- **Inferred, not run:** `gh api repos/d5c0d3/lms-plugin-squeezewax/issues -f
  title=… -f body=…` (REST `POST /issues`) should create an issue.
- **Unverified:** whether this owner's sessions can write to GitHub at all.
  Earlier hand-offs say "Push fails here as usual; the owner pushes"
  (`claude/build-version-scheme.md`). If push fails, issue creation likely
  fails too (inferred). Also unverified: whether the Claude GitHub App has the
  Issues write permission on this repo.

#### Not changed

§15.37 parts 3 (channels), 4 (merge forward), 7 (project knowledge follows
`master` + `v1-buildout`), 8 (test servers; now applies to feature builds with
migrations).

#### Open

- Discogs: whether contributors may share the registered "SqueezeWax" app or
  must register their own. **Unchecked.** Before inviting developers.
- Project knowledge does not sync issues (sync config lists two branches only;
  verified in project settings). Feature requests reach design chats only if
  pasted.
- The feature split's open questions for A1 and A2 are in `TODO.md`.

### 15.44 A2 (GitHub #3): a Discogs item at the top of Material's album menu — 2026-10-17

**Owner ruling: option 2, a hybrid.** A server setting, off by default: "Also
show a Discogs item at the top of Material's album menu". The item appears on
every album. It opens a SqueezeWax page for the album (Material `lmsbrowse`
action with the album id) showing the owned entries and the Discogs link, or
"not on record". No new Discogs requests (inferred: the same data the More
entries use).

The More entries always stay (`Menu.pm` init, `registerInfoProvider`). A
provider cannot tell Material apart from other app-style clients: it receives
only `menuMode`, `menuContext` and `playlistIndex` (slimserver `eb59bbf`,
`Slim/Menu/AlbumInfo.pm` ~652-667). Material sends `menu:1 html:1`
(`browse-page.js:1265`, Material `631a481`), and `html` is not passed on.
Filtering on `menuMode` would also hide the entries in other app-style clients
(inferred; Jivelite unchecked). Listen Later `ecb3622` keeps both too
(`Plugin.pm:1691-1716`). Accept the duplicate in Material.

**Verified** (Material `631a481` and `e85a897`): `registerCustomAction`
(`MaterialSkin/Plugin.pm:545-553`) only adds and has no unregister. So
switching the setting on can take effect at once; switching it off takes effect
after an LMS restart, and the settings page must say so. Material 6.4.6 added
the plugin hook (ChangeLog 6.4.6 item 7). Show the setting only when Material
>= 6.4.6 is loaded. Handle the 6.4.6/6.4.7 one-argument pitfall the way Listen
Later `ecb3622` does (its CLAUDE.md ~2176).

**Inferred:** the setting is server-wide, so it applies to every Material user
on that server. Material's top-level list cannot vary per album
(`customactions.js` `getSectionActions` filters only on `locked`, `localonly`
and an id prefix).

**Unverified:** the minimum Material version for `lmsbrowse`; whether LyrPlay
(iPhone/iPad) and Squeeze-LX (Windows 11) show the item, and whether they need
reopening after it is switched on.

Requested by forum user Dentaku (Material in LyrPlay and Squeeze-LX). Decided
in the design chat "Top-level menu setting request".

### 15.45 Owned pressings are stored — reverses §14.10 — 2026-10-17 (owner)

Amended 2026-10-22 by §15.56.

GitHub #7. Decided in the design chat.

1. The collection sync keeps, per album, the release id(s) of the collection
   entries that made it owned (`basic_information.id`), one-to-many, rebuilt in
   full at every completed sync. No extra request: the ids are in the sync reply
   (§14.10, "The information exists and is deliberately discarded").
2. The album menu shows each owned pressing as a link plus its "Release details"
   submenu, for `version` albums and also for `exact` albums where further
   pressings are owned. All owned pressings are listed.
3. Storage rule: inferred to fit §9.5 ("store conclusions, not Content"): a bare
   id plus our conclusion, the same class as `discogs_release_id`, refreshed each
   sync. **Unverified:** whether Discogs treats ids taken from a user's private
   collection differently; never examined.
4. Answers §14.10's three grounds: (1) §9.5 examined as above; (2) amends §13.2,
   which now reads "the sync stores conclusions and the owned release ids; the
   rest of the payload is discarded"; (3) this is the separate examination
   §14.10 asked for.
5. Needs a migration. Shape (column vs a small table keyed by `album_key`) is
   decided in the build plan; inferred: a table, because one album can have
   several owned pressings (TODO 2026-09-30).
6. **Master link from the owned pressing** (owner, 2026-10-17): the collection
   entry's `master_id` (in the sync reply; `Ownership.pm` `_indexCollection`
   reads `$entry->{master_id}`) gives a version album its master link with no
   search. This replaces the separate "master search for version albums" item
   (TODO 2026-09-29); its "re-match from the album menu" half is moot after
   §15.46.
7. Designed together with C4 (wantlist sync, GitHub #10), which shares the "what
   may a sync keep" question; each ships alone (§15.43).

### 15.46 The review queue becomes a read-only "needs attention" list; manual matching is removed — before 1.0.0 — 2026-10-17 (owner)

GitHub #8.

1. **Ownership rules unchanged** (owner and design chat agreed, 2026-10-17;
   matches `Ownership.pm` `_decide`): tagged + release in collection → `exact`,
   the only "owned" in the strict sense; tagged but not in collection, while
   another pressing is (same master, or title + artist) → `version`; untagged or
   contested → title route, or the queue.
2. **The queue lists, never decides.** Each item shows its reason and what to fix
   outside SqueezeWax (tags or the Discogs collection). Removed: manual re-match
   (§15.16 part 6), reject (§15.16 part 7), and every rule that exists only for
   manual rows. Why: §14.4's premise (a wrong badge is fixed in the collection
   or the tags, not in the plugin), less code, and no full collection sync per
   re-match open (ceil(items/100)+1 requests, about 51 for 5,000 items).
3. **Accepted cost:** all-remote albums (§13.10.1) cannot be tagged. If their
   title or artist does not match the collection, they stay unowned. Manual
   match was their only fix.
4. **Before 1.0.0** (owner): after the release this removal would break existing
   users and need `2.0.0` (§15.43 ruling 2). Ships as a 1.0.0 beta on
   `v1-buildout`, not as a feature branch.
5. **Open, for the build plan:** what happens to existing
   `match_tier = 'manual'` rows on update (drop them, or treat them as
   untagged); which decisions and docs are superseded (at least §15.16 parts 6,
   7, 11, 13; §15.5's reason for recovery, "recovery exists for manual rows";
   §10.3; design §3's manual link; README and user guide re-match text);
   whether orphan recovery is still needed at all.

#### Settled 2026-10-18 (owner, design chat)

**6. Existing manual rows become ownership-only rows** (migration 8, data only).
- `match_tier = 'manual'` and `ownership = 'absent'` → row deleted (it would
  assert nothing; §14.8 invariant 3).
- Other manual rows keep `album_key`, `mb_album_id`, `lms_album_id`, `ownership`.
  Every other column → NULL: `match_tier`, `state`, `discogs_release_id`,
  `discogs_master_id`, `matched_at`, `snapshot_*`, `source_timestamp`,
  `derived_master_id`, `derived_from_release_id`, `derived_at`, `review_reason`.
- Why not delete: "Records I own" is rebuilt only after a sync
  (`API/Async.pm` `_finish` → `View->rebuild`); the menu reads the row
  (`Menu.pm` `_row`). Deleting would make the two disagree until the next sync.
- What follows (inferred from reading): the menu keeps the ownership line, loses
  the release and master links (`Menu.pm` `_entries` needs a release id;
  `Ownership::_effectiveMaster` returns undef). The next scan re-examines the album
  (no strict row and no no-match row: `Match.pm` `$STATE_SQL` filters
  `match_tier IS NOT NULL`; `recordManual` had cleared the no-match row;
  `Importer.pm` `_canSkip` returns 0 with no state). — Corrected 2026-10-19 (b6
  check B): not an album with only streaming tracks; the importer skips those
  (`Importer.pm` `local_tracks` gate). Its ownership is decided by title and
  artist at the next sync. On the reference server one such album went back to
  `artist-disagree` and one became `ambiguous` (two or more owned pressings with
  that title and artist). Exact 152 → 150, queue 5 → 7, as the rules give
  (part 3). The next sync re-decides
  ownership by tags or title (`Ownership.pm` `_decide`): owned, back in the queue,
  or not owned. A gone album's converted row is deleted by the pass
  (`Ownership.pm` `_apply`, gone-row loop, `_isOwnershipOnly`).
- Reference server: the `artist-disagree` album matched by hand on 2026-10-17
  16:36:03 is expected back in the queue as `artist-disagree` after the next sync,
  and exact 152 → 151 (inferred).

**7. Queue items and their "what to fix" text.** Reasons kept: `conflict`,
`ambiguous`, `artist-disagree`, `artist-absent`, `various-gated`. Each item shows
its reason and one fix line; nothing on the page writes. Text is in the build plan
§4. Rules behind it:
- Every fix is a tag edit or a collection edit, then a rescan or sync.
- `artist-disagree` on a record that really is different stays in the queue for
  good. Unchanged from §15.16 part 7 (no stored dismiss); its fix line says it can
  be ignored.
- "Show tags" stays: it reads two files and writes nothing (§15.17 part 1).
- **GitHub #6 folded in.** `Tags::decide` also returns the unreadable values;
  `Tags::examineCandidates` gives the in-file case two more kinds, `unreadable`
  (no readable id) and `unreadable-mixed` (one readable id plus unreadable values).
  Wording only: stored `review_reason` stays `conflict`, verdicts unchanged, so no
  migration for it and no `LOGIC_VERSION` bump (inferred; the constant's own
  comment excludes messages).
- `PLUGIN_SQUEEZEWAX_QUEUE_TAGS_RESOLVED` said "The tags agree again. The next scan
  will clear this." With part 9 that is true for removed tags too, but "agree" is
  wrong for "no tags"; reworded.

**8. `orphan` is gone from the queue; automatic relink stays.**
- Kept: `Importer.pm` `_prePass` (one-to-one relink, artist backfill) and
  `Match.pm` `relinkOrphan`, `_resolveRelinks`, `backfillArtist`. They are now an
  optimisation only: a moved album keeps its derived master (no Discogs request)
  and its files are not re-read (`relinkOrphan` carries `derived_*` and
  `source_timestamp`).
- Removed: the orphan list, the relink and remove buttons, and the pass's
  `'orphan'` marking. Migration 8 clears existing `'orphan'` marks.
- Unrelinked orphans sit, unseen. §2a invariant 4 already accepts no sweep. Escape
  hatch: README "Starting over". A sweep was rejected: a scan with the music share
  offline makes every album "gone" (§15.28), and today those rows come back for
  free when the share returns (same `album_key`).
- §15.5's rationale ("recovery exists for manual rows") is superseded: recovery is
  the optimisation §15.5 already called it for tagged albums. Parts 1, 3, 4 stand;
  part 2's "two or more goes to the queue" and part 4's queue obligation are
  superseded (an ambiguous orphan stays orphaned).

**9. New importer rule: tags removed from a conflict row delete the row.**
- Problem: an incumbent conflict (§3a demotion: release id kept, tags now
  disagree) whose tags are then removed falls to `_recordNoMatch`'s "kept" path
  and stays `conflict` forever. Reject was its only exit (design §3, "The queue
  must also offer reject").
- Rule: `_recordNoMatch` also deletes the row when
  `match_tier = 'strict' AND state = 'candidate' AND review_reason = 'conflict'`;
  then the no-match row is written as usual (§2a invariant 1 holds).
- §2a invariant 2's test, applied: the row carries no decision (no user decisions
  exist after §15.46; a conflict row's id is used by neither ownership,
  `Ownership.pm` `_decide` / §15.16 part 4, nor the menu, `Menu.pm` `_entries`),
  and its snapshot serves only the relink optimisation. The existing narrow
  predicate is unchanged; this is a second, named clause.
- Existing stuck rows: migration 8 NULLs `source_timestamp` on
  `review_reason = 'conflict'` rows, so the next scan re-examines them (2 file
  reads each). No `LOGIC_VERSION` bump: that would re-read the whole library
  (§15.24: 63.9 s over 578 albums).
- Not changed, recorded: an identified (non-conflict) album whose tags are removed
  keeps its identification (the "kept" path). Pre-existing; TODO.

**10. Schema.** Migration 8, data only, no DDL: four guarded statements in one
transaction (build plan §3). The CHECKs keep `'manual'` and `'orphan'`: narrowing
needs a full rebuild of the one table that is not regenerable (as §14.1), for no
gain. Nothing writes them; `scripts/syntax-check.sh` gets a guard. §15.37 part 5:
`v1-buildout` is the newest line (no `v2-buildout`; verified `git branch -a`).
§15.42: plain UPDATE/DELETE, nothing newer than 3.22.0. Downgrade: b5 refuses
`user_version = 8` (`Schema::_migrate`); the README already says there is no way
back except "Starting over".

**11. The sync stops keeping re-match fields.** `API::entryFromRelease` drops
`year`, `formats`, `labels` (kept only for the re-match list, §15.16 part 6);
`_labelLabel` goes if unused (`_formatLabel` stays, `Details.pm` uses it).
`API/Async.pm` `_finish` stops passing the entry list to callbacks (only
`Queue.pm` read it; Claude Code verifies the other two callers). Less held in
memory; §9.5 direction.

**12. Superseded.** Decisions: §15.16 parts 5, 6, 7, 10 (seam now queue → render),
11, 13, and part 2's `orphan` value (no longer written); §15.17 part 2; §15.5
rationale and part 2's queue branch; §2 "Orphan recovery" ambiguous branch;
§3a's manual-row sentence; §10 entire (with GitHub #5, B+C prompt part 6), incl.
§10.3 and §10.5; §14.1's `'manual'` (allowed, never written). Design: §3
"Confirmed … or the user linked the album by hand", "Manual re-match…",
"Reject deletes…", "The queue must also offer reject…" (→ part 9), re-match
trigger "manual re-match", the menu's "tag or manual link" and "Re-match… stays
on the review-queue page"; §9 clear & rebuild "escape hatch … demoted candidate"
(→ part 9); §10 `match_tier`/`review_reason` comments; §11 v1 list "manual
re-match". Code comment: `Ownership.pm` `_decide` ("A manual link is not subject
to the collection cross-check").

**Interactions, not designed here.** #7 (§15.45): a formerly manual album owned
by title may get its pressing link back from the owned release id; #7 must not
re-introduce choosing. #10: none. #6: folded in (part 7).

#### Where the evidence is thin
- Nothing here was run. Migration 8 and part 9 rest on reading
  `Match.pm`, `Ownership.pm`, `Importer.pm`, `Menu.pm`, `Schema.pm` @ `ec75033`.
- "A tag edit changes the file's timestamp, so the next scan re-examines" is the
  existing assumption (§3a), not re-checked for every tagger.
- The reference server's expected counts after update are inferred.
- Fix-text wording is untested with users.

#### As built, 2026-10-18 (`137efda`..`0be60ba`, for 1.0.0b6)

Built from `plans/build-order-gh8-queue-read-only.md`. Offline suites green on
SQLite 3.46.1 and 3.22.0 after every commit; nothing here has run on a server.
Deviations from the plan, each small:

- **Steps 3 and 5 swapped.** Removing `recordManual` and `rejectRow` (step 3)
  before the queue page stopped calling them (step 5) leaves `queue-check.pl`
  red, so the queue page went first.
- **Strings landed with their first user.** The new fix-line and streaming
  strings came with the queue page (step 5) and the two unreadable-kind strings
  with step 6; step 8 did the rewording and the removals (32 tokens).
- **Migration 8's statement (d)** carries `AND source_timestamp IS NOT NULL`, so
  its count in the info line is the rows it actually changed and a re-run
  reports 0. Same effect.
- **`relinkOrphan` no longer names `review_reason`** (step 4). Its `CASE` cleared
  `'orphan'`, which nothing writes after part 8, and kept the literal in code
  the step 8 guard forbids.
- **The streaming note replaces the fix line** for an album with no local
  tracks, rather than appearing beside it: every fix line asks for a tag edit
  the user cannot make on such an album (part 3).
- **Part 9 also fires when no candidate file could be read.** `_examine`
  returns the same empty decision for "unreadable" as for "no tag", so an
  incumbent conflict examined while its files are unreachable is deleted and
  given a no-match row. Pre-existing for fresh conflicts; recorded in
  `TODO.md`, not changed.

### 15.47 New-masters notice in 1.0.0; automatic sync in 1.1.0 — 2026-10-19 (owner)

GitHub #14 and #13.

1. **Owner chose:** for 1.0.0, a notice on the settings page (GitHub #14). The
   automatic sync after the master job (GitHub #13) follows in 1.1.0.
2. **The notice** reads "New master releases found. Press 'Sync collection now'
   to update which records you own." It shows when at least one `discogs_match`
   row has `derived_master_id` not NULL and `derived_at` later than the last
   completed sync's time (`Schema->syncState`), for an album whose `ownership`
   is not `'exact'`. With no completed sync there is no notice: the first-steps
   hint (§15.38 item 2) covers that case.
3. **Hidden while the master job runs** (`Derive->isRunning`), and gone after
   the next completed sync, whichever path writes the marker.
   **Forward note (2026-10-19): amended by §15.48 part 1.** "Runs" was read as
   `isRunning` alone, which is false in the 60 s gaps between runs; the notice
   must also be hidden while the job waits.
4. **No Discogs request.** A read at page render only, like the derive count
   (§15.38 item 3); it is part of the 5 s live refresh (§15.40).
5. **Relaxes the `Schema.pm` note** "Nothing branches on [derived_at]" (migration
   6 comment). That note guards against age-based re-fetching (§15.22); this is
   a display comparison and fetches nothing. The comment is amended to say so.
6. **Why #13 is not in 1.0.0:** it would be the first Discogs traffic that is not
   directly caused by a user's action (a scan, the button), so it needs its own
   beta round.

### 15.48 The notice is hidden while the master job waits; settings page redesign later — 2026-10-19 (owner)

GitHub #14 (the fix) and #17 (the redesign). Found by the 1.0.0b7 hardware check
(`TODO.md`, 2026-10-19): on a fresh install the notice showed in each 60 s gap
between derive runs. **Verified** on hardware: 16 runs, the notice present in the
gaps and absent during runs.

1. **Hidden while the master job runs or waits, shown when it is paused or has
   finished.** Cause: "waiting" is a pacing stop with a re-arm (`Derive.pm`
   `%REARM_ON`, `isResumeScheduled`, `REARM` 60 s, `PER_RUN` 30). `isRunning` is
   false then, and `Settings.pm` tested only `!isRunning`, as §15.47 part 3
   specified. The condition becomes `!( isRunning || isResumeScheduled )`.
   **Amends §15.47 part 3** (forward note added there). Paused shows the notice
   on purpose: the button then resumes the job and updates ownership in one
   press.
2. **"Sync collection now" stays enabled during the master job, by design.** The
   job yields to a sync (`Derive.pm` `_yieldReason`) and re-arms (`%REARM_ON`),
   so a press never collides with it.
3. **The settings page is redesigned after 1.0.0, as its own release** (GitHub
   #17; §15.43, one feature per release). 1.0.0 ships the current page with the
   part 1 fix. Whether the redesign comes before #13 or together with it (1.1.0)
   is decided at design time, and so are its details. The owner has more changes
   in mind, not yet listed. The redesign must keep the 5 s live refresh (§15.40)
   and the buttons disabled while a scan runs.
4. **Owner ideas, recorded and not designed, folded into #17:** (a) keep the
   master count on screen after the job ends (the row is hidden today,
   `settings.html` `[% IF derive %]`); (b) a hint why the job is slow; (c) move
   the notice into the Master releases row (needs (a)).

### 15.49 The new-masters notice can ask for a second press — kept for 1.0.0 — 2026-10-20 (owner)

GitHub #14 and #17. Seen in the 1.0.0b8 hardware check (`TODO.md`).

1. **What happens.** The new-masters notice can ask for a second press of "Sync
   collection now": that press's sync works out ownership before the master job
   it starts has run (§15.38 item 7). Real case: README setup step 5 (job paused
   → press → job runs → notice).
2. **1.0.0 keeps the notice and its wording** (§15.47, §15.48). Rewording alone
   would not remove the second press, and #17 redesigns the page.
3. **The second press goes away with #13** (automatic sync). Where the notice
   lives, or whether it is still needed after #13, is decided in #17 (comment
   2026-10-20 on GitHub #17).
4. **Not pursued: storing "this master is new"** to suppress the notice. In
   normal use a lookup only runs for a new or retagged album (`Derive.pm`
   `$UNSETTLED`; the only other reset is a migration, `Schema.pm:900`), so the
   notice is almost always accurate. Inferred from reading, not measured.

### 15.50 Master job: 15 s pause, a reserve of 10, a 429 waits one window — 1.0.0b9 — 2026-10-20 (owner)

GitHub #19. Amends §15.22 (pacing bullets; "Re-arming is narrowed to pacing
stops"); forward notes added there. Owner's proposal; the design chat settled the
details.

1. **Pause between runs** (`REARM`) 60 s → 15 s. `PER_RUN` 30 and `SPACING` 1
   unchanged. `PER_RUN` stays the bound on a run's length, not a rate (`Derive.pm`
   comment at `PER_RUN`).
2. **Reserve.** The job sends nothing while the last counted reply said
   `Remaining` < 10 **and** that reply is less than one window (60 s) old. It
   counts down like `rateWait` (§15.32): the job makes no request while it yields,
   so a stored figure would never clear. It leaves at least 9 for menus and the
   sync. Job only: `API::rateWait`, `Details.pm`, the sync are unchanged.
3. **Re-arm delay.** Budget spent or reserve reached: the larger of `REARM` and
   the time left in the window. Sync running or per-run cap: `REARM`. Without this
   a spent budget would re-arm four times a window and log a stop each time.
4. **429.** The job stops and re-arms after one window (`WINDOW_SECONDS`, 60 s).
   The third 429 in a row stops it without re-arm; the next completed sync arms it
   with a fresh count. Any other reply resets the count. 401, 5xx, dropped
   connection, bad body: unchanged (stop, no re-arm). A 429 is still not recorded
   as "no master".
5. **Unchanged:** one shared rate state per process (§15.22); nothing keyed by
   token.
6. **Not in b9: skipping albums that carry a master tag** (owner, 2026-10-20).
   Deferred to the #16 release (master-tag names as a list). §15.28 stays: the job
   still looks them up. Why deferred: the stored answer is the fallback when #16
   stops reading `DISCOGS_MASTER_ID` / `DISCOGS MASTER ID` on existing installs;
   skipping first would leave those albums not owned until looked up and synced.
   Inferred from reading. Recorded on GitHub #16 (comment 2026-10-20).

**Arithmetic (inferred, not measured).** §15.22 measured 476 requests, 18 runs,
25 min 18 s → (1518 − 17 × 60) / 476 = **1.05 s per request**, latency included.
Model: Discogs counts requests in the last 60 s (docs: "moving average over a 60
second window"; the exact rule is unverified). 476 releases, 16 full-speed runs:

| s/request | pause | total | avg/min | peak in any 60 s | left |
|---|---|---|---|---|---|
| 1.05 | 60 s (today) | 23.3 min | 20 | 30 | 30 |
| 1.05 | 15 s | 12.1 min | 39 | 43 | 17 |
| 0.8 | 15 s | 10.1 min | 47 | 57 | 3 → reserve stops it |
| 1.5 | 15 s | 15.7 min | 30 | 30 | 30 |

At the measured speed the job alone never reaches the reserve. On a faster link it
does, and the reserve is what keeps the headroom. Under a stricter reading of the
docs (the window only resets after 60 idle seconds) the reserve's full-window wait
is that idle minute, so the job cannot run the budget down under either reading.
15 s and 10 kept.

**Sizing: two reference cases** (owner, 2026-10-20). Every pacing decision is
checked against both, not only the reference library:

- *Reference library:* 764 albums, 479 identified (476 distinct releases),
  203-item collection.
- *Large library (forum user):* 5,000+ CDs (GitHub #20). Assumed worst case:
  ~5,000 identified distinct releases, and a ~5,000-item collection (the user's
  real figures are unverified). Collection sync ≈ 51 requests (`ceil(items/100)` +
  profile); scan-time sync near its 120 s cap (`TODO.md` "large collections
  against the scan-time sync cap").

Simulated one-time master lookups (same 1.05 s/request; reading A = Discogs counts
the last 60 s; reading B = the window clears only after 60 idle seconds; both
unverified):

| design | 476, A | 476, B | 5,000, A | 5,000, B | lowest left |
|---|---|---|---|---|---|
| today (60 s pause) | 23 min | 23 min | 4.2 h | 4.2 h | 30 |
| **b9 (15 s + reserve 10)** | **12 min** | **19 min** | **2.2 h** | **3.5 h** | 17 (A) / 9 (B) |
| sliding pause above reserve, no fixed pause | 12 min | 21 min | 2.1 h | 3.8 h | 13 / 9 |

b9 roughly halves the large case's time under A and stays safe under B. The best
sliding curve tried saves ~5 minutes in 2 hours under A and is slower under B. At
5,000 the conclusion is clearer, not weaker: b9 first. Model script: design chat
2026-10-20 (not in the repo).

**The bigger lever at 5,000 is not looking up again:** §15.51 (lookups survive
database changes). Each lookup is done once per release, ever (§15.22). Skipping
master-tagged albums is the other lever, deferred (item 6).

**Does the reserve protect the menus and syncs?** By reading `30628e3`:

- Details menu: one request per open, blocked only when `rateWait` > 0, i.e.
  `Remaining` reached 0 (`Details.pm` `rateWait` check before the fetch; `API.pm`
  `_waitLeft`). The reserve keeps ≥ 9 → protected from the job's own spend. Not
  from other users of the same address or token.
- Server sync: the job yields while it runs (`Derive.pm` `_yieldReason`); the sync
  waits on `rateWait` and retries a 429 up to `MAX_RETRIES` (`API/Async.pm`
  `_get`, `_handle`). 203 items cost 4 requests (§13.8).
- Scanner: own process, own rate state (`API/Sync.pm` header; `TODO.md`
  cross-process item). The job yields during a scan (`Match.pm` `_writeOk`,
  `stillScanning`). A scan-time 429 fails once and the server retries after the
  scan (§15.18 part 11). Exposure falls from "30 vs 4" to "≥ 9 vs 4". Inferred;
  stays a `TODO.md` item.

**Per token or per address.** Discogs' developer page (fetched 2026-10-20) gives
60/min, the moving 60 s window and the three headers; it names neither IP nor
token. Only a third-party listing (publicapis.dev, undated) quotes "throttled by
source IP"; archived official docs were not reachable. **Unverified.** The design
holds either way: the headers are the only truth, and the state is not keyed by
token. `API.pm`'s comment above `my $rateState` stated the IP link as fact; it is
reworded as unverified.

**§15.15 part 1 and Discogs' terms.** The job's timers are already accepted
(§15.22) as pacing re-arms, bounded by pending work and started by a sync. A 429
is a pacing answer, not a fault, and the cap allows at most two extra re-arms per
sync, so §15.22's objection (a persistent error becoming a one-a-minute timer)
does not apply. Discogs' docs ask apps to throttle locally and warn that
circumventing the limit may get an app banned; the API Terms of Use (updated
2025-05-27) forbid circumventing rate limits and interfering with others' use, and
say nothing about retries. Waiting a full window after a 429 honours the limit.
Argued from the text; Discogs has not been asked.

**Ship:** 1.0.0b9 (owner, 2026-10-20). b8 is not promoted. No migration; no
`LOGIC_VERSION` change (that versions the tag rule, `Plugin.pm` comment at
`LOGIC_VERSION_KEY`). Inferred from reading.

**Where the evidence is thin:** one library, one server, one network; 1.05 s is a
derived average; the window rule is one sentence of the docs; per-IP unverified;
whether a 429 carries the rate headers unverified (if not, `accountRequest`'s
ladder takes one off the last figure, so a menu or sync could fire straight into a
second 429); the 12-minute figure is unmeasured.

**Considered, deferred (owner question, 2026-10-20): a sliding pause from
`Remaining`** (e.g. 20 left → none, 10 → 5 s, 5 → 10 s, 1 → 15 s). Sound only if
Discogs frees requests gradually (unverified); if the window clears only after 60
idle seconds, a trickle keeps it from clearing and runs the budget to 0. A ladder
below 10 also spends the menus' headroom: any sliding pause sits above the
reserve, which stays. Small gain even at 5,000 (table above: ~5 min in 2 h under
reading A, slower under B). Revisit after the b9 per-request `Remaining` lines
show how the window behaves.

**Two points kept as the owner wrote them, noted:** "fewer than 10" keeps 9 free,
not 10; "3 in a row" is two retries, where the sync allows three (`MAX_RETRIES`).

**Build note (1.0.0b9, `a444995`).** `_next` looks for remaining work before it
yields, so a finished job never re-arms and never shows "waiting" (§15.48). Hardware
2026-10-20: the settings page showed "waiting" only in the 15 s gaps of a running job.

### 15.51 Master lookups survive database changes — 2026-10-20 (owner)

GitHub #21.

1. **Rule:** any future migration that rebuilds or copies `discogs_match` carries
   `derived_master_id`, `derived_from_release_id` and `derived_at`. A migration
   that clears them states why in its decision, and the release notes give the
   cost: one Discogs request per identified release, roughly 2–3½ hours for 5,000
   (§15.50 sizing).
2. **Why:** the plugin is in beta and its database will change. A large library
   should not pay hours of lookups again for a change that did not need it. §9.5
   allows keeping the bare ids indefinitely.
3. **Evidence, by reading `30628e3`:** the columns are written only by `Derive.pm`
   `_record` and migration 8 (`Schema.pm:900`, manual rows only). `squeezewax.db`
   is a separate file attached to LMS's connection, keyed by `album_key`
   (urlmd5-based), which survives a `library.db` wipe (`Schema.pm` comment above
   the `discogs_match` definition). So an LMS "clear library and rescan" should not
   cause lookups again — **inferred, not tested** (`TODO.md`).
4. **Hazard:** `Schema.pm` `@MATCH_COLUMNS` is migration 3's fixed list of 12
   columns and omits the three lookup columns (they arrived in migration 6).
   `_rebuildMatchTable` must not be reused for a later rebuild as it stands. A
   one-line warning comment sits above `@MATCH_COLUMNS`.

### 15.52 1.0.0 is 1.0.0b9's code; #2 is a known limitation — 2026-10-20 (owner)

1. **1.0.0 adds no feature.** It is 1.0.0b9's code (master `6281b9b`, hardware
   report 91) with its version and wording changed for release. Every open
   feature issue ships after 1.0.0, one per release (§15.43).
2. **When:** after 1.0.0b9 has run on the forum without a blocking report. The
   owner calls it; no fixed period. Wanted, not required: piCorePlayer and
   large-library reports (TODO items). A blocking report gets a fix as 1.0.0b10
   with its own hardware check first.
3. **GitHub #2 ("Rescan album") is after 1.0.0**, as its design note already
   placed it (`claude/design-gh2-rescan-album.md`, "Order of work"; TODO "A1
   (GitHub #2)", owner 2026-10-17). Not ready: Discogs' "Collection Items By
   Release" endpoint is unverified, and the order of LMS's rescan notifications
   needs a real server. It becomes a README known limitation. **Cost accepted
   until then (inferred):** each "Rescan album" starts a full collection sync,
   about 4 requests on the reference collection, about 51 on a 5,000-item one
   (§15.50 sizing), during which details menus may say "busy".
4. **Milestones.** `1.1.0` = #13, #16, #17 together (owner, 2026-10-19). #2 and
   the other open issues get no milestone yet; their order is decided after
   1.0.0. A milestone is one release (§15.43 ruling 1).
5. **The release step itself** (version 1.0.0, README "This is a beta" line,
   release `repo.xml`, official plugin listing) is planned in its own session
   when the owner calls 1.0.0.

### 15.53 Release order after 1.0.0 — 2026-10-20 (owner)

Amends §15.52 item 4 ("order decided after 1.0.0"). One feature per release (§15.43); each
milestone is one release on GitHub.

| Release | Issue | Why there |
|---|---|---|
| 1.0.1 | #22 no collection sync after "Rescan album" | Fix, no migration; split from #2. |
| 1.1.0 | #13, #16, #17 | One release (owner, 2026-10-19). |
| 1.2.0 | #3 Material "Discogs" item | Decided (§15.44), user-requested, no migration. Open: minimum Material version. |
| 1.3.0 | #2 Rescan album (tag re-read, one lookup) | Phase 0 first: Discogs "Collection Items By Release" endpoint (unverified). |
| 1.4.0 | #7 owned pressings | Decided (§15.45); migration. Designed with #10, ships alone (§15.45 item 7). |
| 1.5.0 | #10 wantlist | Builds on #7; Listen Later and Discogs questions first. |
| none | #18 multi-language | Translations only (owner, 2026-10-20); ships when a translator is found. |
| none | #9, #11, #12 | Undecided; no milestone. |

- **Split (owner, 2026-10-20):** stopping the full collection sync after "Rescan album" leaves
  #2 (which decided it 2026-10-17 as part of #2) and ships first as **1.0.1**, GitHub #22. A fix
  to the released version per §15.43 ruling 5: branch from the last promoted commit, no
  migration, merged forward. Why: that sync re-checks ownership with the old tags (inferred from
  `Plugin.pm` `_rescanDone` / `_syncTick`), and costs ~51 requests per album rescan at 5,000
  items. Trade-off (inferred): a Discogs collection change is then noticed at the next scan or
  "Sync collection now", not after an album rescan.
- **Before 1.0.1 is built:** how to tell an album rescan from a full scan. Both end in
  `['rescan','done']`; whether the `rescan album` command is visible first, and in what order, is
  unverified (#2 design note) and needs a real server. Same check #2 needs; do it once.
- Considered: fixing it in 1.0.0 instead (as b10). Not chosen: 1.0.0 stays b9's code (§15.52).
- The order may change by a later dated decision; the milestone follows the decision.

### 15.54 Database changes after 1.0.0 must not cost users a rebuild — 2026-10-20 (owner)

Raised by the owner: a user who installs 1.0.0 should not soon have to rebuild the database.

1. **Rule.** After 1.0.0, a database change must:
   1. run by itself when LMS starts after the update (`Schema.pm` `_migrate`, verified by reading);
   2. add, not destroy: master lookups are kept (§15.51) and no existing data is lost;
   3. never require "Starting over";
   4. not bump `LOGIC_VERSION` (the next scan re-reads every file, §15.24) without its own dated
      decision;
   5. state its cost in the release notes: Discogs requests at the next sync, and scan time if any.

   A change that cannot meet these is a `2.0.0` (§15.43 ruling 2).
2. **Why 1.0.0 still ships without #7** (amends nothing in §15.52). Planned changes, inferred from
   the records, none built:
   - #7 (1.4.0) adds storage for owned-pressing ids, filled by the next normal sync (§15.45 items 1
     and 5). No rescan or master lookup expected.
   - #10 (1.5.0): shape not designed (unverified).
   - #13, #16, #22, #2: no database change (#13's design avoids a table rebuild; #16 is settings
     only; §15.53).

   Before 1.0.0, changes went in because they broke existing users (#8, §15.46 item 4). #7 only
   adds. Pulling it into 1.0.0 would delay 1.0.0 by a feature-sized beta and would not end
   migrations (#10 likely adds one).
3. **Unchanged:** an update still cannot be undone without "Starting over" (`Schema.pm` `_migrate`
   refuses a newer database). README already says so.
4. **Not planned:** narrowing the CHECKs that still allow 'manual' and 'orphan' (a full table
   rebuild "for no gain", `Schema.pm` comment above `_migration_8`).

### 15.55 German translation (GitHub #23): review rules — 2026-10-24 (owner)

Amends the #18 row of §15.53 only in that a translator now exists. Which release carries German is
NOT decided here.

1. **Contribution.** Dentaku242 (GitHub #23, 2026-10-21): DE for all 127 string IDs, matching
   1.0.0b9's EN (checked at 5b53aa8). One EN difference: "→" was lost as "?" in FIRST_STEPS.
2. **The three Discogs notices stay English, with no DE line:** ATTRIBUTION_NOTAFFILIATED,
   ATTRIBUTION_DATA, DETAILS_NOTICE. Why: the Discogs API Terms of Use (updated 2025-05-27) give the
   exact English wording, and the German version of the terms keeps it English. Translation is not
   addressed (unverified whether allowed).
3. **Review covers real issues only:** the notices, labels a user must find (buttons, views, LMS
   menus, Discogs pages), broken characters, wrong meaning. Wording and style otherwise stay as the
   translator wrote them.
4. **Changes requested in #23:**
   - FIRST_STEPS: LMS labels SETUP_RESCAN "Medienbibliothek erneut durchsuchen" and
     SETUP_STANDARDRESCAN "Nach neuen und veränderten Mediendateien suchen" (slimserver public/9.1
     @ e9430b4); restore "→".
   - CURRENCY_UNKNOWN: "Sammlung jetzt synchronisieren".
   - TOKEN_DESC: "Tonträger im Besitz".
   - DETAILS_HAVE "Haben %s", DETAILS_WANT "Suchen %s" (Discogs German site, owner screenshots
     2026-10-24).
5. **Discogs German labels are checked manually by the owner only.** No automated fetching or
   browsing of discogs.com: the Discogs Terms of Service (updated 2026-02-23) exclude robots,
   scraping and similar tools.
6. **Server language only.** Per-app language stays in #18, not designed.

### 15.56 Multiple pressings: other owned pressings, linked by master — amends §15.45 — 2026-10-22 (owner)

GitHub #7.

1. **What is shown.** For exact and version albums: a submenu listing the user's other owned
   pressings of the same master. Each entry has:
   - its link;
   - "Release details" (fetched on open, as today, §15.31);
   - "Play this version" when an LMS album is tagged with that release.

   This amends §15.45 item 2: "Play this version" is new. If only one pressing is ripped, there is
   no "Play".
2. **Linked by master id only.** The album's master is `Ownership.pm` `_effectiveMaster` (tag,
   else lookup). The other pressings' masters come from the stored collection entries (§15.45
   items 1 and 6). No title and artist fallback: the same title and artist is not the same record
   (e.g. Peter Gabriel I-IV).
3. **`version` stays an ownership state** (§15.46 item 1 unchanged). Under §15.22, a single wrongly
   tagged file in a correct album is not a version but a conflict (`Tags.pm` `examineCandidates`).
4. **Accepted gaps** (inferred from reading, not run):
   1. the list is empty until the master lookup has run for a new tag (`Derive.pm`);
   2. a version album found by title and artist with no matching master gets no list;
   3. a release without a master gets no list.
5. **Not planned.** An untagged album matching two owned pressings stays ambiguous (outside the
   well-tagged premise, §14.4). Two rips of the same pressing: recorded, not designed.
6. **Open for #7's design.**
   1. LMS merges same-title, same-artist rips across folders when disc tags exist and there is no
      differing MusicBrainz album id (verified by reading slimserver public/9.1 @ 05968ee,
      `Slim/Schema.pm` `_createOrUpdateAlbum`; not run). The README must say how to keep pressings
      apart.
   2. Unverified: how a menu item opens another album in Material, the web UI and SqueezePlay.

### 15.57 German in 1.0.0 — 2026-10-28 (owner)

Amends §15.52 item 1 and closes the timing question left open in §15.55.

1. **1.0.0 = 1.0.0b9's code plus the German strings from GitHub #23 (§15.55).** No other change.
2. **Why:** strings only. LMS reads plugin strings as UTF-8 (`Slim/Utils/Strings.pm` `loadFile`,
   `'<:utf8'`), logs and skips a malformed line (`parseStrings`, `logError`), and falls back to EN
   for a missing language (`storeString`, `$failsafeLang = 'EN'`). Read at slimserver `public/9.1`
   @ `847ca05`, not run.
3. **Check:** no extra beta. The 1.0.0 build itself is checked before promotion: a container run
   (this session, unpackaged tree) and an owner check of the German menus and settings page on a
   real server (release-step session).
4. **Translator:** Dentaku242 agreed to all review changes, GPL-2.0 inclusion and credit as
   "Dentaku" (#23, 2026-10-24).

### 15.58 1.0.0 release step — 2026-10-28 (owner)

1. **Order:** build 1.0.0 on `v1-buildout` -> owner checks it on a real server (update from
   1.0.0b9; German menus and settings page, §15.57) -> `promote-master.sh 1.0.0 <report>` ->
   GitHub release `v1.0.0` on the promoted master commit -> close #23, forum post.
2. **Official listing deferred** (owner, 2026-10-28). Not submitted to
   `LMS-Community/lms-plugin-repository` `include.json` for now. Until it is, §15.43 ruling 10
   does not apply: the website `repo.xml` stays the one user channel, and the README keeps
   "SqueezeWax is not on the main LMS plugin list". Submission is "add the URL to include.json"
   (that repo's README @ `6c8ab51`, read); by pull request is inferred.
3. **GitHub release: yes.** Tag `v1.0.0` on master's promotion commit, zip attached, release notes
   from this record and the README. Created by the owner (Claude Code does not push or create
   tags).
4. **Translation licence.** Dentaku agreed to "GPL-2.0" in writing (#23, 2026-10-24). "or later"
   (README: GPL-2.0-or-later) is the owner's inference from that wording and Dentaku's forum
   messages, **not confirmed in writing**. It matters only if the licence ever moves past
   GPL-2.0.
5. **Database:** no change from 1.0.0b9; no Discogs requests or rescan caused by the update
   (§15.54 item 5).

### 15.59 Website review at every promotion to master — 2026-10-28 (owner)

1. **Every promotion to master includes a review of the pages the website serves**, against the
   promoted version and the README. The owner reviews before pushing master.
2. **Why:** website pages live only on master and are edited by hand ("Website: ..." commits), so
   promotion never touches them. 1.0.0 went live with "A beta, with no way back" on `index.html`
   (fixed in `2a572a1`).
3. **`promote-master.sh` runs `scripts/site-check.sh` and warns, but does not stop,** when a release
   still mentions beta/alpha (exit 2, run continues). The word scan does not replace the review.

Next free decision number: §15.60.
