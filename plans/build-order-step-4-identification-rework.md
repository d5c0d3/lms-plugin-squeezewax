# Build order step 4 — Identification rework

**Code complete 2026-09-19 at `a50c9d0` (commits f0ff368, cf995f4, b4f307e, 31a4289, a50c9d0). Hardware checks (§6) open in TODO.md.**

**Planned 2026-09-19 (design chat). Branch `v1-buildout`, at `a9b71b6`.**
Source read in full at that commit: `SqueezeWax/Importer.pm`, `Match.pm`,
`Library.pm`, `Plugin.pm`; the relevant parts of `Tags.pm`, `Settings.pm`,
`strings.txt` and `HTML/EN/plugins/SqueezeWax/settings.html`. LMS claims are
checked against slimserver `a670a38c2b14` (`public/9.1`, 2026-06-19), the pin
of `refs/`. Line numbers below are at `a9b71b6`; resolve by symbol if they
have drifted.

Design authority: `docs/squeezewax-design.md` §3 (identification, node E), §10
(the snapshot columns). Decision authority: `docs/squeezewax-v1-decisions.md`
§3, §3a, §3b, §11.3(d), §11.4, §13.4, §15.3, §15.4, §15.5, §15.8, §15.9,
§15.11, §15.12. **This plan does not restate those records. Where it disagrees with
one, the record wins and the disagreement is a defect to report.**

`plans/build-order-step-4-structural-matching.md` is stale in its entirety and
was not used as a source, only as a model for §0's shape.

---

## §0. What step 3 established that step 4 must honour

Required by `TODO.md`. Every item below is still true after step 4, and each
names what would break it.

**0.1 The write policy is a pure function, and stays one.**
`Match::_writeRefusal($ready, $isScanner, $isScanning)` (`Match.pm:43-58`) with
`_writeOk` reading the environment around it (`:60-85`). `main::SCANNER` is
constant-folded, so the scanner branch is only testable through the pure
function. **Every new write in step 4 — the backfill and the relink — calls
`_writeOk` first.** No new input to the policy, no parallel check.

**0.2 The manual guard is rule one of the write path.** `recordStrict` checks
`match_tier = 'manual'` before anything else and refreshes only
`source_timestamp` and `lms_album_id` (`Match.pm:236-256`). `ON CONFLICT … WHERE`
was verified not to work here. Step 4's relink *does* move manual rows — that is
what §15.5 exists for — but it changes no decision column, so it is compatible
with the guard rather than an exception to it. The backfill writes
`snapshot_artist` only.

**0.3 The narrow delete predicate is not widened.** `_recordNoMatch`
(`Match.pm:362-384`) deletes only `strict` / `candidate` / NULL release id /
NULL `snapshot_track_count`. Step 4 adds no delete. §15.4 makes it a rule that
a conflict row never carries a snapshot, which is what keeps that predicate
reachable — so `_recordConflict` must not start writing `snapshot_artist`.

**0.4 Invariant 1.** An album never has a row in both `discogs_match` and
`discogs_no_match` for one tier. Enforced by `_clearNoMatch` (`:422-431`) and
detected for free by `strictState`'s two-row case (`:148-216`). The relink moves
a row onto an `album_key` that, by the definition of a key miss below, has no
row in either table — so the invariant holds without new code, **provided the
key-miss test checks both tables.**

**0.5 The skip contract.** `Importer::_canSkip` (`:269-282`): skip when a row
exists and `source_timestamp` equals the album's current value; NULL never
skips. A relinked row carries its `source_timestamp` forward unchanged, so an
album whose files merely moved is skipped on the same scan, and one that was
moved *and* retagged is re-examined.

**0.6 §3b invalidates `tier = 'strict'` only** (`Match::invalidateStrict`,
`:102-146`), leaving manual rows untouched. Its note that a pref-derived tier
needs its own clause has no v1 subject after §15.8.

**0.7 The `use` gate does not change** (`Importer.pm:92`, §15.8). Only the
stale comment above it (`:90-91`) does.

**0.8 The `local_tracks` gate does not change** (`Importer.pm:184-193`,
§15.11). All-remote albums have no local candidates and nothing to read tags
from; §13.10.1's all-albums scope belongs to the ownership pass (step 7).

