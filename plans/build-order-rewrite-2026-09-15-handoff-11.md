# Build-order rewrite — enumerate the tables in CLAUDE.md, 2026-09-18

**Drafted 2026-09-18 (design chat).** Eleventh handoff, and a one-line
correction to handoff 10. Scaffolding; no authority once applied.

**Why this exists.** Handoff 10's Block A replaced `CLAUDE.md`'s step 2 with a
cross-reference — "the tables in design §10" — instead of naming the tables.
That was wrong, and the reason is worth keeping rather than quietly fixing:

**A stale list is greppable; a stale pointer is not.** The defect handoff 10
set out to fix was found precisely because `discogs_collection` appears
literally in `CLAUDE.md`. Replacing the names with a cross-reference would have
made the next such drift invisible rather than absent — and a cross-reference
can rot on its own if design is renumbered, leaving no string to search for.

The distinction handoff 10 should have drawn: a **volatile sequence** changes as
decisions land and wants one home, so `implementation-plan` §1 rightly points at
`CLAUDE.md` for it. **Settled names** are worth repeating wherever someone might
grep for them. `discogs_collection` in particular should appear in `CLAUDE.md`
*with its status*, so a grep lands on the truth instead of on silence.

`plans/build-order-rewrite-2026-09-15-handoff-10.md` as committed may carry
either the cross-reference draft or the revised one, depending on which file was
saved. Either way it stays as committed — it is a record of what was proposed,
and this handoff is the record of the correction.

---

## Block A — enumerate the tables in `CLAUDE.md`'s step 2

Find this single line:

```
2. SQLite schema, migrations 1 and 2 — the tables in design §10 — **done**
```

Replace it with:

````
2. SQLite schema, migrations 1 and 2 — **done**. v1's tables are
   `discogs_match`, `discogs_no_match`, `discogs_release_cache` and
   `discogs_price_snapshot` (design §10). Migration 1 also creates
   `discogs_collection`, which v1 must not have — see below
````

**If that line is not found**, quote `CLAUDE.md`'s step 2 exactly as it stands
and STOP this block. If it already names the four tables, the revised handoff 10
was the one applied and there is nothing to do — say so.
