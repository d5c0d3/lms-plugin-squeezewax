# Build-order step 2 — `<importmodule>` + Importer.pm + Schema.pm + DDL

## Context

`docs/squeezewax-v1-decisions.md` §2 settled the storage design on paper: a
plugin-owned `squeezewax.db` attached per-connection via `postDBConnect`,
versioned with `PRAGMA squeezewax.user_version`, keyed on an `album_key` hash
over the album's tracks' `urlmd5`. Five parts of that were reasoned about but
not grounded in a real API, and two of them turned out to be wrong. This plan
records what the source and SQLite actually do, then lands step 2 as three
commits.

Citations are against `refs/slimserver/` on branch `public/9.1`, by file and
symbol. SQLite behaviours were executed, not recalled — SQLite 3.50.6.

Scope: no matching, no tag reading, no OAuth, no badge.

---

## Findings

### 1. Retrieving an album's tracks — raw SQL on `Slim::Schema->dbh`

Two real routes exist; both work in the server **and** the scanner.

**DBIC:** `Slim/Schema/Album.pm:46` —
`$class->has_many('tracks' => 'Slim::Schema::Track' => 'album')`. Used at
`Slim/Schema/Album.pm:414` (`duration`) and `Slim/Menu/AlbumInfo.pm:377`.

**Raw SQL:** `Slim/Plugin/FullTextSearch/Plugin.pm:547-556` (`_getAlbumTracksInfo`)
is a plugin doing exactly this — `Slim::Schema->dbh->prepare_cached` over
`SELECT ... FROM tracks WHERE tracks.album = ?`. `Slim/Schema/Album.pm:390-395`
does the same from LMS's own code.

**Use raw SQL** — not because DBIC is unavailable, but because
`Slim/Utils/Scanner/API.pm:37-38` warns in its own POD that "Track objects
should be avoided when possible to avoid slowing down the scanner", and we
would be inflating every track of every album to read one column.

`urlmd5` is real and always populated: `Slim/Schema/Track.pm:33`, DDL
`SQL/SQLite/schema_16_up.sql:42`, index `SQL/SQLite/schema_12_up.sql:8`; set by
`Slim/Schema.pm:1758` and `:1947` (`md5_hex($url)`) on every create/update.

```sql
SELECT urlmd5 FROM tracks
 WHERE album = ? AND audio = 1
   AND content_type NOT IN ('cpl','src','ssp','dir')
 ORDER BY urlmd5
```

The audio predicate is LMS's own, from `Slim/Control/Queries.pm:4811`. Digest
via `Digest::MD5 qw(md5_hex)`, LMS's convention (`Slim/Utils/SQLiteHelper.pm:25`).

Available in the scanner: `Slim::Schema->init()` runs before plugins load there
(`Slim/Music/Import.pm:760` `_checkLibraryStatus` ← `addImporter` `:558` ←
`Slim::Music::VirtualLibraries->init` `scanner.pl:255`; `load('import')` is
`scanner.pl:283`). Because the file is ATTACHed to the *same* handle, one query
can join `squeezewax.discogs_match` to `main.tracks` in either process — the
payoff of the attach design.

**Not implemented this session** (matching is step 3/4). Recorded here and in
TODO so it is not re-derived.

### 2. `album_key` for a zero-track album — `undef`, and it is reachable

`md5_hex('')` is a single constant, so every empty album would collide on one
key and a match written there would later badge something unrelated.
**The compute sub returns `undef`; the caller skips.** Column gets `NOT NULL`
plus `CHECK(length(album_key) = 32)` so it cannot be written by accident.

Observable? Not where we intend to run, but yes elsewhere — the guard is
required, not defensive:

- LMS reaps empty albums itself: `Slim::Schema::Album->rescan`
  (`Slim/Schema/Album.pm:382-405`) does `DELETE FROM albums WHERE id = ?` when
  `SELECT COUNT(*) FROM tracks WHERE album = ?` is 0. Called from
  `Slim/Utils/Scanner/Local.pm:757`, `:855`, `:1110`, `Slim/Schema.pm:2549`.
