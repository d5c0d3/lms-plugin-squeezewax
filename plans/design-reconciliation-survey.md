# Design-reconciliation survey — decisions §13/§13.10 against design

**Surveyed 2026-09-12 (design chat, via Claude Code).** Scope of this survey:
`docs/squeezewax-design.md` read in full against `docs/squeezewax-v1-decisions.md`
§13 and §13.10, looking for every place design states something, present tense
and without qualification, that decisions §13 contradicts.

This is scaffolding for a reconciliation that has not happened yet. The markers
placed in `docs/squeezewax-design.md` off the back of this survey are temporary —
they come out when design is rewritten in its own voice around the
collection-first flow (decisions §13), citing decisions for the reasoning, with
no superseded prose retained. That is a separate design-chat session. This file
is the record the reconciliation session should start from, so the survey does
not need re-deriving.

Section references name their document, per `docs/working-agreement.md` §2.

---

## List 1 — contradicted

### A. Design §2 — Core Concept

**Claim:** "Ownership awareness — see at a glance which albums in LMS you own
physically; inspect details and value of **the owned pressing**." (line 137)

**Contradicted by decisions §13.3 / §13.10.2.** Ownership now has two strengths —
*exact* (that release id is in the collection) and *version* (a different release
under the same master is) — and §13.10.2 badges version ownership from title and
artist alone. "The owned pressing" describes only the exact case.

### B. Design §3 — "Matching runs at library scan time via `Importer.pm`"

**Claim:** lines 150–152, and the stored tuple
`album_key → discogs_release_id, match_tier, state, matched_at` (line 155).

**Contradicted by decisions §13.1, §13.2, §13.3, §13.6, §13.7.** Identification
for ownership runs against the collection during its sync, which has three
triggers of its own (scan start, interval pref, manual button — §13.7), and
ownership is a separate pass triggered by a *completed* sync, not the importer's
per-album loop (§13.6). The tuple omits the ownership column §13.3 adds.

### C. Design §3 — "Three matching tiers — a cascading pipeline" (the tier table)

Four distinct contradictions in one place:

1. **The cascade itself** (lines 168–172: Strict → Structural → Fuzzy, Settings
   selecting a maximum tier) — **superseded by decisions §13.8 in full**: §8's
   candidate enumeration, the `type=master` search, ranking on `community.have`,
   the per-album fetch cap and the duration-vector verdict are all gone, and
   §11's zero-result title-only retry with them. Fuzzy has no whole-database
   search left to make.
2. **Strict's "Auto-confirm when the configured tags agree"** (line 176) —
   **narrowed by decisions §13.4**: `state = 'confirmed'` now requires the tagged
   release id *and* that same id present in the collection. (§13.10.2 corrects
   §13.4's badging claim but leaves exact confirmation unchanged.)
3. **Structural's "Auto-confirm"** (line 177) — **superseded by decisions §13.4
   and §13.8**: nothing is structurally confirmed now.
4. **"The only gate that holds is `local_tracks == 0`"** (line 177) —
   **explicitly removed by decisions §13.10.1**: all albums are in scope,
   including all-remote ones; the gate excluded 186 of 765 albums (24%) and
   removing it matched 10 additional owned records.

### D. Design §3 — "Matching pipeline (flowchart)" (lines 188–202)

The Structural track-shape and Fuzzy artist+title branches no longer exist
(§13.8), and node H ("Badge painted, color from Collection list state") is wrong
twice over — the badge reads the stored ownership label (§13.3), not a
`discogs_collection` join, and does not require confirmation (§13.10.2).

### E. Design §3 — Example walkthroughs 2 and 4 (lines 210–231)

Walkthrough 2 describes a search yielding six pressings narrowed by duration
vector; walkthrough 4 describes a Fuzzy search for a Spotify album. Both describe
the flow §13.8 supersedes. Walkthrough 4's premise ("no local files… no
durations to fingerprint") is precisely the population §13.10.1 brings into scope
and §13.10.2 lets auto-badge.

### F. Design §3 — "Match states per album", the badge-derivation note (lines 248–253)

**Claim:** badge state is "derived at render time by joining the confirmed
release against `discogs_collection.list_state`".

**Contradicted by decisions §13.2** (no Discogs Content persists; the sync holds
each page in memory and discards it — reaffirming TODO's 2026-09-07 ruling
against a `discogs_collection` mirror), **§13.3** (ownership is its own column)
and **§13.10.2** (a confirmed state is not required to badge).

### G. Design §3 — "Confirmation & feedback loops" (lines 255–267)

The reject/dismiss requirement survives, but the argument that reaches it — "it
is skipped by Structural because a `discogs_match` row exists" — no longer
applies (§13.8).

### H. Design §3 — "Multi-disc releases & box sets (resolved)" (lines 272–279)

**Claim:** a box set is "only promoted to **Structural-tier confirmation** if
every disc matches". **Superseded by decisions §13.4 / §13.8** — there is no
Structural confirmation. Whether duration comparison returns at all, as a ranker
rather than a verdict, is explicitly open in §13.8.

### I. Design §3 — "Re-match triggers" (lines 281–297)

All four triggers key on file or user state, and "Confirmed matches are otherwise
stable across rescans". **Contradicted by decisions §13.6**: ownership
deliberately does not use the file-state skip, because buying a record changes
nothing on disk — a full rescan does not recover the badge. §13.7 supplies the
sync's own triggers.

### J. Design §4 — the "When" bullet (lines 318–319)

**Claim:** the badge paints "for albums in **confirmed** match state whose linked
release is in the user's Collection". **Superseded by decisions §13.10.2 and
§13.10.3**: an unambiguous title-and-artist match against the collection —
exactly one entry agreeing on both — badges version ownership with no tag, no
confirmed state and no local file. Several candidates, or artist disagreeing or
absent on either side, go to the queue instead.

### K. Design §4 — "Badge-state derivation (flowchart)" and its walkthrough (lines 352–370)

Both tests in the diagram are wrong: `B` gates on confirmation (§13.10.2) and `D`
reads `discogs_collection.list_state` (§13.2, §13.3).

### L. Design §4 — "Badge context menu" first bullet (lines 391–394)

**Claim:** "An edition-level (Structural) match has no resolved pressing to show
here — see TODO.md for what it shows instead, **a product decision not yet
taken**." **Decisions §13.3 takes it**, explicitly settling §8's
"recorded, not taken" and closing the pressing-versus-edition conflation TODO has
carried since 2026-09-07. Separately, "Collection data: date added/acquired,
condition/grading if tracked" is not held locally under §13.2 and needs a live
fetch.

### M. Design §5 — the opening paragraph (lines 412–414)

**Claim:** "pulls the user's Collection (and optionally Wantlist) into a **local
cache** via a **slow background sync job**". **Contradicted by decisions §13.2**
(nothing is cached — conclusions only) and **§13.1** (3 requests for a 203-item
collection; `ceil(items/100)` per sync, seconds not hours).

### N. Design §8 — three claims

1. "Badges render entirely from the **local cache** (match table + **collection
   cache**)" (lines 553–555) — no collection cache exists (§13.2).
