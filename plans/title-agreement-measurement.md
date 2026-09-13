# Title agreement: LMS library vs Discogs collection

Measurement plan and Phase 1 results. Phase 1 ran **read-only against a live
server on 2026-09-12** (LMS PID 2466 active, `journal_mode = wal`); every figure
below carries that date and that server state.

Filename is descriptive per `TODO.md`'s `plans/` naming item — this is a
measurement session, not a build-order step.

## Context

Decisions §13 makes title-led matching against the user's own Discogs
collection the foundation of v1, and decisions §13.9 records as its largest
unmeasured assumption that **nobody has measured whether LMS album titles and
Discogs `basic_information.title` actually agree**. Decisions §8 measured title
normalisation against *search results* — a different population with different
title conventions. The build order is about to be rewritten around decisions
§13, so the number is needed first.

Secondarily, landing decisions §13 collided with design §13 (the API request
budget). Two spots in the repo carry both referents. That gets fixed and the
convention that prevents a third gets recorded.

Scope is measurement plus one new script — **no plugin code**, nothing under
`SqueezeWax/`, no changes to existing `scripts/*`. The LMS database is
read-only throughout.

---

## Phase 1 — inputs located (DONE)

| Item | Finding |
|---|---|
| `library.db` path | `/var/lib/squeezeboxserver/cache/library.db` — **single candidate**. Found by `find` over `/var/lib`, `$HOME`, `/srv`, `/media`, `/mnt`; the LMS process's own `--cachedir` confirms it. 24.7 MB, mtime 2026-09-11 21:36, world-readable. |
| LMS running? | **Yes.** PID 2466 `/usr/sbin/squeezeboxserver`, `systemctl is-active lyrionmusicserver` → `active`. `journal_mode = wal`; `-wal` is 0 bytes, `-shm` present. Read-only open succeeds. |
| Album count | `albums` table: **765** rows (prior sessions record 764). All 765 pass the Library iterator gate. **579** have `local_tracks > 0`; **186** are all-remote. **All 765 are the measurement population** — see the gate decision below. 579 and 186 are reported separately. |
| Fixture | `scripts/fixtures/collection-page1.json`: `releases` = **100** entries. Its own `pagination` block says `items=203, page=1, pages=3, per_page=100` — **confirms decisions §9.4 exactly**. One page = 100/203 = **49.3%** of the collection. |
| Encoding | `albums.title` is a `BLOB` column, so DBD::SQLite returns raw bytes. Scanned all 765: 40 contain non-ASCII, **0 invalid UTF-8, 0 double-encoded**. Fixture: 1 non-ASCII title, decodes cleanly. **No encoding damage found; nothing to repair.** |

### Columns used, named exactly

**Title:** `albums.title` (BLOB → decode UTF-8 explicitly). Discogs side:
`releases[].basic_information.title`.

**Artist — an SQL approximation of a runtime accessor.**
`Slim::Schema::Album::artists` (decisions §11.4) is unavailable to a standalone
script. `refs/slimserver/Slim/Schema/Album.pm:293-324` shows `artists()` tries
`ALBUMARTIST`, then `BAND` (pref-gated), then `ARTIST` (pref-gated), then the
Various Artists object, then `contributors`. Role ids from
`refs/slimserver/Slim/Schema/Contributor.pm:76-83`: `ARTIST => 1`,
`ALBUMARTIST => 5`.

Per album, the first of:

1. `contributor_album.contributor` where `role = 5` (ALBUMARTIST)
2. `contributor_album.contributor` where `role = 1` (ARTIST)
3. `albums.contributor` (the singular contributor)

resolved to `contributors.name`, ties broken by lowest `contributors.id`.
`Slim::Schema->variousArtistsObject` is **never called** — `TODO.md` records it
as not side-effect-free.

### How exact that approximation is — measured, not assumed

Read 2026-09-12 from `/var/lib/squeezeboxserver/prefs/server.prefs`:

