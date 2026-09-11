# Build order step 4 — Structural matching

**Planned 2026-09-07 (design chat). Branch `v1-buildout`.**

Design authority: `docs/squeezewax-design.md` §3 (tiers), §4 (derivation), §9
(maintenance), §10 (schema), §13 (request budget).
Decision authority: `docs/squeezewax-v1-decisions.md` §8 (the Structural
matching algorithm) and §9 (Discogs API access). **This plan does not restate
§8 or §9. Where they disagree with anything below, they win.**

---

## §0. What step 3 established that step 4 must honour

Step 3's plan did this for step 2's findings; this is the same shape. One
branch and full visibility of step 3's code do not stop step 4 writing
`recordStructural` alongside `recordStrict` in a way that skips `_writeOk`,
reimplements the manual guard wrongly, widens the narrow delete predicate, or
breaks invariant 1.

### 0.1 The write policy is a pure function, and it stays one

`_writeRefusal($ready, $isScanner, $isScanning)` in `SqueezeWax/Match.pm`, with
`_writeOk` reading the environment around it. Verified by
`scripts/match-check.pl`, six exhaustive cases.

The reason is not style. `slimserver.pl` has `use constant SCANNER => 0` and
`scanner.pl` has `=> 1`; `use constant` creates an inlinable sub, so
`return 1 if main::SCANNER` is resolved at `Match.pm` compile time and is **not
in the optree** in the server process. One process cannot exercise both sides.
The scanner branch is the one whose removal silently stops the importer writing
anything at all, so it is the branch that most needs a test, and the only way to
test it is to make the policy a function of its inputs.

**Obligation:** `recordStructural` calls `_writeOk`. It does not re-derive the
policy, add a fourth input, or inline a `main::SCANNER` check of its own. If
Structural needs a different rule, the change is to `_writeRefusal`'s signature
and its six cases, not a parallel path.

**New in step 4, and deliberately kept separate:** `_writeRefusal` answers "may
we write?" Structural introduces a second, unrelated question — "may we spend a
request?" — with different inputs (credentials present, rate-limit budget
remaining, tier enabled). Do **not** fold it into `_writeOk`. That would make
the pure function impure for a reason unrelated to writing.

### 0.2 The manual guard is rule one, for every tier

`match_tier = 'manual'` is never overwritten by any tier. Verified in
`scripts/match-check.pl`: a manual row keeps release 777 and tier `manual` even
when a clean strict hit for 123 arrives.

Two details step 4 will otherwise get wrong:

- The cheap columns **are** refreshed on a manual row — `source_timestamp` and
  `lms_album_id` — or the importer re-examines it on every scan forever. The
  suite records that `ON CONFLICT … WHERE` was **verified not to work** here: it
  leaves the row entirely untouched.
- `invalidateStrict` NULLs `source_timestamp` `WHERE match_tier = 'strict'`, so
  `manual` falls outside the predicate. The test protecting this has no other
  coverage.

**Obligation:** Structural is the second tier to test this, and the first to
test it from a tier that did not write the row. The guard is not "Strict does
not overwrite manual" — it is "nothing overwrites manual."

### 0.3 The narrow delete predicate — Structural does not use it

`Match.pm::_recordNoMatch` holds the one permitted deletion:

```
match_tier = 'strict' AND state = 'candidate'
  AND discogs_release_id IS NULL AND snapshot_track_count IS NULL
```

The rule behind it (decisions §2a invariant 2): **never delete a row carrying a
decision or a recovery snapshot.** `'strict'` excludes manual, `'candidate'`
excludes confirmed, NULL id excludes anything adjudicated, NULL snapshot
excludes orphan recovery's index material.

**Structural needs no delete path at all.** The predicate exists to clear a
phantom conflict — a `(strict, candidate, NULL, NULL)` row whose tags have since
been removed. Structural produces no analogous row.

**Do not parameterise the predicate by tier.** A `$tier`-parameterised version
would be the widening decisions §2a warns against, dressed as a refactor, and it
becomes reachable the moment a later tier writes a NULL-id row. A structural
NULL-id row (decisions §8) must never become collateral.

### 0.4 Invariant 1 and the schema asymmetry

Invariant 1: an album never has a row in both `discogs_match` and
`discogs_no_match` for the same tier. No constraint can express it — foreign
keys are banned (decisions §2), SQLite has no cross-table CHECK — so `Match.pm`
enforces it, detected for free by `$STATE_SQL` returning two rows.

