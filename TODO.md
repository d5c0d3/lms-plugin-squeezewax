# SqueezeWax — TODO

Synced branch: v1-buildout, 2026-09-07

Shared reminder list. Both I and Claude Code read and update this.

**Conventions**
- Newest items go at the top of their section.
- Tick with `[x]` and leave the line in place until the next release, then prune.
- Anything blocked on a real server or an external answer goes under
  **Waiting** with what specifically is being waited for.
- Claude Code: check this at the start of a session, and add items here rather
  than only mentioning them in chat.

---

## Blocking — do before build-order step 2

- [x] Add `<importmodule>Plugins::SqueezeWax::Importer</importmodule>` to
      `SqueezeWax/install.xml` together with a minimal `Importer.pm`, in the
      same commit — so the scanner never logs a load failure for a module
      that doesn't exist yet. Deferred to the build session (Schema.pm is
      not this session's job either).
      Answered 2026-08-28: naming a not-yet-existing `<importmodule>` is
      **tolerated, not fatal** — `PluginManager.pm`'s `load()` calls
      `Slim::bootstrap::tryModuleLoad`, which wraps the require in
      `eval "use $module ()"`; a failure is logged and that one plugin is
      left disabled, but the loop over all plugins continues
      (`Slim/bootstrap.pm`, `tryModuleLoad`). Still landing it together with
      `Importer.pm` rather than relying on that tolerance.
- [x] Reconcile `docs/squeezewax-v1-decisions.md` into
      `docs/squeezewax-design.md` and `docs/implementation-plan.md`, so
      there is one source of truth again.
- [x] Re-verify the slimserver citations in `docs/squeezewax-v1-decisions.md`
      against `refs/slimserver/` (they were taken on v9.2.0; refs is on
      `public/9.1`, so line numbers differ — located by symbol). All twelve
      confirmed; one citation corrected (DATE/MUSICBRAINZ_ID attribution).

## Next — build-order step 2

- [x] **`postDBConnect` fires twice in immediate succession.** 91ms apart on
      server, 2ms apart in scanner, before the separate post-scan firing. Either
      two genuine connections or the handler runs twice against one handle;
      second ATTACH fails with "already in use", eval swallows it, pragma
      read-back succeeds — so logs success either way. Benign today, but
      `postDBConnect` should explicitly detect an already-attached schema rather
      than getting the right outcome by accident. Do this in whichever session
      next touches `Schema.pm`.
      Done 2026-09-03 (1d63aac, e95f2c7). The stated mechanism was wrong:
      RaiseError is on (`Slim/Schema.pm:273-275`), so a repeat ATTACH *dies*
      rather than being swallowed — the two observed firings were two genuine
      connections. `_attachedFile` reads `pragma_database_list`; paths are
      compared with `Cwd::abs_path`, because SQLite canonicalises what it
      reports while `dbFile()` is never canonicalised, and a raw comparison
      would have disabled the plugin on any symlinked prefs directory.
- [x] `Schema.pm`: plugin-owned attached SQLite file, `postDBConnect`
      registration, `PRAGMA user_version` migrations, per `docs/squeezewax-v1-decisions.md` §2.
- [x] Configurable Discogs tag names + detection action (v1, per §3 of the
      decisions doc). Done 2026-09-03/04 (15d19e4, 939819b, fee0aac, 1b18e45).

## Next — build-order steps 3–5 (matching)

- [ ] **2026-09-12: the review queue must not fill with albums the user does
      not own (§13.4).** An album identified from a tag but absent from the
      collection needs no human decision. Against a few-hundred-item
      collection and a 764-album library most albums are unowned, so a
      candidate predicate that catches them turns the queue into noise. This
      is a constraint on step 5's predicate, not a preference.
- [ ] **2026-09-11: plan §5 item 4 measures the confirm/candidate split as ONE
      ratio, but there are now five routes into the review queue** —
      durations absent Discogs-side (7.5% of 40), zero countable tracks (2.5%
      of 40), NULL secs (unmeasured), incompletely-ripped sets (present in the
      reference library, count unknown), and compilations whose title-only
      retry surfaces a master the fingerprint correctly rejects (unmeasured).
      decisions §8's ~10% expectation was built from the first two only.
      Measure the split BY ROUTE. If the total lands materially above 10%, the
      answer is bulk confirm actions in step 5's queue, NOT a laxer matcher —
      see §12.3. Recorded, not designed.
- [ ] **2026-09-11: Library.pm's iterator supplies neither per-track durations
      nor an album artist.** The artist gap is recorded (decisions §11.4); the
      duration gap was not recorded anywhere. Both items 4 and 5 depend on it,
      and it touches a module with an existing suite
      (scripts/library-check.pl). Sequencing, not a decision: it wants its own
      commit ahead of item 4 rather than being folded into either.
- [ ] **2026-09-11, verified: tracks.secs is a NULLABLE FLOAT, and a NULL local
      duration yields (structural, candidate)** — see
      squeezewax-v1-decisions.md §12.2. SQL/SQLite/schema_16_up.sql,
      CREATE TABLE tracks, "secs float", no NOT NULL; no later migration
      redefines the table. Reachable rather than theoretical:
      Slim/Schema/Album.pm sub duration carries
      "return if !defined $_->secs;". Unhandled, the failure is undef-as-0
      falling inside the ±2–3 s margin of a short Discogs track — a spurious
      match, and Structural auto-confirms silently. Checked against a fresh
      slimserver clone at 4015c6a8 (public/9.1, 2026-09-07), which is NEWER
      than refs/'s a670a38c — re-verify by symbol per working agreement §6.
- [x] **2026-09-07, verified: step 4's master-only Structural row needs NO
      migration.** `discogs_match.discogs_release_id` is already nullable
      (`Schema.pm::_migration_1`: `discogs_release_id INTEGER`, no
      `NOT NULL`), consistent with §3a's conflict rows and with
      `Match.pm::_recordNoMatch`'s `discogs_release_id IS NULL` predicate.
