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

- [x] **2026-09-22, SHIPPED BUG, FIXED: `syncNow` and `testToken` were dead
      buttons.** Found on the reference server — the manual "Sync collection
      now" button did nothing at all: no sync, no pref change, no log line.
      `settings/footer.html:39` puts a **hidden** `saveSettings=1` in the
      settings form beside the visible Save button at `:38`, so every submit
      carries `saveSettings` whichever button was clicked. `Settings.pm`'s
      `handler` tested `saveSettings` second in its `elsif` chain, so it
      swallowed `syncNow` and `testToken`, which sat behind it.
      `detectTagNames` was tested first and so always worked — which is why
      this was never noticed. Fixed by testing every named action first and
      leaving `saveSettings` as the fallback.
- [x] **2026-09-22, FIRST REAL RUN of the sync and the ownership pass**, on
      the reference server at 0.0.0.4. Recorded here because it is the first
      evidence that steps 5–7 work end to end on real rows, and nothing else
      tracked holds it.
      Sync: `203 items over 4 requests` (1 identity + 3 pages) — matches
      §9.4's measured collection size.
      Pass: `764 albums, exact=149 version=50 absent-with-row=305; wrote
      inserted=26 updated=477 deleted=0 promoted=0 demoted=327; queue-to-be
      gated=0 ambiguous=5 artist-disagree=2 artist-absent=0 undecodable=0`.
      **No identification was touched.** All 481 pre-existing rows still
      carry their original `match_tier`, `discogs_release_id` and
      `snapshot_track_count` — diffed against
      `BASELINE-discogs_match.csv`: 0 lost, 0 added, 0 changed. The 26
      inserts are ownership-only rows from the title route (NULL tier), for
      507 rows total and 199 with ownership.
      **demoted=327 is design §3 node E working, not a regression.** Step 3
      wrote `confirmed` with no collection check (the defect step 4 fixed);
      478 strict rows were confirmed, only 149 are owned exactly, so 327
      dropped back to `candidate`. The identification stands in every case.
      **Three rows look wrong and are not.** `strict/confirmed/absent` ×2 and
      `manual/confirmed/absent` ×1 all carry synthetic release ids (999999,
      77777, 888888) from earlier hand testing. The manual one keeps
      `confirmed` because a manual link is not subject to the collection
      cross-check (design §3). The other two are orphans: album 3633 has no
      tracks left, and `ab8737fa…` claims `lms_album_id 2919` but album
      2919's real `album_key` is `f0be6395…`, which has its own row and WAS
      correctly demoted. An orphan carrying an identification keeps its state
      for orphan recovery, exactly as `Ownership::_apply` says it should.
      **`gated=0`, against the page-1 measurement's 6.** Not a contradiction:
      `scripts/title-agreement.pl` measures the title route over every album,
      while the pass reaches node H only for albums no tag resolved first.
      Those compilations are tagged, so they never reach the gate. The
      script's figures bound the title route, not the pass.
