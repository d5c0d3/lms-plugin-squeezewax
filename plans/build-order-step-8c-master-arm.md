# Build-order step 8c: the master arm, and tags that disagree across tracks

Written 2026-09-28 by the design chat. Input: decisions §15.19, §15.20 (as
corrected by the §9.5 errata) and §15.21; the step 8c survey; three measurements
(hand-offs 18, 21, 23); the design chat's rulings of 2026-09-27 and 2026-09-28.

Base: `v1-buildout` at `e2b3eb3`, `check-all.sh` 1459 green. Verification pin for
LMS: slimserver `a670a38c2b14ad42b86a39884bcb842121b35571`.

**What this step does.** Two independent things, both aimed at the same defect —
an album the user owns being reported as not owned.

1. **The master arm starts working.** Node F (`Ownership.pm:377-381`) compares a
   column that is filled only from a tag, so it has never once fired. A bounded
   background job derives the master id for identified albums and node F reads it.
2. **Tags that disagree across an album's tracks stop being invisible.** The
   importer reads at most two tracks and stops at the first that answers, so a
   folder whose files name different releases is identified from whichever came
   first. Comparing them costs no requests and catches the worst measured case.

**What it does not do.** No release data is stored (§9.5). No plausibility rule
built from track counts or artists — §15.21 dropped it, with nothing to catch. No
`anv`, no alias matching. No reading of more than two tracks per album.

---

## §0. What this plan rests on

### §0.1 Three things §9.5 says, separated

They have been conflated once already and the distinction matters to this step.

- **Reading every local file of an album** — rejected on measured cost
  (19–137 ms per file on a NAS, ~9,000 reads, ten to fifteen minutes per scan),
  nothing to do with the terms. `Library.pm:230-244`'s two candidates stand.
- **Reading a Discogs payload in memory** — permitted. The context menu already
  does it, and this step does it once per release.
- **Storing that payload, or anything Content-shaped from it** — forbidden.
  §9.5: *store conclusions, not Content.* `discogs_release_cache` stays unwritten.

A **master id is storable**: §9.5 puts a bare identifier in the same class as the
release id already in `discogs_match`, "unconstrained; kept indefinitely."

*Recorded so it is not re-derived wrongly later:* a per-disc test — does some
single disc of this release hold exactly this album's track count — **is**
permitted at fetch time, storing only its verdict. §15.21's remark that it "needs
the tracklist, which §9.5 says we do not keep" is right about **keeping** and
wrong if read as "cannot be computed". Ruling 2 was dropped because there was
nothing to catch, not because the test was impossible.

### §0.2 Rulings this plan implements

From the survey (2026-09-28) unless noted:

1. The derived master lives in **its own column**, distinct from the tag-derived
   one. Provenance: the user's tag is their assertion and ours never overwrites it.
2. The job runs **server-side, after a successful sync, bounded per run and
   resumable**; zero work on a settled library.
3. It **yields to the sync** for rate budget: never starts while one runs, and
   stops when the budget is spent.
4. A derived master is fetched **once**, and again only if the album's release id
   changes.
5. **404 is an ordinary outcome** (§15.21): the release is gone, there is no
   master, and there is no reason to ask again until the tags change.
