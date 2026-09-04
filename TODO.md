# SqueezeWax — TODO

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
      registration, `PRAGMA user_version` migrations, per `docs/v1-decisions.md` §2.
- [x] Configurable Discogs tag names + detection action (v1, per §3 of the
      decisions doc). Done 2026-09-03/04 (15d19e4, 939819b, fee0aac, 1b18e45).

## Next — build-order steps 3–5 (matching)

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
      A confirmed match demoted to candidate by a tag conflict keeps its
      adjudicated `discogs_release_id` and its snapshots (decisions §3a); if the
      user then removes the tags entirely, the importer may not delete the row —
      it carries a decision, and §2a forbids that — and Structural skips it
      because a `discogs_match` row exists. With a confirm-only queue the album
      would propose a release with no tag behind it forever. Recorded in design
      §3.

## Open design questions

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
- [ ] **Step 4 must relax the `use` gate.** It is currently
      `scalar @{discogsTagNames}`, which would wrongly disable the importer for
      a user who wants Structural only — Structural needs no tag names. Becomes
      wrong the moment step 4 lands.
- [ ] **v2 triage page must distinguish "unparseable tag" from "tags
      disagree".** Both write `(strict, candidate, NULL)` in v1, which is
      correct for v1 — neither is a match — but they are different user actions
      (fix one file's tag vs. decide between two). Recorded, not designed.
- [ ] **`discogs_collection` wantlist rekey (v2).** `instance_id` as primary
      key cannot hold wantlist rows — a Discogs want has no instance id. The
      table is entirely regenerable (design §10), so the migration is DROP +
      re-sync, ~20 requests. Note the obvious fix does **not** work:
      `UNIQUE(list_state, discogs_release_id, instance_id)` with `instance_id`
      NULL for wants constrains nothing, since SQLite treats NULLs as distinct
      in unique indexes — verified, three identical rows inserted without
      error. Needs a partial unique index (`... WHERE instance_id IS NULL`) or
      a non-NULL sentinel.

## Waiting — needs a real server

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
- [ ] **Album-id stability on a normal rescan.** Record some album ids, rescan,
      compare. Then edit an album title and rescan again.
- [ ] **Step 3 end-to-end on a server — NOT YET RUN.** Step 3 is code-complete
      as of 2026-09-04 but entirely unverified on hardware. The full procedure
      is in `plans/build-order-step-3-tag-jolly-minsky.md` under *Verification
      on a real server*: the two fail-safe branches, detection, Strict end to
      end, cheap rescan, tag-change trigger, conflict, abort, the manual-row
      survival test, the unconfigured-install silence check, the tag-list
      invalidation test, and the online-library counts. **Do not start step 4
      planning until this has run**, and report what actually happened rather
      than that it passed.
- [ ] **Remote-track timestamps in plugins other than TIDAL.** Downgraded from
      blocking: `Slim/Formats.pm:261` is the sole in-tree producer of a
      `TIMESTAMP` attribute and sits behind `if (-e $filepath)` at `:259`, which
      is false for a non-file URL because `$filepath = $file` at `:165`, so the
      NULL is structural for the standard path. What remains unverified is only
      whether a third-party online-library importer supplies its own `TIMESTAMP`
      through `updateOrCreate`. `SELECT remote, COUNT(*), COUNT(timestamp) FROM
      tracks GROUP BY remote` on a box with Spotty installed settles it.
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

## Waiting — external

- [ ] **Lyrion forum question** about plugin-owned attached databases. Drafted;
      not posted. Not blocking — an own-file layout cannot collide with anything
      LMS owns, and migrating later is cheap.

## Housekeeping

- [x] **Revisit `plugin.squeezewax` defaultLevel before v1 release.** Done
      2026-09-04 (cec7a46): WARN in both entry points. The scan-progress row and
      LMS's own "Starting/Completed ... Scan" pair carry the healthy-run signal
      that INFO was standing in for; the one thing neither reports —
      "examined 4,800, confirmed 0" — is escalated to warn by the importer.
- [ ] **`working-agreement.md` exists twice** — repo root and
      `docs/working-agreement.md`, identical content. Same defect class as
      the `dev-repo-workflow.md` location item; pick one.
- [ ] **`working-agreement.md` §2 names `docs/v1-decisions.md`;** the file is
      `docs/squeezewax-v1-decisions.md`. TODO's ticked step-2 line repeats
      the wrong name. Two documents disagreeing is a defect (§2's own rule).
- [ ] **`discogs_no_match` rows orphaned by an `album_key` change are not
      swept in v1.** Bounded by library churn; the table is regenerable and
      design §9's "clear & rebuild matches" action clears it. Revisit only if
      a real library shows meaningful growth.
- [ ] **"No rollback in the scan path" is inferred, not proven.** Design §8's
      resumability promise leans on it. A rollback would discard our
      uncommitted matches along with LMS's uncommitted scan work — recoverable,
      but it changes what §8 can promise.
- [ ] Decide whether `dev-repo-workflow.md` lives in the repo root or in
      `docs/` — its own §3 layout diagram says `docs/`, but the file is at the
      root. Pick one and make them agree.
- [ ] After any commit under `docs/`, hit "Sync now" in the claude.ai project
      before the next design chat.

## Deferred by decision — not forgotten

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
