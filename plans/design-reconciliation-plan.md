# Design-reconciliation plan — how `docs/squeezewax-design.md` gets rewritten

**Planned 2026-09-13 (design chat).** Successor to
`plans/design-reconciliation-survey.md`, which found the twenty contradictions
and is not re-derived here. This file sorts them, records what each is replaced
by, and fixes the order of the rewrite.

Rulings taken to unblock this plan are in `docs/squeezewax-v1-decisions.md` §14.
Section references name their document, per `docs/working-agreement.md` §2.

**Scope, unchanged from the survey:** reconcile design only. Not the build
order, not migration 3's implementation, not the pages 2–3 measurement. The
survey's List 2 is binding — a section recorded as surviving untouched is not
rewritten because it reads oddly beside a rewritten neighbour.

---

## Sync state at the time of planning

Project knowledge verified current 2026-09-13 against five artifacts that
postdate the prior session: the survey, decisions §13.10 ending at §13.10.6,
design's reconciliation banner, `scripts/title-agreement.pl`, and
working-agreement §2's section-reference paragraph. All five present.

**One partial:** the banner's claim of eleven section markers was not counted.
Four were observed directly — design §3 (tier table), §9, §10, §13. Retrieval
returns chunks, not files, so this was confirmation of currency rather than an
inventory. **Claude Code must grep the marker count before removing them**, so
step 6 below removes eleven and not four.

---

## List 1 sorted

**CORRECT** — prose is stale, the replacement is already decided.
**DECIDE** — §13 removed something without replacing it. All three are now
resolved; the resolution is named.