- In the delete path the hook fires **before** the deletion: `Local.pm:707-710`
  dispatches `onDeletedTrackHandler`, `:731-736` deletes the track, `:757`
  reaps the album. At `onDeletedTrack` the album still has its tracks.
- By `onFinished` (`Local.pm:1193-1196`) the empty rows are gone.
- **But** `Album->rescan` counts with an unfiltered `COUNT(*)` while we filter
  on `audio = 1 AND content_type NOT IN (...)`. An album can have zero
  *qualifying* tracks while LMS still sees rows and keeps it. Different
  predicates, different answers.

### 3. Double `postDBConnect` registration — idempotent, and the two never coexist

`Slim/Utils/SQLiteHelper.pm:390-402`:

```perl
sub addPostConnectHandler {
    my ( $class, $handler ) = @_;
    if ($handler && $handler->can('postDBConnect')) {
        $postConnectHandlers{$handler}++
    }
    if ( $postConnectHandlers{$handler} == 1 ) {
        Slim::Schema->disconnect;
        Slim::Schema->init;
    }
}
```

Two independent mechanisms:

1. `%postConnectHandlers` is a **hash keyed by handler**; dispatch at `:379-381`
   is `foreach (keys %postConnectHandlers)`. A repeat call increments the count
   to 2, the key set is unchanged, `postDBConnect` still runs once per connect.
2. The disconnect/reconnect is guarded by `== 1` — first registration only.

Requirement: pass a **class-name string**, not an object; the hash key is the
stringified handler. `Slim/Plugin/FullTextSearch/Plugin.pm:199` passes `$class`.

**They never coexist in one process anyway.** `Slim/Utils/PluginManager.pm:204`
is `next unless $manifest->{ $moduleType . 'module' }` — `module` for the server
(`slimserver.pl:482`), `importmodule` for the scanner (`scanner.pl:283`). One
class per process. The idempotency is belt-and-braces, not load-bearing.

Ordering is safe both sides: server `Schema->init()` `slimserver.pl:437` <
`load()` `:482`; scanner `load('import')` `:283` < `AutoCommit = 0` `:294`, so
the forced reconnect lands before the scan's long-lived transaction opens.

**Gotcha to code around:** `Slim::Schema::disconnect` (`Slim/Schema.pm:325-331`)
does not clear the `$_dbh` cache; `$_dbh` is reassigned at `Slim/Schema.pm:139-141`,
*after* `_connect` returns, and `postConnect` runs inside `_connect` (`:283`).
During `postDBConnect`, `Slim::Schema->dbh` returns the **old, disconnected**
handle. Use only the `$dbh` passed in.

### 4. If the ATTACH fails

**Hard constraint: `postDBConnect` must never `die`.** `RaiseError => 1`
(`Slim/Schema.pm:273`), so a failed ATTACH does die — verified, an ATTACH into a
missing directory returns SQLITE_CANTOPEN (14) rather than failing silently. The
dispatch loop at `SQLiteHelper.pm:379-381` has no `eval`, `postConnect` is
called unguarded from `Slim/Schema.pm:283`, and `Slim::Schema->init` is called
unguarded from `slimserver.pl:437`. An uncaught die there takes LMS's entire
database connection down over a plugin's problem. Everything goes in `eval {}`.

**A missing *file* is not an error — SQLite creates it silently.** Verified: with
`fresh.db` absent, `ATTACH 'fresh.db' AS squeezewax` exits 0 and leaves a 0-byte
file; `PRAGMA squeezewax.user_version` on it returns `0`, also without error.
Only a missing or unwritable *directory* fails.