- [ ] **2026-09-07: no cheap discriminating filter exists for Structural
      candidates — track count and durations appear only in the release
      payload.** Strategy must be rank, fetch in rank order, stop early, cap
      hard — not filter-then-fetch. Ranking signals, none exclusionary:
      `stats.community.in_collection` (strongest), country, released,
      format, title. **A hard per-album fetch cap is REQUIRED** and is what
      makes the budget bounded now that the format gate is a ranking signal
      (see the falsified-claims item below), not a filter. Over-cap albums
      go to the review queue rather than grinding. Blocks the §13 rewrite.
      ~~OPEN: enumerate candidates via `/masters/{id}/versions` or
      `/database/search`? Take it with the budget.~~ — **RESOLVED
      2026-09-07: `/database/search` with `type=master`. See the settled
      step-4 candidate-enumeration flow below.**
      2026-09-12: superseded by §13 — v1 performs no per-album Discogs search.
- [ ] **2026-09-07, SETTLED DESIGN: step-4 candidate enumeration, ranking,
      comparison and write rule.** Superseded as the design record by
      `squeezewax-v1-decisions.md` §8 — see there for the full design
      (flow, ranking, comparison, write rule, multi-disc handling).
      Not in §8, kept here: `type=master` search results also carry
      `barcode`/`catno`. A barcode is a **Strict-grade identifier** — some
      taggers write a `BARCODE` tag, and where present it identifies a
      pressing more decisively than durations can, so it is a possible
      future tag-based path alongside the Discogs release ID. Recorded,
      not designed; v2.
- [x] **2026-09-07: tracklist-entry parsing must allowlist, not denylist,
      and must not assume duration format.** From a 40-release sample:
      entries have at least three `type_` values (`"track"`, `"heading"`,
      `"index"`) though the documentation shows only `"track"` — count and
      compare ONLY `type_ == "track"`, an ALLOWLIST, so an unknown fourth
      value is ignored rather than counted as a track. 2 of 40 releases
      (5%) contain non-track entries, so `.tracklist|length` is wrong for
      them; the filter is mandatory. Headings are sub-sections, NOT disc
      boundaries (release 14772 has four headings spanning two per disc
      across two discs) — discarding headings loses no disc structure.
      Disc membership appears in `position` as `"D-T"` (`1-1` … `2-8`) on
      that one sample; ~~vinyl (A1/B2) and other formats are unsurveyed~~ —
      **corrected 2026-09-12, Phase 0:** vinyl A1/B2 positions occur in four
      of eight fixtures (42 of 98 tracks), the most common format in the
      corpus — what is unsurveyed is multi-record vinyl disc membership,
      since both vinyl fixtures are `format_quantity: 1`; and
      position is not parsed regardless (see the settled comparison flow
      above). After filtering to tracks: 36 of 40 releases (90%) have
      complete durations, 3 (7.5%) have none at all, 1 (2.5%, release 2516)
      has zero countable tracks. Unverified: whether long tracks use
      H:MM:SS — all observed are M:SS, longest 9:10, but the parser must
      handle both, since mis-parsing `1:02:33` would silently poison a
      comparison. Duration availability is a property of the Discogs
      ENTRY, not the endpoint: master 18080 (Violator) has durations,
      master 3855547 (*Escape The Chaos*) and its main release 33986376 are
      both blank — fetching the release does not recover what the master
      lacks.
      2026-09-12: superseded in operative part by §13 — no Discogs tracklist
      is parsed in v1. The allowlist finding stands as evidence about the API.
- [ ] **2026-09-07: `data_quality` is not usable as a pre-fetch ranking
      signal.** 40-release sample: 20 "Correct" (0 with missing durations),
      20 "Needs Vote" (3 with missing durations) — direction is real but
      doesn't narrow (85% of "Needs Vote" releases have complete
      durations; Fisher exact p ~ 0.23 on n=40, suggestive not
      established), and it's absent from search results, so it can't rank
      candidates before the fetch is paid for. Usable only as (a) a
      tiebreaker between already-fetched candidates and (b) a confidence
      note in step 5's review queue — do not build on it. No-durations and
      masterless are largely independent populations (of 3 genuine
      no-duration releases, 2 have masters; n=3).
- [ ] **2026-09-07: Structural skips `local_tracks == 0` for its own
      reason** (no local files, no evidence about a physical object), not
      inherited from Strict. Needs its own test.
- [x] **2026-09-07: the `use` gate's max-tier default is decided.** RESOLVED
      2026-09-07 — see `plans/build-order-step-4-structural-matching.md` §0.7.
- [ ] **2026-09-07, verified: the "no master" sentinel is
      endpoint-dependent — both representations must be guarded.**
      Collection `basic_information`: `0` (5 of 100 sampled, zero nulls).
      Release payload: `null` (verified, release 9701013). Every master
      comparison needs both an explicit `!= 0` guard AND a definedness
      check, depending on which endpoint's `master_id` is in hand.
      Fixtures need TWO masterless releases, because the failure mode is
      that distinct masterless releases collide on the same sentinel.
- [ ] **2026-09-07: ownership test needs BOTH sets** —
      `release_id in owned_releases` OR (`master_id != 0` AND
      `master_id in owned_masters`). The release arm is required, not a
      fallback — it's the only arm that fires for the ~5% masterless
      releases. Ownership is decided at MASTER level; identity stays at
      RELEASE level (resolves the ripped-the-CD-owns-the-LP case).
- [ ] **2026-09-07, FALSIFIED: "one request per master answers ownership
      across every pressing."** `/masters/{id}/versions` is paginated and
      unbounded — Depeche Mode, *Violator*: 529 versions, and the owned
      release was not in the first 100 under default sort. A negative
      answer requires exhausting every page, so "not owned" is the
      expensive case. Dropped as the ownership mechanism; the collection
      sync's owned-master set replaces it.
- [ ] **2026-09-07, FALSIFIED: "`/database/search` requires
      authentication."** Returns 200 unauthenticated, despite the
      documentation stating otherwise. Consequence: requiring a token is a
      throughput/setup-coherence choice (60/min vs 25/min), not a technical
      necessity — the use-gate rationale needs rewriting accordingly; the
      gate condition itself is unchanged.
- [ ] **Implement stable sort pinning on every paged Discogs endpoint.**
      Hazard and remedy recorded in `squeezewax-v1-decisions.md` §9.4.
- [ ] **2026-09-07: no `discogs_collection` mirror in v1.** Ownership is a
      derived per-album label, written by a sync that fetches transiently
      and stores only the conclusion. The column lands in migration 3, in
      the step that reads it — NOT step 4 (step 2 finding 8: don't add a
      column nothing reads yet). Sync has its own trigger: interval pref
      plus a visible manual "Sync collection now" — a music rescan does not
      refresh it, since the skip contract keys on file state and ownership
      isn't in it. Settings page shows collection last-synced time.