- [ ] **2026-09-22, DEFECT: `unauthorized` is unreachable through
      `API/Async.pm`, so a rejected token reads as a dropped connection.**
      Found by step 5 check (c) on hardware at 0.0.0.6. A wrong token
      produces `no_response` at **warn**, never `unauthorized` at error, and
      `discogsLastSyncError` reads `no_response`.
      **Mechanism, verified in refs:**
      `Slim/Networking/SimpleAsyncHTTP.pm:76-101` (`onError`) sets `error` and
      calls the error callback but never calls `$self->code(...)`; only
      `onBody` at `:112` sets the code, and that runs on success only. So on
      the error path `$http->code` is unset and `API::classifyResponse` takes
      its `!$code` branch. `classifyResponse` itself is correct — its 401
      branch is simply never reached from the async side.
      `Async.pm:331-334`'s comment records the wrong assumption: "the error
      path means no response". A 401 is a real response that also takes the
      error path. `Settings.pm`'s `_testToken` shares the pattern and the
      hole.
      **This breaks §14.2** ("a rejected token must read differently from a
      dropped connection") and it is not cosmetic: a rejected token is
      treated as transient, so the interval retries it forever, at warn, with
      nothing naming the real cause.
      **Likely fix:** `onError` passes `$http->response` as its THIRD
      callback argument, so the real code is available there. Not applied —
      it changes retry behaviour on a recorded decision, and belongs in a
      design ruling first.
- [ ] **2026-09-22: the two token buttons disagree about which token they
      mean.** `_testToken` deliberately prefers the unsaved field
      (`Settings.pm:321`) — the point of a Test button is to check before
      committing. `_syncNow` reads the stored pref (`:220`), and
      `SUPER::handler` only saves the field afterwards, inside
      `_finishSyncNow`. So pasting a token and pressing **Sync collection
      now** syncs with the PREVIOUS token and saves the new one after the
      fact; you must Save first, then Sync. Observed 2026-09-22: the first
      click succeeded with the old token while the new one was already in the
      field. Decide whether `_syncNow` should prefer the field like
      `_testToken`, or whether the page should say so.
- [ ] **2026-09-22, FOR THE DESIGN CHAT: the scheduled sync cannot be turned
      off.** `Plugin.pm:77` validates `discogsSyncInterval` with
      `intlimit, low => 3600`, so the smallest legal value is one hour and
      there is no `0 = off`. For a plugin that makes unattended third-party
      network calls from someone's music server, "you may choose the
      frequency but not whether" is the wrong default. Compounded by the
      defect above: with a bad or revoked token the schedule retries daily
      forever and reports a misleading transient error each time. The 86400
      default is already recorded in `Plugin.pm:46-50` as a product call, not
      a measured or specified figure.
- [x] **2026-09-22, REGRESSION SHIPPED AND FIXED IN ONE SESSION: 0.0.0.5's
      disable-on-click made the buttons dead again.** Disabling a submit
      button inside its own click handler does not merely drop its name from
      the form data set — it **cancels the submission**. On the reference
      server the buttons greyed out, relabelled, and produced no server-side
      activity at all; the only sync in the window was the 300s first-poll
      timer. Fixed in 0.0.0.6 by deferring the disable with `setTimeout(…, 0)`,
      after the form data set has been serialised.
      **Why the suite missed it:** `settings-check.pl` asserted that the name
      is copied BEFORE the disable, which was still true. The defect was that
      the disable happened synchronously at all. Two assertions added: the
      script must defer with `setTimeout`, and the disable must be inside the
      deferral.
      Second time in one session that this page's dispatch has been broken by
      something invisible to the server (the hidden `saveSettings` field, then
      this). Both were browser-side facts, and neither offline suite could
      have found them without being told what to look for. **A browser-level
      check of this page is the only thing that would catch the third.**
- [ ] **2026-09-22: `discogsTestExcludeReleases` is a development aid and must
      not outlive v1's testing.** A hidden pref, empty by default, no settings
      field: `API/Async.pm`'s `_testFilter` hides the listed release ids from
      the ownership pass, after the completeness gate and before
      `Ownership->apply`, so "a record left the collection" can be exercised
      on a live server without altering a real collection. The fetch is
      untouched and nothing is sent to Discogs. Every sync warns while it is
      set, including with a count of 0. Documented in
      `docs/dev-repo-workflow.md` §6a; asserted in `sync-check.pl` (15
      assertions). **Before v1 ships, decide whether it stays.** It is a
      back door into the badging rules that no user should ever need, and its
      only defence is that it warns.
- [ ] **2026-09-22, NAMED COST of decisions §15.13 part 3 (artists at L2): two
      correct badges lost on the reference library** — Future Sound Of London,
      albums 3124 and 3127, against Discogs `The Future Sound Of London`.
      §13.10.4's trade, accepted; these reach the review queue (step 8).
      Revisit only if the pattern repeats.
- [ ] **2026-09-22, STEP 8 CONSTRAINT, restated with a number:** after the
      first real pass the reference server has 329 `strict`/`candidate` rows,
      of which 305 are ownership `absent` — tagged albums the user does not
      own. None of them is a queue item (§13.4, §14.3, design §3: candidate is
      not the queue). The queue selects §13.10.5's four contents only; on this
      run that is 5 ambiguous + 2 artist-disagree, plus Strict conflicts and
      (later) tag disagreements.
- [x] **2026-09-22, DECIDED (design chat): settings-page action buttons
      disable and relabel on click**, client side, showing the existing
      running string. A polling interim page is recorded, not designed:
      revisit if syncs longer than ~10s are seen.
      DONE 2026-09-22. Plain DOM in `settings.html`, no framework and no
      polling; the page still works with JavaScript off. **Deviation worth
      knowing:** the existing `*_RUNNING` strings are sentences ("A collection
      sync is running.") that read wrong as a button label, so three short
      labels were added — `PLUGIN_SQUEEZEWAX_{SYNC,TOKEN_TEST,DETECT}_BUTTON_RUNNING`
      — and the sentence strings keep their existing server-rendered uses.
      The subtlety the implementation turns on: a disabled control is not part
      of the form data set, so the clicked button's name and value are copied
      into a hidden input BEFORE anything is disabled, or every action would
      fall through to a plain save. `settings-check.pl` asserts that ordering,
      that the wired buttons are exactly the three `handler()` dispatches on,
      and that each running string exists in `strings.txt`.
      No core pattern was followed because none exists:
      `settings/server/basic.html:11-30` polls `rescan ?` on an Ext TaskRunner,
      which is the shape this was decided against.
- [x] **2026-09-22: `Settings.pm` has an offline suite.**
      `scripts/settings-check.pl`, 43 assertions. It drives the REAL
      `handler()`, not an extracted dispatcher: extracting the chain would
      have left the shipped dispatch as untested as it was when the bug
      shipped. Which action ran is observed at the module's real boundaries
      (`Async->sync`, `SimpleAsyncHTTP->get`, `sample_albums`/`add_task`, the
      pref write), never by overriding the action subs. It also reads
      `settings/footer.html` out of `refs/` and asserts the hidden
      `saveSettings` field is still there, so a core change to that template
      fails here rather than in the field.
      **Verified to catch the original bug:** restoring 0.0.0.3's dispatch
      order fails 10 of the 43, including "saveSettings + syncNow reaches
      _syncNow".
      Also adds `scripts/check-all.sh` — there was no all-suites runner
      before, which is part of why a missing suite was easy to miss. 733
      assertions across eight suites.
- [x] **2026-09-22: the offline check-6 harness is not committed.** DONE —
      landed as `scripts/ownership-offline-check.pl`. Takes its paths as
      arguments like `title-agreement.pl`, defaults to the committed page-1
      fixture and to dropping releases 9701013 and 443973, and takes its own
      copies of both databases through SQLite's online backup from a
      read-only handle — so it is safe to point straight at a running LMS and
      it does not trust the caller to have passed a copy. Verified against
      the live files: same two-row result, and `discogs_match` byte-identical
      afterwards. **Not in `scripts/check-all.sh`**, and its header says why:
      it needs a real library, which no other suite does.

- [ ] **2026-09-22, UI: the action buttons give no "working on it" feedback.**
      Asked for after the first real sync. `_syncNow` defers the page render
      through `$callback` until the sync's own callback fires, so the browser
      sits on a pending POST for the whole sync and the person who clicked
      sees nothing at all — no spinner, no "syncing…", just a page that has
      not come back yet. It happened to be ~2s on the reference collection
      (203 items, 4 requests); a larger collection, a rate-limit wait or
      §15.2's retry makes it long enough to look broken, and the natural
      response to a button that looks dead is to click it again.
      The template already has a `sync.running` branch
      (`settings.html:49-50`, `PLUGIN_SQUEEZEWAX_SYNC_RUNNING`), but it only
      renders for someone who RELOADS the page while a sync is running —
      never for the person who started it. So the string exists and the state
      exists; what is missing is showing it to the clicker before the work
      finishes.
      Same gap on "Test token" and "Detect tag names", which defer the same
      way. Worth solving once for all three rather than three times.
      Needs a decision on the shape: a client-side disable-and-relabel on
      submit is the cheap one and needs no new round trip; rendering an
      interim page that polls is the honest one and is what a long sync
      actually wants. Design chat, not a unilateral pick.
- [x] **2026-09-22, NO SUITE COVERS `Settings.pm`'s dispatch.** DONE — see
      `scripts/settings-check.pl` above.
      ~~ The dead-button
      bug above shipped in 0.0.0.3 and would have been caught by one offline
      test asserting that a params hash carrying BOTH `saveSettings` and
      `syncNow` reaches `_syncNow`. There is no `scripts/settings-check.pl`;
      `Settings.pm` is the only module with no offline exercise, and it is the
      one module whose inputs come from a browser. Worth one, at least for the
      dispatch chain — the async render paths are harder and can wait.~~

- [x] **2026-09-13, CHANGES MIGRATION 3'S SHAPE: migration 3 is a 12-step table
      rebuild of `discogs_match`, not an `ALTER TABLE ADD COLUMN`.** DONE
      e275221 (`Schema.pm::_migration_3`) — every obligation below is ticked
      individually. The 3.53.0 reasoning held up: LMS bundles SQLite 3.46.1
      (VERIFIED 2026-09-20), so `ALTER COLUMN ... DROP NOT NULL` was not
      available and the rebuild was required rather than chosen. Verified
      against `sqlite.org/lang_altertable.html` (page dated 2026-06-04): SQLite
      cannot modify an existing CHECK constraint; the ALTER TABLE page's §8
      names the create-copy-drop-rename procedure as the only route. `ALTER COLUMN ...
      DROP NOT NULL` exists as of SQLite 3.53.0 (2026-04-09) but covers the
      nullability half only. The ownership column (§13.3) and the narrowed
      `match_tier` CHECK (§14.1) therefore ride one rebuild. Two obligations,
      both blocking:
      (a) DONE e275221. COUNT any `match_tier IN ('structural','fuzzy')` rows before copying
          and REFUSE LOUDLY if any exist — the narrowed CHECK would otherwise
          fail mid-copy on the one table that is not disposable. That none
          exist is INFERRED (step 4 stopped after item 3), not verified.
          Inference is not sufficient for a destructive migration.
      (b) DONE e275221. ASSERT in the offline suite that a NULL `match_tier` is accepted by
          `CHECK(match_tier IN ('strict','manual'))`. Standard SQL treats a
          CHECK evaluating to NULL as not violated, so no explicit
          `OR match_tier IS NULL` should be needed — expected, NOT verified
          here. Assert alongside the existing cases (rejects `'Strict'`,
          accepts `'manual'`). ALSO FLIP the existing cases that assert
          `match_tier` ACCEPTS `'structural'` and `'fuzzy'`
          (`scripts/schema-check.pl`, the `for my $tier (qw(strict
          structural fuzzy))` loop): after the narrowing both must be
          REJECTED. Added 2026-09-15 — obligation (h) carried this for
          `discogs_no_match.tier` and (b) did not for `match_tier`.
      (c) DONE e275221. DROP the `state` column's `DEFAULT 'candidate'`. Decisions §14.8
          makes `state` nullable; with the default retained, any insert
          omitting it writes `candidate` instead of NULL and drops an
          auto-badged album into the review queue — silently wrong rather
          than an error. ASSERT in the offline suite that an insert omitting
          `state` yields NULL.
      (d) ~~CONFIRM the orphan-recovery index `(state, snapshot_track_count)`
          needs no change. Recovery selects `state = 'confirmed'`, so NULL
          rows should be excluded by the predicate — INFERRED from the
          predicate, not verified against a query plan (decisions §14.8).~~
          **CORRECTED 2026-09-18 (decisions §15.9): SUPERSEDED BY (g).** This
          was written under §14.8, when recovery keyed on `state =
          'confirmed'`. §15.5 moved the predicate off `state` and (g) rebuilds
          the index accordingly. Do (g); do not "confirm no change" here.
          The struck text is kept because the reasoning it carries — that a
          predicate-based exclusion is inferred rather than verified against a
          query plan — still applies, and (g) inherits it.
      (e) DONE e275221. COPY `state` AND `match_tier` FORWARD UNCHANGED, and set
          `ownership = 'absent'` on every copied row (decisions §15.3). COUNT
          rows before and after the rebuild and assert equal; assert that no
          row's `state` differs from its pre-migration value. The ownership
          pass, not the migration, re-derives `state`.
      (f) DONE e275221. DROP `snapshot_total_duration` (decisions §15.5). Nothing in v1
          reads or writes it; the rebuild makes dropping it free. COUNT the
          columns of the rebuilt table and assert the expected set.
      (g) DONE e275221, IN PART — and (d), which it superseded, is discharged
          with it. REBUILD the orphan index to match §15.5's predicate
          (`match_tier`, `snapshot_track_count`) instead of
          `(state, snapshot_track_count)`. Verify with EXPLAIN QUERY PLAN
          that the recovery lookup uses it, per obligation (d)'s standard.
          The rebuild is done and asserted (`schema-check.pl`, the orphan-index
          case). The EXPLAIN QUERY PLAN half is NOT done and cannot be: there
          is no such lookup to plan. VERIFIED 2026-09-20 by Claude Code against
          HEAD — `Match::snapshotRows` (`Match.pm:259-268`) selects the whole
          table and `Importer::_prePass` (`:355-359`) filters in Perl, and the
          only two statements naming `snapshot_track_count`
          (`Match.pm:412-416`, `:662-672`) are keyed on `album_key`, the
          PRIMARY KEY. Replaced by the recorded finding at the 2026-09-19 item
          below, approved with the plan (N2). This is the same defect shape as
          (d): an obligation written against a query that was never built as
          SQL.
      (h) DONE e275221. NARROW `discogs_no_match.tier` to `CHECK (tier IN ('strict'))`
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
      (i) DONE e275221. DROP `discogs_collection` and its index `discogs_collection_release`
          (decisions §15.10). A plain `DROP TABLE IF EXISTS` — the table is
          entirely regenerable and carries no decision, unlike
          `discogs_match`. Two sub-obligations:
          - CONFIRM FIRST that nothing in `SqueezeWax/` reads or writes it.
            The 2026-09-13 item requires this and it still stands.
            ALREADY KNOWN, so do not report "zero": `scripts/schema-check.pl`
            inserts into the table at two sites (verified 2026-09-18).
          - UPDATE `scripts/schema-check.pl` in the same change. THREE sites,
            not two — corrected 2026-09-18, the earlier text named only the
            inserts: the two inserts, the `list_state` CHECK assertions around
            them, AND the "expected tables exist" loop, which asserts the
            table is present. Do not work from this list alone: grep the suite
            for `discogs_collection` and account for every hit, because this
            enumeration has already been wrong once.
- [x] **2026-09-13: `SqueezeWax/Schema.pm` migration 1 creates
      `discogs_collection`, which v1 must not have.** DONE e275221 by obligation
      (i). The "CONFIRM ZERO READERS AND WRITERS FIRST" condition was met:
      Phase 0 (2026-09-20) grepped `SqueezeWax/` and `scripts/` and found 11
      references, zero readers, and no writers outside `_migration_1`'s own
      DDL — and found the table present with 0 rows on the reference server,
      so the drop discards nothing. The inference the item refused to migrate
      on is now a verified count. VERIFIED in
      `_migration_1`: the table plus an index on
      `(discogs_release_id, list_state)` commented as "the badge-derivation
      join in design §4" — a join decisions §13.3 replaced with a column
      read. Migration 1 is shipped and hardware-verified, so the table exists
      on the reference server. The ruling against it (`TODO.md` 2026-09-07,
      reaffirmed decisions §13.2) postdates the code by days and nobody went
      back for it. Design describes the intended model and omits the table.
      **Migration 3 should drop it — but CONFIRM ZERO READERS AND WRITERS
      FIRST.** Collection sync was never built so there are almost certainly
      none, but that is INFERRED and a destructive migration should not run
      on an inference. `discogs_price_snapshot` and `discogs_release_cache`
      are NOT the same case: both are unwritten in v1 by plan, serve v2/v3,
      and are named in design §10.
- [x] **2026-09-13: the ownership pass must not write a row per album.**
      DONE 3b197cb (`Ownership::_apply`, the `!$row` branch). Decisions
      §14.8's invariant: absence of a row already means "nothing
      known", so a row with NULL `state`, NULL `match_tier` and
      `ownership = 'absent'` asserts nothing and must never be written. A row
      exists only where there is an identification, or an ownership
      conclusion other than `absent`. Without this the pass would write 765
      rows on the reference library, most of them empty. The invariant is
      NEW in §14.8 — it follows from the columns but was never stated.
      Asserted in `scripts/ownership-check.pl`: an untagged album owning
      nothing gets no row, an ambiguous one gets no row, a Various-gated one
      gets no row, and §15.13 part 5's delete removes a row whose ownership
      lapsed. The hardware check is (2) of the step 6-7 entry below.
- [x] **2026-09-13: is a master-id tag among the configurable tag names?**
      UNVERIFIED — `SqueezeWax/Tags.pm` settles it. Design §3's flowchart
      node F asks whether an album's master is in the collection, and it
      fires only where the master is ALREADY known: from a configured tag, or
      stored on the row. It must never look one up — a `GET /releases/{id}`
      per tagged unowned album is exactly the per-album cost decisions §13.1
      removed. If no master tag is configured by default, node F is near-dead
      in v1 and essentially all version ownership comes from the
      title-and-artist route. That does not make the flow wrong; it changes
      which path is the main one.
      2026-09-15, RESOLVED — decisions §15.1. No master tag is configurable:
      `Tags.pm`'s `@MASTER_KEYS` is a fixed list of three spellings, read only
      on `decide()`'s clean-hit path. The "near-dead if not configured by
      default" reasoning above was built on the wrong premise — node F is
      live for those spellings, and its real reach is unmeasured (see the
      node F measurement item).
- [ ] **2026-09-13: confirm the no-master sentinel against a fixture.**
      Design's ownership test guards against it, and the reconciliation
      carried the guard forward without verifying it. Reported as `0` in
      collection `basic_information` and `null` in the release payload —
      RECALLED from the existing design text, NOT verified. One of the ten
      captured fixtures should settle it.
- [x] 2026-09-12, BLOCKS THE BUILD ORDER: docs/squeezewax-design.md is partly
      superseded by decisions §13 and §13.10 and has NOT been reconciled.
      working-agreement §2 makes design win over everything and calls decisions
      "not live spec", so the precedence rule currently points at the stale
      document — a build session following the rule would build the
      search-first Structural flow. Temporary markers are in place as of this
      commit; they are scaffolding, not the fix. 20 contradicted places surveyed,
      listed in plans/design-reconciliation-survey.md along with what survives
      untouched. The reconciliation is a design-chat session: design gets
      rewritten in its own voice around the collection-first flow, citing
      decisions §13 for the reasoning, with no superseded prose retained (design
      is live spec, not a record). Do the reconciliation BEFORE the build order.
      2026-09-15: done. Reconciled 2026-09-13, f9a7644..32a6504; rulings in
      decisions §14; banner removed. Ticked late — the reconciliation session
      did not close this item.
- [x] 2026-09-12: Importer.pm's local_tracks == 0 gate and the comment above
      it now contradict decisions 13.10.1 and must be changed by the build
      order. ~~The gate came from Structural's duration fingerprint, which no
      longer runs.~~ It excluded 186 of 765 albums, 24%.
      2026-09-19, CORRECTED AND CLOSED — decisions §15.11. The struck reason
      belongs to decisions §8's Structural gate, a different gate. The
      importer's own comment gives its reason as "nothing to read tags from",
      which still holds: all-remote albums have no local candidates. The gate
      STAYS in the importer; §13.10.1's all-albums scope is carried by the
      ownership pass (step 7). Closed without a code change.
- [ ] **2026-09-12: plans/build-order-step-4-structural-matching.md is stale in
      its entirety** — it plans decisions §8's search-first flow, which
      decisions §13.8 supersedes. Its §6 still calls for a "design §13 rewrite"
      of a request budget that no longer has per-album searches to budget for.
      Do not patch it; it is superseded by the build-order rewrite.
- [ ] **2026-09-12: the review queue must not fill with albums the user does
      not own (§13.4).** An album identified from a tag but absent from the
      collection needs no human decision. Against a few-hundred-item
      collection and a ~~764~~ — corrected 2026-09-12: 765 — album library,
      most albums are unowned, so a candidate predicate that catches them
      turns the queue into noise. This
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
      go to the review queue rather than grinding. Blocks the design §13
      rewrite.
      ~~OPEN: enumerate candidates via `/masters/{id}/versions` or
      `/database/search`? Take it with the budget.~~ — **RESOLVED
      2026-09-07: `/database/search` with `type=master`. See the settled
      step-4 candidate-enumeration flow below.**
      2026-09-12: superseded by decisions §13 — v1 performs no per-album
      Discogs search.
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
      notice — decide before step 6 starts.** 2026-09-19: "step 6" is the
      2026-09-07 numbering and meant the badge, now build-order step 9.
      Decide before step 9 starts.
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
- [x] **Orphan recovery writes an UPDATE, not an INSERT.** Relink by updating
      the orphaned row's `album_key`, `lms_album_id` and snapshot, carrying
      `discogs_release_id`, `match_tier`, `state` and `matched_at` forward:
      relinking re-identifies which local album the match belongs to, it does
      not re-decide which release it is. An INSERT would need a provenance
      value nothing re-evaluated.
      — done in step 4 commit 5. `Match->relinkOrphan` is an UPDATE of
      `album_key` and `lms_album_id` only, asserting exactly one row changed.
      **One correction to this item's own wording:** the snapshot is NOT
      updated, it is carried. §15.4 captures the snapshot at identification,
      and a relink is not one — it re-identifies the album, not the release,
      so there is nothing to re-snapshot. `source_timestamp` is carried too,
      which is what makes the moved album skip on the same scan (plan §0.5).
      The ambiguous branch is step 8's (§15.5 part 4).
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
      2026-09-13: ground (c) is obsolete — Structural no longer exists
      (decisions §13.8). The failure shape moved rather than vanished: a wrong
      VERSION badge from the title-and-artist route auto-badges without ever
      entering the queue, so there is nothing to reject. v1 ships no recovery
      path for it by decision — decisions §14.4 — on the stated assumption of a
      well-tagged library and a maintained Discogs collection. Grounds (a) and
      (b) are unaffected and still require reject/dismiss.
- [x] **2026-09-15, BUILD ORDER MUST HANDLE: `Match::_recordMatch` writes
      `state = 'confirmed'` on every clean tag hit, with no collection
      check.** VERIFIED: the SQL literal is `'strict','confirmed'`, and
      `match-check.pl` asserts "a clean hit auto-confirms". Design §3 node E
      and decisions §13.4 confirm only when the tagged id is in the
      collection. INFERRED, not observed in the database: reference-server
      rows are therefore confirmed regardless of ownership. Knock-ons: existing strict rows need their state re-derived
      (Q1 in the build-order rewrite item below); `hasAnyStrictMatch`
      keys on strict+confirmed, so the anomaly warning changes meaning
      (INFERRED); snapshots are captured at confirm time, which moves if
      confirmation moves to the server-side pass; comments saying "the badge
      join is state='confirmed'" are stale.
      — done in step 4 commit 4. `_recordMatch` writes `'strict','candidate'`
      and returns `'identified'`; `hasAnyStrictMatch` keys on a non-NULL
      `discogs_release_id` at strict tier in any state; the stale
      badge-join comments in `Match.pm` and `match-check.pl` are rewritten.
      The two knock-ons this item could not settle were ruled on rather than
      coded: re-derivation of existing rows is the ownership pass's (§15.3),
      and snapshot capture stays at identification (§15.4).
- [ ] **2026-09-15: size of decisions §13.5's all-tags read** (albums both
      owned and tagged). It now runs server-side in a Scheduler task
      (decisions §15.2), so its size bounds how long the ownership pass takes.
      Unmeasured.
- [ ] **2026-09-15: build-order rewrite from step 4 — in progress, NOT
      decided.** ~~The design chat has proposed a sequence; no plan file exists
      yet.~~ **2026-09-19: the sequence is decided (decisions §15.9, and
      `CLAUDE.md`'s Build order), and step 4's plan is
      `plans/build-order-step-4-identification-rework.md`. The item stays
      open for Q9 and Q10.** Recorded so it is not re-derived from scratch,
      not as a ruling.
      2026-09-19: step 4 code complete at a50c9d0; hardware checks open below.
      Proposed, in order:
      4 identification rework (importer stops writing `confirmed`; write
        `snapshot_artist` from `albums.contributor`, §11.4 and §15.5; build
        the unambiguous orphan relink, §15.5; remove `discogsMaxTier`, §15.8;
        detection bare-master fix; stale comments; `hasAnyStrictMatch`
        semantics. Neither the `use` gate nor the `local_tracks` gate
        changes, §15.8 and §15.11);
      5 collection sync (server-side, async — decisions §15.2). Testable on
        its own: three requests, last-synced timestamp advances, nothing
        written to `discogs_match`;
      6 migration 3 (its obligations as already recorded in this file).
        REORDERED 2026-09-18 by decisions §15.9, and it SHIPS WITH step 7 —
        reviewable as its own step, not merged ahead of the code that
        exercises it;
      7 ownership pass (design §3 nodes C–K, decisions §14.8).
        Iterates EVERY album, all-remote included — this is where §13.10.1
        lands, not in the importer (§15.11). §13.5's all-tags read moved to
        step 8 on 2026-09-19 (decisions §15.13 part 7). Plan:
        `plans/build-order-step-6-7-ownership.md`;
      8 review queue and manual re-match (decisions §13.10.5, §14.9);
      9 owned badge and context menu (design §4, decisions §14.5, §14.10);
      10 on-demand marketplace lookup (design §7).
      Open questions blocking it. CONVENTION: an open one ends with
      "Not decided."; a settled one carries a "RESOLVED <date>" line naming
      the decision record. Grep for "Not decided." to list what is still
      open — two design-chat reports were wrong about this because the
      marker had not been applied consistently. The two occurrences of the
      phrase inside THIS note are expected hits; count from the Q lines
      below, not from a raw grep total.
      Q1 — existing `strict`/`confirmed` rows: migration 3 demotes them all
        and the first ownership pass re-promotes owned ones, or the ownership
        pass demotes the unowned ones. Demoting first removes them from
        orphan recovery (`state = 'confirmed'`) until a sync completes.
        Leaning: the pass does it, now that §15.2 runs it after identification.
        RESOLVED 2026-09-15 — decisions §15.3, as the leaning above: the pass
        promotes and demotes; migration 3 copies `state` unchanged
        (obligation (e) on the migration item).
      Q2 — `discogs_no_match.tier`'s CHECK still allows `'structural'`. Does
        it narrow in migration 3? The table is regenerable, so it could be
        dropped and recreated rather than rebuilt. Not in migration 3's
        recorded obligations as far as the design chat read.
        RESOLVED 2026-09-15 — decisions §15.6: it narrows to `strict`, by
        DROP and recreate inside migration 3, keeping the `tier` column and
        the composite PK. Now obligation (h) on the migration item.
      Q3 — RESOLVED, decisions §15.2.
      Q4 — does the ownership pass treat "Various" and "Various Artists" as
        the same artist? Discogs uses the former, LMS the latter (7 of 100
        fixture entries, against 95 compilations). Under the badging rule an
        artist disagreement sends the album to the review queue, so without a
        rule most matched compilations queue for a lexical reason. The
        title-agreement measurement reports the bucket split both ways and
        deliberately does not add the equivalence. Recorded 2026-09-15: the
        question is open and blocks step 7.
        RESOLVED 2026-09-15 — decisions §15.7: they agree. The LMS side is
        `Slim::Music::Info::variousArtistString()`, never a literal; the
        Discogs side is `Various` or `Various Artists` after the ` (N)`
        strip, both case-folded. `albums.compilation` is deliberately not
        sufficient on its own. GATED: the ownership pass must not auto-badge
        an album whose artist agreement is reached only through this
        equivalence until the pages 2–3 measurement reports — see that item's
        four added questions, and Q9. Corrected 2026-09-19 (§15.11): the gate
        first keyed on `compilation = 1`, which §11.3(c) measured as wrong for
        11 Various-ish albums.
      Q5 — RESOLVED 2026-09-15 — decisions §15.5: recovery considers any
        orphaned row with an identification and a snapshot
        (`match_tier IS NOT NULL AND snapshot_track_count IS NOT NULL`),
        not rows selected on `state`. The premise of the original item was
        partly wrong; see its own item, now ticked.
      Q6 — when is the orphan-recovery snapshot captured? Design §10 says
        "at confirm time", which was the same instant as identification while
        `_recordMatch` confirmed. Decisions §15.2 and §15.3 split them across
        two processes. Leaning: capture at identification, since the scanner
        has the LMS album data in hand and the pass would otherwise re-read it
        per promotion. CONSTRAINT, verified in `Match.pm::_recordNoMatch`: the
        one permitted deletion requires `state = 'candidate' AND
        discogs_release_id IS NULL AND snapshot_track_count IS NULL`, so
        capturing a snapshot on a CONFLICT row would make that delete
        unreachable and leave phantom conflict rows in the queue forever.
        Whatever is decided must leave conflict rows without a snapshot.
        RESOLVED 2026-09-15 — decisions §15.4: capture stays at
        identification, conflict rows never carry a snapshot, and the pass
        neither captures nor refreshes. No code change; the residual is
        design §10's wording, now item (e) of the design-fix list.
      Q7 — which step owns orphan recovery? It is NOT built: its `TODO.md`
        item ("writes an UPDATE, not an INSERT") is unticked and `Match.pm`
        has no relink path. The step-2 plan deferred it to "step 3/4" and
        step 3 did not take it. The proposed sequence above does not name it.
        RESOLVED 2026-09-15 — decisions §15.5: recovery belongs to the
        identification step (step 4), which builds the unambiguous relink.
        The ambiguous branch is an obligation on the review-queue step.
      Q8 — what happens to the `discogsMaxTier` pref? VERIFIED 2026-09-15:
        `Settings.pm` initialises it to `'strict'` and lists it in `sub
        prefs`, and `HTML/EN/plugins/SqueezeWax/settings.html` offers a
        `structural` option. Structural and Fuzzy do not exist (§13.8,
        §14.3), so the settings page lets a user select a tier that cannot
        run, and picking it does nothing at all — no error, no log line.
        Four things touch it: the importer's `use` gate (the stale step-4
        plan wanted `@discogsTagNames || ($maxTier ne 'strict' && $token)`),
        decisions §10.2 which lists "tier selector" among the prefs that
        survive clear & rebuild, design §9's settings list, and §3b's
        per-pref invalidation clauses. Design-chat leaning: REMOVE the pref —
        a selector with one valid value is a control that can only be set
        wrong. Against: it is shipped and hardware-verified, so removal needs
        a prefs migration or an accepted orphan key. Blocks step 4, because
        the `use` gate is part of the identification rework.
        RESOLVED 2026-09-18 — decisions §15.8: the pref is REMOVED, by a
        `$prefs->migrate` step in the identification rework. Design §9 already
        says matching is not configurable, so this is compliance rather than a
        choice, and the code was the thing out of line. The `use` gate does NOT
        change — it stays `scalar @{discogsTagNames}`, which is correct for
        tag-driven identification.
        (The snapshot-column question informally numbered Q8 in chat is
        settled by §15.5; this is the only Q8 in the record.)
      Q9 — should the badging rule gain a CONFIRMATION TEST on the
        single-candidate path: label, catalogue number or year checked
        against the one remaining collection entry? Raised 2026-09-15 by
        §15.7: once `Various` agrees with the LMS label, artist carries no
        information for compilations (§11's placeholder finding), so title
        uniqueness alone bounds a compilation badge — and §14.4 gives a
        wrong version badge no recovery path. VERIFIED against slimserver
        `a670a38c2b14`: `albums.label` exists (`schema_23_up.sql`) but
        nothing in 9.1 writes or reads it and `Slim/Schema/Album.pm` does
        not declare it, so label means a per-album file read; and
        `albums.year` is the file's YEAR tag (often the original year) while
        Discogs' `year` is the pressing's. This AMENDS §13.10.3, so it is a
        decisions change, not build order. Decide from the pages 2–3
        measurement's four added questions, not from these two facts alone.
        2026-09-19: step 7 ships with this open (decisions §15.13 part 8) —
        matches reached only through the `Various` equivalence stay
        unbadged, per §15.7/§15.11, until the measurement reports.
        2026-09-20, FOUND WHILE BUILDING B2, must be settled with Q9: the
        gate has a seam. §15.13 part 8 gates matches reached ONLY through
        the equivalence, and §2.2 consults the equivalence only after plain
        equality fails. So with `variousArtistsString` at its English
        default, a Discogs credit of `Various Artists` is plain equality and
        BADGES, while `Various` on the same record reaches the equivalence
        and is GATED — the outcome turns on which of its two
        various-artists spellings Discogs used, though §15.7 calls both the
        same vocabulary. Asserted as-built in
        `scripts/ownership-check.pl`. Q9's answer must cover both spellings
        or the gate is arbitrary.
        2026-09-20: the SEAM is closed by decisions §15.14 — the gate now
        holds every Various-to-Various match, however spelled, until the
        pages 2–3 measurement reports. Q9 itself (a confirmation test) is
        still open. Not decided.
      Q10 — which LMS album artist does the ownership pass compare with
        Discogs'? Decisions §11.4 recommended `Slim::Schema::Album::artists`,
        and §15.12 found its rationale false at slimserver `a670a38`:
        `artists` never reads `albums.contributor`, and it can reach
        `variousArtistsObject`, which §11.3(d) forbids because it writes to
        the library. Step 4 uses the `albums.contributor` column for the
        snapshot, which compares LMS with LMS only. Step 7 compares with
        Discogs, where the choice decides which albums badge — including the
        11 Various-ish albums §11.3(c) measured with `compilation = 0`, and
        §15.11's equivalence gate. Must not be `Album::artists`. Blocks
        step 7.
        RESOLVED 2026-09-19 — decisions §15.13 part 2: the rule
        `scripts/title-agreement.pl` measured with — first ALBUMARTIST
        (role 5) by contributor id, else first ARTIST (role 1), else
        `albums.contributor`, by raw SQL, decoded to characters — compared
        at L2 after the ` (N)` strip (§15.13 part 3, which departs from the
        script's L5 for artists). The snapshot keeps `albums.contributor`.
      Dependencies the design chat believes are already in TODO.md, not
      verified by it: (i) Various/Various Artists: FOUND at line 613
      (ii) version-menu picker: FOUND at lines 370, 423, 533
      (iii) marketplace minimum scope: FOUND at line 445
      (iv) migration 3 obligations: FOUND at lines 63, 292, 937
      (i) matched only the pages 2-3 measurement item, not a decision item.
- [x] **2026-09-15: nothing writes `snapshot_artist`, so orphan recovery
      cannot work.** VERIFIED 2026-09-15: one grep hit, the DDL in
      `Schema.pm::_migration_1`. `Match.pm::_recordMatch` writes
      `snapshot_album_title` and `snapshot_track_count` only. Decisions §15.5
      makes artist part of the fit predicate, so the identification step
      (step 4) must start writing it. Conflict rows still carry no snapshot
      (§15.4). Offline assertions to add: a clean hit writes all three
      snapshot columns; a conflict row's snapshot columns are NULL; the
      narrow delete still fires on a conflict row whose tags were removed.
      — done in step 4 commit 4. `_recordMatch` writes `snapshot_artist` from
      `$album->{artist}` in both the INSERT and the ON CONFLICT list;
      `_recordConflict` still names no snapshot column. All three assertions
      are in `match-check.pl`, plus one that a non-ASCII artist is stored
      byte-identical and one that an existing row's snapshots are carried
      through a conflict rather than lost.
- [ ] **2026-09-19: "Structural" wording survives outside plan §3's list.**
      There is no Structural tier (decisions §13.8, §14.3). Hits at step 4
      commit 4: strings.txt:68 (USER-VISIBLE — the token is "Required for
      Structural matching"; after step 5 the token serves the collection
      sync, so step 5 rewrites this string), Tags.pm:126, API.pm:4, :48,
      :266, tags-check.pl:114, title-agreement.pl:227, api-check.pl:388.
      Comment-only except strings.txt:68. Sweep in step 5's first commit.
      Also: Importer.pm _prePass uses `my $b` as a loop variable, which masks
      sort's $b in that scope — rename in the same commit.
- [ ] **2026-09-19: the orphan relink runs only in the importer, which runs
      only when tag names are configured** (`Importer.pm`'s `use` gate, kept
      by §15.8). A user with manual matches and no tag names gets no relink.
      INFERRED from reading. Step 8 must place the relink so manual-only
      users are covered, or record why not.
- [ ] **2026-09-19: the ambiguous orphan relink is a step-8 obligation.**
      Decisions §15.5 part 4 and §15.12 part 2: step 4 relinks only
      one-to-one fits. An orphan fitting several new albums, or a new album
      fitting several orphans, is left untouched and counted as unresolved
      in the importer's summary. Step 8's review queue must offer it,
      pre-filled with the previous answer (decisions §2). Until then those
      rows stay orphaned: no loss, no automatic relink.
- [ ] **2026-09-19: the artist snapshot is order-dependent for mixed-artist
      albums with no album artist.** VERIFIED at slimserver `a670a38`:
      `Slim::Schema::_createOrUpdateAlbum` sets `albums.contributor` per
      track from `_postCheckAttributes`'s primary contributor (`ALBUMARTIST`,
      else `ARTIST`, else `TRACKARTIST`, first entry), so the last track
      written wins. A rescan in a different order can change it; the snapshot
      then does not fit, which fails safe for a tagged album
      (identification recovers it) and loses a manual row's choice. Same
      shape as the retagged-title hole. Recorded, not solved — revisit if
      seen on hardware.
- [ ] **2026-09-19, STEP 8: the review-queue marker.** Decisions §15.13
      part 4: step 7 stores none. An ambiguous or artist-disagreeing album
      is `ownership = 'absent'` if tagged and has NO ROW if untagged, and
      the collection is discarded (§13.2), so step 8 cannot find these
      without stored state. Step 8 adds a nullable reason column
      (ambiguous | artist disagrees | artist absent | Various-gated) by
      `ADD COLUMN`, and the ownership pass writes it. `ADD COLUMN` with a
      CHECK needs no rebuild — OBSERVED on SQLite 3.45.1, and LMS bundles
      SQLite 3.46.1 (DBD::SQLite 1.76, perl 5.32–5.42 trees in
      `refs/slimserver/CPAN/arch`; VERIFIED 2026-09-20 by Claude Code, Phase
      0 of steps 6–7). Perl 5.20–5.30 trees carry 3.22.0. Step 7's pass
      already counts all four buckets in its summary, so the queue's size is
      known before it is built.
- [ ] **2026-09-19, STEP 8: decisions §13.5's all-tags read.** Moved out of
      step 7 by §15.13 part 7: its only product is a queue item. Runs as a
      Scheduler task (§15.2 obligation 2). Accepted gap until then: an owned,
      tagged album whose tracks 3..N carry a different release id can badge
      `exact`. Size still unmeasured (the 2026-09-15 item).
- [ ] **2026-09-19, STEP 8: an ownership-only row blocks a later relink.**
      `Importer::_prePass` treats any `discogs_match` row as "not a key
      miss", so once a sync has written an ownership-only row (NULL
      `match_tier`) on a new album, an orphan can no longer relink onto it.
      INFERRED from reading: reachable only when the relink did not happen
      at the scan that moved the files — an ambiguous fit, or a user with no
      tag names — since the pass runs after the scan. The ambiguous-relink
      work must delete that row first (§15.13 part 5's predicate), or
      `relinkOrphan`'s UPDATE hits the primary key and dies in the scanner.
- [ ] **2026-09-19, STEP 8: a conflict row with an incumbent id looks like a
      tagged candidate.** Both are `strict`, `candidate`, non-NULL release id
      (decisions §3a, §13.4). The ownership pass treats it as an
      identification and may promote it to `confirmed`. The queue's "Strict
      conflicts" entry (§13.10.5) has no way to select these rows today.
- [x] **2026-09-19, MEASURE BEFORE STEP 7 SHIPS: the auto-badge split under
      the step-7 rules.** Decisions §15.13 parts 2–3: artist source as
      measured, but artists at L2 rather than the script's L5. Re-run
      `scripts/title-agreement.pl` with an L2 artist rule on the reference
      `library.db` and the page-1 fixture — no token needed. Expected, not
      verified: only moves albums from badge to queue. Report; add no rule
      mid-run.
      **MEASURED 2026-09-20**, `scripts/title-agreement.pl --step7` on a
      scratch copy of the reference `library.db` (764 albums) and
      `scripts/fixtures/collection-page1.json`. The split is taken through
      `Ownership`'s own `_titleKey` / `_artistKey` / `_artistsAgree`, so it
      measures the shipped module rather than a re-implementation of it.
      `variousArtistsString` is unset in `server.prefs` (`~`), so the label
      used is the English `VARIOUSARTISTS` default, `Various Artists` — which
      is what `Slim::Music::Info::variousArtistString()` resolves to on this
      install.

      | | old (L5 artist) | step 7 (L2 + gate) |
      |---|---|---|
      | auto-badge | 87 | **79** |
      | Various-gated (§15.14) | — | **6** |
      | artist disagrees | 8 | **10** |
      | LMS artist absent | 0 | 0 |
      | Discogs artist absent | 0 | 0 |
      | several candidates | 1 | 1 |
      | total L2 title matches | 96 | 96 |

      **Nothing flagged.** All 8 albums that move, move badge → queue, which
      is the direction §15.13 part 3 inferred. None moves queue → badge. Of
      the 8: two are `Future Sound Of London` against Discogs' `The Future
      Sound Of London` (albums 3124, 3127) — L5 stripped the leading article,
      L2 does not, so these are two badges genuinely lost on the same record;
      six are §15.14's gate firing on `Various`/`Various` (albums 3345, 3347,
      3351, 3355, 3356, 3358). Of the 79 that still badge, 77 are exact
      string matches on both sides and the other two differ only by Discogs'
      ` (2)` disambiguator (`Oasis (2)`, `Snow (2)`) — read, and the same
      record in both cases. No auto-badge pairs two records that look
      different.

      Two corrections to the record, for the next design chat: §15.14 says
      "measured page 1 has no matched compilation, so nothing about this is
      measured either way" — it has six, and the gate costs six badges on
      page 1 alone. And the distinct-release-id index collapses zero
      duplicates on this fixture, so the artist rung accounts for the whole
      difference.
- [x] **2026-09-19, MEASURE: the ownership pass's run time** on the
      reference library. It runs synchronously in the server process over
      every album; INFERRED to be well under a second, not measured. If it is
      not, it needs the Scheduler shape `Settings.pm`'s detection uses.
      **MEASURED 2026-09-22 on 0.0.0.4**, from INFO timestamps between
      `_gotPage`'s "collection sync complete" and `_apply`'s summary, over
      764 albums and 203 collection items: **49.6 ms** with 503 writes
      (the first pass), **39.3 ms** and **39.5 ms** with zero writes. Three
      orders of magnitude inside the budget, so it does **not** need the
      Scheduler shape. Re-measure if the library grows by an order of
      magnitude.
- [ ] **2026-09-19: migration 3 obligation (g)'s EXPLAIN QUERY PLAN check has
      no query to check.** VERIFIED 2026-09-19 (design chat): nothing in
      `SqueezeWax/` queries through the orphan index — the relink loads every
      row and matches in Perl (`Match::snapshotRows`,
      `Importer::_prePass`), and the two statements naming
      `snapshot_track_count` are keyed on `album_key`. The index is rebuilt
      as (g) requires and the check is replaced by this finding (approved
      2026-09-19). Same defect shape as (d)/(g): an obligation written
      against a query that was never built as SQL. Revisit if a SQL lookup
      is ever added, or drop the index by its own ruling.

## Open design questions

- [x] **2026-09-13: v1's configurable tag names are promised twice and
      specified nowhere.** Design §11 lists "Configurable Discogs tag names"
      as v1 and cross-references "(§3, §9)"; §3 describes an ordered list of
      tag names being read; §9 has never carried a bullet for it, before or
      after the reconciliation. ~~A v1 setting with no specification of its
      default order, its UI, or which tags are in the default set.~~
      Surfaced by the post-reconciliation read: the rewritten §9 says
      "Which tag names are read is a setting (§3)", which points at the gap
      more directly than the old text did. Related and still open: whether a
      MASTER-ID tag is among them, which bounds design §3's flowchart node F.
      Settle both together — they are one question about the same list.
      2026-09-15, CORRECTED — the premise was false. Default and order are
      specified in decisions §3, invalidation in §3b, and all of it is built
      in step 3: pref `discogsTagNames`, default `[]` (`Tags.pm` file-scope
      init), user-set order, detection action (`Settings.pm` over
      `Tags::candidateKeys`). The residual is design text only: design
      carries none of it. Design-fix pass, not the build order. The
      master-id half is decisions §15.1.
- [ ] **2026-09-13: design §3's "Find on Spotify" backfill bullet is
      orphaned.** It says a successful manual "Find on Spotify" (§6) can
      retroactively backfill or promote the original scan-time match. Nothing
      in design explains how a Discogs-to-streaming cross-browse action would
      backfill a Discogs IDENTIFICATION — and under collection-first it is
      harder to see, since identification comes from a tag and ownership from
      the collection, neither of which a Spotify lookup touches. It was
      already unclear before decisions §13 and the reconciliation carried it
      verbatim rather than inventing a meaning for it. Either work out what it
      means and say so, or delete it.
- [ ] **2026-09-13: what does a `version`-ownership context menu offer beyond
      stating the fact?** A version picker promoting the choice to a manual
      match is the candidate, recorded in the reject/dismiss item as
      "refinement, not rejection" and never decided. Design §4 states what
      the menu says and stops there, because design does not specify
      mechanisms only a `TODO.md` note proposes.
- [ ] **2026-09-13, v2: should the sync retain the release id of the owned
      collection entry?** Decisions §14.10 rules NO for v1, so pressing
      details, credits and value are ABSENT from the context menu for an
      album owned by version alone — the majority case (87 of 96 auto-badged
      on the measured page). The data is in hand at the moment of the
      decision, in `basic_information.id`, and discarded one line later by
      §13.2. Rejected for v1 on three grounds, all in §14.10; none of them is
      that it would not work. **Revisit with wantlist**, which needs
      collection-entry data of its own and forces the same question about
      what a sync may keep. A later fix is a migration on `discogs_match`.
- [x] **2026-09-13, RESOLVED: one badge state, not two.** Decisions §13.8 left
      exact-versus-version open as a UI question; both design §3's and §4's
      flowcharts terminate in a node that cannot be drawn without it. Version
      ownership is the main path (§13.10.2), so two colours would teach a
      distinction that is almost always one value. Distinction shows in the
      badge context menu only. Revisit after the hardware pass. Decisions §14.5.
- [ ] **2026-09-13: define the minimum scope for on-demand marketplace
      lookup.** Marketplace lookup stays in v1 (decisions §1 item 10, §13.1,
      §14.3), but "at a minimum" was the instruction and design §7 currently
      specifies a compact summary line, an expandable full listing, and five
      user-configurable filter/sort axes in Settings. Design §7 is on the
      reconciliation survey's List 2 as surviving untouched, so the
      reconciliation session must NOT trim it. Its own session. Candidate cut:
      summary line plus link-out, no filters, filters to v2.
- [ ] **2026-09-13: does Discogs expose a per-release lookup of the caller's
      own collection entry?** UNVERIFIED — not checked against the API
      documentation, and decisions §9 does not cover it. Needed only if the
      badge context menu is ever to show date added, acquisition date or
      condition/grading; decisions §14.6 drops those from v1 precisely because
      the mechanism is unverified and §13.2 persists nothing. If the only route
      is paging the whole collection, the feature is a sync-shaped cost wearing
      a context-menu shape. Settle before collection value or statistics
      (v2/v3) are designed.
- [ ] 2026-09-12: examine the 8 artist disagreements individually. Eight
      unrelated cases are noise the queue absorbs; one repeated pattern is a
      data-format fact deserving a declared rule, like the Discogs ` (N)`
      strip. Undetermined. See decisions 13.10.6.
- [x] **2026-09-12, RESOLVED 2026-09-13: what `match_tier` value does a
      collection-derived match carry?** None. `match_tier` becomes NULLABLE,
      NULL meaning "no identification was made", and the CHECK narrows to
      `strict | manual`. A collection match establishes ownership, not
      identity, so there is no provenance to record; a fifth value would put
      an ownership fact in an identification column, which is what decisions
      §13.3 exists to prevent. Decided BEFORE migration 3 rather than at it,
      because design §3 and §10 could not be written around the hole. See
      decisions §14.1.
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
      2026-09-19: "step 6" is the 2026-09-07 numbering — the badge is now
      step 9. The premise is also stale: under decisions §13.10.3 a rip and
      a stream of one owned record BOTH badge (design §3 walkthrough 4), so
      "only the local row is badged" no longer happens. Re-check at step 9;
      likely closable.
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
- [x] **2026-09-07: `discogs_no_match` tier `'structural'` skip predicate.**
      Two-part, unlike Strict's one-part: `source_timestamp` unchanged AND
      `checked_at` within TTL. Proposed TTL 30 days as a pref — not
      TOU-constrained, a UX/freshness choice. The clear & rebuild decision is
      no longer blocking (decisions §10); its implementation is tracked in
      the step-4 build order (build-order-step-4-structural-matching.md §3
      item 9).
      2026-09-15, SUPERSEDED — Structural does not exist (§13.8), so there
      is no `'structural'` no-match row to expire and no TTL to set.
      Decisions §15.6 removes the value from the CHECK entirely. Closed by
      the build-order rewrite, not implemented.
- [x] **2026-09-07: §3b needs a `tier='structural'` invalidation clause
      keyed on the duration-margin pref** — §3b's own "Step 4 note" trigger
      has fired. The clear & rebuild decision is no longer blocking
      (decisions §10); its implementation is tracked in the step-4 build
      order (build-order-step-4-structural-matching.md §3 item 9).
      2026-09-15, SUPERSEDED — the duration margin pref it keys on belongs
      to Structural, which does not exist (§13.8). §3b's "a pref-derived
      tier needs its own clause" note still stands for any future tier; it
      has no v1 subject. Closed by the build-order rewrite, not implemented.
      NOTE: §3b's note now applies to `discogsMaxTier` instead, if that pref
      survives Q8.
      2026-09-19: moot — the pref is removed in step 4 commit 2.
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
- [x] **Step 4 must relax the `use` gate.** It is currently
      `scalar @{discogsTagNames}`, which would wrongly disable the importer for
      a user who wants Structural only — Structural needs no tag names. Becomes
      wrong the moment step 4 lands.
      2026-09-18, SUPERSEDED — decisions §15.8. The replacement gate existed
      to let a user with no tag names run Structural; Structural does not
      exist (§13.8). `scalar @{discogsTagNames}` is correct for tag-driven
      identification and is left alone. Closed by the build-order rewrite,
      not implemented.
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
- [ ] **2026-09-15: design-fix pass — wording defects recorded, not fixed,
      during the build-order rewrite.** The rewrite session was scoped away
      from design, so these wait for a bounded pass of their own
      (working-agreement §2 wants same-session fixes; the session brief
      overrode it deliberately).
      (a) Design §3, node F: "from a configured master tag". None exists —
          decisions §15.1.
      (b) Design §5: "Each page is matched against LMS albums in memory, the
          conclusion is written to the ownership column". Per-page writes
          break decisions §13.7 (recompute only from a completed sync) and
          §13.10.3 ("exactly one collection entry" needs the whole
          collection). The pass needs a whole-sync in-memory index, no writes
          until the last page, discarded after. INFERRED from reading.
      (c) Design's wording of the sync's scan trigger, if it places it at
          scan start: decisions §15.2 moves it to scan completion, in the
          server. Locations: design §3.
      (d) Design carries none of decisions §3's tag-name specification (see
          the ticked tag-names item).
      (e) Design §10: the `snapshot_*` comment says "captured at confirm
          time". Decisions §15.4 puts capture at identification, which is
          where the code has always put it; confirm time is now a different
          moment in a different process (§15.2, §15.3).
      (f) Design §10 lists `snapshot_total_duration`; decisions §15.5 drops
          it in migration 3. Design §10's snapshot comment also still names
          four columns.
      (g) Design §10's orphan index is `(state, snapshot_track_count)`;
          decisions §15.5 keys recovery on having an identification, and
          migration 3 rebuilds the index accordingly (obligation (g)).
      (h) Design §3's artist gate says nothing about the `Various`
          equivalence decided in §15.7 — check that when the design-fix pass
          runs. The other half of this item is ANSWERED and needs no pass:
          design §9 does NOT carry the tier selector, because the
          reconciliation deleted it. That is precisely why decisions §15.8
          rules the pref out of the code rather than out of design.
- [x] **2026-09-15: detection likely offers a bare master id as a RELEASE
      candidate.** `Tags::candidateKeys` corroborates a bare integer when the
      key matches `/DISCOG/i`, and bare digits parse through
      `_parseReleaseId`, so `DISCOGS_MASTER_ID=999` would be listed as a
      corroborated release-id key. A user who ticks it alone stores master ids
      as release ids. INFERRED from reading, untested — `tags-check.pl`
      covers only the master-URL form. Step-3 code; schedule in the build
      order. — fixed in step 4 commit 1 (decisions §15.12 part 4)
- [ ] **2026-09-15, recorded not acted on: `API.pm`'s synchronous `get` has no
      v1 caller** once Structural is gone and the sync is server-side
      (decisions §15.2). Keep it, or record why it stays, when the sync step
      is planned.
- [x] **2026-09-15: orphan recovery's reach shrinks under decisions §13.4, and
      it can lose user work.** Recovery selects `state = 'confirmed'`
      (§14.8, inferred from the predicate; the index is commented "confirmed
      rows whose snapshot might fit a new album" in
      `Schema.pm::_migration_1`). ~~Under §13.4 only OWNED albums reach
      `confirmed`, so two classes now sit permanently outside recovery: a
      tagged-but-unowned album, and — the one that matters — **a MANUAL match
      on an unowned album**, which is work the user typed.~~ When `album_key`
      changes (files moved, retagged, library rebuilt) those rows orphan with
      no relink path and the manual choice is gone, silently.
      Recovery may need to key on "has an identification"
      (`match_tier IS NOT NULL`) rather than on `state`, or `manual` rows may
      need their own clause. This is a consequence of §13.4 that predates the
      build-order rewrite and was never followed through. Recovery is not yet
      built (see Q7), so deciding it now costs nothing but a ruling. Blocks
      the review-queue/manual-re-match step.
      2026-09-15, CORRECTED AND RESOLVED — decisions §15.5. The struck claim
      was wrong: design §3 says confirming a manual link writes
      `match_tier = 'manual'` and `state = 'confirmed'`, and a manual link is
      explicitly exempt from the collection cross-check that governs Strict.
      So manual rows DO reach `confirmed` and were never outside a
      `state`-keyed predicate. What was right: `state` is the wrong key.
      Conflict-demoted rows keep an adjudicated id and their snapshots (§3a)
      while sitting at `candidate`, and they are the rows whose tags can no
      longer reproduce their identification. §15.5 keys reach on having an
      identification instead.
- [ ] **2026-09-15: a retagged album title defeats orphan recovery, and a
      manual row's work is lost.** Decisions §15.5's predicate is exact
      equality on artist, album title and track count. Change the title tag
      and nothing fits, so the row stays orphaned — for a tagged album
      identification re-derives the match anyway, but a MANUAL row's choice
      is gone with no notice. Recorded rather than solved: two-of-three
      matching and normalised comparison both trade a fail-safe predicate for
      a guess. Revisit if it happens on hardware.
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

## Waiting — needs a real server

- [x] **2026-09-20: build-order steps 6-7's hardware checks (migration 3 and
      the ownership pass).** Plan
      `plans/build-order-step-6-7-ownership.md` §5. Code complete and
      offline-verified (`schema-check.pl` 110 assertions, `ownership-check.pl`
      96, `match-check.pl` 153, `sync-check.pl` 104); none of these can be
      checked without a real server, a real library and a real Discogs
      account.
      (1) **Upgrade.** `user_version` goes 2 → 3; the row count equals Phase
          0's figure of 481; no row's `state` changed; `discogs_collection`
          is gone; the log shows rows copied and the per-state counts.
      (2) **First sync.** Requests = pages + 1. `discogsLastSynced` advances
          only after the pass logs its summary. Report
          exact/version/gated/ambiguous against §13.10's page-1 figures —
          they will not match exactly, because the rules differ per §15.13
          parts 2-3 and the full collection is 203 items, not 100.
          **EXPECT A LARGE DEMOTION HERE.** Phase 0 found all 478 strict rows
          `confirmed`, written by step 3 before §13.4. Every one whose
          release is not in the collection drops to `candidate`, which could
          be most of them. That is §13.4/§15.3 working as designed and it
          closes §15.3's accepted window. Record the promoted and demoted
          counts. Check (1)'s "no state changed" applies to the UPGRADE only.
      (3) **Second sync, nothing changed:** zero writes. This is §13.2's
          determinism on real data; the offline suite asserts it on fixtures.
      (4) **Start a scan mid-sync:** the pass is `refused`, the log says so at
          info, and the next rescan-done brings a sync that applies. Inherits
          step 5's checks (d) and (e).
      (5) **An untagged local album that is owned:** an ownership-only row
          appears, and the next scan logs NO invariant-1 error. This is the
          one that would catch §15.13 part 6 being wrong.
      (6) **Remove a record from the Discogs collection:** after a sync its
          ownership-only row is deleted, and a tagged row goes to `absent` /
          `candidate` while keeping its release id.

      **RUN 2026-09-22 on 0.0.0.4.** All six pass. Evidence below; the
      backups are `/home/denny/squeezewax-backups/2026-09-20-pre-step-6-7`
      (pre-migration) and `.../2026-09-22-pre-hardware-checks` (pre-checks,
      plus a `-pre-collection-change` pair taken before check 6).
      (1) **PASS**, observed 2026-09-20, re-verified 2026-09-22.
          `user_version` 3; the migration logged `481 rows copied ... by
          state: candidate=2, confirmed=479`, which equals the Phase 0
          baseline exactly, so no state changed at the upgrade; a row-level
          diff of tier/release id/snapshot against
          `BASELINE-discogs_match.csv` is 0 lost, 0 added, 0 changed;
          `discogs_collection` and its index are absent from `sqlite_master`;
          `discogs_no_match` carries `CHECK (tier IN ('strict'))`;
          `discogs_match_orphan` is rebuilt on `(match_tier,
          snapshot_track_count)` per obligation (g); the log carries all four
          migration lines.
      (2) **PASS**, observed 2026-09-20/22, re-verified. 203 items over 4
          requests = 3 pages + 1 identity. `discogsLastSynced` advances only
          after the pass: `Async.pm:570` sets it strictly after
          `Ownership->apply` at `:561`, and check 4 below proves the negative
          case. Split: exact=149 version=50 gated=0 ambiguous=5
          artist-disagree=2 artist-absent=0 undecodable=0; inserted=26
          updated=477 deleted=0 promoted=0 **demoted=327**. The demotion is
          confirmed by query: exactly 327 rows moved `confirmed` ->
          `candidate`, 154 unchanged, 481 total. `gated=0` against the page-1
          measurement's 6 is NOT a discrepancy - the script measures the
          title route over every album, while the pass reaches node H only
          for albums no tag resolved first, and all six of those compilations
          are tagged.
      (3) **PASS**. Sync driven through the settings form's own `syncNow`
          button (`POST /plugins/SqueezeWax/settings.html`;
          `csrfProtectionLevel` is 0, so `CSRF.pm:179` admits it). Log:
          `inserted=0 updated=0 deleted=0 promoted=0 demoted=0`, and a full
          `SELECT *` diff of `discogs_match` before and after is byte
          identical.
      (4) **PASS**, both halves. Sync started 12:44:34.86; rescan fired
          12:44:35.56 via `["rescan"]` (`Request.pm:607`); fetch finished
          12:44:37.1155; 1.1 ms later `Match::_writeOk` logged *refusing to
          write to squeezewax.db: a scan is running* and Settings reported
          *ownership pass declined*. `discogsLastSynced` did NOT advance and
          `discogsLastSyncError` read `refused`. Then `_rescanDone` at
          12:45:11.81 scheduled a sync that fired at 12:46:11.31 (the 60 s
          `DEBOUNCE_AFTER_RESCAN`) and applied - timestamp advanced to
          12:46:13, error cleared.
      (5) **PASS**, and not vacuous. The check-4 rescan repopulated
          `discogs_no_match` to exactly 100 strict rows (migration 3 had
          emptied it per obligation (h)). Exactly two albums then carried a
          row in BOTH tables at once - 3204 *Here Comes The Night* and 3233
          *Route 66*, each NULL `match_tier`, NULL `state`,
          `ownership = 'version'` in `discogs_match` and `strict` in
          `discogs_no_match` - and the scan logged no invariant-1 error.
          **This is the check that would have caught §15.13 part 6 being
          wrong. It did not.**
      (6) **PASS — offline first, then ON HARDWARE 2026-09-22 at 0.0.0.6.**
          The owner declined to
          alter a real Discogs collection, which is a reasonable refusal: the
          designed check mutates data this project does not own and cannot
          restore if a step fails. Run instead against COPIES of the live
          `squeezewax.db` (507 rows) and `library.db` (764 albums), driving
          the real `Ownership->apply` and the real `Library::eachAlbum` /
          `ownershipArtists`, with the committed page-1 fixture as the
          collection. Three sequential passes on one database, which is how
          the real thing behaves since every sync re-derives everything:
          A = full fixture, B = fixture minus releases 9701013 (*Route 66*,
          Nat King Cole) and 443973 (*Jagged Little Pill*, Alanis
          Morissette), C = full fixture again. Albums whose owned release is
          not on page 1 conclude `absent` in all three passes and cancel out,
          so the two removals are the only variable.
          A -> B differs in **exactly two rows**: album 3233's ownership-only
          row is **DELETED** (§15.13 part 5's permitted deletion), and album
          2898 goes `confirmed` -> `candidate` and `exact` -> `absent`
          **while keeping release id 443973**. A -> C is **empty**: adding
          them back restores both rows exactly.
          What this does NOT prove, and why the hardware check stays open:
          the sync handing the pass a genuinely changed list, the live write
          path in the server process, and Discogs itself.
          **Then proved on hardware**, without touching the collection, using
          `discogsTestExcludeReleases` (0.0.0.6). With the filter set to
          `9701013,443973` a real sync fetched the real collection — 203 items
          over 4 requests, the unfiltered count — logged `test filter active:
          hiding 2 releases from the ownership pass` at warn, and wrote
          `updated=1 deleted=1 demoted=1`. The diff against a copy taken
          beforehand is **exactly two rows**: album 3233's ownership-only row
          deleted, and album 2898 `confirmed` -> `candidate`,
          `exact` -> `absent`, keeping release id 443973, its snapshot
          (`Alanis Morissette`, 13 tracks) and its `source_timestamp`.
          Clearing the pref and syncing again restored the table
          **byte-identical** to the copy (`inserted=1 promoted=1`). This is
          what the harness could not prove: the real fetch handing a changed
          list to the pass, and the live write path in the server process.
      **Live data was never written by any check.** `discogs_match` is
      identical across checks 3, 4, 5, (d) and 6, and identical to the
      `-pre-collection-change` backup: 507 rows, 100 no-match rows,
      `user_version` 3 throughout.
- [ ] **2026-09-19: build-order step 5's hardware checks (collection sync).** PARTLY DONE — (a) (b) (d) (e) pass; (c) not observed.
      Plan `plans/build-order-step-5-collection-sync.md` §3. Code complete and
      offline-verified; none of these can be checked without a real server and
      a real Discogs account.
      (a) A sync produces exactly `ceil(items/100) + 1` requests — the pages
          plus the `/oauth/identity` lookup — and `discogsLastSynced` advances.
          `discogs_match` row count unchanged before and after. The offline
          suite asserts the arithmetic and the request sequence against a stub
          transport (`scripts/sync-check.pl`, 67 assertions); what it cannot
          assert is that the real transport issues them.
      (b) The manual button, the interval timer and a rescan's
          `['rescan','done']` do not start overlapping syncs. Exercise the
          guard, or say explicitly that it simply was not hit in practice.
      (c) A revoked token produces the `error`-level log line and
          `discogsLastSynced` stops advancing; a simulated transient failure
          (kill the network mid-sync) produces `warn` and leaves prior state
          untouched.
      (d) The existing "abort a scan mid-run" check below becomes load-bearing
          for the first time here — decisions §15.2 obligation 1 rests on an
          inference from `SQLiteHelper`'s `_notifyFromScanner` exit branch that
          has never been observed. Run it: abort an external scan mid-run,
          confirm a second `['rescan','done']` arrives, and confirm a pending
          sync then completes.
      (e) Not covered offline at all, and the reason (a)-(d) are here: nothing
          in `scripts/sync-check.pl` touches a real event loop. Both its stubs
          are synchronous — a stubbed request calls back before `->get`
          returns, a stubbed timer fires before `setTimer` returns. The real
          `Slim::Utils::Timers` / `SimpleAsyncHTTP` interaction is unproven.

      **PARTLY RUN 2026-09-22 on 0.0.0.4**, alongside the steps 6-7 checks.
      (a) **PASS.** 203 items over 4 requests = `ceil(203/100) + 1`, on four
          separate syncs. `discogsLastSynced` advances on each that applies.
          `discogs_match` row count unchanged at 507 before and after.
      (b) **PASS for the rescan-done trigger**, via (d) below: three
          `_rescanDone` events in 2.7 s produced exactly ONE sync, because
          `_scheduleSync` kills any armed timer before arming the next
          (`Plugin.pm:159-160`). The manual button against the interval timer
          was not hit in practice and stays unproven - the interval is 24 h.
      (c) **PARTLY OBSERVED 2026-09-22 at 0.0.0.6, and it FOUND A DEFECT.**
          The owner pasted a deliberately wrong token and synced. State
          protection passes: `discogsLastSynced` stayed at the last
          successful sync and `discogs_match` was byte-identical to a
          507-row snapshot. **The error vocabulary does not:** the failure
          came out as `no_response`, logged at **warn**, and the
          `Discogs rejected the token` line appears nowhere in the log. See
          the `unauthorized`-is-unreachable item above. Killing the network
          mid-sync is still NOT OBSERVED.
      (d) **PASS — and this is the one that was load-bearing.** §15.2
          obligation 1 rested on an INFERENCE from `SQLiteHelper`'s
          `_notifyFromScanner` exit branch that had never been observed. It
          is now observed: a full rescan started 12:46:49, `abortscan`
          (`Request.pm:474`) issued at 12:46:57 while `rescan ?` still
          reported 1. `_rescanDone` fired immediately at 12:46:57.7134, then
          twice more at 12:47:00.0579 and .3963 as the scanner exited. One
          sync was scheduled, fired at 12:48:00.3555 (60 s after the last
          notification) and applied. **The inference holds.**
      (e) **PASS by implication.** Every observation above ran through the
          real `Slim::Utils::Timers` and `SimpleAsyncHTTP`: the 300 s
          first-poll timer fired on its own at 12:30:33, the 60 s debounce
          fired twice to the second, and four real HTTP syncs completed. The
          stub-only gap this item names is closed for the paths exercised.

- [ ] **2026-09-19: prove the `discogsMaxTier` removal on a real prefs file.**
      Check 1 could not, because this server's `squeezewax.prefs` never had the
      key (it predates the pref). Stop LMS, put `discogsMaxTier: 2` and
      `_ts_discogsMaxTier: 1` and `_version: 0` into a copy of the file, start,
      and confirm both keys are gone and `_version` is 1. Read but not observed:
      `Namespace.pm:355-377`, `Base.pm:242-258`.
- [ ] **2026-09-19: the pre-step-4 rows with a NULL `source_timestamp` are
      re-examined once, and a `confirmed` one is demoted to `candidate`.**
      Observed after `Amorph` was removed from the local folder: two old
      "Isolar" rows (`state = 'confirmed'`, NULL `source_timestamp`) became
      current again, were examined, and came out `candidate` with a timestamp
      and `snapshot_artist`. This is §15.3's accepted consequence, recorded
      because it is the first time it was seen on real rows.
- [ ] **2026-09-19: `unrelinked orphans` is the absolute count, not a per-scan
      figure.** It is 3 on the reference server after the test data was removed,
      all three identified by recomputing every current `album_key` from
      `library.db` and diffing against `discogs_match` (481 rows, 764 current
      albums): the manual row for Isolar (release 888888, 18 tracks) and the
      strict row for "Isolar: Unidentified Explorers" (999999, 12 tracks) —
      both taken when the local `Amorph` folder joined the NAS copy — and the
      strict row for "ZZ SqueezeWax Test v2" (77777, 12 tracks, album 3633 no
      longer exists) — its local folder was deleted. All three are pre-existing
      rows from 6–7 Sep with fake release ids, not check 6's row; check 6's
      three rows were deleted with the other test data. Nothing sweeps orphans
      in v1 (§2a invariant 4); make sure the step 8 review queue shows them
      rather than growing them silently.
- [ ] **2026-09-19: test albums for future hardware checks.** The local
      `Music/` folder is now empty. A repeatable setup is documented by
      what worked here: copy albums off the read-only NAS with `cp`, retag the
      album title with mutagen so LMS does not join them to the originals, keep
      the release-id tag, and rescan with the JSON-RPC `rescan` command (the
      changes-rescan; `rescan album|track` runs in-process and skips our
      importer, `Commands.pm:2676-2790`). `scanner.log` is rewritten per scan.

- [x] **2026-09-19: step 4 commit 5, plan §6 check 3.** "After the first scan
      on commit 5, count rows with a non-NULL `snapshot_track_count` and a
      NULL `snapshot_artist`: expect zero among rows whose album is current."
      **Done 2026-09-19 on 0.0.0.2 (package-build 835920a).** First scan on the
      new code, changes-rescan: BEFORE 481 rows with a snapshot and 0 with
      `snapshot_artist`; AFTER 479 with it, `backfilled 479`, `unrelinked
      orphans 2` (479 + 2 = 481). The two without are stale "Isolar" rows whose
      album grew from 9/6 to 18/12 tracks when the NAS copy joined the local one
      (inferred at the time from the track counts and the newer rows; later observed:
      when the local `Amorph` folder was removed, those two keys became current
      again and were re-examined). Every
      other column of all 481 rows was identical to the pre-scan copy. 44 rows
      hold non-ASCII artists, stored as single-encoded UTF-8 bytes.
- [x] **2026-09-19: step 4 commit 5, plan §6 check 4.** "Move one tagged
      album's folder, rescan: its row is relinked (new `album_key`, same
      release id), no `discogs_no_match` row appears for it, and the summary
      counts one relink."
      **Done 2026-09-19.** Folder renamed with `mv` (mtime unchanged), changes-
      rescan: `examined 0, … relinked 1, unrelinked orphans 2`. Same release id,
      tier, state, `matched_at`, `source_timestamp` and snapshot; new
      `album_key` and `lms_album_id`. Row counts (`discogs_match` / `discogs_no_match`)
      were 483 / 101 immediately before this scan (copy taken right after the
      scan that first identified the two test albums) and 483 / 101 after, so no
      row was added and no `discogs_no_match` row appeared. The 481 → 483 seen
      since check 3 came from two earlier scans: the untagged test album (+1
      `discogs_no_match`, 100 → 101, `no tag 1`), then the tagged test albums
      first matched (+2 `discogs_match`, 481 → 483, `identified 2`).
- [x] **2026-09-19: step 4 commit 5, plan §6 check 5.** "The same with a
      **manual** row. None exist until step 8, so insert one with `sqlite3`
      on a copy of `squeezewax.db`." Plan §6 check 7 asks for checks 4 and 5
      repeated with a non-ASCII artist name; do that at the same time, since
      the byte-level comparison is only proven offline.
      **Done 2026-09-19, checks 5 and 7 both.** A row hand-set to `manual`
      (ASCII artist) and one with a non-ASCII artist (`Blüchel & Von Deylen`,
      bytes `42 C3 BC 63…` identical before and after) were relinked in one scan:
      `relinked 2`, both still `manual`. The non-ASCII artist also relinked as
      `strict` (check 7 part 1). The db edit needed
      `sudo -u squeezeboxserver sqlite3` because `squeezewax.db` is owned by the
      server user. The test rows were deleted afterwards.
- [x] **2026-09-19: step 4 commit 5, plan §6 check 6.** "Copy one album folder
      so that two new albums fit a single orphan: neither is relinked, and the
      summary counts it unresolved."
      **Done 2026-09-19.** `mv` plus `cp -a` gave two separate LMS albums (no
      DISC tag, so the same-folder rule in `Slim/Schema.pm` keeps them apart):
      `relinked 0, unrelinked orphans 3` (baseline 2). The original row was
      untouched. Note the two new albums each got fresh rows from their tags in
      the same scan, so the orphan stays an orphan.
- [x] **2026-09-19: time the pre-pass on the reference library, and time the
      FIRST post-upgrade scan specifically.** It adds a second full walk over
      `tracks` before the main loop. The first scan after this ships is the
      expensive one: every row identified before step 4 has a NULL
      `snapshot_artist`, so that scan backfills all of them — hundreds or
      thousands of UPDATEs, not a handful. Later scans backfill nothing.
      **The pre-pass cannot be aborted.** VERIFIED by reading, not observed:
      `$progress->update` is the entire abort mechanism in the scanner — it
      reaches `Slim::Utils::SQLiteHelper::updateProgress`, which POSTs to the
      server and calls `exit` when the answer matches `/abort/`
      (`Slim/Utils/SQLiteHelper.pm:443-458`, called from
      `Slim/Utils/Progress.pm:244`) — and the pre-pass makes no such call.
      Deliberately not worked around with synthetic `update` calls. If the
      measurement comes back long, that is its own decision.
      **Measured 2026-09-19:** the whole importer took 0.093 s on the first
      scan (765 albums, 8,693 file tracks, 479 UPDATEs); 0.08 s on every later
      scan. The scan's ~4 minutes were ContributorPictureScan (199 s), not ours.
      The "cannot be aborted" property is real but costs nothing at this size.
      Re-measure only if the library grows by an order of magnitude.
- [x] **2026-09-19: step 4 commit 4 — a rescan of a healthy library shows no
      "check the configured tag names" warning, and the summary reads
      "identified N".** Plan §6 check 2. The warning's condition is now
      `$count{identified} == 0 && !hasAnyStrictMatch`, and
      `hasAnyStrictMatch` no longer reads `state`. Offline coverage proves
      the predicate; only a real library proves the warning stays quiet.
      **Done 2026-09-19.** The first scan (`examined 0`) could not exercise the
      warning, so a proper case was built: one untagged album added to a library
      with strict matches gave `examined 1, identified 0, no tag 1` logged at
      INFO with no "check the configured tag names" line, which is the case the
      old `state = 'confirmed'` predicate would have warned on. Summary reads
      "identified N" throughout.
- [ ] **2026-09-13: the pages 2–3 measurement is now also the revisit trigger
      for two decisions.** Already recorded above as its own item; noting the
      dependants so they are not missed. Decisions §14.4 (no recovery path for
      a wrong version badge) rests on zero wrong badges measured at L2 on page
      1, and §13.10.6's generic-title hazard is the shape that would falsify
      it. Any wrong badge on pages 2–3 reopens §14.4.
- [ ] **2026-09-13: confirm the badge's single-state rendering after the
      hardware pass.** Decisions §14.5 chose one badge on the reasoning that
      version ownership is the common case. If the hardware pass shows exact
      ownership is the common case instead, the trade-off inverts. Data
      supports either (§13.8); no schema consequence.
- [ ] **2026-09-13: observe a complete collection sync end to end.** Design
      §13's budget says a 203-item collection is 3 requests. The per-page
      mechanics are VERIFIED (decisions §9.4) and `ceil(203 / 100) = 3` is
      ARITHMETIC — but a full three-request sync has NOT been run; the
      title-agreement measurement worked from page 1 only. Design is worded
      as the arithmetic it is rather than as "measured 3". The pages 2–3
      measurement will produce a full sync anyway; record the observed count
      when it does.
- [ ] 2026-09-12: measure collection pages 2 and 3. Page 1 is 100 of 203
      items, sorted by label, not a random sample. Decisions 13.10.6 carries
      the Various / Various Artists vocabulary risk as UNRESOLVED, not
      absent: it measured zero on page 1 only because no compilation matched
      there, and there are 95 LMS compilations. Pages 2-3 could move the
      auto-badge rate materially. Needs a token and a live sync.
      2026-09-15, SCOPE ADDED — decisions §15.7 gates compilation
      auto-badging on this measurement. Four questions it must answer, all
      answerable from the same fixture plus pages 2 and 3, at no extra
      request cost:
      (i)   how many LMS albums match a collection entry at L2 with artist
            agreement reached only through the `Various` equivalence —
            counted separately from `compilation = 1`, which §11.3(c)
            measured as unreliable (corrected 2026-09-19, §15.11). Page 1
            measured ZERO compilations matching, so §15.7's premise that most
            matched compilations would queue is a projection;
      (ii)  whether any two collection entries, or a collection entry and a
            DIFFERENT LMS album, share a normalised compilation title —
            this is the wrong-badge exposure §15.7 accepts;
      (iii) for each matched compilation, whether `albums.year` equals the
            Discogs `basic_information.year` — is year usable as a
            confirmation test at all (Q9);
      (iv)  whether `albums.label` is populated on the reference server, and
            whether the files carry a LABEL or ORGANIZATION tag. VERIFIED in
            slimserver `a670a38c2b14` that nothing in 9.1 writes the column;
            (iv) checks that empirically and asks what a file read would
            cost to get it (Q9).
      (v)   Count the albums that actually reach the title route (node H): no
            identification, or a strict identification not resolved at node D
            or F. The gate governs only those; (i)-(ii) over every album
            measure the title route, not the gate (decisions §15.14
            correction, 2026-09-22). Needs a copy of squeezewax.db beside
            library.db.
      Add no rule mid-run: report the numbers, decide afterwards. That is
      the same trap warning this measurement's first run honoured over the
      `Various` equivalence itself.
- [ ] **2026-09-11: measure how many of the ~~764~~ — corrected 2026-09-12:
      765 — reference albums have any local track with secs IS NULL.** Feeds
      the review-queue sizing item below; the §12.2 rule is correct at any
      frequency, only its cost varies.
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
      captured and the ~~764~~ — corrected 2026-09-12: 765 — album reference
      library is on hand. Do this BEFORE the build order is rewritten.
      Recorded as §13.9's largest unmeasured assumption.
- [ ] **2026-09-12: what proportion of the ~~764~~ — corrected 2026-09-12:
      765 — reference albums match the collection at all?** Every cost
      estimate in §13.5 and §13.6 rests on "a few hundred", which is the
      collection's size, not the measured overlap.
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
- [ ] **2026-09-15, NEEDS A REAL SERVER: node F's reach.** Custom tags are not
      in `library.db` (decisions §3), so count from files: albums with a clean
      release tag AND a master key (`Tags.pm` `@MASTER_KEYS`) AND release id
      not in the collection AND master in the collection; of those, how many
      node H would NOT badge. Decisions §15.1's revisit trigger.
- [ ] **2026-09-15, NEEDS A REAL SERVER: abort a scan mid-run** and confirm a
      second `['rescan','done']` arrives after the scanner exits, and that a
      pending ownership pass then completes. Decisions §15.2 obligation 1
      rests on this; inferred from `_notifyFromScanner`'s `exit` branch,
      not observed.
- [ ] **2026-09-19, NEEDS A REAL SERVER: step 4 commit 2's pref migration.**
      After upgrading, `squeezewax.prefs` no longer carries `discogsMaxTier`
      and `_version` is 1; the settings page has no tier selector. Plan §6
      check 1.
      **PARTIAL 2026-09-19, left open.** Proven: `_version` went 0 to 1 (BEFORE
      copy `_version: 0`, live file after the 0.0.0.2 install `_version: 1`),
      and the settings page (`GET /plugins/SqueezeWax/settings.html`) has no
      tier selector (0 matches for "tier"; token and tag-name fields render).
      NOT PROVEN: that the migration removes `discogsMaxTier` and
      `_ts_discogsMaxTier` — the live prefs file never contained either key, so
      the removal code did not run on anything. Closed by the separate item
      "prove the `discogsMaxTier` removal on a real prefs file" above.

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

- [ ] **2026-09-19: `decisions §9.4` / `design §9` state a documented default
      for the collection listing that the documentation does not state.** Both
      say the endpoint "defaults to `sort=label&sort_order=asc`". The API
      documentation states no default for this endpoint at all — the figure is
      an observation from this repo's own fixture,
      `scripts/fixtures/collection-page1.json`, whose `pagination.urls.next`
      carries those two parameters. The hazard §9.4 draws from it is real and
      unaffected; the provenance is what is wrong, and a decision record that
      presents an observation as documentation is the kind of thing a later
      session will build on. Design-chat's to fix, not Claude Code's.
      Read 2026-09-19 from the Wayback snapshot `20251226151912` of
      `discogs.com/developers` (the live page is behind a Cloudflare
      interstitial and returns 403 to any non-browser client).
- [ ] **2026-09-19: the Discogs collection-listing pagination read, recorded so
      it is not re-derived.** Same source as above, section "Collection Items
      By Folder".
      - `page` and `per_page` confirmed, "up to 100" confirmed as the
        documented maximum. This is what `ceil(items/100)` rests on.
      - Valid `sort` keys, complete: `label`, `artist`, `title`, `catno`,
        `format`, `rating`, `added`, `year`. `sort_order` is `asc` or `desc`.
      - **There is no id-based sort key** — neither `id` nor `instance_id` is
        offered — so no sort Discogs provides is guaranteed unique, and §9.4's
        "pin an explicit stable sort" cannot be satisfied outright. Decided:
        pin `sort=added&sort_order=asc`. Every other key but `rating` is
        release metadata any contributor can edit mid-sync and `rating` is
        user-mutable, while the time an instance entered a collection is not
        editable at all. Residual risk, documented rather than dropped: a bulk
        add gives many instances the same timestamp and ties may reorder
        between requests. Near-theoretical for step 5, which reports only a
        count; load-bearing for step 7, which consumes the rows.
      - Nothing is documented about pagination stability or snapshot
        consistency. There is no cursor.
- [ ] **2026-09-19: `discogsSyncInterval`'s 86400s (24h) default is a product
      call, not a sourced figure.** Made in step 5's plan; no prior decision
      sets one, and nothing measured it. The 3600s floor on the field is
      likewise a judgement call, as are `DELAY_FIRST_SYNC` (300) and
      `DEBOUNCE_AFTER_RESCAN` (60) in `Plugin.pm`. Recorded so a later reader
      does not mistake any of the four for measured or specified.
- [ ] **2026-09-19: a shared `['rescan','done']` debounce helper, if a third
      caller ever appears.** Step 5 built one in `Plugin.pm` (`_scheduleSync`,
      kill-then-arm). The `lms_album_id` refresh hook found in build-order
      step 2 still needs its own `['rescan','done']` subscription and is still
      unbuilt; when it lands, the two debounces could be one helper. Flagged as
      scope creep and deliberately not done in step 5 — two callers is not yet
      a pattern.

- [ ] **2026-09-13: grep design for definite references to a resolved
      pressing.** Two findings this session — the token-revocation
      degradation path and the empty `version` context menu — have the same
      shape: decisions §13 removed a guarantee and the places relying on it
      went on reading as though it held. A survey hunting CONTRADICTIONS
      cannot find these, because nothing contradicts anything; a promise
      simply became unreachable. If a third exists it is somewhere design
      says "the release" or "the pressing" without asking whether one is
      known. Check each against the version case. Cheap, and it is the one
      defect class the reconciliation's method is structurally bad at
      catching.
- [ ] **2026-09-13: four stale passages left unswept by the reconciliation,
      because the survey did not flag them.** Recorded rather than fixed, to
      keep List 2 binding — rewriting unflagged prose because it reads oddly
      beside rewritten prose is the drift that list prevents. Listed in the
      order I would fix them:
      (AC) design §9's Authentication bullet — "required for
           Collection/Wantlist features" understates the dependency: under
           collection-first there are no badges at all without a token, not
           a reduced feature set. MATERIALLY MISLEADING, one line, the
           strongest candidate.
      (Z)  design §3's closing Constraints block — references "the tier
           system" (removed, decisions §13.8) and says large-library scans
           "must be batched/throttled" (matching now issues no requests at
           all, decisions §13.1). Wrong twice over.
      (AB) design §4's artist-level badge — "off by default to avoid the
           extra API calls". There are none, and the reason is stronger than
           first recorded: artist ownership is a LOCAL JOIN over the already
           written ownership column, not a cheap API call. No Discogs request
           of any kind is involved. The default may still be right for other
           reasons — a per-artist badge is visual noise some users will not
           want — but the stated justification is simply false.
      (AD) design §9's Badge section lists wantlist settings among v1
           settings without the v2 scoping design §4 now carries.
- [ ] **2026-09-13: which SQLite version ships in the DBD::SQLite under
      `refs/`?** UNVERIFIED — not checked. It did not change the §14.1
      decision, since the CHECK forces a table rebuild whatever `ALTER COLUMN`
      supports, but it will matter the next time a schema change looks cheap.
      One grep by Claude Code.
- [ ] **2026-09-13: `sqlite.org/lang_altertable.html`'s prose and its syntax
      diagram disagree.** The diagram shows `ADD CONSTRAINT <name> CHECK
      (expr)` and `DROP CONSTRAINT <name>`; the prose never mentions either and
      that page's §8 list of supported changes omits both. The diagram looks
      newer than the text. Recorded because a future reader hitting the diagram
      will conclude a CHECK can be altered in place. It could not have helped
      §14.1 regardless: our CHECK is inline and unnamed, so there is nothing to
      `DROP CONSTRAINT`, and CHECKs combine conjunctively so adding one narrows
      rather than widens.
- [ ] 2026-09-12: decisions §13 and §13.10 were written into
      docs/squeezewax-v1-decisions.md, which working-agreement §2 defines as
      reasoning and evidence rather than live spec. The spec change went into
      the reasoning file, across several sessions, and nothing caught it until
      the design doc was surveyed. Recorded so the pattern is visible: a
      decision that changes WHAT the plugin does belongs in design, with
      decisions carrying WHY. Worth a line in working-agreement §7.4, which
      currently lists decision records as a design-chat output without saying
      that a scope change also needs a design edit.
- [ ] 2026-09-12: two defects in docs/squeezewax-design.md found during the §13
      marker survey, outside §13's scope and not fixed. §10 cites "roughly 20
      requests (§4)" — wrong figure, and §4 is the Badge section, not a
      request-budget section. §11 says "OAuth + Collection sync", contradicted
      by decisions §9.1. Both predate decisions §13. Sweep them up during the
      reconciliation rather than separately.
- [ ] **2026-09-12: bare §N references are ambiguous across design, decisions
      and the plans.** Convention recorded in working-agreement §2 as of this
      commit; the two known collisions (§12, §13) are fixed. Older bare
      references elsewhere are NOT swept — fix them when touched, not in a
      sweep, since a sweep would rewrite text nobody is reading.
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
- [x] **2026-09-07: `plans/` filenames are inconsistent.** Steps 2 and 3
      use invented verb-adjective-noun names
      (`build-order-step-2-read-effervescent-squirrel.md`,
      `build-order-step-3-tag-jolly-minsky.md`); step 4 uses a descriptive
      one (`build-order-step-4-structural-matching.md`). Descriptive is the
      convention going forward. Renaming 2 and 3 requires a `grep -rn`
      reference sweep across `docs/`, `plans/`, `CLAUDE.md` and `TODO.md`;
      cosmetic, optional, not blocking. — 2026-09-19: steps 2 and 3 renamed to
      build-order-step-2-importer-schema.md and
      build-order-step-3-strict-identification.md. Step 4's stale
      structural-matching plan keeps its name: it is cited 20 times,
      including by decision records.
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

- **2026-09-20: `invalidateStrict`'s tier scoping is untested in v1.** With
  `discogs_no_match` narrowed to `CHECK (tier IN ('strict'))` (§15.6), no second
  tier exists to prove the DELETE's `WHERE tier = 'strict'`. The v1 assertion is
  "the table is empty afterwards". When v2 widens the CHECK for fuzzy negatives
  (§15.6 Scope), restore a two-tier assertion: `'strict'` rows deleted, the other
  tier kept.
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
