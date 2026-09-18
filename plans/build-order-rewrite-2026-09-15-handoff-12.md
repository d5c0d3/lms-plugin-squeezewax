# Build-order rewrite — the `discogs_collection` drop, 2026-09-18

**Drafted 2026-09-18 (design chat).** Twelfth handoff. Scaffolding; no authority
once applied.

Paste fenced block **contents** exactly. No placeholders.

**Why this exists.** Handoff 10 put a plain statement into `CLAUDE.md` —
"Migration 1 creates it and migration 3 drops it" — while the drop itself lives
in a `TODO.md` item *separate from* migration 3's obligations (a) to (h). An
implementer working that list would not drop the table, and `CLAUDE.md` would
have told them it happens. That is a disagreement this session created, and it
is fixed here rather than left.

Two things it also settles, both found by Claude Code while applying handoffs 10
and 11:

- **"Zero readers and writers" is already false.** `scripts/schema-check.pl`
  inserts into `discogs_collection` at two places. Not plugin code, but the
  drop breaks the offline suite unless the same edit covers it — the shape
  obligation (h) already carries for `discogs_no_match.tier`.
- **`plans/build-order-step-4-structural-matching.md` carries no stale
  marker**, while `CLAUDE.md` now names it as stale in its entirety.

---

## Block A — append to `docs/squeezewax-v1-decisions.md`, after §15.9

````
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
(verified 2026-09-18 by Claude Code, two insert sites). It is a test rather than
plugin code, so it does not block the drop — but it does mean the suite fails
the moment the table is gone unless the same edit removes those assertions.
Recorded so the confirmation step is not reported as "zero found" when the
answer is "zero in `SqueezeWax/`, two in the suite".

#### Scope

Wantlist (v2) will need collection-entry storage of some kind, and `TODO.md`
carries a struck v2 item about rekeying this table. Dropping it now does not
prejudge that: a v2 table would be designed against v2's requirements rather
than inheriting an `instance_id` primary key that cannot hold wants.
````

---

## Block B — add obligation (i) to `TODO.md`'s migration-3 item

Find these two consecutive lines:

```
          - The drop costs one rescan's worth of re-reads for untagged
            albums. Expected, not a defect.
```

Insert immediately after them, at the same indentation as the `(h)` line:

````
      (i) DROP `discogs_collection` and its index `discogs_collection_release`
          (decisions §15.10). A plain `DROP TABLE IF EXISTS` — the table is
          entirely regenerable and carries no decision, unlike
          `discogs_match`. Two sub-obligations:
          - CONFIRM FIRST that nothing in `SqueezeWax/` reads or writes it.
            The 2026-09-13 item requires this and it still stands.
            ALREADY KNOWN, so do not report "zero": `scripts/schema-check.pl`
            inserts into the table at two sites (verified 2026-09-18).
          - UPDATE `scripts/schema-check.pl` in the same change: the
            `list_state` CHECK assertions and both inserts go, since the
            table they exercise will not exist.
````

---

## Block C — add a stale banner to `plans/build-order-step-4-structural-matching.md`

Find this single line — the file's first line:

```
# Build order step 4 — Structural matching
```

Replace it with:

````
# Build order step 4 — Structural matching

> **STALE IN ITS ENTIRETY — 2026-09-18. Do not patch, do not use as a
> template, do not mine for shape.** This plans the Strict → Structural →
> Fuzzy cascade against a per-album Discogs search. Decisions §13.8 replaced
> that with collection-first ownership and §14.3 deleted Fuzzy from the
> roadmap, so there is no Structural tier for this to plan. The build order
> from step 4 is in `CLAUDE.md` and `docs/squeezewax-v1-decisions.md` §15.9.
>
> Kept as a record of what was planned, in the same spirit as the
> reconciliation scaffolding in this directory. Its §0 — "what step 3
> established that step 4 must honour" — is the one part whose *shape* is
> still worth copying, because `TODO.md` requires the new step-4 plan to open
> the same way; its *contents* are about Structural and do not carry over.
````