**The asymmetry step 4 will trip over:**

- `discogs_no_match` is `PRIMARY KEY (album_key, tier)` — two rows per album.
  Verified, `Schema.pm::_migration_2`.
- `discogs_match` is `album_key TEXT NOT NULL PRIMARY KEY` — **one row per
  album, no tier in the key.** Verified, `Schema.pm::_migration_1`, and
  confirmed by `recordStrict`'s `ON CONFLICT(album_key) DO UPDATE`.

Consequences:

1. **Structural cannot write a match row alongside a strict one.** It would have
   to `UPDATE` the single row and flip `match_tier`, destroying what the strict
   row recorded. So "skip any album with a `discogs_match` row" is not a policy
   choice — it is what the schema permits. Decisions §3a independently rejects
   Structural fall-through on its own merits: *"a Structural search could
   auto-confirm a third release over the top of two tags the user wrote
   deliberately."*
2. **The demoted-row case is a step-5 dependency, not a step-4 defect.** A row
   demoted to `(strict, candidate, incumbent-id)` whose tags were then removed
   cannot be deleted (it carries a decision) and cannot be re-matched (a match
   row exists). Step 4 asserts this state is terminal until step 5's
   reject/dismiss; the offline suite asserts Structural skips it rather than
   leaving the behaviour undefined.
3. **The enforcement machinery is strict-only and must not be copied.**
   `_clearNoMatch($dbh, $key)` hardcodes `AND tier = 'strict'`. `$STATE_SQL`'s
   no-match arm hardcodes `AND tier = 'strict'`. A `structuralState()` written
   by pattern-matching on `strictState()` inherits both and silently never
   detects a structural invariant-1 violation. **Generalise both by tier
   parameter** — this is the one place tier parameterisation is correct, and
   0.3 is the one place it is not.

### 0.5 The skip contract does not transfer

For Strict: a row exists **and** `source_timestamp` equals the current
`MAX(tracks.timestamp)` over local tracks. NULL never compares equal, so a NULL
never skips, and §3b depends on that. Verified in `scripts/match-check.pl`.

For Structural this is **incomplete**. File state is a complete key for Strict —
the answer lives in the files. A structural no-match failed because of *Discogs'
catalogue*, not the file. The file will never change, so `source_timestamp`
matches forever and a `discogs_no_match` row at tier `'structural'` becomes
permanent: the album is never searched again for the life of the library.

**Structural's skip predicate is a conjunction of two independent freshness
tests:** `source_timestamp` unchanged **AND** `checked_at` within a TTL.
`checked_at` already exists — decisions §2a: *"inert for Strict and load-bearing
for Structural."* No migration.

Proposed TTL: **30 days, as a pref.** Not TOU-constrained — a no-match records
our own finding, not Discogs Content (decisions §9.5). Cost of re-checking is
bounded: one search per expired album, ~9 minutes at 60/min for 500 albums.

### 0.6 §3b needs a structural clause

Decisions §3b's *Step 4 note*, verbatim: *"If a later tier ever derives its
answer from a pref, it needs its own invalidation clause here."*

**That trigger has fired.** Structural's duration margin is a pref (design §9,
default ±2–3 s) and directly determines whether a candidate matches. Widening it
from ±2 s to ±5 s should re-examine every structural no-match; under the current
invalidation it re-examines nothing, for the same silent reason §3b was written
to fix — no file moved.

`Settings.pm::_setChanged` demonstrates the pattern and records the trap:
`Slim::Utils::Prefs::Base::set` dispatches onchange on `… || ref $new`, so an
arrayref pref fires on every save regardless of change. A scalar numeric pref
will not have that problem, but the "compare, don't trust the dispatch" habit
carries over.

Accepted coverage gap, unchanged from §3b: a change made via the CLI or a
hand-edited prefs file misses the hook. Escape hatch is "clear & rebuild
matches" — see §4 below.

### 0.7 The `use` gate

Current gate is `scalar @{discogsTagNames}`, which becomes wrong the moment
Structural lands — Structural needs no tag names.

**New gate:** `@discogsTagNames || ($maxTier ne 'strict' && $token)`.

Two notes:

- "Structural enabled" is not a boolean. Design §9 specifies a single
  **maximum-tier selector** (Strict / Structural / Fuzzy) where *"the cascade
  always starts at Strict and stops at the selected tier."* Do not add a second
  boolean pref and end up with two sources of truth.
