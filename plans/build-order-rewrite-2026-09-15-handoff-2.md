# Build-order rewrite — Q1 ruling and follow-on records, 2026-09-15

**Drafted 2026-09-15 (design chat).** Second handoff of the session, successor
to `plans/build-order-rewrite-2026-09-15-handoff.md`. Scaffolding, as that one
is: it has no authority once applied.

Paste fenced block **contents** exactly. No placeholders in this file.

---

## Block A — append to `docs/squeezewax-v1-decisions.md`, after §15.2

````
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
and `absent` overstates it for one sync interval. The alternative is a fourth
value for "not yet synced", which would have to be handled at every read site
forever to buy accuracy in a window that closes by itself. §14.9 already accepts
this exact shape: badges are dark until the next sync completes.

#### The cost, recorded rather than hidden

Steps 4 and 5 of the build order land before the sync exists at step 6. In that
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
````

---

## Block B — add obligation (e) to `TODO.md`'s migration-3 item

Find the line
`          predicate, not verified against a query plan (decisions §14.8).`
and insert immediately after it, at the same indentation:

````
      (e) COPY `state` AND `match_tier` FORWARD UNCHANGED, and set
          `ownership = 'absent'` on every copied row (decisions §15.3). COUNT
          rows before and after the rebuild and assert equal; assert that no
          row's `state` differs from its pre-migration value. The ownership
          pass, not the migration, re-derives `state`.
````

---

## Block C — add Q5, Q6, Q7 to `TODO.md`'s build-order-rewrite item

Find the line
`      Dependencies the design chat believes are already in TODO.md, not`
and insert immediately before it, at the same indentation as the other `Q`
lines:

````
      Q5 — RECORDED as its own item under "Open design questions": orphan
        recovery's reach shrinks under decisions §13.4. Blocks step 8.
      Q6 — when is the orphan-recovery snapshot captured? Design §10 says
        "at confirm time", which was the same instant as identification while
        `_recordMatch` confirmed. Decisions §15.2 and §15.3 split them across
        two processes. Leaning: capture at identification, since the scanner
        has the LMS album data in hand and the pass would otherwise re-read it
        per promotion. CONSTRAINT, verified in `Match.pm::_recordNoMatch`: the
        one permitted deletion requires `state = 'candidate' AND
        discogs_release_id IS NULL AND snapshot_track_count IS NULL`, so
        capturing a snapshot on a CONFLICT row would make that delete
        unreachable and leave phantom conflict rows in the queue forever.
        Whatever is decided must leave conflict rows without a snapshot.
        Design §10's comment is a wording defect either way — add to the
        design-fix item when Q6 is ruled. Not decided.
      Q7 — which step owns orphan recovery? It is NOT built: its `TODO.md`
        item ("writes an UPDATE, not an INSERT") is unticked and `Match.pm`
        has no relink path. The step-2 plan deferred it to "step 3/4" and
        step 3 did not take it. The proposed sequence above does not name it.
        Not decided.
````

---

## Block D — new `TODO.md` item under `## Open design questions`

Find the line
`      v1 caller** once Structural is gone and the sync is server-side`
and insert the item below immediately after the line `      is planned.` that
follows it, at the start of a new line:

````
- [ ] **2026-09-15: orphan recovery's reach shrinks under decisions §13.4, and
      it can lose user work.** Recovery selects `state = 'confirmed'`
      (§14.8, inferred from the predicate; the index is commented "confirmed
      rows whose snapshot might fit a new album" in
      `Schema.pm::_migration_1`). Under §13.4 only OWNED albums reach
      `confirmed`, so two classes now sit permanently outside recovery: a
      tagged-but-unowned album, and — the one that matters — **a MANUAL match
      on an unowned album**, which is work the user typed. When `album_key`
      changes (files moved, retagged, library rebuilt) those rows orphan with
      no relink path and the manual choice is gone, silently.
      Recovery may need to key on "has an identification"
      (`match_tier IS NOT NULL`) rather than on `state`, or `manual` rows may
      need their own clause. This is a consequence of §13.4 that predates the
      build-order rewrite and was never followed through. Recovery is not yet
      built (see Q7), so deciding it now costs nothing but a ruling. Blocks
      the review-queue/manual-re-match step.
````