| # | Design location | Bucket | Replaced by |
|---|---|---|---|
| A | §2 "the owned pressing" | CORRECT | exact / version / absent (§13.3); version badges on title+artist (§13.10.2) |
| B | §3 scan-time matching, stored tuple | CORRECT | ownership is its own pass off a completed sync (§13.6); three triggers (§13.7); ownership column (§13.3); `match_tier` per §14.1 |
| C1 | §3 the cascade | CORRECT | collection-first identification (§13.1); §13.8 supersedes §8 whole |
| C2 | §3 Strict auto-confirm | CORRECT | narrowed by §13.4; exact confirmation intact per §13.10.2 |
| C3 | §3 Structural auto-confirm | CORRECT | nothing structurally confirms (§13.4, §13.8) |
| C4 | §3 `local_tracks == 0` gate | CORRECT | removed; all albums in scope (§13.10.1) |
| D | §3 matching flowchart | CORRECT | redrawn from §13.1 / §13.3 / §13.10.2 / §13.10.3; terminal node per §14.5 |
| E | §3 walkthroughs 2 and 4 | CORRECT | rewritten from measured cases in §13.10.3 / §13.10.4 |
| F | §3 badge-derivation note | CORRECT | stored ownership label (§13.3); no `discogs_collection` join (§13.2) |
| G | §3 confirmation & feedback loops | CORRECT | requirement survives; queue contents per §13.10.5; obsolete ground (c) per §14.4 |
| H | §3 multi-disc box sets | CORRECT | no duration rule in v1; §13.8 leaves duration-as-ranker open for later only |
| I | §3 re-match triggers | CORRECT | §13.6 (no file-state skip for ownership) + §13.7 (sync's own triggers) |
| J | §4 the "When" bullet | CORRECT | §13.10.2 + §13.10.3 |
| K | §4 badge-state flowchart | CORRECT | as D; single terminal state per §14.5 |
| L | §4 badge context menu | CORRECT | §13.3 takes the pressing-vs-edition decision; collection metadata dropped per §14.6 |
| M | §5 opening paragraph | CORRECT | §13.2 (nothing cached) + §13.1 (3 requests, seconds) |
| N1 | §8 "local cache" | CORRECT | §13.2 |
| N2 | §8 resumability | CORRECT | §13.6 |
| N3 | §8 token revocation | **DECIDE → resolved** | §14.2 |
| O | §9 Matching settings | CORRECT | settings shrink; L2 is fixed by §13.10.4, not a pref |
| P | §9 Collection/value settings | CORRECT | additive: manual sync button + last-synced timestamp (§13.7), plus the auth-failure state (§14.2) |
| Q1 | §10 `discogs_collection` table | CORRECT | §13.2, reaffirming `TODO.md` 2026-09-07 |
| Q2 | §10 ownership column | CORRECT | §13.3 — values and migration 3 |
| Q3 | §10 `match_tier` vocabulary | **DECIDE → resolved** | §14.1 — nullable, CHECK narrowed to `strict \| manual` |
| Q4 | §10 dual ownership test | CORRECT | collapses to reading the stored label (§13.3) |
| R | §11 v1 scope & roadmap | **DECIDE → resolved** | §14.3 — Fuzzy deleted; wantlist stays v2; marketplace lookup stays v1 |
| S | §12 multi-disc follow-up | CORRECT | deleted; nothing left to validate (§13.8) |
| T | §13 budget table | CORRECT | two-part rewrite per §14.7 |

### Findings the survey did not carry

Raised while sorting; all four resolved before the rewrite.

| | Finding | Resolution |
|---|---|---|
| U | A wrongly auto-badged album never enters the queue, so there is no way to reverse it | §14.4 — nothing built in v1; design §11 states the well-maintained-library assumption |
| V | Both flowcharts end in a node that needs the exact-vs-version question answered | §14.5 — one badge state |
| W | §4's context menu promises collection metadata via an unverified endpoint | §14.6 — dropped from v1 |
| X | The rewritten budget has no row for on-demand cost | §14.7 — two-part table |

### Two corrections to the survey's own framing

Recorded because the survey is the starting point and these would otherwise be
carried forward as read.

1. **N.3 is not wholly false.** Design §8 claims matching *and* read-only
   browsing survive revocation. Matching does not (§13.1). Browsing does —
   `/database/search` returns 200 unauthenticated, **verified**, `TODO.md`
   2026-09-07. The premise underneath both ("app-level auth") is wrong either
   way, since v1 uses a personal access token (§9.1). §14.2 removes the whole
   sentence rather than rescuing half of it, and deliberately declines to
   promise the unauthenticated path.
2. **"Unowned records nothing" does not follow from "not in the collection
   means not owned".** An unowned album still records its identification when a
   tag supplies one (§13.3, §5), the ownership label `absent` (§13.3), and a
   `discogs_no_match` row. The reconciliation must not write prose implying an
   empty row, and must not let the review queue key on `state = 'candidate'` —
   most albums are unowned candidates (§13.4; `TODO.md` 2026-09-12).

---

## Order of the rewrite

Dependency order, not document order. Steps 1–4 are complete.

1. ~~Decide `match_tier`~~ — done, §14.1.
2. ~~Settle token revocation and the roadmap~~ — done, §14.2, §14.3.
3. ~~Rule on U, V, W, X~~ — done, §14.4–§14.7.
4. ~~Land the rulings and this sorted list~~ — done: decisions §14 and this file.
5. **Rewrite, in this sequence:**
   §10 → §3 → §4 → §5 → §8 → §9 → §11 → §12 → §13 → §2.
   §10 first because §3 and §4 both reference the data model. §2 last because
   it is one paragraph summarising everything above it.
6. **Remove the markers and the banner in a single final pass**, after the
   prose is done. Section-by-section removal would leave the document in a
   state where the precedence inversion is silently gone but the prose is still
   stale — the exact condition the markers exist to prevent. Grep the count
   first (see the sync note above).
7. **Verify:** every List 2 section byte-identical; no `structural` or `fuzzy`
   outside a historical clause; no bare `§N` introduced (working-agreement §2);
   the document still clean UTF-8 with no mojibake (survey's encoding note).

## Swept during the rewrite, not separately

Both from `TODO.md`'s housekeeping item, both predating §13:

- **Design §10** — "a collection re-sync of roughly 20 requests (§4)". Figure
  is wrong (measured 3, §9.4 / §13.1) and "(§4)" points at design's own Badge
  section, not a budget. Fix during step 5's §10.
- **Design §11** — "OAuth + Collection sync" under v1. Contradicted by §9.1
  (user-supplied personal access token, 2026-09-07), `CLAUDE.md`, and design
  §13's own inline correction. Fix during step 5's §11.

## Deliberately not in this session

Recorded, not designed. Each has a `TODO.md` item.

- The build-order rewrite. `plans/build-order-step-4-structural-matching.md` is
  stale in its entirety and is not patched.
- Migration 3's implementation, including the rebuild obligations in §14.1.
- The pages 2–3 measurement.
- Trimming design §7 to a minimum marketplace lookup.
- The per-release collection-entry endpoint question (§14.6).
