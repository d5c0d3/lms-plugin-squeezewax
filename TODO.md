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

- [x] `Schema.pm`: plugin-owned attached SQLite file, `postDBConnect`
      registration, `PRAGMA user_version` migrations, per `docs/v1-decisions.md` §2.
- [ ] Configurable Discogs tag names + detection action (v1, per §3 of the
      decisions doc).

## Next — build-order steps 3–5 (matching)

- [ ] **`album_key` computation.** Resolved during step 2, deliberately not
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
- [ ] **`Slim::Music::Import->addImporter`** registration, which step 2
      deliberately omitted: an importer whose `startScan` does nothing would
      only put a dead row in the scan progress UI.

## Open design questions

- [ ] **Scanner→server handover for the re-match trigger.** Decisions §6 wants
      `onChangedTrack` / `onNewTrack` / `onDeletedTrack` to accumulate affected
      album ids, but those fire in the scanner process and the set cannot reach
      the server in memory. Two options, neither chosen: a handover table in
      `squeezewax.db` written by the scanner (DML, which the scanner is allowed
      — only DDL is server-only), or a server-side recompute at
      `['rescan','done']`. Needs deciding before the tag-change trigger lands.
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
- [ ] **Material Skin.** Does a plugin settings page render in Material Skin?
      Does a custom page via `Slim::Web::Pages->addPageFunction`? This blocks
      both the §4 badge overlay and the v2 triage page, so it is worth an early
      throwaway dev build to find out.
- [ ] **Album-id stability on a normal rescan.** Record some album ids, rescan,
      compare. Then edit an album title and rescan again.
- [ ] **`addPostConnectHandler` from a third-party plugin.** Registration forces
      a disconnect/reconnect; the interaction with plugin load ordering has been
      read, not observed.
- [ ] **DDL during a scan.** Only evidence is a 2016 CustomScan log; WAL and
      `sqlite_use_immediate_transaction` have both changed since.
- [ ] **Step 2 end-to-end on a server.** Plugin loads with the new
      `<importmodule>`; `squeezewax.db` appears in the prefs directory;
      `PRAGMA squeezewax.user_version` is 1 after first start; the file
      survives a wipe-and-rescan; deleting it and then running a scan before
      restarting the server logs loudly and writes nothing (the scanner should
      attach the empty file SQLite creates for it, then fail the version check).

## Waiting — external

- [ ] **Lyrion forum question** about plugin-owned attached databases. Drafted;
      not posted. Not blocking — an own-file layout cannot collide with anything
      LMS owns, and migrating later is cheap.

## Housekeeping

- [ ] Decide whether `dev-repo-workflow.md` lives in the repo root or in
      `docs/` — its own §3 layout diagram says `docs/`, but the file is at the
      root. Pick one and make them agree.
- [ ] After any commit under `docs/`, hit "Sync now" in the claude.ai project
      before the next design chat.

## Deferred by decision — not forgotten

- v2: triage / library-health page (problem releases only).
- v2: completeness check ("you have 9 of 12 tracks").
- v2: "Add to Wantlist" action, alongside Wantlist sync.
- v3: FX-rate source for optional currency conversion — still unselected.
- Not planned: any write to the Discogs Collection.