- **The max-tier pref's default is DECIDED 2026-09-07: `'strict'`.** A fresh
  install matches only tag-carrying albums, spends zero Discogs requests, and
  needs no token. Structural is opt-in, so the `use` gate keeps its original
  purpose of suppressing per-scan log noise on an unconfigured install.
  Rejected: `'structural'` as the default — it would attempt an unattended
  cold structural pass on a fresh install, hours of requesting from a user
  who opted into nothing, and it would make the gate true for everyone,
  defeating its purpose (`runImporter` logs `Starting $importer scan` at
  *error* level inside the `use` guard, `Slim/Music/Import.pm:573-579`).
  **Accepted cost:** for a library tagged by MusicBrainz/Picard rather than a
  Discogs-aware tagger, a `'strict'` default does nothing on first run and the
  plugin can appear broken. Mitigated by settings-page copy explaining what
  each tier does and what Structural costs, NOT by changing the default.
- The token conjunct is a **choice, not a necessity**: decisions §9.2 records
  that unauthenticated search returns 200. It buys 2.4× throughput and the user
  needs a token for ownership anyway.

### 0.8 Both step-3 falsifications, as calibration

Named because this is the calibration, not a solved problem. Both had the shape
*a mechanism verified for one path, stated as a general property*:

- `tracks.timestamp` on remote rows is **not** structurally NULL. Spotty
  supplies its own `TIMESTAMP` via `updateOrCreate`: 2858 of 2982 remote tracks
  carried one.
- An aborted scan **does** commit: exit → END → theEND → sigint → cleanup →
  forceCommit.

**Step 4's research produced five more instances**, all recorded in decisions §8
and §9 and in `TODO.md`. The specific lesson added by this step: *reading a
documented response example is not verification.* Four of the five came from
generalising a single documented example or a single observed object.

**Consequence for the abort path:** an aborted scan commits, so a half-finished
structural pass commits whatever it wrote. This is fine only if each album is
written atomically after its own decision. **Never write a partial structural
decision** — if abort lands mid-album, no row is written and the album retries
next scan.

---

## §1. Scope

**Structural matching only.**

In scope: the Discogs API client's synchronous path, token authentication,
rate limiting, master search, candidate ranking, the track-shape comparison,
`recordStructural`, the cascade from Strict to Structural, the `use` gate
change, §3b's structural invalidation clause, and the offline suites.

Out of scope, record and do not design: collection sync, badge overlay, review
queue, manual re-match, master-level ownership resolution, the context-menu
version picker, marketplace lookup, `API/Async.pm`. These are steps 5 and 6.

**The named drift risk:** building "the API client properly" and ending up
specifying collection sync. Step 4 needs the *sync* path only — Structural runs
in the scanner. `API/Async.pm` is server-side and belongs to steps 5/6.

**Streaming albums are an explicit non-goal.** They have no local files, are
skipped by the `local_tracks == 0` guard, and route to Fuzzy in v2.
`discogs_no_match`'s CHECK deliberately omits `'fuzzy'`.

---

## §2. Preconditions

Step 4 does not start until these are resolved. Both are recorded as blocking in
`TODO.md`.

**2.1 "Clear & rebuild matches" (design §9) must exist.** The manual-rows
question is answered: decisions §10 — wipe every non-manual `discogs_match`
row and every `discogs_no_match` row, both tiers; manual rows untouched. The
remaining precondition is **implementation** of the action, not the decision.
Built in step 4, §3 item 9.

**2.2 Register `SqueezeWax`** at discogs.com/settings/developers, for
breaking-change notices only. **DONE 2026-09-07** — the application is
registered; consumer key and secret exist. Commit neither key nor secret
(decisions §9.1).

---

## §3. Build order

Each item is independently reviewable. Commit before packaging — an uncommitted
edit is invisible to `git archive HEAD` and therefore to the build, silently.

1. **Token authentication.** Pref, settings field, the risk warning and
   revocation link required by decisions §9.1, and validation via
   `GET /oauth/identity`.
