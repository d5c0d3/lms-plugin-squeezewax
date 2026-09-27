# Build-order step 8b: the collection sync and the ownership pass inside the scan

Written 2026-09-27 by the design chat. Input: decisions §15.18 (recorded at
`5870741`), the step 8b survey, the design chat's rulings of 2026-09-27, and
Claude Code's Phase 0 report (read-only, at `5870741`).

Verification pin: slimserver `a670a38c2b14ad42b86a39884bcb842121b35571`, the
same pin as `refs/`. Base: `v1-buildout` at `5870741`, `check-all.sh` 1181
assertions green.

**What this step does.** Today the collection sync and the ownership pass run in
the server, sixty seconds after a scan finishes. After this step they also run
inside our own scan step, so that when a scan ends the badges are already right.
The server-side path stays as a fallback for scans our importer did not run.

**What this step does not do.** It does not make the server fallback smarter, add
any settings-page control, or reconsider per-album ownership lookups (§13.8
settled that: four requests for 203 items against 764 requests).

---

## §0. What this plan rests on

### §0.1 Rulings taken 2026-09-27 (design chat)

Ten answers to the survey and to Phase 0. Each is appended to decisions §15.18
as parts 7–16 by hand-off 11; the reasoning lives there, the consequences here.

1. **The marker is a one-row table, and it becomes the single "last synced".**
   Migration 5 adds `discogs_sync_state`. Both sync paths write it;
   `API::Async->status` reads it; `discogsLastSynced` and
   `discogsLastSyncItems` retire by `$prefs->migrate(3, …)`. (Survey Q1(a).)
   This also answers Phase 0's C12: the settings page keeps meaning "ownership
   last derived", because the marker is written only after the pass's writes
   commit.
2. **`Importer.pm`'s `use` gate does not change.** Identification still gates on
   tag names (§15.8 stands, unamended). The sync gets its own importer with its
   own gate, so widening the old one would only give a token-only user a dead
   progress row and an orphan log pair — the thing `Importer.pm:83-95` exists to
   avoid. Survey Q2 is answered against its own recommendation, and Q7(a)'s
   restructuring of `startScan`'s early returns is not needed at all.
3. **Timeouts: 15 s per request, 120 s for the whole sync.** The second bound is
   our own clock, checked **between** requests, because LWP's timeout measures
   inactivity rather than total time (Phase 0 I5) and nothing can interrupt a
   request midway. (Survey Q3(a), sharpened.)