- [ ] **2026-09-07: artist pre-filter** to shrink any master backfill from
      library-sized to collection-sized, at zero request cost. Needs a
      conservative fallback for various-artists and album-artist
      mismatches.
      2026-09-12: superseded by §13 — v1 performs no per-album Discogs search.
- [ ] **2026-09-07: mandatory Discogs attribution.** Both required notices
      are recorded in `squeezewax-v1-decisions.md` §9.6. Still open: **a
      grid badge has no natural place for the "Data provided by Discogs"
      notice — decide before step 6 starts.**
- [ ] **Step 4's plan must open with an enumerated "what step 3 established
      that step 4 must honour" section**, each item citing its decision
      record or symbol — the same shape step 3's plan used for step 2's
      findings 2a, 3 and 9. This is a contract problem, not a git problem:
      one long-lived branch (`v1-buildout`) and full visibility of step 3's
      code do not by themselves stop step 4 from writing `recordStructural`
      alongside `recordStrict` in a way that skips `_writeOk`, reimplements
      the manual-match guard wrongly, widens the narrow delete predicate, or
      breaks invariant 1. At minimum, enumerate: `_writeOk`/`_writeRefusal`;
      the manual guard as rule one of the write path; the narrow delete
      predicate and the rule behind it; invariant 1 and `_clearNoMatch`; the
      skip contract (row exists AND `source_timestamp` equals current
      `MAX(tracks.timestamp)`; NULL never skips); and §3b invalidating
      `tier='strict'` only, with its note that a pref-derived tier needs its
      own clause.
- [x] **`album_key` computation.** Resolved during step 2, deliberately not
      implemented: raw SQL on `Slim::Schema->dbh` (the pattern in
      `Slim/Plugin/FullTextSearch/Plugin.pm:547-556`), not DBIC — the
      `Slim::Utils::Scanner::API` POD (`:37-38`) warns against inflating Track
      objects in the scanner. Query is
      `SELECT urlmd5 FROM tracks WHERE album = ? AND audio = 1 AND
      content_type NOT IN ('cpl','src','ssp','dir') ORDER BY urlmd5`, digest
      `md5_hex`. **Zero qualifying tracks must yield `undef`, never
      `md5_hex('')`** — that is one constant every empty album would collide
      on. Reachable because `Album->rescan` counts unfiltered while we filter.
- [ ] **Orphan recovery writes an UPDATE, not an INSERT.** Relink by updating
      the orphaned row's `album_key`, `lms_album_id` and snapshot, carrying
      `discogs_release_id`, `match_tier`, `state` and `matched_at` forward:
      relinking re-identifies which local album the match belongs to, it does
      not re-decide which release it is. An INSERT would need a provenance
      value nothing re-evaluated.
- [ ] **`lms_album_id` refresh** on `['rescan','done']`, debounced — *not*
      `Slim::Utils::Scanner::API->onFinished`. Reasoning in decisions §6.
- [x] **`Slim::Music::Import->addImporter`** registration, which step 2
      deliberately omitted: an importer whose `startScan` does nothing would
      only put a dead row in the scan progress UI.
      Done 2026-09-04 (cec7a46): `type => 'post'`, `weight => 120`, and `use`
      gated on a non-empty `discogsTagNames` so an unconfigured install stays
      silent.

- [x] **Importer must never overwrite a `match_tier='manual'` row.** An
      in-place file change (artwork, ReplayGain, a tag editor rewriting the
      whole file) moves `tracks.timestamp` without moving `album_key`, so the
      album is re-examined and the original Discogs tag reverts the user's
      manual pressing choice — no log line, silently wrong badge. Refresh
      `source_timestamp` and `lms_album_id` only. "Retagging beats a manual
      override" is defensible but needs an explicit step-5 mechanism, not an
      UPSERT side effect.
      Done 2026-09-04 (cec7a46). Not expressible as
      `ON CONFLICT ... DO UPDATE ... WHERE match_tier <> 'manual'`: verified,
      that leaves the row completely untouched including `source_timestamp`, so
      the importer would re-examine it every scan forever.
- [x] **Gate `use =>` on a non-empty `discogsTagNames`**, per
      `Slim/Music/ReleaseTypes.pm:32`. Done 2026-09-04 (cec7a46).
- [x] **Never pass `every` to `Progress->new`.** Done 2026-09-04 (cec7a46).
- [x] **Online-library albums never skip.** Done 2026-09-03 (eae1455): the
      iterator exposes local/remote track counts and Strict skips
      no-local-track albums.
- [x] **Anomalous-run summary at `warn`** when
      `matched == 0 && examined > 0`. Done 2026-09-04 (cec7a46).
- [x] **`startScan` returns an integer** (matched count). Done (cec7a46).
- [ ] **Step 5's review queue must offer reject / dismiss, not only confirm.**
      Recorded three times over — corrected 2026-09-07; previously miscounted
      as four, with two cases that don't actually belong (see below):
      (a) **A confirmed match demoted to candidate by a tag conflict** keeps
          its adjudicated `discogs_release_id` and its snapshots (decisions
          §3a); if the user then removes the tags entirely, the importer may
          not delete the row — it carries a decision, and §2a forbids that —
          and Structural skips it because a `discogs_match` row exists. With a
          confirm-only queue the album would propose a release with no tag
          behind it forever. Recorded in design §3.
      (b) **A wrong manual row** is not fixable by "clear & rebuild matches"
          (decisions §10.5) — the action deliberately preserves manual rows,
          so a user who confirmed the wrong pressing has no recovery path.
      (c) **A wrong Structural auto-confirm, introduced by step 4.**
          Structural confirms silently, so a wrong edition-level match
          produces a badge with no trace of the disagreement and no way to
          reverse it. The strongest of the three; not previously recorded
          anywhere.
      NOT reject/dismiss cases: the phantom-conflict row, which
      `Match.pm::_recordNoMatch`'s delete predicate clears automatically; and
      the edition-level context menu, which needs a version picker promoting
      to manual — refinement, not rejection.

## Open design questions