**0.9 Commit cadence and visibility.** `COMMIT_EVERY` (`Importer.pm:37-58`), the
extra `forceCommit` that makes the progress row visible (`:149-163`), and no
`every` on `Progress->new` (`:138-147`). The pre-pass below does its writes
before the main loop and commits once after them.

**0.10 `endImporter` on every early return** (`Importer.pm:101-134`), so the
scan log never shows a start without a finish.

**0.11 Abort safety of the iterator.** `Library::eachAlbum` finishes its
statement handle on die and from an `END` block on abort (`Library.pm:26-44`,
`:134-186`). Two walks are safe only if they are sequential — the pre-pass walk
must complete before the main walk starts. `Library::sample_albums`
(`:286-345`) is the existing two-pass precedent.

**0.12 The calling convention** (`CLAUDE.md`): public subs are class methods,
`_`-prefixed helpers are plain functions, including from the offline suites.

**0.13 LMS is read-only to us.** Never call `Slim::Schema->variousArtistsObject`
(§11.3(d): it creates and renames contributor rows). **Nor
`Slim::Schema::Album::artists`, which reaches it** — verified at `a670a38`:
`Slim/Schema/Album.pm`'s `artists` calls `variousArtistsObject` for a
compilation with no `ALBUMARTIST` and no usable `ARTIST`. This is new, and §11.4
recommends `artists`; see §5.

---

## §1. Scope

**In:** the seven work items in §2.

**Out, and why:**

- **The schema.** Migration 3 is step 6 and ships with step 7 (§15.9). §15.9
  verified item by item that nothing here needs it.
- **The collection sync, the ownership pass, and anything that writes
  `ownership`** — steps 5 and 7.
- **The ambiguous relink branch.** It needs the review queue (step 8). Recorded
  as a step-8 obligation, not built.
- **`Importer.pm`'s `local_tracks` gate** — unchanged by §15.11.
- **The design-fix pass and the `implementation-plan` reconciliation** — their
  own sessions, tracked in `TODO.md`.

---

## §2. Work items

### 2.1 Identification stops confirming

**Record:** §13.4, design §3 node E, §15.3. `TODO.md` 2026-09-15 item on
`_recordMatch`.

`_recordMatch` (`Match.pm:271-303`) writes `state = 'confirmed'` on every clean
tag hit. It writes `'candidate'`. Promotion to `confirmed` belongs to the
ownership pass alone (§15.3). The function returns `'identified'` rather than
`'confirmed'`, and `recordStrict`'s POD (`:218-226`) lists the new value.

`Importer.pm` renames its `confirmed` counter to `identified` in `%count`
(`:165-168`), in the outcome tally (`:209`), in the summary line (`:225-228`)
and in the return value (`:266`).

**Consequence, accepted by §15.3:** a row written `confirmed` before step 4 is
demoted to `candidate` whenever its album is re-examined. Nothing user-visible
depends on `state` until step 7.

### 2.2 `hasAnyStrictMatch` stops depending on `state`

**Why this is not optional.** After 2.1, nothing is `confirmed` until step 7.
`hasAnyStrictMatch` (`Match.pm:162-181`) keys on `state = 'confirmed'`, so it
returns 0 forever — and the anomaly warning (`Importer.pm:250-255`) fires on
**every scan of every library**, telling the user to check tag names that are
fine. That is the warning's own documented failure mode, observed twice on
hardware and fixed twice.

**Redefine a hit as a clean tag hit:** a row with `match_tier = 'strict'` and a
non-NULL `discogs_release_id`, whatever its `state`. The question the warning
asks — "has this configuration ever produced anything" — is answered by the
tags, not by ownership. A conflict row with an incumbent id counts, because tags
did once name a release; a fresh conflict row (NULL id) does not. The warning's
condition uses `$count{identified}`.

### 2.3 The iterator supplies the album artist

**Record:** §15.5 (artist is part of the fit predicate), §11.4 (use the
`albums.contributor` column rather than joining `contributor_album` by role).

`Library.pm`'s `$ALBUM_TRACKS_SQL` (`:58-67`) gains
`LEFT JOIN contributors c ON c.id = a.contributor` and selects `c.name`. It is a
property of the album, taken from the accumulator like `title` (`:146-154`,
`:231-237`), and emitted as `artist` in the `eachAlbum` record and its POD
(`:81-103`).