This has a direct consequence for the scanner. If the scanner ever attaches
before the server has migrated — a first-ever run that begins with a scan, or a
deleted `squeezewax.db` — **the attach will succeed and create an empty
database**, and every query against it would then fail one table at a time. So
the attach is *not* what protects us. **The `user_version` check is.** A fresh
file reports 0, which is `!= SCHEMA_VERSION`, so the scanner declares itself not
ready, logs per the list below, and writes nothing. That check is the load-bearing
gate, and it must run on every connect, not only when the file looked suspicious.

**Server, on failure:** `logError()` (`Slim/Utils/Log.pm:318-330` — root logger
at ERROR, so it appears at default levels) plus `$log->error` on
`plugin.squeezewax`; set `$READY = 0` and keep the error string. Every entry
point checks `Schema->isReady` and returns cleanly. The plugin does nothing
rather than half-working; LMS is unaffected.

**Scanner, on failure — "loudly", concretely:**

1. `logError(...)` + `$log->error(...)` — reaches `scanner.log` at default levels.
2. A `Slim::Utils::Progress` row so it shows in the running scan:
   `->new({ type => 'importer', name => 'plugin_squeezewax_matching', total => 1 })`,
   `->update($errorString)`, `->final`. The `info` column is real
   (`SQL/SQLite/schema_5_up.sql:13`) and surfaced by `rescanprogress`
   (`Slim/Control/Queries.pm:3274-3276`) — but only while `active`, so this is a
   transient surface, not a record.
3. `Slim::Music::Import->endImporter(__PACKAGE__)` and return — **write nothing**.
   Existing confirmed matches untouched, satisfying design §8.
4. No `die`. `PluginManager` does `eval { $module->$initFunction }` and only
   `logWarning`s (`Slim/Utils/PluginManager.pm:389-396`), which would leave us
   half-initialised rather than cleanly off.

No durable record is written from the scanner: it cannot write `squeezewax.db`
(that is the failure), and prefs written there are clobbered by the server's
in-memory copy — neither reference importer writes prefs from its importer.
Durable surfacing is the server's job.

Consequently the scanner's `postDBConnect` does ATTACH + verification only, and
reads `PRAGMA squeezewax.user_version`. Version behind `SCHEMA_VERSION` → not
ready, log, do nothing. Never CREATE, never migrate (decisions §2).

### 5. `lms_album_id` refresh — `onFinished` is the wrong hook

`Slim::Utils::Scanner::API->onFinished` is real (`Slim/Utils/Scanner/API.pm:131-135`,
dispatched from `markDone` at `Slim/Utils/Scanner/Local.pm:1193-1196`) but wrong
on three counts:

1. **Wrong process** — for an external scan it fires inside the scanner.
2. **Too early** — `markDone` ends the media-folder phase. `runScan`
   (`Slim/Music/Import.pm:371`) returns, then `runScanPostProcessing`
   (`:432-460`) runs the `post` importers, including `Slim::Music::ReleaseTypes`
   and `Slim::Music::VirtualLibraries`, which still touch `albums`.
3. **Incomplete coverage** — it only fires if `Scanner::Local::rescan` ran.

**Use the server-side `['rescan','done']` notification** via
`Slim::Control::Request::subscribe` — what `Slim::Schema` itself uses
(`Slim/Schema.pm:243-248`) and FullTextSearch uses (`:204-209`).

That it fires where the plugin can write is verifiable, not assumed: in
`Slim/Utils/SQLiteHelper.pm::_notifyFromScanner`, the post-scan
`Slim::Schema->disconnect; Slim::Schema->init;` is at **`:626-628`** and the
`notifyFromArray(undef, ['rescan','done'])` at **`:638`** — the reconnect, and
therefore our re-ATTACH, happens first. Server process, `AutoCommit = 1`, event
loop running. Registered from `Plugin.pm`; the scanner is uninvolved.