2. "matching is resumable — already-matched albums are skipped (cached)" (lines
   589–591) — true of identification, false of ownership (§13.6).
3. "**matching** and read-only browsing (which work with app-level auth)
   **continue**" after token revocation (lines 594–598) — **contradicted by
   §13.1**: the collection *is* where identification happens, and it needs the
   token. (Decisions §9.2 independently falsifies the "search does not require
   authentication" premise underneath it.)

Also an **omission rather than a contradiction**: §13.7's rule that a failed or
partial sync leaves previous ownership conclusions untouched. Design's "stale
data simply persists" is compatible but does not state it, and §13.7 calls a
silently vanished badge the same failure as a silently wrong one.

### O. Design §9 — "Matching" settings (lines 608–616)

"Maximum matching tier enabled: Strict / Structural / Fuzzy" and "Duration margin
for structural matching" configure a cascade that no longer runs (§13.8), and
"Multi-disc releases require all discs to match for auto-confirmation" has no
tier to govern (§13.4). The maintenance action and review-queue behaviour
survive.

### P. Design §9 — "Collection / value" settings (lines 641–646)

**Incomplete, not wrong.** Decisions §13.7 requires a manual "Sync collection
now" button and a visible last-synced timestamp; neither is listed. Both were
already specified in TODO, 2026-09-07.

### Q. Design §10 — the data model

1. **The `discogs_collection` table** (lines 686–692) and the paragraph asserting
   it is "entirely regenerable, and that is a design property worth relying on"
   (lines 720–732) — **contradicted by decisions §13.2**: v1 builds no such
   table. **This ruling predates decisions §13** — it was taken 2026-09-07 in
   `TODO.md` ("no `discogs_collection` mirror in v1"), and §13.2 reaffirms it
   rather than creating it. The same paragraph's "a collection re-sync of
   roughly 20 requests (§4)" is contradicted by §13.1's measured 3, and its
   "(§4)" points at design's Badge section rather than a budget — a stray defect,
   predating §13, worth noting separately (see below).
2. **`discogs_match` has no ownership column** — §13.3 lands it in migration 3.
3. **`match_tier (strict | structural | fuzzy | manual)`** — `structural` and
   `fuzzy` are no longer produced, and §13.8 leaves a possible fifth value open
   ("**Decide before migration 3**").
4. **The dual ownership test** (lines 734–748) —
   `release_id in owned_releases` OR (`master_id` present and not the sentinel
   AND `master_id in owned_masters`). **Superseded by §13.3**: ownership is a
   stored label (exact | version | absent) written by the sync, not a render-time
   expression — and **the test has no branch at all for the title-and-artist
   route** §13.10.2 and §13.10.3 create, which is now the main path. This is a
   missing primary path, not stale prose, and changes what the reconciliation has
   to write rather than merely correct.

### R. Design §11 — v1 Scope & Roadmap (lines 754–767)

"Strict + **Structural** matching" is v1's headline (§13.8 supersedes
Structural), and "Fuzzy tier (streaming-album matching)" sits in v2 while
§13.10.1 puts all-remote albums in v1 scope now. Separately and **not** a §13
contradiction: "**OAuth** + Collection sync" is a live defect against decisions
§9.1, `CLAUDE.md` and design §13's own inline correction — flagged because it
sits in an unmarked present-tense line (see the stray-defects note below).

