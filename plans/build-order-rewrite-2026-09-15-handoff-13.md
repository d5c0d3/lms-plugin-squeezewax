# Build-order rewrite — completing obligation (i)'s suite list, 2026-09-18

**Drafted 2026-09-18 (design chat).** Thirteenth handoff, and a correction to
handoff 12. Scaffolding; no authority once applied.

Paste fenced block **contents** exactly. No placeholders.

**Why this exists.** §15.10 and obligation (i) both name only the two insert
sites in `scripts/schema-check.pl`. Claude Code found a third:
`scripts/schema-check.pl:231` lists `discogs_collection` in the
"expected tables exist" loop. Dropping the table fails the suite there too.

**How the omission happened, recorded because it is this session's recurring
shape.** The grep in handoff 11's Phase 0 reported three line numbers — 231, 288
and 293. A later report characterised 288 and 293 as "the two insert sites", and
handoff 12 was written from that characterisation rather than from the three
numbers already in hand. The same mechanism as the miscounted "Not decided."
marker: a list built from a description of the artifact instead of the artifact.

---

## Block A — correct §15.10 in `docs/squeezewax-v1-decisions.md`

**Revised 2026-09-18** after Claude Code stopped the first version. That version
named a two-line run whose second line was only a prefix of the real line —
line 3749 continues " It is a test rather than", and replacing it whole would
have deleted that tail and left a sentence fragment. The anchor had been written
from a search result's line wrapping rather than from the line itself.

This is a **substring** replacement, not a line replacement. Find this text,
which occurs once:

```
(verified 2026-09-18 by Claude Code, two insert sites).
```

Replace that text, and nothing else on the line, with:

````
~~(verified 2026-09-18 by Claude Code, two insert sites)~~ — **corrected
2026-09-18: three sites, not two. Two inserts plus the "expected tables exist"
loop. The count was taken from a summary that named two of the three as "the
insert sites", rather than from the grep that had already listed all three.**
````

The text following it on that line — " It is a test rather than" — and every
line after it are untouched. After the edit, read the whole paragraph back and
confirm it is a single coherent sentence sequence with no fragment.

---

## Block B — complete obligation (i)'s last sub-bullet in `TODO.md`

Find these three consecutive lines:

```
          - UPDATE `scripts/schema-check.pl` in the same change: the
            `list_state` CHECK assertions and both inserts go, since the
            table they exercise will not exist.
```

Replace **all three** with:

````
          - UPDATE `scripts/schema-check.pl` in the same change. THREE sites,
            not two — corrected 2026-09-18, the earlier text named only the
            inserts: the two inserts, the `list_state` CHECK assertions around
            them, AND the "expected tables exist" loop, which asserts the
            table is present. Do not work from this list alone: grep the suite
            for `discogs_collection` and account for every hit, because this
            enumeration has already been wrong once.
````