**What `albums.contributor` is, verified at `a670a38`:** it is set per track by
`Slim::Schema::_createOrUpdateAlbum` (`Slim/Schema.pm:1283-1296`), from the
primary contributor `_postCheckAttributes` passes it (`:3060-3091`) —
`ALBUMARTIST`, else `ARTIST`, else `TRACKARTIST`, first entry — or the VA
contributor's id for a compilation without an album artist. **The last track
written wins.** For any album with a consistent album artist it is stable; see §5
for the case where it is not.

**Bytes, not characters, on both sides.** No `sqlite_unicode` or
`sqlite_string_mode` is set anywhere in slimserver's `Slim/`, so DBD::SQLite
returns bytes, and LMS decodes by hand where it needs characters
(`Slim/Schema/Album.pm:239`, `utf8::decode($contributorName)`). The snapshot
stores `contributors.name` as read and recovery compares it as read. **Decoding
one side and not the other breaks every non-ASCII artist silently** — the fit
simply never matches. `snapshot_album_title` already follows this pattern; the
artist must too.

### 2.4 The snapshot carries the artist

`_recordMatch` writes `snapshot_artist` in the INSERT and in its
`ON CONFLICT … DO UPDATE` list, beside `snapshot_album_title` and
`snapshot_track_count` (`Match.pm:277-298`). `_recordConflict` does not
(§15.4, and 0.3).

### 2.5 Backfill: rows written before step 4 get their artist

> **Decided 2026-09-19 — decisions §15.12, part 1.**

Every snapshot written before step 4 has a NULL `snapshot_artist`, because
nothing wrote it. NULL equals nothing, so **none of those rows could ever be
relinked.** And the skip contract means an unchanged album is never re-examined,
so 2.4 alone never fills them in. Without a backfill, recovery works only for
rows first written after step 4 ships — and not for anything that exists on the
reference server today.

**Proposed:** during the pre-pass (2.6), for each current album whose
`album_key` has a `discogs_match` row with a non-NULL `snapshot_track_count` and
a NULL `snapshot_artist`, set `snapshot_artist` from that album's `artist`.
**That column only** — no state, no timestamp, no other snapshot column. No
file reads: it is LMS's own data for the same `album_key`. Through `_writeOk`.
Idempotent, since it only fills NULLs.

Manual rows are included. Conflict rows are excluded automatically, since they
have no `snapshot_track_count`.

### 2.6 The orphan relink, unambiguous branch only

**Record:** §15.5 (columns, predicate, reach, owner), decisions §2 (the flow),
`TODO.md` "orphan recovery writes an UPDATE, not an INSERT".

> **Decided 2026-09-19 — decisions §15.12, part 2.**

**Why a pre-pass.** §15.5's "exactly one fit" is one-to-one across the whole
library. Inside the per-album loop it would be decided greedily: the first new
album to fit an orphan would claim it before a second candidate was ever seen.
So the relink is decided on complete information, before the main loop starts.

**The pre-pass — one `eachAlbum` walk, no file reads:**

- the set of current `album_key`s;
- for the backfill, each current album whose row needs its artist (2.5);
- the **key-miss albums**: those whose `album_key` has **no row in
  `discogs_match` and no strict row in `discogs_no_match`** — both tables, per
  0.4 — recorded with `album_key`, `album_id`, `artist`, `title` and
  `local_tracks`.

Our own two tables are small and may be loaded whole into hashes first; the walk
over LMS's tables stays one streaming pass. **No N+1 over LMS's tables.**

**Orphans:** `discogs_match` rows whose `album_key` is not current, with
`match_tier IS NOT NULL AND snapshot_track_count IS NOT NULL` (§15.5). Before
migration 3 `match_tier` is `NOT NULL`, so this reduces to "has a snapshot" —
§15.9 verified the behaviour is identical.

**Fit:** exact equality of (`snapshot_artist`, `snapshot_album_title`,
`snapshot_track_count`) with (`artist`, `title`, `local_tracks`), as bytes
(2.3). A NULL on either side fits nothing. All-remote albums never fit, since no
snapshot records zero local tracks.

**Resolution — a pure function, so it is testable offline:**
`_resolveRelinks(\@orphans, \@misses)` returns the pairs where **the orphan fits
exactly one miss and that miss fits exactly one orphan.** Every other orphan and
miss is left exactly as it was. The one-to-one test is on both sides
deliberately: requiring it on one side only lets two new albums contend for one
orphan, or one album claim two orphans.