It fires more than once per logical scan — six sites: `SQLiteHelper.pm:638`,
`Slim/Music/Import.pm:238` (abort) and `:741` (scanner-crash recovery),
`Local.pm:391`, `:663`, `:1224` — so the refresh must be idempotent and
debounced through a coalescing `Slim::Utils::Timers` timer, as
`Slim/Utils/AutoRescan.pm:112` does.

→ `docs/squeezewax-v1-decisions.md` §6 says otherwise and needs correcting.

### 6. SQLite pragmas on an attached database — executed, not assumed

Two of my own assumptions were wrong. Executed on SQLite 3.50.6:

```
main.synchronous  = 0        (OFF, set by LMS at SQLiteHelper.pm:99)
sw.synchronous    = 2        (FULL — the default)
main.journal_mode = wal      (set by LMS at SQLiteHelper.pm:101)
sw.journal_mode   = delete   (the default)
```

**Neither pragma is inherited by an attached database.** LMS's `on_connect_do`
(`SQLiteHelper.pm:96-116`) sets both unqualified, which applies to `main` only.

- **`synchronous`: leave it alone.** Our file is already at FULL (2). Setting
  NORMAL would have *reduced* durability, which was the opposite of my stated
  intent. No pragma.
- **`journal_mode`: must be set to WAL.** Both the server and the scanner attach
  the same file. In rollback-journal mode a writer takes an exclusive lock on
  the whole file, so a server-side write during a scan can block or fail.

Three verified properties of that pragma drive the implementation:

1. **It persists in the file.** Set once, reconnect fresh, attach again with no
   pragma → still `wal`; opening `sw.db` directly as `main` also reports `wal`.
   So it is one-time, not per-connect.
2. **It cannot be set inside a transaction — and it fails *silently*.** Inside
   `BEGIN`…`COMMIT` the statement returns the unchanged mode (`delete`), raises
   no error, and exits 0. There is nothing to catch. **The returned value must be
   read back and compared to `wal`**; fire-and-forget would leave the file in
   rollback-journal mode with no signal at all.
3. `SELECT * FROM pragma_journal_mode('squeezewax')` is a pure read — the right
   verification for the scanner, which must not mutate the file.

Where `postDBConnect` runs there is no open transaction (server: inside
`_connect`, `AutoCommit = 1`; scanner: before `scanner.pl:294`), so the set will
take — but it is checked anyway, because the failure is invisible.

### 7. `dbFile` — call it rather than reimplement its body

`Slim/Utils/SQLiteHelper.pm:556-566`:

```perl
sub dbFile {
    my ( $class, $name, $persistent ) = @_;
    if ($persistent) {
        my $persistDir = Slim::Utils::Prefs::dir() || Slim::Utils::OSDetect::dirsFor('prefs');
        return catfile($persistDir, $name);
    }
    ...
}
```

The second argument is `$persistent`, a plain **boolean truthiness test**, not
an enum or a mode. In-tree callers pass different truthy values, confirming
that: `SQLiteHelper.pm:345` and `:520` pass the string `'persistent'`;
`Slim/Schema/Storage.pm:62` passes `$dbfile =~ /persist/`, a regex boolean. Any
true value selects the prefs directory.

So `dbFile('squeezewax.db', 1)` is correct, and its persistent branch is
literally the expression decisions §2 quotes. → §2's citation should name the
method rather than quote the resolution expression.

### 8. `match_confidence` — nothing reads it; §3 is stale, §10 is right

Design §3 (`docs/squeezewax-design.md:145`) gives the match row as
`album_key → discogs_release_id, match_tier, match_confidence, matched_at`.
§10 (`:568-584`) lists `match_tier` and `state` and **no** `match_confidence`.
That is a genuine spec conflict and my earlier plan followed §10 silently.

**Nothing consumes it.** `match_confidence` appears exactly once in the whole
repo — that one line. Checked against every reader:

- **§4 badge derivation** (`:307-315`) is a pure boolean cascade: confirmed
  match? → release in `discogs_collection`? → `list_state`. No threshold, no
  score, nowhere it could enter.
