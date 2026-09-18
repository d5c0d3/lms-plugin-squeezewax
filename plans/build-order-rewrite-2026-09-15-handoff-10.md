# Build-order rewrite — the canonical build-order lists, 2026-09-18

**Drafted 2026-09-18 (design chat).** Tenth handoff of the session. Scaffolding;
no authority once applied.

Paste fenced block **contents** exactly. No placeholders.

**Why these two documents and not more.** `CLAUDE.md` is loaded at the start of
every Claude Code conversation (working-agreement §4), and its Build order
section still names step 4 as Structural-tier matching — a tier decisions §13.8
deleted. A session opening to build step 4 is told that before it reads anything
else, with `plans/build-order-step-4-structural-matching.md` sitting beside it
in agreement. `docs/implementation-plan.md` §1 carries the same list.

**No strikethrough in these two.** Working-agreement §7.7's
strikethrough-and-correction convention is for decision records, where the
reasoning is the point. `CLAUDE.md` is live operating instructions, and
`implementation-plan` §1 is a build list — struck text in either is something a
reader might act on. Both are replaced outright, as design was during the
reconciliation, with a pointer to decisions §15.9 for the reasoning. This is the
same distinction working-agreement §2 draws between live spec and record.

**One list, one home.** Both documents currently carry the same five-step list,
which is the duplication working-agreement §2 calls a defect. After this,
`CLAUDE.md` holds the list — it is the auto-loaded one — and
`implementation-plan` §1 points at it.

---

## Block A — replace the Build order section of `CLAUDE.md`

Replace everything from the line:

```
## Build order
```

through the line:

```
OAuth, and is in scope for step 4.
```

inclusive, with:

````
## Build order

**v1 only** (design §11), in this order. Steps 1-3 are done and
hardware-verified on Lyrion 9.1.1. The sequence from step 4 is
`docs/squeezewax-v1-decisions.md` §15.9, which also records why migration 3
sits where it does.

1. Plugin skeleton + `install.xml` that LMS actually loads — **done**
2. SQLite schema, migrations 1 and 2 — the tables in design §10 — **done**
3. Strict identification from file tags — **done**
4. **Identification rework** — stop writing `state = 'confirmed'` without a
   collection check (decisions §13.4, design §3 node E); drop the
   `local_tracks == 0` gate (§13.10.1); write `snapshot_artist` and build the
   unambiguous orphan relink (§15.5); remove the `discogsMaxTier` pref
   (§15.8). The importer's `use` gate does **not** change (§15.8)
5. **Collection sync** — server-side, asynchronous, on `['rescan','done']`
   plus an interval and a manual button (§15.2, §13.7)
6. **Migration 3** — the `discogs_match` rebuild. Reviewable on its own,
   but **ships with step 7 and is never merged ahead of it** (§15.9)
7. **Ownership pass** — design §3's flow, writing the `ownership` column
8. **Review queue + manual re-match**
9. **Owned badge + badge context menu**
10. **On-demand marketplace lookup**

**There is no Structural tier and no Fuzzy tier.** Decisions §13.8 replaced the
per-album Discogs search with collection-first ownership, and §14.3 deleted
Fuzzy from the roadmap. `plans/build-order-step-4-structural-matching.md` is
stale in its entirety: do not patch it, do not use it as a template, do not
mine it for shape.

**`discogs_collection` is not a v1 table.** Migration 1 creates it and
migration 3 drops it (§13.2, and `TODO.md` 2026-09-07). Nothing may read or
write it. Ownership is a column on `discogs_match`, not a mirrored collection.

v1 auth is a user-supplied Discogs personal access token (§9.1), never OAuth.
Token handling, request construction and rate-limit accounting are already
built; they serve the collection sync at step 5.
````

---

## Block B — replace §1 of `docs/implementation-plan.md`

Replace everything from the line:

```
## 1. Build order
```

through the line:

```
v2/v3 do not start until matching works end to end.
```

inclusive, with:

````
## 1. Build order

**The build order lives in `CLAUDE.md`, and the sequence from step 4 is
`docs/squeezewax-v1-decisions.md` §15.9.** It is not restated here.

Both documents carried the same five-step list until 2026-09-18, and both went
stale together when decisions §13.8 removed the Structural tier — which is the
duplication `docs/working-agreement.md` §2 calls a defect rather than a
convenience. One statement, in the document Claude Code loads at the start of
every session.

**What this section's neighbours still assume.** The file skeleton in §2 and
parts of §4 were written against the Strict → Structural → Fuzzy cascade and
have not been reconciled; decisions' own header already declares §4.3 and §4.6
superseded. Treat this document as a record of how v1 was planned to be built,
not as live instructions, until that reconciliation happens. It is tracked in
`TODO.md`.
````

---

## Block C — new `TODO.md` item under `## Open design questions`

Add at the end of that section:

````
- [ ] **2026-09-18: `docs/implementation-plan.md` needs its own
      survey-then-reconcile session.** Same shape as the design
      reconciliation, and deliberately NOT done during the build-order
      rewrite — that session's scope was the build order, and reopening a
      second document because a plan found it convenient is how a boundary
      erodes. §1 is fixed (it now points at `CLAUDE.md` and decisions §15.9).
      Known-stale entries, not a complete survey:
      (i)   §2's file-skeleton table describes `Importer.pm` as the
            "Scan-time matching cascade (Strict → Structural → Fuzzy)";
      (ii)  §4.3 and §4.6 are declared superseded by decisions' own header;
      (iii) anything else in §2-§4 written against the per-album Discogs
            search (§13.1) or the `discogs_collection` mirror (§13.2).
      Working-agreement §2 makes this a defect to reconcile, so it should not
      sit indefinitely. Survey first, as the design reconciliation did, so
      the session starts from a list rather than deriving one.
````