**The write:** a public class method on `Match`, through `_writeOk`, that
**UPDATEs** the orphan's `album_key` and `lms_album_id` and nothing else. It
carries `discogs_release_id`, `discogs_master_id`, `match_tier`, `state`,
`matched_at`, `source_timestamp` and the snapshot forward unchanged. Never an
INSERT: a relink re-identifies which local album a match belongs to; it does not
re-decide which release it is.

**Order:** resolve everything, then write every resolved pair, then
`forceCommit`, then start the main loop. Resolving completely before the first
write means an abort mid-write — which commits, per `Importer.pm:44-50` —
leaves only pairs that were each individually correct. The main loop then finds
the relinked rows through `strictState` and applies the skip contract as normal.

**Reporting:** the summary line gains relinked and unresolved-orphan counts, at
the same level as the rest of the summary. Not a per-scan warning: an orphan
that stays unresolvable would repeat it forever.

**Not built:** the ambiguous branch (§15.5 part 4 — review queue, pre-filled
with the previous answer), and sweeping orphans whose album is gone (§2a
invariant 4 — not swept in v1).

### 2.7 Remove `discogsMaxTier`

**Record:** §15.8.

> **Decided 2026-09-19 — decisions §15.12, part 3.**

Remove the `$prefs->init` block and the comment above it (`Settings.pm:26-31`),
and the `discogsMaxTier` element of `sub prefs` (`:58`, which becomes
`qw(discogsToken)`), with the comment at `:52-57` that describes both prefs; the selector block in
`settings.html` (`:28-35`); and the four `PLUGIN_SQUEEZEWAX_MAXTIER*` strings
(`strings.txt:112-122`).

**The `$prefs->migrate(1, sub { … remove … ; 1 })` call goes in `Plugin.pm` at
file scope, not in `Settings.pm`.** `Plugin.pm:36-40` loads `Settings.pm` only
under `main::WEBUI`, so on a headless server the migration would never run.
File scope in `Plugin.pm` is the core plugins' pattern (for example
`Slim/Plugin/Podcast/Plugin.pm:40`), and `Plugin.pm` is never loaded by the
scanner, so the prefs file is written by one process only. §15.8 verified that
the namespace's `_version` is absent on an existing prefs file and that the
comparison is silent.

### 2.8 Detection stops offering master ids as release ids

**Record:** `TODO.md` 2026-09-15 item on the bare-master hazard; §15.1.

`Tags::candidateKeys` (`Tags.pm:341-366`) corroborates a bare integer whenever
the key matches `/DISCOG/i`, so `DISCOGS_MASTER_ID=999` is offered as a
corroborated *release* candidate. A user who ticks it stores master ids as
release ids.

> **Decided 2026-09-19 — decisions §15.12, part 4.**

**Proposed: a key naming a master is excluded entirely**, matching
case-insensitively against `@MASTER_KEYS` (`Tags.pm:53`) or `/MASTER/i`. This
is consistent with the existing behaviour for a master *URL*, which
`tags-check.pl` asserts is "not offered as a release candidate" at all — not even
demoted. The demoted list means "other numeric tags that might be a release id";
a master id is known not to be one.

---

## §3. Stale comments

Known at `a9b71b6`, and **not a complete list — grep `SqueezeWax/` and
`scripts/` for `confirmed`, `Structural` and `Fuzzy` and account for every hit**,
because every hand-written enumeration in this session has been wrong at least
once:

- `Importer.pm:90-91` — "Step 4 must relax this: Structural needs no tag names".
- `Importer.pm:184-193` — correct; add that all-remote albums are the ownership
  pass's (§15.11).
- `Match.pm:269-270` — "Auto-confirm is what design §3 specifies for Strict".
- `Match.pm:317-318` — "since the badge join is state = 'confirmed'". The badge
  reads `ownership` (design §4).
- `Match.pm:364-366` — "step 5 cannot even render it". The review queue is
  step 8.
- `Library.pm:55-57` — "v2's Fuzzy tier is precisely for streaming albums". The
  design is right, the reason is not: the ownership pass is.
- `Plugin.pm:18-19` — "examined 4,800, confirmed 0".
- `scripts/match-check.pl:349` — "(the join is state='confirmed')".

---

## §4. Commits, in order

Each commit carries its own tests and ticks its own `TODO.md` items.