2. **`API.pm` — request construction.** User-Agent, settled 2026-09-07:
   `SqueezeWax/<version> +<repo-url>`.
   - `<version>` is read at runtime from `install.xml`, never hardcoded — a
     hardcoded version drifts, and the point is that Discogs can identify
     which build is misbehaving.
   - `<repo-url>` is `https://github.com/d5c0d3/lms-plugin-squeezewax` — the
     project's GitHub repository, derived from the raw.githubusercontent.com
     URL `scripts/package-build.sh` already writes into `repo.xml`.
   - The LMS version is deliberately **not** included: it is a fingerprint of
     the user's setup sent to a third party on every request, for a benefit
     accruing to us rather than to them. Ask for it in a bug report instead.

   Unique, RFC 1945 form, contact URL, plugin version — silent blocking is
   the documented penalty (decisions §9.3). Also: the
   `Authorization: Discogs token=…` header form, URL building, JSON decode.
3. **Rate limiting.** Local throttle honouring the documented 60/min moving
   window; read and record `X-Discogs-Ratelimit`, `-Used`, `-Remaining`;
   backoff on 429. Decisions §9.2.
4. **`Structural.pm` — candidate enumeration.** `type=master` search, title
   normalisation, ranking by `community.have` then country/year/format. Never
   gate on format.
   - Search artist + title. **On zero results, retry title-only** before
     giving up. Decisions §11.
   - The album artist for that search comes from
     `Slim::Schema::Album::artists`, or the `albums.contributor` column it
     builds on — **not** a hand-rolled `contributor_album` join by role.
     Decisions §11.4.
5. **`Structural.pm` — comparison.** Filter to `type_ == "track"` (allowlist),
   count equality, sorted duration vectors within margin. Duration parser must
   handle `M:SS` **and** `H:MM:SS`.
   The allowlist does not recurse into sub_tracks, and a NULL local
   duration yields a candidate rather than a confirmation — decisions §12.

**Item 5 writes nothing.** It is a pure function returning a verdict. All
database writes are item 6, which touches `Match.pm` — the module §0 exists
to protect. Keeping the boundary means a mistake in the comparison logic
cannot reach the write path. **Do not merge items 5 and 6 into one commit.**

6. **`Match.pm::recordStructural`.** Via `_writeOk`. Tier-parameterised
   `_clearNoMatch` and `$STATE_SQL`. Confirm/candidate rule per decisions §8.
7. **`Importer.pm`.** Cascade Strict → Structural; the `use` gate change; the
   `local_tracks == 0` guard as Structural's own rule with its own test.
8. **Settings.** Max-tier selector with an explicitly chosen default, duration
   margin, structural TTL.