- [ ] **2026-09-12: what `match_tier` value does a collection-derived match
      carry?** The CHECK allows `strict`, `structural`, `fuzzy`, `manual`. A
      title-plus-artist match against the collection is a genuinely different
      ORIGIN, which is what `match_tier` records — so unlike §3a's conflict
      case, a fifth value is defensible rather than expressing something
      `state` already expresses. Against: a migration, an amendment to design
      §3 and §10, and every future reader. DECIDE BEFORE MIGRATION 3.
      See §13.8.
- [x] **2026-09-11, RESOLVED: sub_tracks is an unrecorded tracklist shape, and
      the type_ allowlist does not recurse into it.** See
      squeezewax-v1-decisions.md §12.1. release-2516.json's single type_
      "index" entry carries sub_tracks with five type_ "track" entries, all
      with durations; the string appeared nowhere in docs/, plans/ or TODO.md
      before that record. Revisit trigger is v2 and is stated in §12.1.
- [x] **2026-09-10, RESOLVED: various-artists compilations are no longer an
      open problem for Structural.** See `squeezewax-v1-decisions.md` §11.
- [x] **2026-09-07, ANSWERED: decisions §3a's v1 invariant NULL-id
      question.** Landed — see `squeezewax-v1-decisions.md` §3a (amended)
      and §8.
- [ ] **2026-09-07, recorded not designed: a user with both a local rip and
      a streaming copy sees the album twice in the grid, and only the
      local row is badged.** Arguably correct; will read oddly. A UI
      question for step 6, not a matching one.
- [ ] **Detection has no progress feedback, and the fix depends on the next
      item.** The Settings worker runs through `Slim::Utils::Scheduler` and the
      page never refreshes, so it shows "Reading files... (0/79)" until the user
      reloads by hand - observed 2026-09-06. Three options were weighed:
      (a) a hint telling the user to reload - honest, but an apology for missing
      feedback; (b) a `<meta http-equiv="refresh">` emitted only while
      `detection.running`, which stops by itself when the run ends - the
      mechanism exists, `settings/header.html:17-18` re-blocks
      `pageHeaderScripts` so a page can inject into the head, and the one
      caveat is that a reload discards anything typed into the tag boxes;
      (c) LMS's own `progress.js` polling `rescanprogress`, which is NOT
      available - that machinery is bound to the scanner's `progress` table and
      only reports while `stillScanning`.
      Held deliberately: if detection moves into the scan (next item) the worker
      and its display may be reshaped anyway, and fixing the display of
      something about to change shape is wasted work.
- [ ] **Should detection run as a by-product of the Strict pass?**
      `_examine` already holds the tag hash for every examined album, so
      `candidateKeys` could run there at zero extra I/O, building the report
      from the whole library instead of a 76-album sample and refreshing it on
      every scan.
      **It cannot replace the standalone Detect action**, and the reason is one
      of our own guards: `use` is gated on a non-empty `discogsTagNames`, so on
      a fresh install the importer never runs - which is exactly when detection
      is needed. So this would be an enrichment, not a replacement: the sample
      report for first-run configuration, the full-library report thereafter.
      Open question is whether that is worth it at all, since the sample is
      already stratified per format, which is the property that matters for the
      one decision it informs.
- [x] **Does "clear & rebuild matches" (design §9) destroy `manual` rows?**
      ANSWERED 2026-09-07 — see `squeezewax-v1-decisions.md` §10.
- [ ] **2026-09-07: `discogs_no_match` tier `'structural'` skip predicate.**
      Two-part, unlike Strict's one-part: `source_timestamp` unchanged AND
      `checked_at` within TTL. Proposed TTL 30 days as a pref — not
      TOU-constrained, a UX/freshness choice. The clear & rebuild decision is
      no longer blocking (decisions §10); its implementation is tracked in
      the step-4 build order (build-order-step-4-structural-matching.md §3
      item 9).
- [ ] **2026-09-07: §3b needs a `tier='structural'` invalidation clause
      keyed on the duration-margin pref** — §3b's own "Step 4 note" trigger
      has fired. The clear & rebuild decision is no longer blocking
      (decisions §10); its implementation is tracked in the step-4 build
      order (build-order-step-4-structural-matching.md §3 item 9).