1. **Detection excludes master keys** (2.8). `tags-check.pl`: a bare
   `DISCOGS_MASTER_ID` is not offered at all.
2. **Remove `discogsMaxTier`** (2.7).
3. **The iterator supplies the artist** (2.3). `library-check.pl`: `artist` is
   present, is the contributor's name as bytes, and is undef rather than fatal
   when `albums.contributor` has no contributor row.
4. **Identification stops confirming, and writes the artist snapshot** (2.1,
   2.2, 2.4), with the stale comments in `Match.pm` and `Importer.pm`.
   `match-check.pl` changes:
   - "a clean hit auto-confirms" becomes: a clean hit returns `'identified'`,
     writes `state = 'candidate'`, and writes all three snapshot columns;
   - `hasAnyStrictMatch`: a strict row with a release id counts in either
     state; a strict row with a NULL id does not; a manual row does not. **The
     existing case at `:405-410` inserts a strict `confirmed` row with no
     release id and expects 1 — under the new predicate it must expect 0.**
     This is the case most likely to be "fixed" the wrong way;
   - a conflict row's snapshot columns are all NULL, and the narrow delete
     still fires on one whose tags were removed (§15.4's two assertions, which
     `TODO.md` records as missing).
5. **The pre-pass: backfill and unambiguous relink** (2.5, 2.6), and the
   remaining stale comments. `match-check.pl`:
   - `_resolveRelinks` exhaustively — one-to-one pairs; one orphan fitting two
     misses; one miss fitting two orphans; NULL `snapshot_artist` fits nothing;
     a byte-level non-ASCII artist fits only itself;
   - the relink write is an UPDATE: row count unchanged, release id, tier,
     state, `matched_at` and `source_timestamp` carried, `album_key` and
     `lms_album_id` changed;
   - a manual row relinks;
   - invariant 1 holds after a relink;
   - the backfill fills only NULL `snapshot_artist` and touches no other
     column.

**Model** (working-agreement §3): commits 4 and 5 are **`opus`** — the write
path and recovery, where a plausible wrong answer surfaces months later as a
silently lost manual match. Commits 1 to 3 are `sonnet`.

---

## §5. Recorded, not solved

- **§11.4's rationale is false, and step 7 inherits the question.** §11.4 says
  `Album::artists` "builds on" `albums.contributor`. At `a670a38` it does not:
  it reads role rows and falls back to `Album::contributors` — every contributor
  via `contributor_album`, `Album.pm:95-100` — never the `albums.contributor`
  column (the `belongs_to` at `:44`). It can also reach `variousArtistsObject`.
  Step 4 is unaffected: it uses the column, as §11.4 also permits, and the
  snapshot only compares LMS with LMS. **Step 7 compares LMS with Discogs**, so
  it must choose its artist source knowingly, and must not choose
  `Album::artists`.
- **`albums.contributor` is order-dependent for mixed-artist albums with no
  album artist.** Last track written wins, so a rescan in a different order can
  change it. The snapshot then does not fit; that fails safe for a tagged album
  (identification recovers it) and loses a manual row's choice. Same shape as
  the retagged-title hole already in `TODO.md`.
- **The ambiguous relink branch** is a step-8 obligation.

---

## §6. Verification

**Offline:** `scripts/syntax-check.sh` and every suite in `scripts/` green after
each commit, with the new cases in §4.

**On a real server** — each goes to `TODO.md`'s "Waiting — needs a real server"
if not run at once:

1. After commit 2, `squeezewax.prefs` no longer carries `discogsMaxTier`, and
   the settings page has no tier selector.
2. A rescan of a healthy library produces **no** "check the configured tag
   names" warning — the regression 2.2 exists to prevent.
3. After the first scan on commit 5, count rows with a non-NULL
   `snapshot_track_count` and a NULL `snapshot_artist`: expect zero among rows
   whose album is current.
4. Move one tagged album's folder, rescan: its row is relinked (new
   `album_key`, same release id), no `discogs_no_match` row appears for it, and
   the summary counts one relink.
5. The same with a **manual** row. None exist until step 8, so insert one with
   `sqlite3` on a copy of `squeezewax.db`.
6. Copy one album folder so that two new albums fit a single orphan: neither is
   relinked, and the summary counts it unresolved.
7. Steps 4 and 5 with a non-ASCII artist name.