- **§3 "Match states per album"** (`:205-216`) enumerates exactly three states —
  Unmatched, Candidate, Confirmed — and says the state records "*that* a link
  exists and how sure we are of it". That "how sure" is already fully carried by
  `(match_tier, state)`: §3's own tier table (`:164-168`) fixes the confidence
  per tier — Strict auto-confirms, Structural auto-confirms, Fuzzy *never*
  auto-confirms and always lands in the review queue. A separate scalar would be
  derivable from the pair, i.e. redundant.
- **§5 statistics, §7 marketplace, §9 settings, §11 scope** — no mention.
- **v2 triage problem classes** (decisions §5) are all categorical — "couldn't
  decide", "unparseable", "deleted release". Not one is a threshold on a score.

The one line that keeps the ghost alive is `:223`: "can retroactively backfill /
upgrade the confidence of the original scan-time match." In context that is the
Flow 2 backfill, and `:221` two lines above already defines the mechanism —
"confirming promotes candidate → confirmed". It is prose for a state promotion,
not a numeric bump.

**So your reading is right: superseded by `match_tier` + `state`, left behind in
§3's shorthand.** §3 predates §10 and predates the state model at `:205-216`,
whose own parenthetical (`:215-216`) records an earlier draft being corrected in
the same area.

**Recommendation:** no `match_confidence` column; correct `:145` to
`album_key → discogs_release_id, match_tier, state, matched_at` in the same
commit as the DDL, and reword `:223` from "upgrade the confidence of" to
"promote" so the phrase stops implying a column. The second is optional; the
first is the defect.

One honest caveat on finding 8, argued against itself: Structural auto-confirms
on durations "within ±2–3 s", so a future triage view *could* want to record how
close the match actually was. That is speculative and nothing asks for it today —
and adding a nullable column later is the cheap kind of migration, unlike the
rekey that makes this table expensive to get wrong. Adding it now for a
hypothetical reader is the wrong trade.

### 9. `match_tier` NOT NULL is safe for relinking — but the CHECK needs a fourth value

Two separate questions hide here. The first resolves the way you guessed; the
second is the one that would have hit a constraint mid-implementation.

**Relinking carries `match_tier` forward — no new value needed.** Decisions §2's
orphan recovery matches an orphaned confirmed row's snapshot against a new album
and, on exactly one fit, relinks. The right shape for that is an **UPDATE of
`album_key`** on the existing row (plus a refreshed `lms_album_id` and snapshot),
not a new row: relinking re-identifies *which local album the match belongs to*.
It does not re-decide *which Discogs release this is* — the release id, the tier
that established it and the user's confirmation are all unchanged and still true.
That is exactly the `album_key`-versus-identity separation the whole design rests
on; a relink that invented a new provenance value would be asserting something
about the release link that nothing re-evaluated. §2's own phrasing agrees — it
describes applying a confidence bar to "something the user personally confirmed",
i.e. carrying an existing confirmation across, not forming a new one.