| Pref | Value | Line | Effect |
|---|---|---|---|
| `bandInArtists` | **0 (off)** | `:504` | The BAND branch never fires. Omitting it is **exact**. |
| `variousArtistAutoIdentification` | **1 (on)** | `:642` | The ARTIST branch is gated on `!$self->compilation`, so compilations with no ALBUMARTIST fall through to the Various Artists object. |

**The divergence is bounded to one set and measured:** albums with
`compilation = 1` and no role-5 contributor — **5 of 765 (0.65%)**. Of those 5,
**3 already return `Various Artists` via role 1**, identical to what real
`artists()` produces. Only **2 actually diverge** (album ids 3589 and 3596, both
*L.S.G.* titles flagged as compilations), in a known direction: the
approximation returns the specific artist where `artists()` would return Various
Artists.

So: **exact for 763 of 765 albums, with the 2 exceptions printed by id.** Good
enough to carry an auto-badge count. The script prints the pref values and the
divergence set so the claim is re-checkable rather than asserted.

Sanity checks, both clean: 0 albums have neither ALBUMARTIST nor ARTIST, and 0
have a NULL `albums.contributor` — tier 3 never fires on this library, and no
album lacks an LMS-side artist string.

---

## Phase 2 — `scripts/title-agreement.pl`

New file. No existing file touched.

**Invocation:** `scripts/title-agreement.pl <library.db> <collection.json>` — no
hardcoded paths. *Deliberate divergence from house style:* no other
`scripts/*.pl` takes `@ARGV`. Noted in the script header.

