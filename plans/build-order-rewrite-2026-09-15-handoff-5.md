# Build-order rewrite — Q2 ruling, 2026-09-15

**Drafted 2026-09-15 (design chat).** Fifth handoff of the session, after
`plans/build-order-rewrite-2026-09-15-handoff.md`, `-2.md`, `-3.md` and `-4.md`.
Scaffolding; no authority once applied.

Paste fenced block **contents** exactly. No placeholders.

Block D is a convention fix, not a ruling. Two consecutive reports from Claude
Code caught the design chat asserting that a settled question still read
"Not decided." when it never did — the marker was never applied to Q2, so Q2
was not greppable as open. Block D states the convention in the item itself.

---

## Block A — append to `docs/squeezewax-v1-decisions.md`, after §15.5

````
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
````

---

## Block B — add obligation (h) to `TODO.md`'s migration-3 item

Find this line:

```
          that the recovery lookup uses it, per obligation (d)'s standard.
```

Insert immediately after it, at the same indentation:

````
      (h) NARROW `discogs_no_match.tier` to `CHECK (tier IN ('strict'))`
          (decisions §15.6), by `DROP TABLE IF EXISTS` and recreate — NOT by
          copying, so surviving `'structural'` rows are discarded rather than
          failing the copy. Three sub-obligations:
          - GREP first and confirm nothing writes `'structural'` to this
            table. §15.6 records that as inferred, not verified.
          - UPDATE `scripts/schema-check.pl`: `'structural'` must now be
            REJECTED, and the "same album_key takes a second row under a
            different tier" case has no second valid tier in v1, so it
            changes shape rather than being deleted.
          - The drop costs one rescan's worth of re-reads for untagged
            albums. Expected, not a defect.
````

---

## Block C — close Q2 in `TODO.md`

Find these two consecutive lines inside the build-order-rewrite item:

```
        dropped and recreated rather than rebuilt. Not in migration 3's
        recorded obligations as far as the design chat read.
```

Replace **both** with:

````
        dropped and recreated rather than rebuilt. Not in migration 3's
        recorded obligations as far as the design chat read.
        RESOLVED 2026-09-15 — decisions §15.6: it narrows to `strict`, by
        DROP and recreate inside migration 3, keeping the `tier` column and
        the composite PK. Now obligation (h) on the migration item.
````

---

## Block D — state the Q-line convention in `TODO.md`

Find this line inside the same item:

```
      Open questions blocking it:
```

Replace it with:

````
      Open questions blocking it. CONVENTION: an open one ends with
      "Not decided."; a settled one carries a "RESOLVED <date>" line naming
      the decision record. Grep for "Not decided." to list what is still
      open — two design-chat reports were wrong about this because the
      marker had not been applied consistently.
````