6. The cross-track rule is adopted **in both halves** — two different ids, and
   one track tagged with the other untagged — and treated alike (2026-09-28, on
   M1's five albums).
7. The plausibility verdict is **dropped** (§15.21). No verdict column, no
   release-fit rule.
8. Step 8c, **before step 9**, since the badge step displays what this corrects.

### §0.3 What earlier steps establish and this must honour

- §13.2: the collection is never stored; nothing here changes that.
- §15.4: the ownership pass never identifies and never snapshots. The job is not
  the pass, and it writes only the derived columns.
- §15.16 part 3: `conflict` is the importer's, and sticky. The pass never writes
  or clears it.
- §2a: a row carrying a decision or a recovery snapshot is never deleted; the
  derived columns are regenerable and so constrain nothing.
- §13.8: rejected a per-album lookup **per sync**. This is one lookup per
  release, once, and the result is a bare identifier. The difference is argued in
  §5, not assumed.

### §0.4 The measurements this rests on

| | |
|---|---|
| Node F's gap | 5 albums mislabelled `absent`; 21 more node F would also decide, already right via the title route; 303 of 329 unhelpable; 29 releases with no master (hand-off 18) |
| Cross-track tags | 467 agree, 2 partial, 3 disagree, 82 untagged, 24 single-track, 186 all-remote (M1) |
| Release fit | 464 consistently-tagged albums; **zero** mis-identified; every threshold flags only false positives (M2) |
| Deleted releases | 3 of 479 identified albums 404 (M2) |

All from one library of 764 albums and a 203-item collection, tagged by one
person. Thin in the way one library is always thin.

---

## §1. Group A — the derived master

### §1.1 Migration 6 (`Schema.pm`, appended to `@MIGRATIONS`)

Three columns on `discogs_match`:

```sql
ALTER TABLE squeezewax.discogs_match ADD COLUMN derived_master_id INTEGER;
ALTER TABLE squeezewax.discogs_match ADD COLUMN derived_from_release_id INTEGER;
ALTER TABLE squeezewax.discogs_match ADD COLUMN derived_at INTEGER;
```

- `SCHEMA_VERSION` is `scalar @MIGRATIONS` (`Schema.pm:32-45`), so this is
  `_migration_6` and yields `user_version 6`.
- Re-runnable by `_migration_4`'s `pragma_table_info` guard — this is
  `ADD COLUMN`, which is what that guard is for.
- **The three columns together express four states**, which is why there are
  three and not one:
  - all NULL — never looked;
  - `derived_from_release_id` set, `derived_master_id` set — looked, found;
  - `derived_from_release_id` set, `derived_master_id` NULL — **looked, and there
    is no master**: a 404, or a release Discogs reports with no master. This is
    the state that stops the job asking again, and without it every run would
    re-fetch the 29 masterless releases forever.
  - `derived_from_release_id` different from the row's current
    `discogs_release_id` — stale, re-derive (ruling 4).
- `derived_at` is for the log and for a human reading the table; nothing branches
  on it.
- `schema-check.pl`: migration 6 adds exactly three columns; re-runs are no-ops;
  a version-5 database migrates with every existing row otherwise byte-identical.

### §1.2 The job (`SqueezeWax/Derive.pm`, new)

A server-side module with one public entry point. Not part of `API/Async.pm`,
which is already the collection client and long enough; not part of the pass,
which must stay request-free.

**What it selects.** Rows where `discogs_release_id IS NOT NULL` and
(`derived_from_release_id IS NULL` or `derived_from_release_id <> discogs_release_id`).
Ordered for determinism. On a settled library this is empty and the job returns
immediately without touching the network.

**What it does per row.** `GET /releases/{id}` through
`Slim::Networking::SimpleAsyncHTTP` (server side, so async — `CLAUDE.md`'s
transport rule), built by `API->buildRequest` and classified by
`API->classifyResponse` exactly as the sync does. From the response it takes
**`master_id` and nothing else**, and the response is dropped. Then it writes the
three columns for every album row carrying that release id — one fetch may settle
several albums.

**Outcomes:**

| response | written |
|---|---|
| 200 with a master id | `derived_master_id` = it, `derived_from_release_id`, `derived_at` |
| 200 with `master_id` absent or 0 | `derived_master_id` NULL, the other two set |
| **404** | same as above — looked, nothing there. Logged at info, not error (§15.21) |
| 401 | stop the run; the token is the sync's problem, not this job's to report |
| anything else | leave the row untouched and stop the run; the next run retries |

The 0-and-absent collapse matches `Match::recordManual`'s guard and
`Ownership::_indexCollection`'s: a `master_id` of 0 at face value would make every
masterless release collide on one key at node F.

**Pacing and yielding (rulings 2 and 3).** At most **30 requests per run**, one a
second, and a run is re-armed a minute later while work remains. That is half
Discogs' documented 60 a minute, leaving room for a manual sync. Before each
request: stop if `API::Async->isRunning`, and stop if the shared rate accounting
reports no budget. Never starts while a scan is running (`Match->_writeOk`, which
refuses server-side writes during a scan anyway).

**Triggered** from `Plugin::_syncDone` on success, and from nothing else: the
collection is what makes ownership interesting, and a library with no sync has no
badges to fix. No startup run and no interval — §15.15 part 1's rule that this
plugin makes no unattended call to Discogs on a schedule is honoured, because the
job's work is bounded by a library that only a scan changes.

**One shared rate state.** `API/Async.pm` keeps `$rateState` at module scope; a
second independent throttle against one budget is how a 429 arrives that nobody
can explain. Move the state into `API.pm` and have both consumers read and write
it. *Cost, named:* it touches `Async.pm` and `sync-check.pl`'s rate assertions,
in a step that is otherwise not about the sync.

### §1.3 Node F reads the derived master (`Ownership.pm`)

- `_loadRows` selects the three new columns.
- `_decide` computes the effective master once, before node F:
  the tag-derived `discogs_master_id` if present, else `derived_master_id` **only
  when `derived_from_release_id` equals the row's `discogs_release_id`**. A stale
  derivation is ignored rather than trusted.
- Node F's own test is otherwise untouched, including its `$master != 0` guard.
- **The pass never writes the derived columns**, and `_write`'s `@COLUMNS` table
  does not gain them. §15.4's rule holds: the pass derives ownership and a review
  reason, nothing else.
- `ownership-check.pl`: node F fires from a derived master and produces `version`;
  a stale `derived_from_release_id` is ignored; a tag-derived master still wins;
  `derived_master_id` of 0 or NULL behaves as no master; the determinism pair
  still holds; and the five measured albums' shape — release absent from the
  collection, master present — badges `version` rather than `absent`.

---

## §2. Group B — tags that disagree across tracks

### §2.1 The comparison (`Importer.pm::_examine`)

Today the loop stops at the first candidate that answers (`:479-494`). Instead:
read **both** candidates (there are at most two, `Library.pm:230-244`), decide
each, and compare.

| candidate 1 | candidate 2 | outcome |
|---|---|---|
| id X | id X | identified, as today |
| id X | id Y | **disagreement** |
| id X | no Discogs tag | **disagreement** (ruling 6) |
| id X | conflict within that file | conflict, as today |
| no tag | no tag | no tag, as today |
| — | album has one candidate | identified from it, as today |

An album with a single local track has one candidate and cannot disagree with
itself; M1 counted 24 such albums and they must keep working.

**Cost:** one extra file read per *examined* album. The importer skips albums
whose files have not changed (`_canSkip`), so in steady state this is near
nothing; on a wipe-and-rescan it is one extra read per album, which on this
library's NAS is of the order of a minute.

### §2.2 What a disagreement records (`Match.pm`)

It routes to the existing `_recordConflict`, which already does exactly the right
things: `review_reason = 'conflict'`, tier `strict`, state `candidate`, release id
**NULL on a fresh conflict** and the incumbent preserved otherwise, no snapshot,
sticky until the tags are fixed (§15.16 part 3), and a warning naming the album.

Consequences, which are the point: a fresh cross-track disagreement leaves the
album with **no release id**, so node C skips it, no ownership is derived from a
contested tag, and node F cannot badge it. The `Cover Versions/` folder that would
have been badged wrongly (album 3421, ids 793593 and 369197) becomes a queue item
instead, at zero request cost and at identification time.

**One reason value, not two.** A judgement call, stated for objection: `conflict`
covers both halves, because the column's job is "this album's tags are contested"
and the remedy is the same — look at the tags, fix them or re-match. What differs
is the **message**, and that is display, not state.

### §2.3 What the user is told (`strings.txt`, `Queue.pm`)

The existing conflict text says two tags name different releases, which is true of
a within-file conflict and wrong for these. The `conflict` list handed to
`_recordConflict` must carry **which file said what**, and the queue must render
the two cases distinctly:

- different ids across tracks: name both ids and the tracks they came from;
- one tagged, one not: say that only some files carry a Discogs tag, and which.

§15.17 part 3 is the precedent: a message that tells the user something untrue
about their library is worse than a missing feature. The "Show tags" action
(§15.17 part 1) already re-reads that album's candidates on demand and needs no
change.

`match-check.pl`: each row of §2.1's table; a fresh cross-track disagreement
writes a NULL release id and `conflict`; an incumbent survives one; fixing the
tags clears it through `_recordMatch`; a single-candidate album is unaffected.

---

## §3. The seam suite — `scripts/derive-check.pl`

New, picked up by `check-all.sh`'s glob. Honest stubs following
`sync-check.pl:209-262`.

1. **Selection.** A settled library selects nothing and issues no request. A
   changed release id re-selects that row. A row that was looked at and had no
   master is **not** re-selected.
2. **Outcomes.** 200 with a master, 200 without, 404, 401, 500 — each writes what
   §1.2's table says and nothing else.
3. **Pacing.** No more than 30 requests in a run; stops when a sync is running;
   stops when the budget is spent; re-arms while work remains.
4. **The join that matters:** derive → `_loadRows` → node F → `version`. Including
   the stale case, which must **not** badge.
5. **Nothing Content-shaped is written.** Assert the columns written are exactly
   the three, and that no title, artist or tracklist reaches the database. This is
   §9.5 made testable rather than promised.

---

## §4. Model and phasing for Claude Code

**Model:** Opus. A new writer on the one table that is not disposable, and a
change to how identification decides.

| | |
|---|---|
| P | this plan, decisions §15.22, TODO edits (hand-off 26) |
| A1 | migration 6 (+`schema-check.pl`) |
| A2 | the shared rate state moves to `API.pm` (+`sync-check.pl`, `api-check.pl`) |
| A3 | `Derive.pm` and its trigger (+`derive-check.pl`) |
| A4 | node F reads the derived master (+`ownership-check.pl`) |
| B1 | `_examine` compares both candidates (+`match-check.pl`) |
| B2 | the conflict message and the queue's rendering (+`queue-check.pl`, `syntax-check.sh`) |
| D | docs: design §3 node F, `CLAUDE.md`, TODO ticks |

Then a package build for §5's hardware checks.

A2 before A3 so the job is never written against a throttle it will not use.
Group B is independent of group A and may be built first if that is easier; the
plan's order is not a dependency.

---

## §5. The §13.8 argument, written out

§13.8 replaced per-album Discogs searches with collection-first ownership: 4
requests for 203 items against 764 requests. This step adds per-release lookups,
which is the shape §13.8 refused, so the difference is argued rather than assumed:

- **Once per release, not once per sync.** §13.8's 764 requests were paid *every
  time ownership was derived*. These are paid once per release id, ever, and a
  settled library makes none.
- **Bounded by identified albums, not by the library.** 479 of 764 albums here,
  and 475 distinct releases.
- **What is kept is a bare identifier**, which §9.5 permits indefinitely — so the
  request is not repeated to keep it fresh (ruling 4).
- **It buys something collection-first cannot.** The collection tells us which
  masters the user owns; nothing in it tells us the master of a release the user
  does *not* own, which is precisely node F's question.
- **Measured cost:** 475 requests, 11.0 minutes, on a cold library of this size,
  spread across runs of 30. A settled library: zero.

---

## §6. Hardware checks (after merge, on the reference server)

0. **Before.** Back up both databases; record `discogs_match`'s row count, the
   queue's contents, and the ownership counts.
1. **Migration 6** in the live server; `user_version` 6; three columns present and
   NULL on every row; nothing else changed.
2. **The job runs and finishes.** After a sync, watch it derive in slices of 30.
   Expect ~475 releases over ~16 runs, no 429, and the log to show it yielding
   when a manual sync is pressed. A second pass after completion must issue
   **zero** requests.
3. **The five albums badge.** The measured bucket-1 albums — 2927, 2974, 3022,
   3023, 3421 — recheck each: the first four should become `version` via node F;
   **3421 should not**, because group B should have made it a conflict first.
4. **404 is quiet.** Albums 2895, 2944 and 3045 name deleted releases. Expect an
   info line, the three columns written with a NULL master, and no retry on the
   next run.
5. **The covers folders queue.** All four `Cover - …` albums become `conflict`
   queue items with a message naming what each file said. *The Baseballs* (3396)
   too — check its files first, since `TODO.md` flags it as worth a look.
6. **Nothing Content-shaped is stored.** Dump the new columns and confirm they
   hold integers and nothing else; `discogs_release_cache` still holds 0 rows.
7. **Scan interaction.** The job during a scan: refused, and resumed afterwards.
8. **Timings**, for the record: a derive run's wall time, the extra cost of
   `_examine`'s second read on a wipe-and-rescan, and the pass unchanged at
   41–46 ms.

Anything that cannot be provoked goes to `TODO.md` rather than being marked
passed.
