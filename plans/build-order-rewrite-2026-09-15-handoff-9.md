# Build-order rewrite — migration 3's position in the sequence, 2026-09-18

**Drafted 2026-09-18 (design chat).** Ninth handoff of the session, after
`plans/build-order-rewrite-2026-09-15-handoff.md` and `-2.md` through `-8.md`.
Scaffolding; no authority once applied.

Paste fenced block **contents** exactly. No placeholders.

**Dates:** §15.1 to §15.7 are dated 2026-09-15, §15.8 and §15.9 are 2026-09-18.
That is correct — the session spans several days and each record is dated to
when its decision was taken. Do not normalise.

---

## Block A — append to `docs/squeezewax-v1-decisions.md`, after §15.8

````
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
- Removing `discogsMaxTier` (§15.8), removing the `local_tracks == 0` gate
  (§13.10.1), redefining `hasAnyStrictMatch`, and the detection bare-master fix
  — none touches the schema.

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
````

---

## Block B — correct §15.3's window sentence in `docs/squeezewax-v1-decisions.md`

Find these two consecutive lines:

```
Steps 4 and 5 of the build order land before the sync exists at step 6. In that
window `discogs_match` holds old rows saying `confirmed` under the pre-§13.4
```

Replace **both** with:

````
~~Steps 4 and 5 of the build order land before the sync exists at step 6.~~ —
**corrected 2026-09-18 by §15.9: the order is identification, sync, migration 3,
ownership pass, so this window spans three steps rather than two.** In that
window `discogs_match` holds old rows saying `confirmed` under the pre-§13.4
````

---

## Block C — correct migration-3 obligation (d) in `TODO.md`

Find these four consecutive lines:

```
      (d) CONFIRM the orphan-recovery index `(state, snapshot_track_count)`
          needs no change. Recovery selects `state = 'confirmed'`, so NULL
          rows should be excluded by the predicate — INFERRED from the
          predicate, not verified against a query plan (decisions §14.8).
```

Replace **all four** with:

````
      (d) ~~CONFIRM the orphan-recovery index `(state, snapshot_track_count)`
          needs no change. Recovery selects `state = 'confirmed'`, so NULL
          rows should be excluded by the predicate — INFERRED from the
          predicate, not verified against a query plan (decisions §14.8).~~
          **CORRECTED 2026-09-18 (decisions §15.9): SUPERSEDED BY (g).** This
          was written under §14.8, when recovery keyed on `state =
          'confirmed'`. §15.5 moved the predicate off `state` and (g) rebuilds
          the index accordingly. Do (g); do not "confirm no change" here.
          The struck text is kept because the reasoning it carries — that a
          predicate-based exclusion is inferred rather than verified against a
          query plan — still applies, and (g) inherits it.
````

---

## Block D — update the step-4 line in `TODO.md`'s sequence

Find these three consecutive lines:

```
      4 identification rework (importer stops writing `confirmed`; drop the
        `local_tracks == 0` gate; detection bare-master fix; stale comments;
        `hasAnyStrictMatch` semantics);
```

Replace **all three** with:

````
      4 identification rework (importer stops writing `confirmed`; drop the
        `local_tracks == 0` gate; write `snapshot_artist`, §15.5; build the
        unambiguous orphan relink, §15.5; remove `discogsMaxTier`, §15.8;
        detection bare-master fix; stale comments; `hasAnyStrictMatch`
        semantics. The `use` gate does NOT change, §15.8);
````

---

## Block E — reorder steps 5 and 6 in `TODO.md`'s sequence

Find these two consecutive lines:

```
      5 migration 3 (its obligations as already recorded in this file);
      6 collection sync (server-side, async — decisions §15.2);
```

Replace **both** with:

````
      5 collection sync (server-side, async — decisions §15.2). Testable on
        its own: three requests, last-synced timestamp advances, nothing
        written to `discogs_match`;
      6 migration 3 (its obligations as already recorded in this file).
        REORDERED 2026-09-18 by decisions §15.9, and it SHIPS WITH step 7 —
        reviewable as its own step, not merged ahead of the code that
        exercises it;
````
