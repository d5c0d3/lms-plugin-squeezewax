# Build-order rewrite — Q6 ruling and Q1 closure, 2026-09-15

**Drafted 2026-09-15 (design chat).** Third handoff of the session, after
`plans/build-order-rewrite-2026-09-15-handoff.md` and `-2.md`. Scaffolding; no
authority once applied.

Paste fenced block **contents** exactly. No placeholders.

**Block A is conditional.** It records existing behaviour as a rule, so the
prompt's Phase 0 verifies that behaviour first. If Phase 0 contradicts it,
Block A does not land and comes back to the design chat.

---

## Block A — append to `docs/squeezewax-v1-decisions.md`, after §15.3

````
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
the `snapshot_*` columns in the same upsert as the identification.
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
````

---

## Block B — close Q1 in `TODO.md`

Find these two consecutive lines inside the build-order-rewrite item:

```
        Leaning: the pass does it, now that §15.2 runs it after identification.
        Not decided.
```

Replace **both** with:

````
        Leaning: the pass does it, now that §15.2 runs it after identification.
        RESOLVED 2026-09-15 — decisions §15.3, as the leaning above: the pass
        promotes and demotes; migration 3 copies `state` unchanged
        (obligation (e) on the migration item).
````

---

## Block C — close Q6 in `TODO.md`

Find these two consecutive lines inside the same item:

```
        Design §10's comment is a wording defect either way — add to the
        design-fix item when Q6 is ruled. Not decided.
```

Replace **both** with:

````
        RESOLVED 2026-09-15 — decisions §15.4: capture stays at
        identification, conflict rows never carry a snapshot, and the pass
        neither captures nor refreshes. No code change; the residual is
        design §10's wording, now item (e) of the design-fix list.
````

---

## Block D — add (e) to `TODO.md`'s design-fix item

Find these two consecutive lines:

```
      (d) Design carries none of decisions §3's tag-name specification (see
          the ticked tag-names item).
```

Insert immediately after them, at the same indentation:

````
      (e) Design §10: the `snapshot_*` comment says "captured at confirm
          time". Decisions §15.4 puts capture at identification, which is
          where the code has always put it; confirm time is now a different
          moment in a different process (§15.2, §15.3).
````
