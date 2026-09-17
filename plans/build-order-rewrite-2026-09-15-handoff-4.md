# Build-order rewrite — orphan recovery ruling, 2026-09-15

**Drafted 2026-09-15 (design chat).** Fourth handoff of the session, after
`plans/build-order-rewrite-2026-09-15-handoff.md`, `-2.md` and `-3.md`.
Scaffolding; no authority once applied.

Paste fenced block **contents** exactly. No placeholders.

Two blocks carry corrections to text this same design chat wrote three turns
earlier (Block B, Block E). Both preserve what was believed, per
working-agreement §7.7. Neither is a quiet edit.

---

## Block A — append to `docs/squeezewax-v1-decisions.md`, after §15.4

````
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
3. **Reach.** Recovery considers any orphaned row that has an identification
   and a snapshot — `match_tier IS NOT NULL AND snapshot_track_count IS NOT
   NULL` — not rows selected on `state`.
4. **Ownership.** Recovery belongs to the identification step: it runs in the
   scanner, on a key miss, before the tag read. The unambiguous relink is built
   there; the ambiguous branch is an obligation on the review-queue step.

#### Why: recovery exists for manual rows

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
````

---

## Block B — correct the snapshot sentence in decisions §15.4

Find these two consecutive lines:

```
**Verified by reading, not observed running:** `Match.pm::_recordMatch` writes
the `snapshot_*` columns in the same upsert as the identification.
```

Replace **both** with:

````
**Verified by reading, not observed running:** `Match.pm::_recordMatch` writes
~~the `snapshot_*` columns~~ — **corrected 2026-09-15: `snapshot_album_title`
and `snapshot_track_count` only. Nothing in the code writes `snapshot_artist`
or `snapshot_total_duration`; see §15.5** — in the same upsert as the
identification.
````

---

## Block C — close Q5 in `TODO.md`

Find these two consecutive lines inside the build-order-rewrite item:

```
      Q5 — RECORDED as its own item under "Open design questions": orphan
        recovery's reach shrinks under decisions §13.4. Blocks step 8.
```

Replace **both** with:

````
      Q5 — RESOLVED 2026-09-15 — decisions §15.5: recovery considers any
        orphaned row with an identification and a snapshot
        (`match_tier IS NOT NULL AND snapshot_track_count IS NOT NULL`),
        not rows selected on `state`. The premise of the original item was
        partly wrong; see its own item, now ticked.
````

---

## Block D — close Q7 in `TODO.md`

Find these two consecutive lines inside the same item:

```
        step 3 did not take it. The proposed sequence above does not name it.
        Not decided.
```

Replace **both** with:

````
        step 3 did not take it. The proposed sequence above does not name it.
        RESOLVED 2026-09-15 — decisions §15.5: recovery belongs to the
        identification step (step 4), which builds the unambiguous relink.
        The ambiguous branch is an obligation on the review-queue step.
````

---

## Block E — tick and correct the recovery-reach item in `TODO.md`

Find the item whose first line is:

```
- [ ] **2026-09-15: orphan recovery's reach shrinks under decisions §13.4, and
```

1. Change its `[ ]` to `[x]`.
2. Insert `~~` immediately before `Under §13.4 only OWNED albums reach` and
   `~~` immediately after `which is work the user typed.` — the struck span
   runs across several lines. Delete nothing.
3. Append, as the last lines of the item, indented to match:

````
      2026-09-15, CORRECTED AND RESOLVED — decisions §15.5. The struck claim
      was wrong: design §3 says confirming a manual link writes
      `match_tier = 'manual'` and `state = 'confirmed'`, and a manual link is
      explicitly exempt from the collection cross-check that governs Strict.
      So manual rows DO reach `confirmed` and were never outside a
      `state`-keyed predicate. What was right: `state` is the wrong key.
      Conflict-demoted rows keep an adjudicated id and their snapshots (§3a)
      while sitting at `candidate`, and they are the rows whose tags can no
      longer reproduce their identification. §15.5 keys reach on having an
      identification instead.
````

---

## Block F — add obligations (f) and (g) to `TODO.md`'s migration-3 item

Find this line:

```
          pass, not the migration, re-derives `state`.
```

Insert immediately after it, at the same indentation:

````
      (f) DROP `snapshot_total_duration` (decisions §15.5). Nothing in v1
          reads or writes it; the rebuild makes dropping it free. COUNT the
          columns of the rebuilt table and assert the expected set.
      (g) REBUILD the orphan index to match §15.5's predicate
          (`match_tier`, `snapshot_track_count`) instead of
          `(state, snapshot_track_count)`. Verify with EXPLAIN QUERY PLAN
          that the recovery lookup uses it, per obligation (d)'s standard.
````

---

## Block G — add items (f) and (g) to `TODO.md`'s design-fix item

Find this line:

```
          moment in a different process (§15.2, §15.3).
```

Insert immediately after it, at the same indentation:

````
      (f) Design §10 lists `snapshot_total_duration`; decisions §15.5 drops
          it in migration 3. Design §10's snapshot comment also still names
          four columns.
      (g) Design §10's orphan index is `(state, snapshot_track_count)`;
          decisions §15.5 keys recovery on having an identification, and
          migration 3 rebuilds the index accordingly (obligation (g)).
````

---

## Block H — new `TODO.md` item under `## Next — build-order steps 3–5 (matching)`

Add at the end of that section:

````
- [ ] **2026-09-15: nothing writes `snapshot_artist`, so orphan recovery
      cannot work.** VERIFIED 2026-09-15: one grep hit, the DDL in
      `Schema.pm::_migration_1`. `Match.pm::_recordMatch` writes
      `snapshot_album_title` and `snapshot_track_count` only. Decisions §15.5
      makes artist part of the fit predicate, so the identification step
      (step 4) must start writing it. Conflict rows still carry no snapshot
      (§15.4). Offline assertions to add: a clean hit writes all three
      snapshot columns; a conflict row's snapshot columns are NULL; the
      narrow delete still fires on a conflict row whose tags were removed.
````

---

## Block I — new `TODO.md` item under `## Open design questions`

Add at the end of that section:

````
- [ ] **2026-09-15: a retagged album title defeats orphan recovery, and a
      manual row's work is lost.** Decisions §15.5's predicate is exact
      equality on artist, album title and track count. Change the title tag
      and nothing fits, so the row stays orphaned — for a tagged album
      identification re-derives the match anyway, but a MANUAL row's choice
      is gone with no notice. Recorded rather than solved: two-of-three
      matching and normalised comparison both trade a fail-safe predicate for
      a guess. Revisit if it happens on hardware.
````