**Style:** matches `scripts/fetch-fixtures.pl`, the only existing script that
prints a plain report rather than TAP. Same header block (what it proves / what
it cannot prove / `# Usage:`), `use strict; use warnings;`, hard tabs, the same
`@INC` dance so DBI 1.628 and DBD::SQLite 1.76 come from
`refs/slimserver/CPAN/arch/5.38/` (verified on this host's perl 5.38.2).
`JSON::XS` for the fixture, read as raw bytes via the `load_fixture` idiom at
`scripts/api-check.pl:344-355`. Per `CLAUDE.md`'s calling convention, all
helpers are `_`-prefixed plain functions called as `_foo(...)`.

**Database access:** `sqlite_open_flags => DBD::SQLite::OPEN_READONLY()`. No
`ANALYZE`, no `VACUUM`, no DDL, no writes, no temp tables. The script writes no
files.

### The badging rule this measures against (decided 2026-09-12)

**A title match against the collection is sufficient to badge a streamed album
without Strict. The 186 all-remote albums do not become review items.**

This **corrects decisions §13.4**, which conflated identification with
ownership. Decisions §13.3 already separates them into different columns, and
the badge reads the *ownership* column — so an album with no local file to carry
a `DISCOGS_RELEASE_ID` tag can still be owned, and still badge.

- **Version ownership auto-badges** when exactly one collection entry matches on
  **title and artist**.
- → **review queue** when several candidates match, **or** artist disagrees,
  **or** artist is absent on either side.
- **Strict-confirmed exact ownership is unchanged.**

*The decisions §13 amendment covering this and the gate removal is a separate
session and will follow — it is not written here.*

**Consequence: artist is load-bearing, not decorative.** Artist agreement gates
*every* auto-badge, so artist-absent and artist-disagrees are review-queue routes
in their own right and are counted for all matches, not just for collisions.

### Population — the `local_tracks == 0` gate is removed

**Decided 2026-09-12: all 765 albums are the measurement population.** The
`local_tracks > 0` gate came from Structural's duration fingerprint, which needed
local files to read durations from. Decisions §13 replaced that flow with
collection-first identification, and a title comparison needs no local file — so
the gate no longer earns its exclusion.

The 579/186 split is still reported separately, because **decisions §13.5's cost
estimates were written against the 579 figure** and a reader comparing the two
documents needs both numbers visible.

### Inputs

LMS albums — gate copied from `SqueezeWax/Library.pm:58-79`, with `local_tracks`
retained as a *reported column* rather than a filter:

```sql
SELECT t.album, COUNT(*) AS qualifying,
       SUM(CASE WHEN t.remote = 1 THEN 0 ELSE 1 END) AS local_tracks
  FROM tracks t
 WHERE t.album IS NOT NULL AND t.audio = 1
   AND t.content_type NOT IN ('cpl','src','ssp','dir')
 GROUP BY t.album
```

joined to `albums.title` and the three-tier artist approximation. No `HAVING`
clause — `Importer.pm:184-193`'s gate is deliberately not reproduced.

Collection — `basic_information.{title, artists[].name, id, master_id}` for all
100 entries.

**Both sides are decoded to character strings before comparison** — LMS bytes via
`Encode::decode('UTF-8', $bytes, FB_CROAK)`, Discogs via `decode_json`. Comparing
bytes against characters would silently fail every non-ASCII title. On a decode
failure the script **records the album id, excludes it, and reports the
exclusion — it does not repair**. (Phase 1 found zero such rows; this is a
guard.)

### The normalisation ladder — fixed, applied cumulatively

| Rung | Rule |
|---|---|
| L0 | exact string equality **after decode** (not byte equality — both sides are character strings by this point) |
| L1 | + `lc` (case-folded) |
| L2 | + leading/trailing whitespace trimmed, internal runs collapsed to one space |
| L3 | + punctuation removed, keeping alphanumerics and spaces |
| L4 | + leading English article removed (`the`, `a`, `an`) |
| L5 | + trailing parenthesised or bracketed suffix removed |

**No rung is added, removed or tuned.** A rule off the ladder that looks like it
would help is written up as a finding and **not implemented**. L4 is
English-only; the script counts titles in either corpus beginning with an
identifiable non-English article and reports the count **without handling them**.

### Outputs (stdout only)

Per rung: LMS albums matched, collection entries matched, incremental gain over
the previous rung.

At L5:

1. **Collisions — two directions, reported separately, never summed.**

   **(a) One LMS album → ≥2 collection entries. The problem direction.**
   Ambiguous: the album cannot be identified without a tiebreak rule. Count,
   full list, and the per-collision artist outcome.

   **(b) One collection entry → ≥2 LMS albums. Legitimate and expected.** A rip
   and a stream of the same record are two LMS albums for one owned item, and
   **both should badge**. Counted and listed for visibility, labelled
   not-a-defect, excluded from any "collision problem" figure. Removing the
   `local_tracks` gate *increases* this direction by construction — the 186
   all-remote albums are exactly where rip-plus-stream pairs appear — so a rise
   here is the expected consequence of the gate decision, not a regression. The
   fixture also contains one intra-collection duplicate title (`Ciao Monkey` ×2),
   a third and separate thing: two owned entries, not two LMS albums.

2. **Does artist disambiguate direction (a)?** Per collision: resolves to one /
   stays ambiguous / eliminates all. Artist strings compared through the same
   L0–L5 ladder, **plus** stripping Discogs' trailing ` (N)` disambiguator — a
   Discogs data-format fact, not a fitting knob, declared as an artist-side rule
   so it cannot be mistaken for a ladder extension.

3. **Overlap** — LMS albums matching any collection entry at all, reported three
   ways: all 765, the 579 with local tracks, the 186 all-remote.

4. **The auto-badge split.** Of all L5 title matches, four buckets summing to the
   match total:

   | Bucket | Outcome |
   |---|---|
   | exactly one candidate, artist agrees | **auto-badge** |
   | exactly one candidate, artist disagrees | queue |
   | exactly one candidate, artist absent either side | queue |
   | several candidates (direction (a)) | queue |

   The artist-absent bucket is split by *which* side is missing — different
   defects with different fixes, and Phase 1 found `artists[]` populated on all
   100 fixture entries, so a Discogs-side absence would be a surprise.

5. **How many of the 186 all-remote albums match a collection entry.** *The
   number the gate decision turns on*, on its own line.

6. **Unmatched collection entries** — owned records with no LMS album.

7. **Ten example failures** at L5, LMS title beside nearest collection title.
   *Deterministic rule, stated in the output:* L5-unmatched LMS albums sorted by
   `albums.id` ascending, first ten; "nearest" = minimum Levenshtein distance on
   the L5-normalised strings (hand-rolled, no CPAN dependency), ties broken by
   lowest Discogs release id. **For reading, not for tuning.**

---

## Phase 3 — run and report (no commit)

Report every number, each labelled **verified** / **inferred** / **unverified**,
and answer:

- raw L0 agreement rate;
- what each rung actually buys;
- **ambiguous-collision count only** — direction (a). Direction (b) is reported
  but is not part of this answer, since it is not a defect;
- whether artist resolves direction (a), i.e. whether a further tiebreak rule
  has to be designed;
- how many of the 186 all-remote albums matched, and therefore what removing the
  gate actually bought;
- **review-queue size, as arithmetic not impression.** Per the badging rule, the
  queue is *direction (a) collisions unresolved by artist* **+** *tag
  disagreements* **+** *Strict conflicts*. It is **not** one item per unowned
  album and **not** one per streamed album. Only the first term is measurable
  from this script; the other two need the importer and are named as unmeasured
  rather than estimated. Scale by the 100/203 fixture fraction, state the
  assumption, and give it against both populations (765 and 579).

**Sample limitation:** the fixture is page 1 of 3, 100 of 203 items (49.3%),
sorted by label and therefore not a random sample. A one-page figure is not a
whole-collection figure and will not be presented as one.

---

## Phase 4 — the §13 numeral collision

**4.1** — qualify the two ambiguous spots so each names its document:
`TODO.md`'s fetch-cap bullet (which carries both `Blocks the §13 rewrite.` for
design §13 and a `superseded by §13` line for decisions §13), and
`docs/squeezewax-v1-decisions.md` §8 (head-of-section marker for decisions §13,
body's `§13's rewrite decides it` for design §13). *Only those two spots* — the
same `superseded by §13` line appears twice more in `TODO.md` and is out of
scope per 4.3's no-sweep rule.

**4.2** — record the convention in `docs/working-agreement.md` §2.

**4.3** — two unticked `TODO.md` items: the housekeeping one recording the
convention and the no-sweep rule, and one recording that
`plans/build-order-step-4-structural-matching.md` is stale in its entirety.
That staleness is verified: its §6 opens with "**§13 needs a full rewrite**"
referring to the request budget.

---

## Verification

- `perl -c scripts/title-agreement.pl` clean.
- `scripts/syntax-check.sh` still passes (untouched by this work).
- Run the script twice and diff the output — must be byte-identical, proving the
  example-failure selection is deterministic.
- Confirm read-only: `library.db*` mtimes unchanged before and after; `git
  status` shows nothing under `SqueezeWax/` or `tmp/`.
- `git show --stat` per commit to confirm only intended files moved.

## Carried into the report regardless of outcome

- **Cross-document disagreement:** `TODO.md` and decisions §13.5 both say
  "764-album library". The database says 765 rows, 579 with local tracks.
  Reported, not fixed — working-agreement §2 makes a disagreement a defect to
  reconcile, so it needs its own decision.
- **Two 2026-09-12 decisions tracked only here**, both deferred to their own
  session by explicit instruction: the `local_tracks == 0` gate removal (which
  contradicts `Importer.pm:184-193`'s live gate and the comment above it), and
  the badging correction to decisions §13.4.
- **The compilation artist vocabulary — reported, not fixed.** LMS calls
  compilation artists `Various Artists`; **Discogs calls them `Various`** — 7 of
  the 100 fixture entries, against 95 LMS albums with `compilation = 1`. Under
  the badging rule an artist disagreement sends the album to the review queue,
  so this one vocabulary difference could push most matched compilations into
  the queue for a purely lexical reason. **A `Various` ≡ `Various Artists`
  equivalence is exactly the rule the measurement's trap warning forbids adding
  mid-run**, so the script does not add it; it reports the artist-disagrees
  bucket split by whether the disagreement is this specific pair, so the number
  is visible with and without it.
- The Discogs ` (N)` disambiguator strip is the one artist-side rule that *is*
  implemented, declared as a data-format fact; 3 of the 62 distinct fixture
  artist names carry one (`Oasis (2)`, `Snow (2)`, `Travis Scott (2)`).

**Not in scope:** rewriting the build order. That is the next session.