- [ ] **2026-09-07, recorded not designed: an edition-level (Structural)
      match has no pressing to show in design §4's badge context menu.**
      Proposed shape — show master-level info plus a version picker ("you
      own a version — which pressing?"); the user's choice promotes the
      row to `match_tier='manual'` with a real `discogs_release_id`. Gives
      `'manual'` a refinement purpose alongside override, and reuses the
      review queue's machinery. Product decision, not taken.
- [ ] **2026-09-07, recorded not designed: no index on
      `discogs_match.discogs_master_id`, and `discogs_collection_release`
      is on `(discogs_release_id, list_state)` only.** The master arm of
      the badge's dual test (see design §10) is unindexed on both sides —
      matters for grid rendering. Belongs in the migration for the step
      that reads it, NOT step 4 (step 2 finding 8).
- [ ] **2026-09-07, recorded not designed: master-level badge fallback vs.
      pressing-level collectors.** Keep both answers recoverable — product
      decision, not yet taken.
- [ ] **2026-09-07, recorded not designed: is a derived "owned" label our
      conclusion, or one bit of Restricted Data under the Discogs TOU?**
      Leaning conclusion; NOT settled. Kept academic by choosing the sync
      interval on UX grounds regardless. Do not record as decided.
- [ ] **`type=master` search results carry `user_data.in_collection`/
      `in_wantlist` per token holder, undocumented.** Recorded in
      `squeezewax-v1-decisions.md` §9.9.

- [ ] **Scanner→server handover — re-scoped, not closed.** The importer needs
      no handover: step-3 finding 3 shows `album_key` covers structural
      change and `MAX(tracks.timestamp)` covers in-place tag edits, both
      readable in either process. Still open: immediate re-match on a
      single-directory rescan, which never reaches `runScanPostProcessing`
      (`scanner.pl:348` is its only live caller). Decide before v1 whether
      the `Slim::Utils::Scanner::API` track hooks are needed for that, or
      whether "the next full rescan picks it up" is enough.
- [ ] **Structural no-match staleness policy (step 4).** `discogs_no_match`
      carries `checked_at` so step 4 can add a policy without a migration;
      the policy itself is undecided. A Discogs search that found nothing
      today may find something in six months.
      2026-09-12: superseded by §13 — v1 performs no per-album Discogs search.
- [ ] **Step 4 must relax the `use` gate.** It is currently
      `scalar @{discogsTagNames}`, which would wrongly disable the importer for
      a user who wants Structural only — Structural needs no tag names. Becomes
      wrong the moment step 4 lands.
- [ ] **v2 triage page must distinguish "unparseable tag" from "tags
      disagree".** Both write `(strict, candidate, NULL)` in v1, which is
      correct for v1 — neither is a match — but they are different user actions
      (fix one file's tag vs. decide between two). Recorded, not designed.
- [ ] ~~**`discogs_collection` wantlist rekey (v2).** `instance_id` as
      primary key cannot hold wantlist rows — a Discogs want has no
      instance id. The table is entirely regenerable (design §10), so the
      migration is DROP + re-sync, ~20 requests. Note the obvious fix does
      **not** work: `UNIQUE(list_state, discogs_release_id, instance_id)`
      with `instance_id` NULL for wants constrains nothing, since SQLite
      treats NULLs as distinct in unique indexes — verified, three
      identical rows inserted without error. Needs a partial unique index
      (`... WHERE instance_id IS NULL`) or a non-NULL sentinel.~~ —
      **2026-09-07: no longer applicable.** v1 holds no `discogs_collection`
      mirror at all (see the "Next — build-order steps 3–5" item above);
      ownership is a derived per-album label, not a synced table. Revisit
      if/when a collection mirror is actually built.

## Waiting — needs a real server

- [ ] **2026-09-11: measure how many of the 764 reference albums have any local
      track with secs IS NULL.** Feeds the review-queue sizing item below; the
      §12.2 rule is correct at any frequency, only its cost varies.
- [x] **LMS multi-disc grouping, verified 2026-09-07.** LMS GROUPS
      multi-disc sets into one `albums` row. Verified three ways: (a)
      whole-set track counts — "Die 100 besten Ostsongs" `discc=6` with
      100 tracks in one row, DMBX4 `discc=6` with 52; (b) no title appears
      once per disc — the only duplicated titlesorts at `discc>=2` are
      *Delta Machine* and *Singles 86>98*, both "2,2", i.e. two complete
      copies, not two halves; (c) `albums.disc` always equals
      `albums.discc` where non-null (1/1, 2/2, 3/3, 6/6). **TRAP:
      `albums.disc` is NOT a disc index on a grouped album — it equals the
      disc COUNT.** A filter reading `disc=2` as "the second disc" would
      silently drop albums. `tracks.disc` exists and is indexed
      (`trackDiscIndex`), so per-disc structure is reconstructible from
      track rows if step 5 wants to report which disc mismatched — not
      needed for matching. Incompletely-ripped sets already exist in the
      library (*Akasha*: `discc=2`, 7 tracks; *Fourteen Pieces*: `discc=2`,
      14 tracks) and correctly fail count equality, falling to the review
      queue — design §3 walkthrough 3, arriving from real data.
      `albums.extid` carries the online-library URI (Spotify) and is empty
      for local albums — observed for Spotty only, 2 samples; the
      `local_tracks == 0` guard remains the primary mechanism.
- [x] **Discogs API, second hardware-testing session, 2026-09-07.**
      `type=master` search results do not carry `main_release` (moot —
      masters carry their own tracklist). Master tracklists sometimes lack
      durations entirely and fetching the release does not recover what
      the master lacks (see the tracklist-parsing item above). Artist +
      title search on `type=master` returns multiple wrong masters (7 for
      Depeche Mode / Violator, 1 correct) — not sufficient identification
      on its own, hence the track-shape fingerprint. Dropping `artist=`
      returns unrelated artists. Search results carry `community.have`/
      `community.want` (free ranking signal) and `user_data.in_collection`/
      `in_wantlist` per token holder (confirmed true on master 18080,
      which the user owns a pressing of — independent confirmation that
      master-level ownership is Discogs-native, but undocumented and a
      cross-check only). See the settled step-4 design above for how these
      feed the candidate-enumeration flow.
- [x] **Discogs API, hardware-tested with a personal access token,
      2026-09-07.** Authentication, the rate-limit header, the collection
      listing path, and collection sync cost are now recorded in
      `squeezewax-v1-decisions.md` §9 (§9.1, §9.2, §9.7) — this entry kept
      only for what isn't there: `stats.user.in_collection`/`in_wantlist`
      on `/masters/{id}/versions` is per-token-holder (null
      unauthenticated, 0/1 authenticated) — kept, not orphaned: it is the
      fallback ownership mechanism if the collection sync proves
      unworkable, and it independently confirms master-level ownership is
      Discogs-native. See the derived-owned-label open question above. See
      "Next —
      build-order steps 3–5" above for the two falsified claims and the
      master_id-sentinel finding from the same session.
- [ ] **2026-09-07, still unverified: unauthenticated rate tier.** Is the
      header actually 25/min? Documented, not confirmed by header.
- [ ] **2026-09-07, still unverified: do unauthenticated search results
      differ in content?** Docs say image URLs are withheld.
- [ ] **2026-09-07, still unverified: collection pages 2–3 unchecked for
      `master_id` population.** Only page 1 of the 203-item sample was
      checked.
- [x] **2026-09-07, ANSWERED: does LMS ever group local and streaming
      copies of one album under a single `albums.id`?** No. Verified —
      *Delta Machine* and *Singles 86>98* each exist as two rows, one
      all-local (`flc`) and one all-remote (`spt`), with `albums.extid`
      carrying the Spotify URI on the remote row. No mixed album exists.
- [ ] **Failed `<importmodule>` load visibility.** Does LMS surface the
      failed-to-load module as a persistent error state on the Plugins page?
      Does that state clear on its own once the module exists (next scan or
      restart), or does it need a plugin reinstall? Bears on whether the
      install.xml/Importer.pm split above is worth the tolerance at all.
- [x] **Material Skin — settings page.** Confirmed 2026-08-29 on the real
      server: all plugin settings pages are reachable in Material Skin.
- [ ] **Material Skin — badge overlay.** Still open, and a different question
      from the settings-page one above: Material renders the browse UI itself
      rather than proxying the Default skin's templates, so a badge injected
      into Default-skin templates presumably would not appear there. That's
      unverified inference, not observed fact — still blocks the §4 badge
      overlay design until actually checked against a build that has one.
- [x] **Album-id stability on a normal rescan.** Verified 2026-09-06. Stable
      across a dozen rescans - every `skipped 764` run is proof, since a moved
      key would have forced re-examination. And the important half: changing an
      album's title moved `lms_album_id` 3632 -> 3633 while `album_key` stayed
      `6720421d...`, one row, no orphan. An `lms_album_id`-keyed design would
      have lost the match there, which is what slimserver issue #397 records
      the Music and Artist Information plugin doing.
- [x] **Step 3 end-to-end on a server.** Run 2026-09-04/06 on Lyrion 9.1.1,
      764 albums. **13 of 14 executed, all passed**; the missing-database
      fail-safe was deliberately SUBSTITUTED by version skew, which exercises
      the same `_checkVersion` branch without the window in which a restart
      strands every match in a renamed file.
      Headline results: 478 matched of 578 examined; a no-change rescan went
      45.552s -> 0.049s; abort left no corruption and resumed correctly; and a
      title change moved `lms_album_id` 3632 -> 3633 while `album_key` held,
      which is decisions §2's central claim on real data.
      Eleven defects found and fixed, none of them reachable by the offline
      suites. Two documented claims falsified - see the plan's verification
      section.
- [x] **Remote-track timestamps in plugins other than TIDAL.** Answered
      2026-09-06 on the real server, and the answer was **no**: Spotty supplies
      its own `TIMESTAMP` through `updateOrCreate`, so 2858 of 2982 remote
      tracks carry one. The in-tree reasoning (`Slim/Formats.pm:261` behind the
      `-e $filepath` guard at `:259`) was correct and did not license the
      conclusion. This entry was right to hedge; `Library.pm` and `Tags.pm` had
      hardened it to "structurally NULL" and were corrected.
      No functional impact - Strict skips on `local_tracks == 0` before any
      timestamp is read - but the local-tracks guard is load-bearing, not
      defensive, and is now commented as such.
- [x] **`addPostConnectHandler` from a third-party plugin.** Confirmed
      2026-08-29 on the real server: working — `squeezewax.db` exists in the
      prefs directory, which it could not without the handler having fired.
- [ ] **DDL during a scan.** Only evidence is a 2016 CustomScan log; WAL and
      `sqlite_use_immediate_transaction` have both changed since.
- [x] **Step 2 end-to-end on a server.** Verified 2026-08-29 on Ubuntu package
      install, Lyrion 9.x: `squeezewax.db` created in prefs folder (not cache),
      owned by squeezeboxserver; `user_version` 1; `journal_mode` wal; all four
      tables present. Migration ran once (0→1), did not repeat on restart.
      `<importmodule>` working — Importer::initPlugin logs from scanner.
      Server and scanner attach concurrently under WAL with no lock errors.
      Post-scan disconnect/init/reconnect at SQLiteHelper.pm:626-628 observed
      firing, confirming postDBConnect necessity — one-shot startup attach would
      have been dropped there. Scanner-fails-safely-on-missing-database check
      unreachable on real server (server recreates during startup); marked as
      untested-on-hardware, covered by offline suite.
- [ ] **2026-09-12, HIGHEST VALUE MEASUREMENT: how often do LMS album titles
      and Discogs `basic_information.title` agree well enough to match?**
      Title-led matching against the collection is §13's entire foundation
      and this has never been measured. §8 measured title normalisation
      against SEARCH RESULTS, not against a collection. If real agreement is
      60%, the design still works but the review queue is far larger than
      anyone is picturing. Measurable now: `collection-page1.json` is
      captured and the 764-album reference library is on hand. Do this
      BEFORE the build order is rewritten. Recorded as §13.9's largest
      unmeasured assumption.
- [ ] **2026-09-12: what proportion of the 764 reference albums match the
      collection at all?** Every cost estimate in §13.5 and §13.6 rests on
      "a few hundred", which is the collection's size, not the measured
      overlap.
- [ ] **2026-09-12: confirm that a full rescan cannot recover a
      newly-bought record's badge (§13.6).** Inferred from `_canSkip` and
      `source_timestamp`'s definition, both read, but never observed. If
      false, §13.6's reasoning needs revisiting — though the separate
      ownership pass is right either way.
- [ ] **2026-09-12: confirm that `https://www.discogs.com/release/{id}`
      resolves without a title slug (§13.9).** The context-menu link is
      constructed from the stored id because `basic_information` carries
      only `resource_url` (`api.discogs.com`), which is not the web page
      §9.6's attribution requirement names. `Tags.pm` documents
      `/release/<id>` as canonical and accepts it, but `Tags.pm`'s own
      header records that discogs.com returns 403 to automated fetches, so
      it was never confirmed against the live site. One browser click
      settles it.

## Waiting — external

- [x] **2026-09-08: collection-page fixture not captured.** Six of the plan's
      seven §4 fixtures are in `scripts/fixtures/` (step 4 item 3 commits);
      the seventh — a page of a real collection, needed to re-verify the
      `master_id: 0` sentinel and the two-masterless-rows collision — needs a
      real Discogs personal access token for an account with a collection to
      page. None was available in the session that ran
      `scripts/fetch-fixtures.pl` (`$DISCOGS_TOKEN` unset). Run
      `scripts/fetch-fixtures.pl <token>` (or set `$DISCOGS_TOKEN`) once one
      is available; it skips fixtures that already exist, so it's safe to
      re-run. Not blocking build-order items 4-5 (out of scope this session
      regardless) but should land before Structural's comparison code is
      tested against it.
      ANSWERED 2026-09-11: the fixture exists — scripts/fixtures/
      collection-page1.json. This item was stale twice: the "six of seven"
      count predates the three 2026-09-10 fixtures, and the token blocker is
      resolved. Release 9701013 observed inside it carrying master_id: 0 and
      master_url: null, the §8 sentinel. NOT confirmed: the plan §4 table's
      claim of TWO masterless rows — one was observed.
- [ ] **Lyrion forum question** about plugin-owned attached databases. Drafted;
      not posted. Not blocking — an own-file layout cannot collide with anything
      LMS owns, and migrating later is cheap.

## Housekeeping

- [ ] **2026-09-11: tmp/ is where prompts and hand-off markdown are served to
      Claude Code, and it is git-ignored.** Recorded in CLAUDE.md as of this
      commit. Same class of undocumented convention as the plans/ filename
      item above. Consequence worth keeping: anything durable that starts life
      in tmp/ must reach a tracked file in the same session, or it exists only
      in an ignored directory and a chat.
- [ ] **2026-09-10: refs/ citation drift — decisions §§1-10 cite commit
      `50e5b725`, §11 cites `a670a38c` (`public/9.1`, 2026-06-19).** Nothing
      contradicted; recorded per working-agreement §6. Worth one pass to
      confirm the earlier citations still hold at the newer commit before
      step 5.
- [ ] **2026-09-10: `Slim::Schema->variousArtistsObject` is NOT
      side-effect-free — never call it from plugin code.** It creates a
      contributor row when no `namesearch` matches (`Slim/Schema.pm:
      2096-2100`) and renames an existing one when the stored name no
      longer matches the resolved string (`:2105-2111`). The read-only
      alternative is in decisions §11.3(d).
- [ ] **2026-09-10: `_pluginVersion`'s scanner-vs-server branch is
      untestable within a single test process, by design of how
      `main::SCANNER` works — recorded so it isn't rediscovered.**
      `Plugins::SqueezeWax::API::_pluginVersion` asks
      `Slim::Utils::PluginManager->dataForPlugin` for a different module
      name depending on `main::SCANNER` (the scanner never loads
      `Plugin.pm`, so its entry is keyed by `Importer` instead — see
      `SqueezeWax/API.pm`'s own comment on `_pluginVersion`). Tried
      reassigning `*main::SCANNER` mid-file in `scripts/api-check.pl` to
      cover both branches; it silently didn't take (Perl printed "Constant
      subroutine main::SCANNER redefined" and the User-Agent kept the
      first value) because `main::SCANNER` is a `()`-prototyped stub, the
      same shape `use constant` produces, and gets constant-folded into
      `API.pm` at compile time — the identical mechanism CLAUDE.md
      documents for why `Match.pm`'s scanner branch of `_writeRefusal`
      needed pulling out as a pure function in the first place. One test
      process fixes `main::SCANNER` for its whole life. The approach that
      works, when this needs covering: a second script, compiled with
      `main::SCANNER` predefined `=> 1`, the same way
      `scripts/syntax-check.sh` already runs every module in both `scanner`
      and `server` mode via two separate `perl -e` invocations rather than
      one process. Not blocking — `_pluginVersion`'s module selection is a
      single ternary, not decision-shaped the way `_writeRefusal` is, and
      wasn't in step 4 §4's minimum coverage list — but the next thing that
      needs both branches covered shouldn't have to re-derive this.
- [ ] **2026-09-07: `plans/` filenames are inconsistent.** Steps 2 and 3
      use invented verb-adjective-noun names
      (`build-order-step-2-read-effervescent-squirrel.md`,
      `build-order-step-3-tag-jolly-minsky.md`); step 4 uses a descriptive
      one (`build-order-step-4-structural-matching.md`). Descriptive is the
      convention going forward. Renaming 2 and 3 requires a `grep -rn`
      reference sweep across `docs/`, `plans/`, `CLAUDE.md` and `TODO.md`;
      cosmetic, optional, not blocking.
- [x] **2026-09-07: fold `docs/squeezewax-design.md`'s inline
      strikethrough-and-correction blocks into clean prose — WITHDRAWN
      2026-09-07.** Measured: §3 carries 9 superseded lines of 160, and
      the file has 11 correction blocks total. The premise was an
      impression, not a measurement. Corrections stay inline by decision
      — see the correction-labels note at the top of
      `docs/squeezewax-design.md`. The one genuine readability issue —
      §3's tiers table packing two falsification blocks into a single
      cell at line ~167 — is cosmetic and not blocking.
- [ ] **2026-09-07: this is the third, fourth and fifth instance of a
      pattern step 3 identified** — a claim derived from one path, or from
      a documented example, stated as a general property. (The
      `/database/search` auth claim, the one-request-per-master claim, and
      the format-exclusion claim, all in "Next — build-order steps 3–5"
      above.) The specific lesson from this pass: **reading a documented
      response example is not verification.**
- [x] **`package-dev-build.sh` writes git history as a side effect.** Done
      2026-09-06: the SqueezeWaxDev/repo-dev.xml arrangement is dropped
      entirely (see decisions §6a, `docs/dev-repo-workflow.md`). Its
      replacement, `scripts/package-build.sh`, never calls git unless
      `--publish` is passed explicitly, and a failed `git push` under
      `--publish` is now a named, non-zero-exit error rather than a bare
      `set -e` abort.
- [ ] **The review queue must not present `matched_at` as "since when".**
      A demoted row keeps the `matched_at` of the match it still carries, so a
      queue sorted by it would place last night's conflict among rows from
      years ago - wrong information, not missing information. Decided
      deliberately (decisions §3a): `matched_at` is the establishment time of an
      incumbent the row still holds, and overwriting it would destroy something
      useful. If step 5 wants a demotion timestamp it ships migration 3 with a
      nullable `state_changed_at`, by which point the requirement is concrete
      rather than assumed. Until then the discovery time is in `scanner.log`,
      which is timestamped - on record, just not queryable.

- [x] **Revisit `plugin.squeezewax` defaultLevel before v1 release.** Done
      2026-09-04 (cec7a46): WARN in both entry points. The scan-progress row and
      LMS's own "Starting/Completed ... Scan" pair carry the healthy-run signal
      that INFO was standing in for; the one thing neither reports —
      "examined 4,800, confirmed 0" — is escalated to warn by the importer.
- [x] **`working-agreement.md` exists twice** — checked 2026-09-06: it
      doesn't (`git log --all -- working-agreement.md` shows no root copy
      was ever committed). Stale; the file exists only at
      `docs/working-agreement.md`.
- [x] **`working-agreement.md` §2 names `docs/v1-decisions.md`;** the file is
      `docs/squeezewax-v1-decisions.md`. TODO's ticked step-2 line repeats
      the wrong name. Two documents disagreeing is a defect (§2's own rule).
      Fixed 2026-09-12: both references corrected.
- [ ] **`discogs_no_match` rows orphaned by an `album_key` change are not
      swept in v1.** Bounded by library churn; the table is regenerable and
      design §9's "clear & rebuild matches" action clears it. Revisit only if
      a real library shows meaningful growth.
- [ ] **"No rollback in the scan path" is inferred, not proven.** Design §8's
      resumability promise leans on it. A rollback would discard our
      uncommitted matches along with LMS's uncommitted scan work — recoverable,
      but it changes what §8 can promise.
- [x] Decide whether `dev-repo-workflow.md` lives in the repo root or in
      `docs/`. Done 2026-09-06: moved to `docs/dev-repo-workflow.md` as part
      of the packaging rewrite (decisions §6a) — it was rewritten anyway, so
      there was no working copy to preserve at the old path.
- [ ] After any commit under `docs/`, hit "Sync now" in the claude.ai project
      before the next design chat.

## Waiting — needs a real server (packaging)

- [x] **The dev LMS's Additional Repositories entry still points at
      `packaging-rewrite`'s `repo.xml`**, not `v1-buildout`'s. Done
      2026-09-07: `v1-buildout` cut its first build
      (`SqueezeWax_0_0_0_1.zip`, commit `8522050`), the entry was moved to
      `https://raw.githubusercontent.com/d5c0d3/lms-plugin-squeezewax/v1-buildout/repo.xml`
      (confirmed live, HTTP 200, and confirmed as the only SqueezeWax entry
      in the dev LMS's `repos` pref), and `packaging-rewrite` was deleted
      (local and remote).
- [x] **Install `SqueezeWax` over the existing `SqueezeWaxDev` on the dev
      server and confirm the transition `docs/dev-repo-workflow.md` §8
      describes.** Done 2026-09-07, on the `packaging-rewrite` branch build.
      All four checks passed: plugin loads (`squeezewax.db`'s WAL/SHM files
      were touched at the exact restart timestamp, proving `postDBConnect`
      ran); settings page renders (200, real content, no error banner — the
      one the old rename broke once); scan progress row shows its label
      (`plugin_squeezewax_match` appeared in `rescanprogress`'s `steps` and
      progressed 0→100% with live per-album `info`, not a missing-string
      placeholder); `squeezewax.db` stayed at `user_version` 2 with all 481
      matches intact (480 strict + 1 manual) through the whole transition
      and a subsequent real rescan. `discogsTagNames` did come back empty
      until reconfigured, exactly as §8 predicts — confirmed as the
      self-heal, not a bug, then reconfigured back to
      `DISCOGS_RELEASE_ID`/`foobar2000/DISCOGS_RELEASE_ID` to actually
      exercise the importer live.
- [ ] **At SqueezeWax's first real release:** enable GitHub Pages for
      `lms-plugin-squeezewax` (currently off — confirmed 404, no
      `_config.yml`), add the release-mode step to
      `scripts/package-build.sh` that regenerates `repo.xml` with a
      `d5c0d3.github.io/...` `<url>` instead of a raw one, and give
      `SqueezeWax/install.xml`'s `<version>` its first real value instead of
      the placeholder `0.1.0`. See `docs/dev-repo-workflow.md` §2.

## Deferred by decision — not forgotten

- **2026-09-07: pressing-vs-edition conflation remains in two ILLUSTRATIVE
  passages of `docs/squeezewax-design.md`, deliberately uncorrected**
  pending the step-5/6 "what does an edition-level match show" product
  decision (see "Open design questions" above), since that decision
  determines the replacement wording rather than another strikethrough:
  §2 Core Concept item 1 ("inspect details and value of the owned
  pressing") and §4's badge-derivation walkthrough ("matched to a
  different pressing that's on the Wantlist"). Both are illustrative. The
  NORMATIVE instance — §10's badge join — was corrected 2026-09-07, as
  were §3's Structural table cell, §4's context-menu list and §3's
  walkthrough 2. §6 Flow 1's "owns one of the listed pressings" is **NOT**
  an instance: Flow 1 browses real versions, so the release arm of the
  dual ownership test applies directly. Recorded so it is not "fixed" by
  mistake.
- **2026-09-07: monthly CC0 data dumps as an alternative to the API for
  tracklists — recorded in `squeezewax-v1-decisions.md` §9.8.** v2/v3.
- **2026-09-07: register `SqueezeWax` at discogs.com/settings/developers;
  obtain key and secret; commit neither.** DONE 2026-09-07 — see
  `plans/build-order-step-4-structural-matching.md` §2.2.
- **2026-09-07: settle the User-Agent string.** RESOLVED 2026-09-07 —
  see `plans/build-order-step-4-structural-matching.md` §3 item 2.
- **2026-09-07: token storage — settings-page action items.** Risk
  described in §9.1 (unscoped bearer credential, plaintext prefs). DONE
  2026-09-08 (step 4 item 1): `discogsToken` scalar pref, settings-page
  warning stating the token's real scope plus a revocation link to Discogs
  Developer Settings, and a "Test token" action. Checked
  `refs/lms-plugin-tidal/API/Auth.pm:139` — TIDAL keeps its OAuth access
  token in `Slim::Utils::Cache`, not prefs, but that token is short-lived
  and refreshed from a refresh_token; a Discogs personal access token is
  long-lived and user-generated with no refresh flow, so prefs (survives
  restarts) is the right place, not an oversight to fix. No secure-storage
  convention found in either reference plugin beyond that — plaintext-with-
  warning per decisions §9.1 stands.
- **2026-09-07: `discogs_price_snapshot` vs. Discogs TOU item 5 (v2/v3) —
  recorded in §9.8.** If built, label snapshots with observation dates.
- **v3: Discogs artist ID — add the column and the capture together.** Decisions
  §3 originally said to capture it while the file is open, justified as saving a
  later re-read. Migration 1 has no artist column and nothing reads one before
  the v3 artist badge, so with nowhere to store it there was no re-read to save
  (step 2 finding 8: don't carry a column nothing reads). `Tags.pm` therefore
  does not capture it. When v3 lands, do both in one migration — the parser
  already has `_parseEntityId`, so the capture is a few lines once the column
  exists.
- v2: triage / library-health page (problem releases only).
- v2: completeness check ("you have 9 of 12 tracks").
- v2: "Add to Wantlist" action, alongside Wantlist sync.
- v3: FX-rate source for optional currency conversion — still unselected.
- Not planned: any write to the Discogs Collection.
