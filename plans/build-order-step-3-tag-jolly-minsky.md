# Build-order step 3 — tag reading + Strict-tier matching

## Context

Step 2 landed the plugin-owned `squeezewax.db`, attached to LMS's own
connection from a `postDBConnect` handler, and confirmed on real hardware
that the importer loads in the scanner, that server and scanner hold the file
concurrently under WAL, that the post-scan disconnect/init/reconnect
re-fires the handler, and that plugin settings pages are reachable in
Material Skin. It deliberately stopped short of `addImporter`, because an
importer whose `startScan` does nothing only puts a dead row in the scan UI.

Step 3 makes the importer do work: read the Discogs release ID out of file
tags and write Strict-tier matches. **Strict needs no Discogs API and no
OAuth** — decisions §4's cost table is explicit that a Strict match is
0 requests, because the tag names the release. Everything in this step is
offline and testable against a real library with no credentials. I agree
with that framing and the plan depends on it: nothing below touches the
network.

Deliverable of the planning session was a verification report plus a plan.
The findings are first; the commits are at the end.

---

# Findings

## 1. Where in the scan matching runs — a `post` importer, weight 120

`Slim::Music::Import` keeps one registry and runs it in two separate passes:

- `runScan` (`Slim/Music/Import.pm:371-413`) iterates `_sortedImporters()`
  and **skips anything whose `type` is not `'file'`** (`:382-384`). This is
  the pass that creates albums — `Slim::Media::MediaFolderScan` registers
  `type => 'file', weight => 1` (`Slim/Media/MediaFolderScan.pm:35-38`).
- `runScanPostProcessing` (`:432-491`) iterates the same sorted list and
  **skips anything whose `type` is not `'post'`** (`:454-456`), then artwork
  importers, then `Slim::Schema->optimizeDB` (`:484`).

`_sortedImporters` (`:415-421`) sorts on `weight`, defaulting to 1000.
`runImporter` (`:568-584`) calls `$importer->startScan` and only if
`$Importers{$importer}->{use}` is true — so `use => 1` is not optional.

So the answer to "albums must exist before they can be matched" is
structural, not a matter of weight: **all `file` importers finish before any
`post` importer starts.** We register `type => 'post'`.

Weights in the `post` pass, all real:

| Weight | Importer | Cite |
|---|---|---|
| 90 | `Slim::Music::ReleaseTypes` | `Slim/Music/ReleaseTypes.pm:29-33` |
| 90 | `Slim::Plugin::FullTextSearch::Plugin` | `Slim/Plugin/FullTextSearch/Plugin.pm:192-196` |
| 90 | `Slim::Plugin::ExtendedBrowseModes::Libraries` | `.../Libraries.pm:22-26` (comment: "must be smaller than VirtualLibrary!") |
| 100 | `Slim::Music::VirtualLibraries` | `Slim/Music/VirtualLibraries.pm:111-114` |
| 110 | `...OnlineLibrary::Importer::VirtualLibrariesCleanup` | `Slim/Plugin/OnlineLibrary/Importer.pm:30-35` |

