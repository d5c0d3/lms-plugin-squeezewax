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

- [ ] Add `<importmodule>Plugins::SqueezeWax::Importer</importmodule>` to
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
- [ ] Reconcile `docs/squeezewax-v1-decisions.md` into
      `docs/squeezewax-design.md` and `docs/implementation-plan.md`, so
      there is one source of truth again.
- [x] Re-verify the slimserver citations in `docs/squeezewax-v1-decisions.md`
      against `refs/slimserver/` (they were taken on v9.2.0; refs is on
      `public/9.1`, so line numbers differ — located by symbol). All twelve
      confirmed; one citation corrected (DATE/MUSICBRAINZ_ID attribution).

## Next — build-order step 2

- [ ] `Schema.pm`: plugin-owned attached SQLite file, `postDBConnect`
      registration, `PRAGMA user_version` migrations, per `docs/v1-decisions.md` §2.
- [ ] Configurable Discogs tag names + detection action (v1, per §3 of the
      decisions doc).

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