4. **The scanner's rate-limit state starts cold, and a computed wait abandons
   the sync.** There is no timer in the scanner, so the only way to honour a
   60 s wait would be to block the scan for 60 s. The check happens **before
   issuing the next request**, so a wait computed after the last page costs
   nothing (Phase 0 I6). (Survey Q4(a) plus the chat's third ruling.)
5. **One progress row covers both halves** — the fetch ticks per request, the
   pass per album. The fetch is the slow part (2.72 s measured) and the survey's
   Q5(a) would have left it unreported. (Chat's second ruling.)
6. **`Ownership::_write` commits the scanner's pending work first, then writes,
   then lets its caller commit.** The `$ownTxn` conditional alone is not safe
   here: on the scanner branch nothing is rolled back, so a pass that dies
   halfway would be committed by the next `forceCommit` — §13.7's named failure
   (Phase 0 I1). A leading `forceCommit` makes the pass the only uncommitted
   work, so a rollback discards exactly the pass. (Survey Q6(a) plus Phase 0's
   correction.)
7. **A second `post` importer of our own, weight 130, gated on the token.**
   In-tree precedent for two importers from one `initPlugin`:
   `Slim/Plugin/OnlineLibrary/Importer.pm:30-35` and `:41-46`. (Survey Q7(b),
   now verified rather than assumed.)
8. **Two new files.** `SqueezeWax/API/Sync.pm` fetches; `SqueezeWax/ScanSync.pm`
   is the importer class. This also makes the design doc's module table true
   (Phase 0 C21).
9. **A new suite, `scripts/scan-sync-check.pl`.** (Survey Q8(b).)
10. **Scan modes: a playlist-only rescan skips the sync; an online-library-only
    rescan runs it.** An online-library rescan adds exactly the all-remote
    albums that only the pass can badge (§15.11), so it is the one mode where
    skipping would lose badges. A playlist rescan changes no album.
    (Phase 0 C13.)

Two further rulings taken without a question, both one-directional:

11. **LWP's self-made 500 is classified as `no_response`.** On a timeout, DNS
    failure or refused connection LWP builds a 500 carrying
    `Client-Warning: Internal response` (`CPAN/LWP/UserAgent.pm:205-219`,
    `:1131-1139`, documented `:1569-1572`; read, not observed). Without this,
    every timeout would be logged as "Discogs returned a server error" and
    §15.18 part 2's "the two paths behave alike" would be false in the log.
12. **The reach of the scan-time path is accepted as it is.** A plain `rescan`
    reaches the external scanner only when some importer registered *in the
    server* forces it — FullTextSearch on a default install (Phase 0 I9). With
    FTS off and no virtual library or streaming plugin, our importer never runs
    and only the fallback syncs. Registering a server-side importer of our own
    to force external scans (TIDAL's pattern, `lms-plugin-tidal/Plugin.pm:71`)
    is refused: it would make every rescan on every user's server fork an
    external scanner for our convenience. This qualifies §15.18 part 2's "every
    ordinary rescan does run our importer" and hand-off 11 amends that sentence.

### §0.2 Derived here, not decided

- **The skip rule is exact, not a time window.** The survey proposed
  `time() - last_synced <= DEBOUNCE_AFTER_RESCAN + grace`. **That is withdrawn.**
  Our importer runs at weight 130, and after it come the artwork importers,
  `updateStandaloneArtwork`, `precacheAllArtwork` and `optimizeDB`
  (`Slim/Music/Import.pm:462-484`) — a tail with no bound, so the marker can be
  minutes old when the tick fires and any fixed grace is a guess that breaks on
  large libraries. Instead: `Plugin::_rescanDone` remembers the time it fired,
  keeping the previous value, and `_syncTick` skips only when the marker's
  `source` is `'scan'` **and** its `last_synced` lies between the previous
  rescan-done and this one. That window is exactly "a sync happened during the
  scan that just finished". It needs the `source` column, because a manual sync
  between two scans also falls inside the window and must **not** suppress the
  fallback — it derived ownership for the library as it was before this scan.
  Before the first rescan-done of a server's life the lower bound is the time
  `initPlugin` ran, which correctly refuses to skip on a marker from a previous
  run.
  *Failure bias, stated deliberately:* a needless sync costs four requests and
  ~2.7 s; a wrong skip costs stale badges until the next scan or the button. The
  rule errs toward syncing.
- **`endImporter` on every exit path**, as `Importer.pm` already requires of
  itself, so a reader of `scanner.log` never sees a "Starting" without its
  "Completed".
- **Nothing escapes `startScan`.** `runScanPostProcessing` runs inside one eval
  (`scanner.pl:348`); a die there would skip the artwork importers, the artwork
  precache, `optimizeDB` and `afterScan`'s `'end'` notice (Phase 0 I3). Every
  failure in this step is caught, logged at error, and returns 0.
- **`_testFilter` applies on both paths.** Not a choice: its whole safety
  argument is that a release hidden from the pass is hidden everywhere the
  pass's conclusions show (`API/Async.pm:670-696`). Phase 0 I7 notes the release
  checklist gains one site.
- **No `cache`.** `SimpleSyncHTTP` caches only when asked (`Base.pm:81-95`,
  verified). TIDAL does ask (`refs/lms-plugin-tidal/API/Sync.pm:104-106`) and
  `CLAUDE.md:59` praises it; for a collection, a cached page would defeat the
  completeness gate silently.
- **The timeout is always passed explicitly.** A falsy timeout makes
  `SimpleSyncHTTP.pm:87` return without sending anything, so the `|| 10` on
  `:91` is unreachable (Phase 0 B4).

### §0.3 What earlier steps establish and this step must honour

- §13.2: the collection is never stored. The entry list lives for one sync and
  is dropped. Nothing in this step persists a release.
- §13.7: never partially advance the marker for a sync that did not complete.
  One exit, one rule.
- §13.10.3, §15.14, §15.17 part 5: the pass's decision rules are untouched. This
  step moves where `Ownership::apply` is called from, and nothing about what it
  decides.
- §15.4: the pass never snapshots and never identifies. `_write`'s column list
  does not grow.
- §15.13 part 1: the pass runs after a complete fetch or not at all.
- §15.16 part 9: a row may assert an ownership conclusion, an identification, or
  a review reason.

### §0.4 Amendments this step makes to the record

Phase 0 found 24 places the tree asserts something this step makes false or
incomplete (C1–C24). Hand-off 11 carries the wording for all of them. Three are
more than wording:

- **C12** — answered by §0.1 part 1; no ruling needed.
- **C13** — `scripts/syntax-check.sh:182-190` skips `Ownership.pm` in scanner
  mode on the grounds that the scanner never loads it. That is a code change,
  in commit C2.
- **C22** — §15.18 part 2's "every ordinary rescan does run our importer" needs
  the qualification of §0.1 part 12.

Two upgrades, in the other direction:

- **C23** — §15.18 part 1's weakest claim is now **verified**, not inferred:
  TIDAL's importer calls its sync inside `startScan`
  (`refs/lms-plugin-tidal/Importer.pm:21`, `:24`, `:67`, `:90`) over
  `SimpleSyncHTTP` with `timeout => 15` (`API/Sync.pm:104-105`). The TODO item
  of 2026-09-27 is ticked, and our 15 s is the same figure the reference plugin
  uses.
- **B3** — `SimpleSyncHTTP` is not merely tolerated in the scanner; `:11` says
  it is "supposed to be used in the scanner only", and `:58` warns when it is
  used anywhere else.

### §0.5 Phase 0 results (Claude Code, 2026-09-27, read-only, at `5870741`)

Baseline 1181, all green. Citation drift corrected: `Import.pm:573` (not :574),
`:716` (not :715), `Match.pm:497-499`, `Progress.pm:154-170`. Beyond the items
already folded in above:

- `code`, `mess` and `headers` are set for **every** response
  (`SimpleSyncHTTP.pm:97-99`), so this path needs none of the async path's
  third-argument workaround. `content` is empty on a non-2xx (`:101-108`,
  `:137`).
- Our `User-Agent` wins over LWP's (`Base.pm:150-152` against
  `CPAN/LWP/UserAgent.pm:250-253` and `HTTP/Headers.pm:109-113`). The header
  list from `buildRequest` must stay even-length, or its last element becomes
  the request body (`Base.pm:109-111`).
- `Progress`'s `total` may be set after `new` (`:154-170`); nothing needs it
  before the first `update`. `final` with no argument uses `total` as `done`
  (`:263`), so pass `final` an explicit value.
- A total of 0 renders as an empty bar (`Web/Pages/Progress.pm:47`) and as `-1`
  percent in `rescanprogress` (`Queries.pm:3267`). The Material skin and any
  visual jump when the total changes are **unverified** — hardware.
- `update` is the abort mechanism (`Progress.pm:221-245` →
  `SQLiteHelper.pm:444-459`, which calls `exit`). There is **no** abort point
  inside a blocking request: abort latency there is the request time plus up
  to 5 s.
- `forceCommit` **swallows a failed commit** with a warning
  (`Schema.pm:2380-2384`). Our code cannot see it (Phase 0 I2), which is one
  reason the marker rides in the same transaction as the pass's writes.
- `Match::_writeOk` is true in the scanner **only while `Schema->isReady`**
  (`Match.pm:46`, `:63`), which in the scanner requires an exact schema version
  match (`Schema.pm:373`).
- No suite binds `Async->status`, the settings page's "last synced", or
  `Importer.pm`'s `use` gate — 0 assertions each. **Every suite opens its handle
  with `AutoCommit => 1`**, so no scanner transaction branch has ever been
  exercised offline.
- Unverified and on the hardware list: SSL resolving in the scanner's perl
  (B7); the progress row's late total (D15); LWP's timeout against
  `api.discogs.com` at scanner priority (I5); a proxied server (I12); a
  `rescan` with FTS off (I9); `rescan playlists` and `rescan onlinelibrary`
  (C13); a token entered seconds before a rescan (I11, prefs are saved 10 s
  after a change, `Namespace.pm:305`).

---

## §1. Group A — the marker

### §1.1 Migration 5 (`Schema.pm`, appended to `@MIGRATIONS`)

```sql
CREATE TABLE IF NOT EXISTS squeezewax.discogs_sync_state (
    id          INTEGER PRIMARY KEY CHECK (id = 0),
    last_synced INTEGER NOT NULL,
    items       INTEGER,
    source      TEXT    NOT NULL CHECK (source IN ('server','scan'))
);
```

- `SCHEMA_VERSION` is `scalar @MIGRATIONS` (`Schema.pm:32-45`), so this is
  `_migration_5` at index 4 and yields `user_version 5`.
- Re-runnable by `CREATE TABLE IF NOT EXISTS`, which is migration 1's form.
  **Not** `_migration_4`'s `pragma_table_info` guard — that shape exists for
  `ADD COLUMN` (Phase 0 G23).
- **No row is inserted.** An absent row means "never synced", which is what the
  retiring `discogsLastSynced => 0` default expressed.
- The single-row shape is enforced by the database, not by the writers: both
  write `INSERT OR REPLACE … (0, …)`.
- `source` is recorded and **not displayed**. It is load-bearing for the skip
  rule (§0.2), and it is the first thing worth knowing when a log is being read.
  A settings-page display of it is v2; recorded, not built.
- `schema-check.pl`: migration 5 creates the table with the four columns; both
  re-run forms are a no-op; the CHECK rejects `id = 1` and an unknown `source`;
  a version-4 database migrates with every existing `discogs_match` row
  untouched.

### §1.2 Writers and the one reader

- **Server path** — `API/Async.pm::_finish`, on success only, in place of the
  two `$prefs->set` calls. `discogsLastSyncError` **stays a pref**: it is
  server-only state and §15.18 part 3 keeps the page unchanged for scan-time
  failures.
- **Scan path** — `ScanSync`, inside the pass's transaction (§2.1, §4.2).
- **Reader** — `API::Async->status` returns `lastSynced` and `lastItems` from
  the table, keeping its existing key names so `Settings.pm` and the template
  need no change (Phase 0 F21: 0 assertions bind either). It also returns
  `lastSource`, unused by the template for now.
  `status` must not die when the schema is not ready: guard on
  `Schema->isReady` and return `lastSynced => 0` otherwise.
- **Prefs** — `$prefs->migrate(3, sub { $_[0]->remove('discogsLastSynced');
  $_[0]->remove('discogsLastSyncItems'); 1 })`, alongside the existing
  `migrate(1)` and `migrate(2)` at `Plugin.pm:38`, `:43`. Drop both from
  `$prefs->init`. `TODO.md`'s release checklist says "whatever N is next" for
  removing `discogsTestExcludeReleases`; that becomes 4.
- `sync-check.pl`'s ~25 pref-write assertions (`:583-593`, `:660-664`,
  `:687-691`, `:712-716`, `:906-907`, `:940-942`, `:969`, `:1069`, `:1359-1368`,
  `:1378-1383`, `:1395`) move to the table. Same expectations, new home.
  `plugin-check.pl:308`, `:500-502` likewise.

### §1.3 The skip rule (`Plugin.pm`)

- `_rescanDone` records `time()` into a module-level scalar, keeping the
  previous value in a second scalar, then arms the debounce as it does today.
  `initPlugin` seeds the previous value with `time()`.
- `_syncTick` gains one check, **after** the token check and **before** the
  rejection-pause check — a healthy scan-time sync should not consult a pause it
  does not use:

  skip when the marker exists, `source` is `'scan'`, and
  `previous rescan-done < last_synced <= this rescan-done`.

  Logged at info, once, with the marker's timestamp, so the log shows why no
  sync happened.
- Everything else in `_syncTick` is unchanged. A failed scan-time sync writes no
  marker, so the fallback runs on its normal 60 s debounce — the recovery for
  §15.18 part 3's "logged only" is a minute away, not a scan away.
- `plugin-check.pl`: the ~26 assertions on `_rescanDone` / `_syncTick`
  (`:311-458`) gain a marker stub. New cases: a `'scan'` marker inside the
  window skips; the same marker outside it does not; a `'server'` marker inside
  the window does **not** skip; no marker does not skip; a marker from before
  `initPlugin` does not skip.

---

## §2. Group B — the pass under the scanner's transaction

### §2.1 `Ownership::_write`

Replace the unconditional `$dbh->begin_work` (`:744`) with:

- `my $ownTxn = $dbh->{AutoCommit} ? 1 : 0;` — the shape `Match::relinkOrphan`
  uses (`Match.pm:497-499`, `:566`, `:573`).
- `$ownTxn` true (server): `begin_work`, then `commit` at `:834` as today, and
  `rollback` at `:840`. No change in behaviour.
- `$ownTxn` false (scanner): **`Slim::Schema->forceCommit` first**, so every
  earlier statement of the scan is durable and the pass's writes are the only
  uncommitted work. Then the writes. Then **return without committing** — the
  caller commits, after it has written the marker (§4.2). On failure,
  `$dbh->rollback`, which now discards exactly the pass, and re-`die` so
  `apply`'s eval reports `'failed'` as it does today.
- `_write` makes no `$progress->update` call and must never gain one: an abort
  between its writes would exit into `cleanup`'s `forceCommit` and commit half a
  pass (Phase 0 I8).
- The comment at `:733-736` ("one transaction for the whole pass") and the one
  at `:815-819` ("a scan would have made `_writeOk` refuse") are both rewritten;
  the second has the right conclusion for the wrong reason in the scanner, where
  ordering is serial rather than guarded.
- `Match.pm:493`'s "the same shape `Ownership::_write` uses, which only ever
  runs server-side" becomes false and is corrected in this commit (Phase 0 C9).

### §2.2 `Ownership::apply`

- The `_writeOk` guard at `:236-239` stays exactly as it is. In the scanner it
  returns true unless the schema is not ready (Phase 0 #19), which is the right
  refusal there too.
- `apply` takes one optional argument: a progress handle to tick per album
  during the decide walk. The walk happens before any write, so this adds abort
  points only where an abort is safe (§0.2, Phase 0 I8). The server path passes
  nothing and behaves as today.
- The comment at `:233-236` ("the pass is a server-side writer") is rewritten.
- `ownership-check.pl`: the first assertions in this project against a handle
  opened with `AutoCommit => 0`. The pass writes inside the caller's
  transaction; nothing is committed by `_write`; a die mid-write leaves no
  partial row visible after a rollback; the determinism pair (`:879-886`) and
  the refused guard (`:893-899`) still hold on both handle types; a progress
  handle is ticked once per album and never during `_write`.

---

## §3. Group C — the scan-side fetch

### §3.1 The pure parts move to `API.pm`

Two transports must not carry two copies of the entry builder; that is the drift
§15.2 reason 1 warned about, and a seam test cannot cover a duplicate. Move,
unchanged in behaviour, from `API/Async.pm` to `API.pm`:

`_pageCount`, `_collectionPath`, `_collectionParams`, `_formatLabel`,
`_labelLabel`, the `basic_information` → entry mapping (as a named
`entryFromRelease`), and `_testFilter`.

- `Async.pm` calls them at their new home. `PER_PAGE`, `COLLECTION_FOLDER` and
  `MAX_PAGES` move with them.
- `sync-check.pl:447-523` calls three of these directly, about 20 assertions.
  Same expectations, renamed target. Grep for any other direct caller before
  moving.
- `api-check.pl` gains the moved helpers' own assertions if it does not already
  cover them.

### §3.2 `SqueezeWax/API/Sync.pm` — the synchronous fetch

One entry point, `fetch($token)`, returning either
`{ ok => 1, entries => [...], items, pages, requests }` or
`{ ok => 0, error => '...' }`. It writes nothing, touches no pref, and knows
nothing about ownership or progress.

- Transport: `require Slim::Networking::SimpleSyncHTTP` at the call site, as
  `Slim/Music/Artwork.pm:771` does, then
  `->new({ timeout => 15 })->get( $url, @headers )` with `$url`, `@headers` from
  `API->buildRequest`. **Never** `cache`.
- The walk is the async path's, minus the callbacks: identity →
  `/users/<user>/collection/folders/0/releases` page 1 → pagination → remaining
  pages → the completeness gate (`counted` against `pagination.items`) → the
  entry list through `testFilter`. Same `MAX_PAGES` bound on the first page,
  same failure names (`no_username`, `too_many_pages`, `count_unknown`,
  `count_mismatch`) so one vocabulary serves both paths.
- Classification: `API->classifyResponse( $http->code, $http->content )`, with
  `code`, `mess` and `headers` always present (Phase 0 B6). Before classifying,
  a 5xx carrying `Client-Warning: Internal response` is turned into
  `no_response` (§0.1 part 11).
- Rate accounting after every response, exactly as `Async::_handle` does:
  `API->accountRequest( API::_parseRateHeaders($headers), time(), $state )`,
  with `$state` local to this run. **`backoffFor` is never called.** If the
  computed wait is non-zero **and another request is still needed**, abandon with
  `error => 'rate_wait'` (Phase 0 I6).
- The 120 s budget is checked between requests against a start time taken at
  entry; on exceeding it, abandon with `error => 'timeout_budget'`. Nothing can
  interrupt a request in flight (Phase 0 I5), so a single slow-but-alive
  response may exceed 15 s — a hardware item, not something this code can fix.
- `API.pm`'s stale file header and `MAX_RETRIES` comment are corrected here
  (Phase 0 C1–C3): name both transports and both callers, and say that the scan
  path does not retry.

### §3.3 Nothing else changes in `Async.pm`

Beyond §1.2's marker write and §3.1's moved helpers. The rejection pause
(`%rejected`), `abort`, `isRunning` and the superseded-run guard are all
server-side machinery and stay that way; §15.18 part 4 makes the pause govern
the fallback alone, and §15.17 part 4's queue-page notice keeps describing
exactly that.

---

## §4. Group D — the importer

### §4.1 Registration (`Importer.pm::initPlugin`)

A second `addImporter`, after the existing one:

```
Plugins::SqueezeWax::ScanSync, {
    type   => 'post',
    weight => 130,
    'use'  => <a non-empty discogsToken>,
}
```

- Loaded with a `require` inside an `eval`, not a `use` at the top of the file:
  a compile error in the new module would otherwise take identification down
  with it, because `tryModuleLoad` disables the whole plugin
  (`PluginManager.pm:323-327`). Phase 0 #10 recommends this and
  `Slim/Music/Artwork.pm:771` is the in-tree shape. If the require fails, log at
  error and register nothing.
- The class must be registered from here, because the scanner loads only the
  `<importmodule>` class (`PluginManager.pm:204`, `:207`). `install.xml` does
  not change. `endImporter` needs nothing of the class beyond `startScan`
  (Phase 0 #10).
- 130 is free: in-tree `post` weights run 90–110, ours is 120, and nothing runs
  after `optimizeDB` (`Import.pm:462-484`). A third-party post importer with no
  weight sorts at 1000, after us; other third-party weights are **unverified**.
- The existing registration, its comments and its gate are untouched (§0.1
  part 2). Its comment at `:90-93` ("the ownership pass at step 7 is server-side
  and does not run here") is corrected.
- Cost, stated: a token-holding user now gets two `Starting … scan` /
  `Completed … Scan` pairs per scan at error level (`Import.pm:578`,
  `:710-712`).

### §4.2 `SqueezeWax/ScanSync.pm::startScan`

Everything inside one eval; no exception may escape (§0.2, Phase 0 I3). Order
matters and is the whole design:

1. **Mode gate.** Return early, with `endImporter`, when `$main::playlists` is
   set. Run when `$main::onlineLibrary` is set (§0.1 part 10). Note in the
   comment that `Import`'s own `scanOnlineLibraryOnly` is useless here: it is
   reset at `Import.pm:409-410`, before post-processing.
2. **Gates.** No token → return 0 (belt and braces behind the `use` gate, as
   `Importer.pm` does for tag names). `Schema->isReady` false → log the reason
   and return 0; without it `_writeOk` would refuse anyway.
3. **Progress row**, `plugin_squeezewax_ownership`, with a new
   `PLUGIN_SQUEEZEWAX_OWNERSHIP_PROGRESS` string following
   `PLUGIN_SQUEEZEWAX_MATCH_PROGRESS` (`strings.txt:61`). Created with no total,
   because the page count is not known until the first collection page answers.
4. **`Slim::Schema->forceCommit`** — the visibility commit, for the same reason
   and with the same comment as `Importer.pm:165`, and additionally because the
   progress write opens `BEGIN IMMEDIATE` and would otherwise hold the write
   lock across the whole blocking fetch (Phase 0 I10, inferred).
5. **`API::Sync->fetch($token)`**, ticking the row once per request. Once
   `pages` is known, set the total to `1 + pages + albumCount`
   (`Progress.pm:154-170`).
6. **On failure**: log at error with the error name, `$progress->final` with an
   explicit value (Phase 0 D14's trap), `endImporter`, return 0. No pref, no
   page, no marker — §15.18 part 3.
7. **`Ownership->apply( $entries, $progress )`**, which ticks per album and
   writes inside the scanner's transaction (§2).
8. **The marker**, only when `apply` returned `'ok'`, written before any commit
   so that it shares the pass's fate. `source => 'scan'`, `items` from the
   fetch.
9. **`Slim::Schema->forceCommit`**, then `$progress->final`, then
   `endImporter`, then return the change count. If this commit fails silently
   (Phase 0 I2) the marker goes with it and the fallback re-syncs — which is why
   the marker is written here and not earlier.

A summary line at info: items, requests, seconds, and the pass's own counters,
so one log line answers "did the scan badge my library".

### §4.3 What this adds that did not exist

- An abort point per album during the pass's decide walk, and none during the
  fetch (Phase 0 #16). Abort latency during a blocking request is the request
  time plus up to 5 s. An abort during the walk exits before any write, so it
  cannot leave a partial pass — which is the property §2.1's ordering buys.
- A second progress row in the scan UI for token holders.

---

## §5. The seam suite — `scripts/scan-sync-check.pl`

Picked up automatically by `check-all.sh`'s glob (`:42`). Follows
`sync-check.pl:209-262`'s honest-transport pattern: canned responses, recorded
requests, and `code` / `headers` placed where `SimpleSyncHTTP` really puts them.
No suite stubs that class today (Phase 0 #22).

The joins that matter, because this is where three verified hazards meet:

1. **Scanner transaction → pass → marker.** With `AutoCommit => 0`: a successful
   run leaves rows and a `'scan'` marker; a fetch failure leaves neither; a die
   inside `_write` leaves neither after the rollback; nothing is committed by
   `_write` itself.
2. **Abandon rules.** A response with no rate headers abandons before the next
   request, and not after the last page. A clock past 120 s abandons between
   requests. `backoffFor` is never called: a 429 fails the sync once.
3. **Error vocabulary.** A 401 gives `unauthorized`; an LWP 500 with
   `Client-Warning: Internal response` gives `no_response`; a real Discogs 500
   gives `server_error`.
4. **`testFilter`** is applied on this path, with the same list the pass sees.
5. **Mode gate.** `$main::playlists` set → no request issued, no marker.
   `$main::onlineLibrary` set → the sync runs.
6. **Nothing escapes.** Every failure path returns a value rather than dying,
   and calls `endImporter` exactly once.

Also owed:
- `syntax-check.sh:176` — the two new modules in `MODULES`, with a stub prelude
  for `SimpleSyncHTTP`'s LWP / Cookies / Prefs chain.
- `syntax-check.sh:182-190` — the scanner-mode skip of `Ownership.pm` is removed
  (Phase 0 C13); the comment explaining it is replaced.

---

## §6. Model and phasing for Claude Code

**Model:** Opus. A new transport, a new writer, and the first change to
`_write`'s transaction handling.

**Phase 0:** done (§0.5).

**Phase 1**, one commit each, `check-all.sh` green after every one:

| | |
|---|---|
| P | this plan, decisions §15.18 parts 7–16, the C1–C24 wording, TODO edits (hand-off 11) |
| A1 | migration 5 (+`schema-check.pl`) |
| A2 | the marker's writer and reader, `$prefs->migrate(3)` (+`sync-check.pl`, `settings-check.pl`, `plugin-check.pl`) |
| A3 | `_syncTick`'s skip rule and `_rescanDone`'s bookkeeping (+`plugin-check.pl`) |
| B1 | `_write`'s transaction, `apply`'s progress argument, the reworded comments, `Match.pm:493` (+`ownership-check.pl`, first `AutoCommit => 0` assertions) |
| B2 | the pure helpers move to `API.pm` (+`api-check.pl`, `sync-check.pl`) |
| C1 | `API/Sync.pm`, and `API.pm`'s header and `MAX_RETRIES` comment |
| C2 | `ScanSync.pm`, the second registration, the new string, `syntax-check.sh` |
| C3 | `scripts/scan-sync-check.pl` |
| D | docs: design, `CLAUDE.md` (transport rule, build order, step 8b), the remaining C-list, TODO ticks including C23 |

Then a package build for the hardware checks.

**Phase 2:** per-commit assertion counts, the final total, any anchor that did
not match, every deviation with its reason.

---

## §7. Hardware checks (after merge, on the reference server)

The motivation is part 1's claim, so check that first.

0. **Before.** Back up both databases. Record the queue's contents and
   `discogs_match`'s row count.
1. **Migration 5** runs in the live server; `user_version` 5; no row in
   `discogs_sync_state`; every `discogs_match` row untouched.
2. **The claim.** Add a record to the Discogs collection **and** copy an album
   folder in, then rescan once. At the moment the scan UI finishes, the badge is
   already right — no sixty-second wait. The scanner log shows two
   Starting/Completed pairs, the sync's own summary line, and then `_syncTick`
   skipping with its reason.
3. **The marker.** `discogs_sync_state` has `source = 'scan'`; the settings page
   shows that time and item count. Press "Sync collection now": the same row
   becomes `source = 'server'`.
4. **The progress row.** Does the ownership row render sensibly while its total
   is 0 and after it is set — in the default skin and in Material (Phase 0
   D15, unverified)?
5. **SSL** (Phase 0 B7, the one that could stop this step working at all):
   HTTPS from the scanner's perl resolves, or the log says
   "No HTTPS support built in".
6. **Failure is silent and recovers.** Break the token, rescan: an error line in
   the scanner log, nothing new on the settings page or the queue page, no
   marker — and the fallback sync 60 s later fails the same way and records
   *its* error, as it does today. Restore the token, rescan, badges correct.
7. **Timeout**, if it can be provoked: a slow or black-holed `api.discogs.com`
   leaves the scan to finish normally, with one error line. Note the wall time,
   because I5 says a slow-but-alive response can exceed 15 s.
8. **Abort.** Abort a scan during the ownership row: the next scan's pass rewrites
   everything, and no marker was written for the aborted one.
9. **Modes.** `rescan playlists` issues no Discogs request. `rescan
   onlinelibrary` does, and an all-remote album's badge appears.
10. **Reach** (Phase 0 I9): disable FullTextSearch, confirm no virtual library
    and no streaming plugin, then a plain rescan — expect the scan to run
    in-process, our importer not to appear in the log, and the fallback to do
    the work 60 s later.
11. **Timings**, for the record: the fetch, the pass, and the whole ownership
    importer, against §4's 2.72 s and 40–48 ms baselines.

Anything that cannot be provoked goes to `TODO.md` rather than being marked
passed.