9. **"Clear & rebuild matches" action**, per decisions §10. Three step-4
   decisions (§0.5, §0.6, §3b's coverage gap) depend on it as their escape
   hatch.
10. **§3b structural invalidation clause**, keyed on the margin pref.
11. **Offline suites** (§4).
12. **Hardware pass** (§5).

---

## §4. Offline test coverage

**The ten fixtures ARE the test plan for items 4-5.** Each pins a case that
reasoning alone got wrong. Tests should read as assertions about those files,
not as invented scenarios. A test that does not trace to a fixture or to a
decision record is probably testing an assumption.

**This is the first step where hardware iteration is the main loop, not a final
check.** Every Discogs call is unverifiable offline. The suites can cover
request construction, response parsing, rate-limit accounting, ranking,
comparison and the write path against fixtures — **not the API.** Plan
accordingly; do not let a green offline suite read as a working matcher.

**Fixtures are captured from real Discogs responses** — the first seven on
2026-09-07, three more on 2026-09-10 — which is the point: each one encodes
a defect or an open question that reasoning alone did not predict:

| Fixture | Encodes |
|---|---|
| Master 18080 (*Violator*) | ~~Durations present; `community.have/want`~~ — **defect found, 2026-09-07:** `community.have`/`community.want` do not appear on `/masters/{id}` at all — verified against the captured fixture (`scripts/fixtures/master-18080-violator.json`): no `community` key present anywhere in the payload. Those fields arrive on search-result entries only, per decisions §8's own text ("arrive free in search results"), which this row's original wording contradicted. Corrected: durations present. The `community.have/want` note moves to the search-result row below, where it belongs. |
| Master 3855547 (*Escape The Chaos*) | Durations absent → candidate, not confirmed |
| Release 14772 | `heading` entries; multi-disc `D-T` positions |
| Release 2516 | `index` only, zero countable tracks → skip. The entry carries a sub_tracks array of five type_ "track" entries with durations; the allowlist deliberately does not descend into it — decisions §12.1. |
| Release 9701013 | `master_id: null` in a release payload |
| Collection page | `master_id: 0` sentinel — **two** masterless rows, because the failure is collision |
| `type=master` search, Violator | 7 masters, 1 correct — title normalisation; `community.have`/`community.want` (search-result entries only, not the master detail payload — see the Master 18080 row's correction) |
| Release 33986376 (master 3855547's `main_release`) | Durations absent at **both** master and release level for the same object — fetching the release does not recover what the master lacks, confirmed at the release itself rather than inferred. |
| Release 14590709 | A real pressing of master 18080 (*Violator*, 529 versions per decisions §8) — the concrete example behind the unbounded-versions finding. 9 tracks, all with durations; an unremarkable reissue otherwise. |
| Release 132512 | **Defect found, 2026-09-10:** captured as "believed to have no master" — it has one, `master_id: 1861554`. Not every various-artists compilation is masterless; that belief was untested, not established. Multi-disc CD compilation, 13+12 tracks across two discs, all with durations, position format `D-TT` (zero-padded, e.g. `1-01`) rather than release 14772's `D-T` — a second, differing convention, confirming §8's "vinyl A1/B2 and other formats are unsurveyed" was the right caution. The release-level artist credit is a single DJ/compiler ("Nick Ashcroft", the mix's presenter), but every individual track carries its own, different artist — the various-artists character is real, it just doesn't show as a literal "Various" credit in this payload. See decisions §8 and TODO.md on what this means for search quality. |

Candidate enumeration cases (decisions §11):

- A zero-result artist+title search triggers exactly one title-only retry.
- A non-zero artist+title search triggers no retry.
- A zero-result title-only retry is not retried again — at most one retry
  per search.

Write-path cases, extending `scripts/match-check.pl`:

- `recordStructural` refuses under every `_writeRefusal` case.
- A `manual` row survives a clean structural hit; cheap columns still refresh.
- Structural skips any album with an existing `discogs_match` row, including a
  `(strict, candidate)` conflict and a demoted incumbent row.
- Invariant 1 holds across tiers; `structuralState()` detects a violation
  involving structural rows.
- The narrow delete predicate is never reached by Structural.
- A structural NULL-id row is not collateral of the strict delete predicate.
- Skip contract: two-part predicate; NULL `source_timestamp` never skips;
  expired `checked_at` does not skip.
- §3b: a margin change invalidates `tier = 'structural'` and nothing else.

"Clear & rebuild matches" (decisions §10):

- A manual row survives the clear; its `discogs_release_id`,
  `source_timestamp` and `lms_album_id` are unchanged.
- Every non-manual `discogs_match` row is deleted.
- Every `discogs_no_match` row is deleted, both tiers.
- The clear refuses under every `_writeRefusal` case.
- Both deletes are one transaction: a failure leaves both tables unchanged,
  never `discogs_match` emptied with `discogs_no_match` intact.

---

## §5. Hardware verification

Local LMS, same music sources, exactly one Additional Repositories entry.
Reference library: 764 albums, ~8,700 local tracks across FLAC/MP3/OGG/WMA,
plus ~2,980 Spotty tracks.

Record for each item: what was expected, what was observed, and whether any
claim written as fact was falsified.

1. Fresh install, no token: gate false, no log noise, no requests.
2. Token configured, max tier `strict`: gate behaves as before step 4.
3. Cold structural pass on a bounded subset first. Measure **requests per
   album** against §13 and the observed `X-Discogs-Ratelimit-Remaining`.
4. Confirm/candidate split. Expected ~90/10 from the 40-release sample —
   **treat that as a prediction to falsify, not a target.**
   Measure the split BY ROUTE, not as one ratio — five routes now feed the
   queue and the ~90/10 figure was built from two of them. See TODO.md.
5. Multi-disc albums match (LMS groups them; `discc = 6` sets carry all tracks
   in one row).
6. Incompletely-ripped sets (*Akasha*, *Fourteen Pieces*) reach the review
   queue rather than mismatching.
7. Streaming albums are skipped; no requests spent.
8. Abort mid-pass: no partial album row; resume re-examines cleanly.
9. Rescan: matched albums skip; structural no-matches skip until TTL expiry.
10. Margin change invalidates structural no-matches and nothing else.

---

## §6. Known open items carried into step 4

- **§13 needs a full rewrite**, not an adjustment. The format gate was its main
  lever and it is gone; the master-level flow replaces the per-album figures.
  Whether a hard per-album fetch cap is needed depends on measured N after title
  normalisation (§5 item 3).
- **The zero-result retry (decisions §11) doubles search cost for albums
  genuinely absent from Discogs** — a title-only retry on a truly absent album
  also returns zero. Belongs in the §13 rewrite above, not a separate item.
- **Decisions §3a's NULL-id invariant** was amended 2026-09-07 to accommodate
  edition-level matches. Verify the amendment holds under the implemented write
  path.
- **`docs/squeezewax-design.md` needs a prose cleanup** before step 5 — inline
  corrections across §3, §4, §9, §10 and §13 have made §3 hard to read as a
  specification.
- **Unverified, carried:** whether long tracks use `H:MM:SS`; the unauthenticated
  rate tier; whether unauthenticated search results are content-degraded.

---

## Appendix A — §12, into docs/squeezewax-v1-decisions.md

To be pasted exactly as written — do not reword, re-wrap or re-order.

## 12. Two rulings on evidence quality in the Structural comparison

**Decided 2026-09-11 (design chat), during build-order step 4 items 4–5
planning.** Both rulings concern what the track-shape comparison does when the
evidence on one side is incomplete. Neither introduces a new principle; each
applies §8's existing confirm/candidate rule to a case §8 did not name.

Source claims below were checked against a slimserver clone at
`4015c6a826420cacedb7223a42da81c70b78c300` (`public/9.1`, 2026-09-07), which is
**newer** than `refs/`'s pin `a670a38c` (2026-06-19). Per working agreement §6,
Claude Code re-verifies by symbol against refs/'s actual pin. The refs/ citation
drift already recorded in `TODO.md` now runs in both directions.

### 12.1 The `type_` allowlist does not recurse into `sub_tracks`

§8 specifies "filter Discogs tracklist entries to `type_ == "track"`". It does
not say whether to descend into nested entries, because `sub_tracks` was not
known when it was written.

**Verified, from the pinned fixture.** `scripts/fixtures/release-2516.json`
holds one top-level tracklist entry with `"type_" : "index"`, carrying a
`sub_tracks` array of five entries, each `"type_" : "track"` and each with a
non-empty duration (`10:50`, `3:15`, `7:11`, `5:12`, `3:54`). The string
`sub_tracks` appears nowhere in `docs/`, `plans/` or `TODO.md` before this
record.

**Decided: count top-level entries only. Do not recurse.**

Release 2516 therefore yields **zero countable tracks**, the candidate is
skipped rather than compared (§8, "Confirm versus candidate"), and the album
reaches the review queue if no other candidate survives.

#### Why, and it is not the obvious reason

The obvious argument — "an `index` entry is not a track" — is weak, because the
nested entries genuinely are tracks and genuinely carry durations. Recursing
would probably have produced a correct match for this album.

The real argument is **calibration**. §8's confirm/candidate rule rests on a
measurement over 40 releases: complete durations 36 (90%), none at all 3
(7.5%), zero countable tracks 1 (2.5%). That measurement counted release 2516
in the third bucket, which means it was taken **top-level-only**. An
implementation that recurses moves albums between buckets that the measured
split was drawn from, so §8's expected ~10% review-queue figure would no longer
describe the code that produced it. Changing the counting rule silently
invalidates the evidence base for the rule that consumes the count.

#### Why this is safe to defer rather than solve

The failure direction is benign. Not recursing costs 2.5% of albums (n=40) a
trip through the review queue. It cannot produce a wrong badge — a skipped
candidate is not a match. The review queue is precisely the mechanism for
albums whose evidence does not support auto-confirmation, so this is the system
behaving as designed, not degrading.

This is the asymmetry that decides it: recursion buys a small number of
automatic confirmations and risks miscalibrating a rule; not recursing costs a
small number of manual confirmations and risks nothing.

#### Revisit trigger, and what would count

**v2.** Reopen if the step-4 hardware pass (plan §5) shows index-only releases
materially above the measured 2.5% of the reference library. "Materially" is
deliberately not given a threshold here — the 2.5% is n=1 of 40 and does not
support one.

**Unverified, carried forward:**

- Whether `sub_tracks` occurs on any entry whose `type_` is something other
  than `"index"`. One shape has been observed, on one release.
- Whether a `sub_tracks` entry can itself nest further.
- Whether any Discogs release expresses a *whole* album as sub-tracks such that
  top-level counting yields a non-zero count that is wrong rather than zero.
  This is the case that would make the ruling unsafe rather than merely
  conservative, and it has not been looked for.

### 12.2 A NULL local duration yields a candidate, never a confirmation

§8 rules on durations being absent **Discogs-side**: `(structural, candidate)`
for step 5's review queue. It is silent on the LMS side, because the LMS side
was assumed complete. It is not.

**Verified in source.** `SQL/SQLite/schema_16_up.sql`, inside
`CREATE TABLE tracks`, declares `secs float` with no `NOT NULL`.
`grep -rn "CREATE TABLE tracks" SQL/SQLite/` returns only `schema_1_up.sql` and
`schema_16_up.sql`, so no later migration redefines the column.

**Reachable, not merely nullable.** `Slim/Schema/Album.pm`, `sub duration`,
contains `return if !defined $_->secs;` — LMS's own album-duration accessor
abandons the whole computation if any single track's duration is undefined.
That is LMS treating the case as ordinary, which is stronger evidence than the
DDL alone.

**Decided: if any local track of the album has a NULL `secs`, the verdict is
`(structural, candidate)`. Count equality is still evaluated and can still
reject; it is confirmation specifically that is withheld.**

#### Why this is application of §8, not a new rule

A NULL local duration puts us in the same epistemic position as a missing
Discogs duration: the track count is known, the duration vector is not. §8
already rules on that position. Deciding it differently depending on which side
the gap is on would mean the tier's confidence depends on where the ignorance
sits rather than on how much of it there is.

#### The failure mode this prevents

An unhandled NULL reaches the comparison one of two ways. Under `use warnings`
a numeric comparison against `undef` warns and the sort order is unreliable —
the same bug `Library.pm::_finish`'s timestamp loop already carries a comment
about, for the same reason. Worse, an implementation that coerces `undef` to 0
produces a duration of zero that falls **within the ±2–3 s margin of any
sufficiently short Discogs track**, yielding a spurious element-wise match.
Structural auto-confirms silently (§8), so that surfaces as a wrong badge with
no trace of the disagreement that caused it — the outcome the tier design
exists to prevent, and the one step 5's reject/dismiss was recorded three times
over to recover from.

A skipped confirmation is visible and recoverable. A wrong confirmation is
neither.

**Rejected — treat a NULL as "this track has no duration" and compare the
remaining vector.** It changes the length of one side of a comparison whose
first step is count equality, so it would either reject every affected album on
count (indistinguishable from a genuine mismatch, and misleading in the queue)
or require the count to be taken before the filter and the vector after, which
is two different track counts in one comparison.

**Rejected — fall back to count-and-title agreement.** §8 already names that as
Fuzzy-grade evidence and refuses to ship it under Structural's auto-confirming
behaviour. The argument is unchanged here.

#### Consequences

- **Float, not integer.** `secs` is a `float`; Discogs durations are integer
  `M:SS`. The comparison is float-to-integer and the margin absorbs it. Stated
  so it is not rediscovered as a defect.
- **`Library.pm` must supply the durations at all.** Its iterator currently
  does not — see `TODO.md` and plan §3. That is sequencing, not a decision, and
  is tracked there.
- **Frequency is unmeasured.** How many of the 764 reference albums carry any
  NULL `secs` is unknown and needs the real server. It feeds the review-queue
  sizing question in `TODO.md`, not this ruling — the rule is correct at any
  frequency; only its cost varies.

**Unverified, carried forward:**

- Whether NULL `secs` correlates with a content type, an importer, or with
  remote rows specifically. Nothing has been measured.
- Whether `Slim::Schema::Album::duration`'s guard was written for NULL `secs`
  on local tracks or for some other case. The guard's existence is verified;
  its motivating case is inferred from its shape.

### 12.3 What these two rulings share, recorded because it will recur

Both cases are the same shape: **Structural's evidence quality varies per
album, and v1's answer to weak evidence is always the review queue.** Neither
ruling tries to rescue an album by finding additional evidence or by relaxing a
threshold.

That is deliberate and should stay the default. The instinct to shrink the
queue by widening what counts as sufficient evidence trades a visible
inconvenience for an invisible wrong badge, which is the wrong direction. The
correct response to a large queue is better queue tooling — bulk actions in
step 5 — not a laxer matcher. Recorded in `TODO.md` so it is not invented under
pressure after the hardware pass.