### S. Design §12 — the multi-disc follow-up (lines 792–795)

"Multi-disc matching (§3) is defined for standard multi-CD/LP releases; edge
cases… should be validated against real Discogs release data" — there is no
duration-vector multi-disc rule left to validate (§13.8).

### T. Design §13 — the scan-time budget table (lines 820–844)

The table already carries a "needs a full rewrite" note, but that note asks for
corrected **per-album** figures — now itself the wrong question. **Decisions
§13.1** replaces the whole shape: `ceil(items/100)` requests **per sync**,
measured at 3 for 203 items, scaling with collection size rather than library
size. The Structural row and "an album with eight pressings costs nine requests"
describe a flow that no longer runs. (The Owned-badge row's corrected
`ceil(items/100)` is the one figure that survives and is now the whole budget.)

---

## List 2 — expected to be contradicted, but is not

Recorded because the reconciliation needs this list as much as the other one.

- **Design §2's items 2 and 3, and §7 in full.** Decisions §13.1 says marketplace
  lookup and cross-browsing "move from scan time to on demand" — but design
  already has them on demand (§2 line 138 says "on demand"; §7 is titled "On
  Demand Only"). §13.1 makes on-demand the *only* path for an unowned album; it
  does not contradict what design says. **This candidate does not hold.** Design
  §6's Flow 1 likewise already resolves live against Discogs.
- **Design §3's `album_key` identity paragraph** (lines 158–164) — §13.8 keeps
  decisions §2 and §2a "in full".
- **Design §3's Candidate state and its two Strict variants** (lines 236–245) —
  §13.3: "§3a's NULL-id invariant is untouched."
- **Design §3's review-queue reject/dismiss requirement** — survives, and §13.10.5
  restates the queue's contents around it.
- **Design §4's glyph, corner, colours, per-edition granularity, rendering note
  and licensing caveat** — untouched. §13.8 raises "whether the badge shows one
  state or two" as open, deciding nothing.
- **Design §8's transaction, commit-cadence, abort and write-lock paragraphs** —
  §13.7 leans on `_writeOk`/`_writeRefusal` and on the abort-commits finding
  rather than displacing them.
- **Design §10's `album_key`, `source_timestamp`, `snapshot_*` columns,
  `discogs_no_match` and `discogs_release_cache`** — §13.2 explicitly confirms the
  `snapshot_*` columns are LMS-side and stay; §13.8 keeps §2/§2a whole.
- **Design §9's "clear & rebuild matches"** clearing `discogs_no_match` — §13.8
  keeps decisions §10 intact.
- **Design §13's 60 req/min rate limit and the single-threaded async/sync rule** —
  untouched.
- **Design §1 in full**, and §5's feature list, currency handling and caveats.

---

## Stray defects found, outside decisions §13's scope

Found while surveying; not fixed here; not caused by decisions §13. To be swept
up during the reconciliation.

- **Design §10** cites "a collection re-sync of roughly 20 requests (§4)" — the
  figure is wrong even before §13 (measured 3, not 20, per decisions §9.4 /
  §13.1), and "(§4)" points at design's own Badge section, not a request-budget
  section.
- **Design §11** lists "OAuth + Collection sync" under v1 scope — contradicted by
  decisions §9.1 (a user-supplied personal access token, decided 2026-09-07),
  `CLAUDE.md`, and design §13's own inline correction elsewhere in the same
  document.

---

## Literal-string note

The prompt driving this survey quoted `The only gate that holds is
local_tracks == 0`. It appears at `docs/squeezewax-design.md:177` wrapped in
backticks around the expression (``The only gate that holds is `local_tracks ==
0` ``). Matched on that basis.

## Encoding note

`docs/squeezewax-design.md`, `docs/squeezewax-v1-decisions.md`, `TODO.md` and
`docs/working-agreement.md` are all clean UTF-8. Distinct non-ASCII in design:
`§ ± – — … →`; in decisions, those plus `× ²`. No mojibake (`Ã`, `â€`, `Â`,
`ï¿½`, U+FFFD) found anywhere.