So `NOT NULL` is safe, and the ambiguous branch (→ review queue, "pre-filled with
the previous answer") likewise carries the old row's values.

**But `manual` is missing, and v1 needs it.** Build-order step 5 and v1 scope
item 7 are "review queue + manual re-match". §3:243-245 has the user re-matching
"after ... learning the auto-match picked the wrong pressing" — overwriting a
row whose tier is `strict`. None of the three cascade values honestly describes
the result:

- Leaving `strict` would claim a file tag names this release, when the user
  overrode precisely that tag.
- Writing `fuzzy` would claim the artist+title search produced it, when no
  search ran — and it would make a user-resolved row indistinguishable from an
  unresolved fuzzy candidate, which the v2 triage page (decisions §5) needs to
  tell apart.

The root of it: **§3's three tiers are the *cascade's* tiers, while the column is
provenance**, and provenance has a fourth origin the cascade does not — the user.

**Decision: `CHECK(match_tier IN ('strict','structural','fuzzy','manual'))`,
`NOT NULL`.** Adding the value now costs nothing; discovering it in step 5 costs
a migration on the one table that is not disposable. Recorded as a §3/§10 note in
the same doc commit as the `match_confidence` fix, since it extends the same
vocabulary.

---

## Implementation — three commits

### Commit 1 — `<importmodule>`, `Importer.pm`, and the attach

`SqueezeWax/install.xml`: add
`<importmodule>Plugins::SqueezeWax::Importer</importmodule>` after `<module>`.
Pattern: `refs/Spotty-Plugin/install.xml` (separate `<module>`/`<importmodule>`).
**Do not** copy Spotty's `<onlineLibrary>true</onlineLibrary>` — we are not one.

New `SqueezeWax/Importer.pm` — log category, then `Schema->init()`, nothing else:

- `Slim::Utils::Log->addLogCategory({ category => 'plugin.squeezewax', ... })` in
  both entry points. Idempotent — it only sets a level and a description
  (`Slim/Utils/Log.pm:378-417`). Without it the category inherits root (ERROR)
  in the scanner, which is what TIDAL's importer silently gets.
- **Prefs: read only, no `init`/defaults here.** Both reference importers take
  `preferences('plugin.<name>')` at file scope and never seed defaults
  (`refs/lms-plugin-tidal/Importer.pm:18`, `refs/Spotty-Plugin/Importer.pm:27`).
  Defaults belong in `Plugin.pm`; the scanner reads the file the server wrote.
  Importer code must tolerate `undef` on a first-ever run.
- **No `Slim::Music::Import->addImporter` yet.** `runImporter` calls
  `$importer->startScan`; registering an importer that does nothing puts a dead
  row in the scan progress UI. It lands with the matching work.

New `SqueezeWax/Schema.pm` — `Plugins::SqueezeWax::Schema`, attach only:

- `init()` — registers once via
  `Slim::Utils::OSDetect->getOS()->sqlHelperClass()->addPostConnectHandler('Plugins::SqueezeWax::Schema')`
  (`SQLiteHelper.pm:390`; caller precedent `FullTextSearch/Plugin.pm:199`),
  passing the literal class-name string per finding 3.
- Path from `sqlHelperClass->dbFile('squeezewax.db', 1)` (finding 7).
- `postDBConnect($dbh)` — wholly inside `eval {}`, never dies (finding 4); uses
  the passed `$dbh` only (finding 3 gotcha):
  1. `$dbh->do('ATTACH ' . $dbh->quote($path) . ' AS squeezewax')` — quoted, not
     interpolated as `SQLiteHelper.pm:353` does, so a path containing an
     apostrophe cannot break it.
  2. `journal_mode`: server attempts `PRAGMA squeezewax.journal_mode = WAL` and
     **compares the returned value to `wal`**; scanner reads
     `pragma_journal_mode('squeezewax')` and logs an error if it is not `wal`,
     without mutating. Per finding 6 — silent failure, so verification is the
     only signal.
  3. No `synchronous` pragma (finding 6).
  4. `PRAGMA squeezewax.cache_size` — small fixed value, not LMS's `_cacheSize`.
- `isReady()` / `lastError()` — the guard every caller uses.
- No busy-timeout handling: DBD::SQLite defaults to 30 s and it is a connection
  property, so it covers the attached file. LMS sets none itself.

`Plugin.pm` gains the same `Schema->init()` call.

### Commit 2 — versioning and the migration runner

- `SCHEMA_VERSION` constant; read/write `PRAGMA squeezewax.user_version`.
- Server: run pending migrations, bump `user_version` per step.
  Scanner: **check only**; mismatch → not ready, log per finding 4, no DDL.
- `@MIGRATIONS` — ordered subs, index *n* producing `user_version` *n+1*. Each
  idempotent (`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`), each
  wrapped so a failure stops the run and leaves `user_version` at the last good
  step.

### Commit 3 — the DDL (migration 1)

Per design §10, in schema `squeezewax`. Attached-schema DDL precedent:
`SQL/SQLite/schema_12_up.sql:19-20` (`ALTER TABLE persistentdb.tracks_persistent`,
`CREATE INDEX persistentdb.urlmd5Index` — index names are per-database, which is
why `urlmd5Index` exists in both `main` and `persistentdb`).

- **`discogs_match`** — `album_key TEXT PRIMARY KEY NOT NULL CHECK(length(album_key)=32)`,
  `mb_album_id`, `lms_album_id`, `discogs_release_id`, `discogs_master_id`,
  `match_tier`, `state`, `matched_at`, plus the four orphan-recovery snapshot
  columns (`snapshot_artist`, `snapshot_album_title`, `snapshot_track_count`,
  `snapshot_total_duration`). **No `match_confidence`** — see finding 8.
  Indexes on `discogs_release_id`, `lms_album_id`, `mb_album_id`, and
  `(state, snapshot_track_count)` for the orphan lookup.

  Enum columns get CHECK constraints, both `NOT NULL`:
  `CHECK(state IN ('candidate','confirmed'))` and
  `CHECK(match_tier IN ('strict','structural','fuzzy','manual'))` — the fourth
  value per finding 9. A typo'd value in either silently produces "no badge"
  rather than an error — precisely the failure mode §4's derivation cascade
  cannot distinguish from "not matched", and the one this design guards against
  everywhere else. Verified that SQLite rejects a case-mismatched value
  (`'Confirmed'`) with SQLITE_CONSTRAINT (19), so the constraint catches the
  realistic typo, not just the absurd one.
- **`discogs_release_cache`** — `discogs_release_id` PK, `discogs_master_id`,
  `payload` (raw JSON from `GET /releases/{id}`; LMS bundles JSON::XS, cf.
  `Slim/Schema/Album.pm:7`), `fetched_at`.
- **`discogs_collection`** — design §10 as written: `instance_id INTEGER PRIMARY
  KEY`, `list_state TEXT NOT NULL DEFAULT 'owned'`, `discogs_release_id`,
  `format`, `catalog_no`, `label`, `country`, `year`, `condition`, `added_at`,
  `notes`, `synced_at`, with `CHECK(list_state IN ('owned','wantlist'))`. Index
  on `(discogs_release_id, list_state)` — the badge-derivation join in §10. v1
  writes owned rows only, so the wantlist keying gap is inert.
- **`discogs_price_snapshot`** — PK `(discogs_release_id, snapshot_at)`,
  `price_low`, `price_median`, `price_high`, `currency`.

**No foreign keys at all** — not into LMS tables (decisions §2; and
`PRAGMA foreign_keys = ON` at `SQLiteHelper.pm:99` is connection-wide, so a
same-file FK *would* be enforced), and none between our own tables in v1, so no
cascade can ever remove a confirmed match.

### Doc edits (with the commits that motivate them)

- **`docs/squeezewax-design.md` §3** — three edits, all in the **same commit as
  the DDL**, since that commit is what resolves them:
  - `:145` — correct the match-row shorthand to
    `album_key → discogs_release_id, match_tier, state, matched_at`, dropping
    `match_confidence` (finding 8).
  - `:223` — "upgrade the confidence of the original scan-time match" →
    "promote the original scan-time match". This is the sentence that would send
    a future reader hunting for the column we just removed.
  - `:164-168` — note that the three tiers are the *cascade's* tiers, and that
    `match_tier` additionally records `manual` for user-established matches
    (finding 9). Mirror the four-value list in §10's `discogs_match` sketch.
- **`docs/squeezewax-design.md` §10** — record that `discogs_collection` is
  **entirely regenerable**: it caches Discogs' own data and holds nothing
  user-entered, by design (§5 rules out a local owned flag). A rekey therefore
  costs `DROP TABLE`, recreate, and a ~20-request re-sync (§4). Two consequences
  belong in the spec, not only in TODO: schema changes to this table are cheap
  at any time, and **orphan recovery must never depend on it** — the recovery
  snapshot lives in `discogs_match` precisely so it survives a collection wipe.
- **`docs/squeezewax-v1-decisions.md` §2** — citation names
  `sqlHelperClass->dbFile($name, $persistent)` rather than quoting its body.
- **`docs/squeezewax-v1-decisions.md` §6** — correct the `onFinished`
  recommendation for the `lms_album_id` refresh per finding 5.

---

## Verification

No LMS instance is available here, so verification is static plus offline SQLite.

1. `perl -c` each of `Plugin.pm`, `Importer.pm`, `Schema.pm` with
   `refs/slimserver` on `@INC` — catches syntax and typo'd package names, not
   API existence.
2. `xmllint --noout SqueezeWax/install.xml`.
3. Offline SQLite exercise of commits 2 and 3: scratch `main` db, `ATTACH` a
   scratch `squeezewax.db`, run migration 1, assert
   `PRAGMA squeezewax.user_version` = 1; run again and assert it is still 1 with
   no error (idempotency); assert `pragma_journal_mode('squeezewax')` is `wal`.
4. Assert every CHECK rejects: a short/empty `album_key`, `state = 'Confirmed'`,
   `match_tier = 'Strict'`, `list_state = 'Owned'` — and **accepts**
   `match_tier = 'manual'`, the value step 5 will write (finding 9).
5. Assert the scanner path fails safely on a fresh file: ATTACH a
   never-migrated `squeezewax.db`, confirm `user_version` reads 0, and confirm
   the scanner branch reports not-ready and issues no DDL (finding 4).
6. Real-server checks → TODO.md **Waiting**: plugin loads with the new
   `<importmodule>`; `squeezewax.db` appears in the prefs directory;
   `user_version` is 1 after first start; the file survives a wipe-and-rescan;
   a scan with the file deleted mid-flight logs loudly and writes nothing.

## TODO.md additions

- **`discogs_collection` wantlist rekey (v2).** §10's `instance_id` PK cannot
  hold wantlist rows — a Discogs want has no instance id. The table is
  disposable (see §10), so the v2 migration is DROP + re-sync. Note that the
  obvious fix does **not** work: `UNIQUE(list_state, discogs_release_id,
  instance_id)` with `instance_id` NULL for wants constrains nothing — SQLite
  treats NULLs as distinct in unique indexes. Verified: three identical wantlist
  rows inserted with no error. v2 needs a partial unique index
  (`... WHERE instance_id IS NULL`) or a non-NULL sentinel.
- **Open design question — scanner→server handover for the re-match trigger.**
  Decisions §6 wants `onChangedTrack`/`onNewTrack`/`onDeletedTrack` to
  accumulate affected album ids. Those fire in the scanner process and the set
  cannot reach the server in memory. Two options, neither chosen this session:
  a handover table in `squeezewax.db` written by the scanner (DML, which the
  scanner is allowed), or a server-side recompute at `['rescan','done']`.
- **`lms_album_id` refresh hook** — use `['rescan','done']`, debounced, not
  `onFinished`; decisions §6 corrected (see Doc edits).
- **`album_key` computation** (findings 1 and 2) is resolved but deliberately
  unimplemented — it belongs with matching in step 3/4.
- Real-server checks from Verification step 6.

- **Orphan recovery writes an UPDATE, not an INSERT** (finding 9) — step 3/4
  must relink by updating the orphaned row's `album_key`, `lms_album_id` and
  snapshot, carrying `discogs_release_id`, `match_tier`, `state` and `matched_at`
  forward unchanged. Recorded so the constraint's assumption is not violated
  later by a plausible-looking INSERT.