**Use `weight => 120.`** We depend on `albums` and `tracks` being final and
on nothing else; running last inside the `post` pass keeps us after
`ReleaseTypes` and `VirtualLibraries` (both still touch `albums`, per step
2's finding 5) and comfortably before `optimizeDB`, which is outside the
loop. 120 also leaves room to slot future SqueezeWax importers around the
OnlineLibrary cleanup at 110 without renumbering.

What the reference plugins pass is *not* the model here. TIDAL and Spotty
call `addImporter('Plugins::X::Importer', { use => 1 })` from **`Plugin.pm`**
(`refs/lms-plugin-tidal/Plugin.pm:71`, `refs/Spotty-Plugin/Plugin.pm:142`) —
that is the server-side registration, which only feeds
`_checkLibraryStatus`. The registration that actually runs is in
`Slim::Plugin::OnlineLibraryBase::initPlugin`
(`Slim/Plugin/OnlineLibraryBase.pm:23-43`), guarded `if (main::SCANNER)`,
passing `type => 'file', weight => 200, playlistOnly => 1,
onlineLibraryOnly => 1`. They are `file` importers because they *create*
tracks from a streaming service. We do not create anything; we annotate what
the file pass produced. Copying their `type` would run us before albums
exist.

Two consequences worth writing down:

- `playlistOnly` / `onlineLibraryOnly` are `runScan`-only filters
  (`:388-401`). They are meaningless for a `post` importer; do not pass them.
- `runScanPostProcessing` has exactly one live caller, `scanner.pl:348`
  (the other hit is the POD synopsis at `Slim/Music/Import.pm:25`). A
  single-directory rescan driven in-server through
  `Slim::Utils::Scanner::Local::rescan` never reaches it. That is acceptable
  — such a scan changes a subtree, and the next full rescan picks it up —
  but it means the importer is not the only re-match path we will ever need.

## 2. Writes from the scanner into the attached file — one commit, and a lock we did not know about

Two questions here. The first confirms the plan; the second changes it.

### 2a. `forceCommit` does commit our writes — verified, not assumed

`Slim::Schema->forceCommit` (`Slim/Schema.pm:2364-2390`) is a plain
`$self->storage->dbh->commit` guarded on `AutoCommit` being off. One
connection, so one transaction, spanning `main` and `squeezewax`.

Executed on SQLite 3.50.6, both files in WAL, both attached to one
connection:

```
BEGIN IMMEDIATE; INSERT INTO main.t; INSERT INTO sw.m; COMMIT;  → main 1, sw 1
BEGIN IMMEDIATE; INSERT INTO main.t; INSERT INTO sw.m; ROLLBACK; → main 1, sw 1 (unchanged)
```

So the scanner's long-lived `AutoCommit = 0` transaction (`scanner.pl:295`)
does enclose our writes, and `forceCommit` commits both.

**What this means for design §8.** Resumability largely falls out of LMS's
existing commit cadence rather than needing anything of our own:
`Slim::Schema->forceCommit` already runs at `Slim/Utils/Scanner/Local.pm:357,
472, 556, 638` during the file pass and at every `endImporter`
(`Slim/Music/Import.pm:716`), and there is no rollback anywhere in the scan
path. An interrupted scan therefore cannot discard already-committed
matches; §8's promise holds mechanically. What we still owe is a cadence
*within* our own `startScan`, because between our first write and
`endImporter` there is no LMS commit at all — see finding 5.

**One caveat that must go in the doc.** SQLite's atomic-commit guarantee
across attached databases does *not* hold when the databases are in WAL mode
(SQLite documentation, "Atomic Commit In SQLite" §6.1: multi-database
transactions are not atomic if any participating database is in WAL). Both
`library.db` and `squeezewax.db` are WAL. So on a crash between the two
file-level commits, `library.db` can land while `squeezewax.db` does not.
This is benign for us and worth saying why: `album_key` is derived entirely
from `library.db` content, so a lost match row simply means the album has no
row on the next scan and gets matched again. There is no state that can go
half-written across the two files. (Documented behaviour, not something I
crash-tested.)

### 2b. The scanner holds a write lock on `squeezewax.db` for the whole scan

This is new and it matters. `Slim/Utils/SQLiteHelper.pm:358` sets
`$dbh->{sqlite_use_immediate_transaction} = 1`, so every implicit
transaction on that connection is `BEGIN IMMEDIATE`.

Executed, same 3.50.6, two connections, both files WAL:

| Holder's transaction | Second connection writes `sw.db` |
|---|---|
| `BEGIN IMMEDIATE;` — no writes at all | **locked** |
| `BEGIN IMMEDIATE;` + write to `main` only | **locked** |
| `BEGIN;` (deferred) — no writes | OK |
| `BEGIN;` + write to `main` only | OK |
| `BEGIN;` + write to `sw` only | **locked** |

Reads of `sw.db` from the second connection succeeded throughout — WAL
readers are never blocked.

So `BEGIN IMMEDIATE` takes a write lock on **every attached database**,
including ours, before touching it. Step 2 proved the server and scanner can
attach and *read* concurrently; it did not prove they can write
concurrently, and they cannot. For the duration of a scan the server process
cannot write `squeezewax.db` at all, except in the instants between the
scanner's commits.

Implications, all of which the plan already wants for other reasons:

- **The scanner owns writes during a scan; the server defers its own until
  `['rescan','done']`.** That is already the shape step 2's finding 5 chose
  for the `lms_album_id` refresh. It now has a second, harder reason.
- Any server-side write path we add later (review queue, manual re-match)
  must handle "database is locked" rather than assume it. Simplest correct
  rule: refuse the action while `Slim::Music::Import->stillScanning` is true
  and say so in the UI.
- Server-side writes should stay in autocommit and be short. The server's
  connection also has `sqlite_use_immediate_transaction = 1`, so a
  server-side transaction over our tables takes a write lock on `library.db`
  too, and would block the scanner.
- `ATTACH` is not a write, so `postDBConnect` is unaffected during a scan.

→ `docs/squeezewax-v1-decisions.md` §2 and design §8 both need this.

## 3. Does the importer learn which albums changed? — it does not need to be told

TODO's open design question asks whether `onChangedTrack`/`onNewTrack`/
`onDeletedTrack` need to accumulate album ids and how that set would reach
the server. For scan-time matching, the answer is that the importer's own
iteration makes the accumulation unnecessary, and the TODO item resolves
itself. Two independent signals, both already in `library.db`:

**Structural change → `album_key` changes.** `album_key` is the md5 of the
album's qualifying tracks' `urlmd5`, sorted (step 2, finding 1). Add, remove,
rename or move a track and the key changes, so the album has no row in
`discogs_match` and is matched. Leave it alone and the key matches an
existing row and we skip. A single `LEFT JOIN` from the computed key against
`squeezewax.discogs_match` yields exactly the albums needing work, in the
scanner, with no cross-process handover.

**In-place tag edit → `tracks.timestamp` changes.** `urlmd5` is `md5_hex($url)`
(`Slim/Schema.pm:1758`, `:1947`), so editing tags in place does *not* move
`album_key` — and editing tags is precisely the case Strict matching cares
about. `tracks.timestamp` is the file mtime; LMS's own changed-file detection
is `scanned_files.timestamp != tracks.timestamp OR ... filesize`
(`Slim/Utils/Scanner/Local.pm:270-284`), and the row is rewritten through
`updateOrCreate`. So `MAX(tracks.timestamp)` over an album's qualifying
tracks is a durable "the files behind this album changed" signal, readable in
either process.

Prefer `timestamp` over `updated_time` (`Slim/Schema.pm:2007`,
`SQL/SQLite/schema_16_up.sql:47`): `updated_time` is reset to `time()` for
every track by a wipe-and-rescan, which would spuriously re-match the entire
library, whereas `album_key` and `timestamp` both survive a wipe intact.

**What LMS offers instead, and why not to use it.** `Scanner::Local` builds a
`changed_albums` table (`Slim/Utils/Scanner/Local.pm:311-321`) that does
survive into `runScanPostProcessing` on the same connection. It is the wrong
thing to reach for: it is `TEMPORARY` unless debug logging is on
(`$createTemporary`), it exists only when `$changedOnlyCount` was non-zero,
it covers changed tracks but not new albums, and it is another module's
scratch space with no contract. Reading it would be exactly the kind of
plausible-looking dependency the project rule forbids.

→ TODO's "Scanner→server handover for the re-match trigger" can be closed
with this reasoning rather than by choosing one of its two options. The
track-level `Scanner::API` hooks are still the right mechanism if we ever
want *immediate* re-match on a single-directory scan; they are not needed for
the importer.

## 4. Progress reporting and logging volume

**What a real importer does.** `Slim::Utils::Progress->new({ type =>
'importer', name => ..., total => ..., every => ... })`, `$progress->update($info)`
per item, `$progress->final` at the end — see
`refs/lms-plugin-tidal/Importer.pm:54-90`. `update`
(`Slim/Utils/Progress.pm:193-252`) writes the `progress` table at most every
`UPDATE_DB_INTERVAL` = 5 s unless `every` is set, and in the scanner also
posts to the server over HTTP on the same throttle.

**What the user sees.** `rescanprogressQuery`
(`Slim/Control/Queries.pm:3233-3283`) reads `progress` rows of type
`importer` and renders each as a named step with a percentage;
`serverstatusQuery` (`:3720-3730`) shows the active one. The step's label is
looked up as a string token: `$request->string($name . '_PROGRESS')`, and
`Slim::Utils::Strings::string` upper-cases (`Slim/Utils/Strings.pm:525-536`).
So `name => 'plugin_squeezewax_match'` requires a
`PLUGIN_SQUEEZEWAX_MATCH_PROGRESS` token in `strings.txt` — the same
convention as `PLUGIN_TIDAL_ALBUMS_PROGRESS`
(`refs/lms-plugin-tidal/strings.txt:188`). Set `total` before the loop, pass
the album title to `update`, and call `final`.

`Slim::Music::Import` frames it either side at `$log->error` on the
`scan.import` category — "Starting %s scan" (`:578`) and "Completed %s Scan
in %s seconds" from `endImporter` (`:710-712`) — which appear in `scanner.log`
at default levels.

**Decision on levels.** Drop `plugin.squeezewax` to `defaultLevel => 'WARN'`
as part of step 3, rather than deferring it to the pre-release TODO item.
The reason INFO was right in step 2 no longer holds: the visible
healthy-run signal was our own handful of lines *because there was nothing
else*. There is now a named row in the scan progress UI and LMS's own
start/complete pair in `scanner.log`, neither of which needs the category
turned up. Leaving INFO on while adding per-album work is how a plugin
quietly starts writing a line per album into everyone's log. WARN also
matches both reference plugins (`refs/lms-plugin-tidal/Plugin.pm:18-22`,
Spotty likewise).

Allocation:

| Level | Content |
|---|---|
| `error` | Nothing new. Schema failures already use `logError`. |
| `warn` | Conflicting tag values on one album (with the album title and every competing value); a configured tag whose value does not parse; the importer skipping the whole run because `Schema->isReady` is false. |
| `info` | One line at start (`N albums, M already matched, K to examine`) and one at end (`matched N, conflicts M, no tag K`). Schema's existing `ready` line stays here. |
| `debug` | Per-album: key, chosen track URL, tag keys found, parsed ID, decision. |

Two INFO lines and a bounded number of WARNs per scan is a category a user
can safely turn up to INFO on a 5,000-album library without regretting it.
Ticks the TODO housekeeping item.

## 5. Commit cadence and abort

**Cadence.** Given finding 2a, our writes ride LMS's transaction, and the
next guaranteed commit after our first write is `endImporter`
(`Slim/Music/Import.pm:716`) at the end of `startScan`. On a large library
that is the entire run's work in one commit, and an abort halfway loses all
of it. So call `Slim::Schema->forceCommit` on a counter — **every 200
albums** — and rely on `endImporter` for the tail. 200 is the same order as
`Scanner::Local`'s per-chunk commits and keeps worst-case lost work to a few
seconds of tag reading. This is safe to do from a `post` importer: it commits
whatever earlier `post` importers left pending as well, which is exactly what
`endImporter` does after each of them anyway.

**Abort.** There is no `abortScan` equivalent to call from inside a scanner
importer, and the obvious candidate is a trap. `Slim::Music::Import->hasAborted`
(`:242`) reads `$ABORT`, and `$ABORT` is only ever set true in `abortScan`
(`:227-241`), whose callers are all server-side —
`Slim/Web/Pages/Progress.pm:22`, `Slim/Web/Settings/Server/Status.pm:27`,
`Slim/Web/Settings/Server/Wizard.pm:172`,
`Slim/Control/Commands.pm:50`. In the scanner process `hasAborted()` is
always false. Checking it there would look right and do nothing.

The real mechanism rides the progress notification.
`Slim::Utils::Progress::update` calls
`$sqlHelperClass->updateProgress(...)` (`Slim/Utils/Progress.pm:243-244`);
`Slim::Utils::SQLiteHelper::updateProgress` posts to the server
(`:404-441`), and if the reply contains `abort` it clears progress, writes a
`SCAN_ABORTED` progress row and **`exit`s the scanner process outright**
(`:443-460`). The server-side half is `_notifyFromScanner`
(`:588-594`), which answers `abort => 1` when `hasAborted` is set.

So: calling `$progress->update` once per album is the whole abort
implementation — nothing to check, nothing to return. The consequence is the
one that drives the cadence above: the process exits without committing, and
DBI rolls back the open transaction, so everything since the last
`forceCommit` is lost. Nothing is corrupted; the work is simply redone next
scan.

## 6. Tag-name detection from a Settings page

**Reading tags is real and works in both processes.**
`Slim::Formats->readTags($url)` (`Slim/Formats.pm:153`) takes a file URL or a
path, returns a hashref of tag names to values, and is what
`Slim::Schema::_newTrack`/`updateOrCreate` call during a scan
(`Slim/Schema.pm:1694`, `:1997`). The `%tagCache` in that file
(`Slim/Formats.pm:151`, `:295`, `:338-346`) is a bounded value-normalisation
cache, not a per-file one, so nothing accumulates per album.

(Decisions §3 cites `CustomTagImporter/Common.pm:492` for this. That plugin
is not in `refs/`, so I could not re-verify it; `Slim/Schema.pm:1694` is an
in-tree citation for the same API and should replace it.)

**Triggering work from a settings page.** `Slim::Web::Settings::handler`
(`Slim/Web/Settings.pm:135-...`) is passed
`($class, $client, $params, $callback, $httpClient, $response)`; a plugin
overrides `handler`, acts on its own `$params` keys, then delegates to
`SUPER::handler` — `refs/lms-plugin-tidal/Settings.pm:20-51` is the pattern.
`Slim/Web/Settings/Server/Plugins.pm:49,138` shows the async form, where the
handler returns without a page and calls `$callback->(...)` later.

**Can it run in the server without blocking the event loop?** Not if done
inline — a sample of albums means that many synchronous file reads, and cold
files on a spinning disk will stall the loop. Do not use the async-callback
form either: that holds the HTTP request open for the duration.

Use `Slim::Utils::Scheduler::add_task` (`Slim/Utils/Scheduler.pm:53-67`),
whose documented contract is a sub that "works on the task incrementally,
returning 1 when it has more work to do, 0 when finished", run only when the
server would otherwise be idle, with a `BLOCK_LIMIT` of 0.01 s (`:39`). It is
what `Slim::Music::VirtualLibraries` uses for exactly this shape of work in
the server process (`Slim/Music/VirtualLibraries.pm:430`). The button starts
the task and re-renders immediately with "detection running"; each tick reads
one album's tags and returns 1; the last tick stores the result and returns
0. The page shows the stored result on the next render.

**The list pref.** Decisions §3 wants an ordered arrayref pref, with
`mediadirs` named as precedent. The mechanism is worth citing exactly,
because `Slim::Web::Settings`'s generic `prefs()` path only handles scalars:
core edits a list with **indexed form fields** assembled by the plugin's own
handler — `for (my $i = 0; defined $paramRef->{"pref_mediadirs$i"}; $i++)`,
push, then `$prefs->set('mediadirs', \@paths)`
(`Slim/Web/Settings/Server/Basic.pm:88-121`, `:137-139` for the render side).
Our tag-name list follows that shape exactly, so `discogsTagNames` stays out
of the `sub prefs` list and is handled in our `handler`.

---

# Plan — six commits

Each is independently reviewable and leaves the tree loadable.

### Commit 1 — `Schema.pm`: detect an already-attached schema explicitly

Closes the TODO item. Today `postDBConnect` gets the right outcome from a
repeat call only by accident.

While confirming the fix I found the TODO's stated mechanism is wrong, which
changes what the fix has to do. `Slim/Schema.pm:273-275` sets
`RaiseError => 1, PrintError => 0`, so a duplicate `ATTACH` would **die**
("database squeezewax is already in use", reproduced), be caught by our
`eval`, and mark the plugin unusable — not be silently swallowed on the way
to a successful pragma read-back. The observed pair of *successful* firings
is better explained by two genuine connections:
`addPostConnectHandler` (`Slim/Utils/SQLiteHelper.pm:390-402`) does
`Slim::Schema->disconnect; Slim::Schema->init` on the **first** registration
of each handler, `disconnect` clears `$initialized` (`Slim/Schema.pm:324-331`)
so `init` reconnects, and `postConnect` runs once per `_connect`
(`Slim/Schema.pm:283`). `Slim::Plugin::FullTextSearch::Plugin` registers a
handler of its own (`Slim/Plugin/FullTextSearch/Plugin.pm:199`) *before* its
`return if main::SCANNER`, and its `install.xml` declares both `<module>` and
`<importmodule>` — so it does this in both processes. Two plugins, two
forced reconnects, two firings a few ms apart, each with a different `$dbh`.

The fix is the same either way and makes both readings moot:

- Before `ATTACH`, read `SELECT name, file FROM pragma_database_list`
  (verified against 3.50.6) and look for `squeezewax`.
- Not present → attach as now.
- Present with the same file → skip the `ATTACH`, continue to the pragma and
  version checks unchanged, and log the skip at debug.
- Present with a *different* file → `die` with both paths. That is a real
  fault we currently have no way to see.

No behaviour change on the healthy path; the log line stays.

### Commit 2 — migration 2 and `Plugins::SqueezeWax::Library`

`_migration_1` stays untouched; append `_migration_2` to `@MIGRATIONS`
(`SCHEMA_VERSION` is `scalar @MIGRATIONS`, so it becomes 2 automatically):

```sql
ALTER TABLE squeezewax.discogs_match ADD COLUMN source_timestamp INTEGER;
```

Holds `MAX(tracks.timestamp)` over the album's qualifying tracks at match
time. This is what makes design §3's "its tags changed since the last scan"
trigger work offline, per finding 3, and it is the same column the
step-4 "examined and found nothing" record will need.

New module `SqueezeWax/Library.pm` — everything that reads LMS's own tables,
raw SQL on `Slim::Schema->dbh`, no DBIC, no Track objects
(`Slim/Utils/Scanner/API.pm:37-38`). Modelled on
`Slim/Plugin/FullTextSearch/Plugin.pm:547-556`.

One streaming query instead of step 2's per-album form, to avoid N+1 over a
whole library:

```sql
SELECT t.album, t.urlmd5, t.url, t.timestamp, t.disc, t.tracknum
  FROM tracks t
 WHERE t.album IS NOT NULL
   AND t.audio = 1
   AND t.content_type NOT IN ('cpl','src','ssp','dir')
 ORDER BY t.album, t.urlmd5
```

Predicate is unchanged from step 2's finding 1 (`Slim/Control/Queries.pm:4811`).
`ORDER BY t.album, t.urlmd5` yields the same per-album `urlmd5` ordering as
`WHERE album = ? ORDER BY urlmd5`, so the digest is byte-identical to the
per-album form — `urlmd5` is `char(32)` with no `COLLATE`
(`SQL/SQLite/schema_16_up.sql:42`), so it sorts BINARY and LMS's ICU
collation machinery (`Slim/Utils/SQLiteHelper.pm:165-207`) never applies.

Per album, in one pass: `md5_hex(join('', @urlmd5))` via `Digest::MD5`
(LMS's own convention, `Slim/Utils/SQLiteHelper.pm:25`); `max(timestamp)`;
and the two lowest tracks by `(disc, tracknum, url)` kept as the primary and
fallback read candidates — the tuple, not the `urlmd5` order, so "first
track" means the first track.

**Zero qualifying tracks yields no key.** In this shape that is not a guard
to remember but a property of the query: an album with no qualifying tracks
produces no rows and is never emitted, so `md5_hex('')` cannot be reached.
Note it in the comment anyway, alongside the `CHECK(length(album_key) = 32)`
that backstops it, since a future caller might reintroduce the per-album
form.

Also here: `sample_albums($n)` for the detection action — the same iteration
capped at `$n`, spread across the library rather than the first `$n` album
ids, so a mixed FLAC/MP3 library is actually sampled.

### Commit 3 — `Plugins::SqueezeWax::Tags`: the pref and the parser

Pref namespace `plugin.squeezewax`, `$prefs->init({ discogsTagNames => [] })`.
Empty by default — decisions §3 chose detection over guessed defaults, and a
guessed default that silently matches nothing is the failure mode it was
choosing against.

Parser, one for all configured tags, per decisions §3:

- bare digits — `123456`
- a release URL — `.../discogs.com/release/123456-Some-Title` (also
  `/releases/`, also with a `www.` or locale prefix)
- `[r123456]` markup
- value may be a **scalar or an arrayref**. Both shapes are real and neither
  is normalised centrally: `MUSICBRAINZ_ID` is unwrapped in
  `Slim/Formats/MP3.pm:343-351`, `DATE` in `Slim/Formats/FLAC.pm:249-256`.
  Anything not on that short list arrives however the reader left it.
- lookup is case-insensitive on the key, because the same tag reaches LMS as
  `MUSICBRAINZ_ALBUMID` from FLAC (`Slim/Formats/FLAC.pm:50`) and
  `MUSICBRAINZ ALBUM ID` from MP3 (`Slim/Formats/MP3.pm:46-49`).

Returns a decision, not a number: `{ id => ..., tag => ..., conflict => [...] }`.

- one configured tag hits, parses → `id`
- several hit, all parse to the **same** id → `id` (agreement, not conflict)
- several hit, parsing to **different** ids → conflict
- a hit that does not parse at all → conflict

Also captures the neighbouring master-release and artist ids while the tag
hash is in hand (decisions §3) — free, and it saves a re-read for §6 and the
v3 artist badge. Stored in `discogs_master_id`, which already exists;
the artist id has no column in migration 1 and is **not** added here — it has
no reader until v3, and step 2's finding 8 is the precedent for not carrying
columns nothing reads.

Pure functions, no LMS calls beyond `readTags` — this is the part
`scripts/syntax-check.sh` and an offline test can exercise directly.

### Commit 4 — `Settings.pm` and the detection action

`SqueezeWax/Settings.pm` + `HTML/EN/plugins/SqueezeWax/settings.html`,
registered from `Plugin.pm` under `if (main::WEBUI)` as
`refs/lms-plugin-tidal/Plugin.pm:60-66` does. Page path
`plugins/SqueezeWax/settings.html` per CLAUDE.md's naming rule.

- The tag-name list renders and saves as indexed `pref_discogsTagNames$i`
  fields assembled in our own `handler`, per finding 6
  (`Slim/Web/Settings/Server/Basic.pm:88-121`).
- A "Detect tag names" button starts a `Slim::Utils::Scheduler::add_task`
  worker over `Library::sample_albums(50)`, one album per tick, and
  re-renders immediately.
- The worker reads each sample album's primary track with
  `Slim::Formats->readTags`, and records every tag key whose value looks like
  a Discogs ID or URL — using the same parser as commit 3, so the report
  cannot disagree with what matching will later accept.
- Result is a count per tag key, plus the sample size and the format mix, held
  in a package variable and rendered as tickboxes that append to the list.
  This doubles as the coverage report decisions §3 asks for.
- Refuse to start while `Slim::Music::Import->stillScanning` is true and say
  so — reads would be fine, but the page invites the user to save afterwards,
  and finding 2b says that write would fail.

### Commit 5 — `Importer.pm`: registration and the Strict pass

`initPlugin` gains, after the existing `Schema->init`:

```perl
Slim::Music::Import->addImporter( $class, {
    type   => 'post',
    weight => 120,
    use    => 1,
} );
```

`startScan`, guarded `if (main::SCANNER)` as
`refs/lms-plugin-tidal/Importer.pm:22` is:

1. `return` early unless `Plugins::SqueezeWax::Schema->isReady` — log at warn
   with `lastError` and let the scan continue. This is the fail-safe path
   step 2 could not reach on hardware; see verification.
2. `return` early if `discogsTagNames` is empty — nothing to look for. Log at
   info pointing at the detection action.
3. Stream `Library`'s iterator. For each album, compute `album_key`; look up
   `squeezewax.discogs_match` by key; skip when a row exists **and** its
   `source_timestamp` equals the album's current `MAX(tracks.timestamp)`.
4. Otherwise read the primary track with `Slim::Formats->readTags`; if no
   configured tag is present, read the fallback track (one more, never all —
   decisions §3).
5. Write the outcome, then move on. No tag on either track → no row, and the
   album falls through to Structural in step 4.
6. `$progress->update($albumTitle)` per album — which is also the entire abort
   mechanism (finding 5); `Slim::Schema->forceCommit` every 200 albums;
   `$progress->final`; `Slim::Music::Import->endImporter($class)`.

Write path, `SqueezeWax/Match.pm`, so step 5's server-side review queue and
manual re-match can reuse it:

- **Clean hit** → `INSERT ... ON CONFLICT(album_key) DO UPDATE` with
  `discogs_release_id`, `discogs_master_id`, `match_tier = 'strict'`,
  `state = 'confirmed'`, `matched_at`, `lms_album_id`, `source_timestamp`,
  and the four `snapshot_*` columns. Auto-confirm is what design §3 specifies
  for Strict.
- **Conflict** → same row shape but `state = 'candidate'`, and a warn line
  naming the album and every competing value. Decisions §3 is explicit that
  disagreement is not Strict and goes to the review queue, so this must not
  be first-wins and must not fall through to Structural. See the open
  question below about what the row should carry.
- Never `DELETE`. Re-matching an album whose key is unchanged updates in
  place; an album whose key changed leaves the old row for orphan recovery,
  which is already a TODO item and is step 5's business.

### Commit 6 — logging levels, docs, TODO

- `defaultLevel => 'WARN'` in both `Plugin.pm` and `Importer.pm` (they must
  match), with the comment rewritten to the finding-4 reasoning rather than
  the step-2 one it replaces.
- `strings.txt`: `PLUGIN_SQUEEZEWAX_MATCH_PROGRESS` plus the settings-page
  tokens.
- `docs/squeezewax-v1-decisions.md`: §2 gains finding 2b (the write lock) and
  the WAL cross-database atomicity caveat; §3's `CustomTagImporter` citation
  is replaced with `Slim/Schema.pm:1694`; §6's open handover question is
  closed with finding 3.
- `docs/squeezewax-design.md` §8: state that scan-time resumability rides
  LMS's own commit cadence plus our 200-album `forceCommit`, and that
  server-side writes are unavailable during a scan.
- `TODO.md`: tick `addImporter`, the `postDBConnect` double-fire, the
  configurable tag names item, the handover open question, and the
  `defaultLevel` housekeeping item; add the new items listed at the end.
- Copy this plan to `plans/build-order-step-3-*.md`, matching the step-2
  precedent.

---

# Verification on a real server

Step 2's untestable branch is now reachable, because the importer does
something whose absence is visible.

**Scanner fails safely — missing database.** With the server running, rename
`squeezewax.db` in the prefs directory (the server's open handle keeps the
inode, so the server is unaffected), then trigger a rescan from the web UI.
The forked scanner attaches a *new, empty* file, `_checkVersion` sees version
0 and dies, `isReady` goes false, and the expected result is: a warn line in
`scanner.log`, no SqueezeWax row in the scan progress UI, and a scan that
completes normally. Then stop the server, delete the empty file, restore the
original.

**Scanner fails safely — version skew.** Cheaper and non-destructive: with no
scan running, `sqlite3 squeezewax.db 'PRAGMA user_version = 99'` from a third
connection, trigger a rescan, expect the same three observations, then set it
back. This exercises the downgrade guard specifically.

**Detection.** Settings → Detect tag names on a library with known Discogs
tags. Expect the real tag key with a plausible count, and — on a mixed
library — the FLAC and MP3 spellings reported separately, which is the whole
reason decisions §3 wanted a list rather than one name.

**Strict end to end.** Tick the detected tag, save, full rescan. Expect a
`PLUGIN_SQUEEZEWAX_MATCH_PROGRESS` step in the scan UI, then:

```
sqlite3 squeezewax.db \
  "SELECT match_tier, state, COUNT(*) FROM discogs_match GROUP BY 1,2;"
```

**Rescan is cheap.** Immediately rescan again with nothing changed. Expect
the same row count, the same `matched_at` values, and the info line reporting
almost everything already matched — that is the `source_timestamp` skip
working.

**Tag-change trigger.** Edit the Discogs tag on one album's files to a
different valid release id, rescan, confirm that one row's
`discogs_release_id` and `matched_at` moved and no other row did.

**Conflict.** Configure two tag names and write different ids into them on
one album. Expect `state = 'candidate'` for that album and a warn line naming
both values.

**Abort.** Start a full rescan on a library big enough to take a minute and
hit abort in the scan-progress UI. Expect the scanner to exit, no
corruption, a partial set of rows corresponding to the last 200-album commit
boundary, and a following rescan that completes the rest.

**Album-id stability** (already a TODO item, cheap to fold in here): record
`lms_album_id` for a few rows, rescan, compare; then edit an album title and
rescan again. `album_key` must not move in either case.

---

# Questions for the design chat

```
Step 3 (Strict tier) — two things I'd rather you settled than I decided:

1. A conflicting tag row. decisions §3 says two configured tags with
   different IDs (or a value that doesn't parse) goes to the review
   queue, not first-wins. discogs_match has nowhere to record what the
   competing values were: match_tier is NOT NULL and CHECKed to
   strict/structural/fuzzy/manual, and there's one discogs_release_id
   column. My interim is match_tier='strict', state='candidate',
   discogs_release_id = the highest-precedence tag's ID, with the
   conflict logged at WARN — the row's existence plus 'candidate' is
   what stops auto-confirm and puts it in the queue, and step 5 can
   re-read the tags to show the alternatives. Alternatives: a
   conflict_note TEXT column; or a fifth match_tier value; or write no
   row and let it fall through to Structural (which contradicts §3).
   Which?

2. An "examined, found nothing" record. Right now an album with no
   Discogs tag gets no row, so every rescan re-reads one or two of its
   files forever. Tolerable at step 3 (it's disk, not API). Not
   tolerable at step 4, where the same albums would re-run a Discogs
   search every scan. Options: a separate regenerable table
   (album_key, tier_attempted, source_timestamp, checked_at); or a
   nullable discogs_release_id row in discogs_match with a new tier
   value like 'none'. I lean to the separate table — it's regenerable,
   and it keeps discogs_match meaning "there is a match". Do you want
   it defined now (so step 3 writes it and step 4 just reads it), or
   deferred to step 4?
```

---

# TODO.md additions

- **Server-side writes are impossible during a scan.** `BEGIN IMMEDIATE`
  (`sqlite_use_immediate_transaction`, `Slim/Utils/SQLiteHelper.pm:358`)
  locks every attached database, so the scanner holds a write lock on
  `squeezewax.db` for the whole scan. Reads are unaffected. Any server-side
  write path (review queue, manual re-match, collection sync) must refuse
  while `Slim::Music::Import->stillScanning`, with a message rather than a
  lock error.
- **`ANALYZE` and the new column.** `schema_optimize.sql`'s unqualified
  `ANALYZE` already writes `sqlite_stat1` into our file (decisions §2). Check
  after the first post-migration-2 scan that nothing else changed.
- **"Examined, found nothing" record** — blocked on the design answer above;
  becomes load-bearing at step 4, not step 3.
- **Single-directory rescans skip the importer.** `runScanPostProcessing` is
  only reached from `scanner.pl:348`, so an in-server
  `Slim::Utils::Scanner::Local::rescan` never runs `post` importers. Decide
  before v1 whether that needs the `Scanner::API` track hooks after all, or
  whether "the next full rescan picks it up" is good enough.
- **Artist ID has no column.** Captured by the parser for free but currently
  discarded. Add the column in the v3 artist-badge work, not before.
