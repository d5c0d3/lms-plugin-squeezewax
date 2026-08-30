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

**Citation provenance.** Line numbers below are from this repo's
`refs/slimserver/` (branch `public/9.1`). An independent re-check against a
fresh `LMS-Community/slimserver` clone at `public/9.1` commit `a670a38c`
(2026-06-19) confirmed findings 1, 2b, 3, 4, 5 and 6 by symbol. Every citation
re-tested matched exactly; line numbers *may* drift between checkouts, so
locate by symbol as step 2 concluded, but no drift was actually observed. Three corrections from that re-check are
folded in: the weight table gained a second entry at 100, `BLOCK_LIMIT` is
`Scheduler.pm:49`, and `abortScan` has a fifth caller.

A second round then resolved two claims in the other direction, both
re-verified here against `refs/`:

- **"`runImporter` logs unconditionally" is withdrawn.** The
  `$log->error("Starting $importer scan")` line is inside
  `if ($Importers{$importer}->{'use'})` (`Slim/Music/Import.pm:573-579`),
  which is *why* gating `use` silences an unconfigured install rather than
  merely tidying it.
- **Correction 4's mechanism was wrong twice and has been re-derived.** An
  earlier revision of this plan claimed `Slim/Formats.pm:261` sits inside the
  `isSong && !$remote` guard, and that `readTags` returns `{}` for a remote
  URL. Both are false. Verified by **brace depth**, not line number: the guard
  opens at `:173` (depth 1) and closes at `:243` (depth 1); `if (-e $filepath)`
  at `:259` is its *sibling*; `:267` closes the `LEADING_MDAT` block; `readTags`
  returns at `:280`. The conclusion — remote rows have NULL `timestamp` —
  survives; the reasoning is replaced. Stated once, in commit 2; not restated
  here.

  **Method note, and the reason this slipped:** the bad check grepped a window
  that began *after* the guard's closing brace and took the first `}` it found.
  Line numbers drift between checkouts and brace depth does not, so structural
  claims about `refs/` are to be settled by depth.

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
`$Importers{$importer}->{use}` is true — so a `use` value is not optional.
Note also that the `$log->error("Starting $importer scan")` line sits
*inside* that `use` guard, which is what makes gating `use` (commit 5) the
way to keep an unconfigured install silent.

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
| 100 | `Slim::Plugin::OnlineLibrary::Importer` | `Slim/Plugin/OnlineLibrary/Importer.pm:41-46` |
| 110 | `...OnlineLibrary::Importer::VirtualLibrariesCleanup` | `Slim/Plugin/OnlineLibrary/Importer.pm:30-35` |

(That second weight-100 entry passes `onlineLibraryOnly => 1`, which is a
`runScan`-only filter and is simply ignored in the `post` pass. It does not
move our number.)

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
(`Slim/Music/Import.pm:716`).

**Inferred, not proven:** that there is no rollback anywhere in the scan
path. It comes from reading the scan path and finding no `->rollback` call,
which is absence-of-evidence over a large surface — `scanner.pl`,
`Slim/Music/Import.pm`, `Slim/Utils/Scanner/*`, plus anything a third-party
importer does on the same connection. Design §8's resumability promise leans
on it, so it is flagged rather than asserted. If it is ever falsified, the
consequence is bounded: a rollback would discard our uncommitted matches
along with LMS's uncommitted scan work, and the next scan would redo both.

Given that, an interrupted scan does not discard already-committed matches
and §8's promise holds. What we still owe is a cadence
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

→ TODO's "Scanner→server handover for the re-match trigger" is **re-scoped,
not closed**, by this reasoning rather than by choosing one of its two
options. The half that blocked step 3 — the importer — needs no handover.
The half that remains open is immediate re-match on a single-directory
rescan, which never reaches `runScanPostProcessing`. The track-level
`Scanner::API` hooks are still the right mechanism there; they are not
needed for the importer.

## 4. Progress reporting and logging volume

**What a real importer does.** `Slim::Utils::Progress->new({ type =>
'importer', name => ..., total => ... })`, `$progress->update($info)`
per item, `$progress->final` at the end — see
`refs/lms-plugin-tidal/Importer.pm:54-90`.

**Do not pass `every`.** `update` (`Slim/Utils/Progress.pm:193-252`) puts the
`progress` table write *and* the scanner→server HTTP POST inside one
`if ($self->dball || $now > $self->dbup + UPDATE_DB_INTERVAL)` guard
(`:221-245`), where `dball` is the `every` flag and `UPDATE_DB_INTERVAL` is
5 s (`:17`). Setting `every` makes both per-item — 5,000 synchronous
`LWP::UserAgent` round-trips to the server on a 5,000-album library. The
5-second throttle is also what bounds abort latency (finding 5): abort is
noticed on the next throttled POST, so up to ~5 s after the user clicks. That
is intended, and the comment should say so, or someone will later "fix" the
latency by adding `every`.

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
| `warn` | Conflicting tag values on one album (with the album title and every competing value); a configured tag whose value does not parse; the importer skipping the whole run because `Schema->isReady` is false; **and the end-of-run summary when `matched == 0 && examined > 0`.** |
| `info` | One line at start (`N albums, M already matched, K to examine`) and one at end (`matched N, conflicts M, no tag K`). Schema's existing `ready` line stays here. |
| `debug` | Per-album: key, chosen track URL, tag keys found, parsed ID, decision. |

Two INFO lines and a bounded number of WARNs per scan is a category a user
can safely turn up to INFO on a 5,000-album library without regretting it.
Ticks the TODO housekeeping item.

**The `matched == 0` escalation is the point of the whole level scheme.**
A mistyped tag name produces "matched 0 of 4,800" and nothing else: LMS's own
start/complete pair reports that the importer ran and how long it took, never
what it achieved, and at WARN our own summary is invisible. That is exactly
the silent failure decisions §3 chose detection-over-guessed-defaults to
avoid, and the detection action cannot catch it because the user can save any
string they like afterwards. So the summary escalates to `warn` in that one
case. `examined > 0` is part of the condition deliberately: a library where
everything is already matched examines nothing and matches nothing, and must
stay quiet.

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
(`:227-241`), whose five callers are all server-side —
`Slim/Web/Pages/Progress.pm:22`, `Slim/Web/Settings/Server/Status.pm:27`,
`Slim/Web/Settings/Server/Wizard.pm:172`, `Slim/Control/Commands.pm:50`
(dispatched as `abortscan`, `Slim/Control/Request.pm:474`), and
`slimserver.pl:1049` on shutdown. In the scanner process `hasAborted()` is
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
server would otherwise be idle, with a `BLOCK_LIMIT` of 0.01 s (`:49`,
enforced at `:192`). It is
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

Two is not a constant, though, and the fix should not assume it is: the guard
is `$postConnectHandlers{$handler} == 1` **per handler**, so the firing count
is one for the initial `init` plus one for every distinct handler that
registers after us — today FullTextSearch, tomorrow any plugin the user
installs. The idempotent attach makes the number irrelevant, which is the
point of doing it rather than reasoning about the count.

The fix is the same either way and makes both readings moot:

- Before `ATTACH`, read `SELECT name, file FROM pragma_database_list`
  (verified against 3.50.6) and look for `squeezewax`.
- Not present → attach as now.
- Present with the same file → skip the `ATTACH`, continue to the pragma and
  version checks unchanged, and log the skip at debug.
- Present with a *different* file → `die` with both paths. That is a real
  fault we currently have no way to see.

No behaviour change on the healthy path; the log line stays.

### Commit 2 — migration 2, `Plugins::SqueezeWax::Library`, decision record §2a

Carries **§2a only** into `docs/squeezewax-v1-decisions.md`, verbatim from
Appendix A — it is a schema record and this is the schema commit. §3a moves
to commit 5, where `Match.pm`'s write path lives: its only schema content is
"the column stays nullable", which migration 1 already settled, and a
behavioural record landing one commit ahead of the code it governs means
`git log` on `Match.pm` never reaches it. (The earlier "same commit as the
DDL" reading came from the step-2 precedent, where the doc edits and the DDL
were one resolution. Here they are not.)

First commit to touch `docs/`, so it triggers the claude.ai sync reminder.

`_migration_1` stays untouched; append `_migration_2` to `@MIGRATIONS`
(`SCHEMA_VERSION` is `scalar @MIGRATIONS`, so it becomes 2 automatically).

```sql
ALTER TABLE squeezewax.discogs_match ADD COLUMN source_timestamp INTEGER;
```

Holds `MAX(tracks.timestamp)` over the album's qualifying tracks at match
time. This is what makes design §3's "its tags changed since the last scan"
trigger work offline, per finding 3.

Same migration, the negative-result table (answer 2 from the design chat):

```sql
CREATE TABLE IF NOT EXISTS squeezewax.discogs_no_match (
    album_key        TEXT    NOT NULL
                             CHECK (length(album_key) = 32),
    tier             TEXT    NOT NULL
                             CHECK (tier IN ('strict','structural')),
    source_timestamp INTEGER,
    checked_at       INTEGER NOT NULL,
    PRIMARY KEY (album_key, tier)
);
```

Composite PK, not `album_key` alone: Strict-negative and Structural-negative
are different facts with very different costs, and step 4 needs to record and
read both independently. `tier` rather than `match_tier`, since this table
records which tier *looked*, not a match's provenance — but it takes the same
CHECK-the-enum treatment for the same reason as `discogs_match.match_tier`
(step 2, finding 9): a typo would otherwise surface as an album silently
re-examined forever, indistinguishable from one never examined. `'fuzzy'` is
deliberately absent; Fuzzy is v2 and adding its value now would assert a
policy nothing has decided.

Kept out of `discogs_match` on purpose. A `'none'` tier there would put
regenerable cache in the one table that is not disposable, and would pollute
the `(state, snapshot_track_count)` orphan index with rows orphan recovery
must never consider. This table is regenerable in full — dropping it costs
re-reads, never a match.

Three things to carry into the code comments:

- **Orphan recovery never reads `discogs_no_match`.** It answers "which local
  album does this existing match belong to", and a no-match row is not a
  match.
- **"Clear & rebuild matches" must clear it too** — see the design §9 edit in
  commit 6. Leaving it behind would make the rebuild skip precisely the
  albums the user asked to reconsider, which is the exact opposite of what
  the action promises.
- **The stitch to §3a**, one line beside the `discogs_no_match` DDL:

  ```
  -- no conflict_note column; conflict rows carry a NULL discogs_release_id,
  -- see §3a.
  ```

  Migration 2 is exactly where someone would otherwise reach for that column,
  so the pointer belongs here even though the record itself lands in commit 5.

New module `SqueezeWax/Library.pm` — everything that reads LMS's own tables,
raw SQL on `Slim::Schema->dbh`, no DBIC, no Track objects
(`Slim/Utils/Scanner/API.pm:37-38`). Modelled on
`Slim/Plugin/FullTextSearch/Plugin.pm:547-556`.

One streaming query instead of step 2's per-album form, to avoid N+1 over a
whole library:

```sql
SELECT t.album, t.urlmd5, t.url, t.timestamp, t.disc, t.tracknum, t.remote
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

**The Perl `max` must skip undef, matching SQL `MAX` semantics.** SQL `MAX`
ignores NULLs; a Perl maximum over a list containing `undef` warns under
`use warnings` and can return the wrong value depending on how it is written.
A mixed local/remote album is exactly where the undefs appear — remote rows
have NULL `timestamp` (see below) — so this is the normal case on any library
with a streaming plugin, not an edge case. Filter first, then take the
maximum; the result is the max over the album's *local* tracks, which is what
the skip logic wants. An album with no local tracks yields `undef`, and is
skipped at Strict for that reason anyway.

**Zero qualifying tracks yields no key.** In this shape that is not a guard
to remember but a property of the query: an album with no qualifying tracks
produces no rows and is never emitted, so `md5_hex('')` cannot be reached.
Note it in the comment anyway, alongside the `CHECK(length(album_key) = 32)`
that backstops it, since a future caller might reintroduce the per-album
form.

**Online-library albums must not be handed to Strict forever.** Streaming
tracks are ordinary `tracks` rows with `audio = 1`, so the predicate above
selects them. **Two independent facts point the same way; do not conflate
them.**

**Fact 1 — `tracks.timestamp` is structurally NULL for remote rows.** The sole
in-tree producer of a `TIMESTAMP` attribute is `Slim/Formats.pm:261`,
`($tags->{'FILESIZE'}, $tags->{'TIMESTAMP'}) = (stat(_))[7,9];`, guarded by
`if (-e $filepath)` at `:259`. For a non-file URL `$filepath = $file`
(`:165`), so `-e 'spotify://…'` is false and the stat never happens. That is
the mechanism — **not** the `isSong && !$remote` guard, which closes at `:243`
and is a sibling of this block, not its parent. (`grep -rn TIMESTAMP
--include=*.pm Slim/` returns `:261` plus `Slim/Formats/Playlists/CUE.pm:80`,
a tag-name whitelist; nothing under `Slim/Plugin/OnlineLibrary*` sets one.
`Slim/Schema.pm:1730-1742` merely copies whatever arrives into matching
`tracks` columns — it explains the copy, not the absence.)

So `MAX(timestamp)` over an all-remote album is NULL, and NULL never compares
equal to a stored value — neither a `discogs_match` row nor a
`discogs_no_match` row could ever cause a skip, and the album would be
re-examined on every scan for the life of the library.

**Fact 2 — `readTags` does *not* return `{}` for a remote URL.** It skips the
tag-reading block, then falls through the "Last resort" `plainTitle` at
`:246-251`, the DISC check, the failed stat, `CONTENT_TYPE ||= $type` at
`:274` and `sanitizeTagValues` at `:278`, returning a **populated** hashref at
`:280` carrying at least `TITLE` and `CONTENT_TYPE`.

`grep -n "return {}" Slim/Formats.pm` finds **four** sites, not three:
`:178`, `:188` and `:208` are inside the guard and unreachable for a remote
URL; `:155` is `my $file = shift || return {};`, outside it, and unreachable
too because a URL is truthy. The conclusion is unaffected — the count is
spelled out because a reader who greps finds four where an earlier draft said
three, and that costs more trust than the clause costs space.

This has teeth for commit 3. **The parser's contract is "none of the
configured keys is present", never "the hash is empty".** `if (!%$tags)` or
`unless (keys %$tags)` can never fire on a remote URL. Commit 5 is still
correct today because commit 2 skips no-local-track albums first — but that
makes the local-track guard load-bearing for a second, non-obvious reason, and
a later cleanup that removes it as redundant would silently break tag
detection. State the contract in the code, not just here.

So the iterator emits `local_track_count` and `remote_track_count` per album;
Strict skips any album with `local_track_count == 0`; and the
primary/fallback track pick prefers a local track.

**Do not put `remote = 0` in the query.** v2's Fuzzy tier exists precisely
for streaming albums with no local file (design §3, walkthrough 4). Filtering
them out at the iterator would have to be undone then; filtering at the
Strict caller is where the decision belongs.

Also here: `sample_albums($n)` for the detection action — the same iteration
capped at `$n`, spread across the library rather than the first `$n` album
ids, so a mixed FLAC/MP3 library is actually sampled, and skipping
no-local-track albums for the same reason.

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

**Carries §3b** into `docs/squeezewax-v1-decisions.md`, verbatim from
Appendix D — the invalidation it describes is Settings-save behaviour, so it
belongs with the code that performs it.

**A save that alters `discogsTagNames` must invalidate the strict answer.**
Both skip caches key on file state alone, and the tag list is not part of that
key — so without this, correcting a wrong tag name changes nothing on the next
scan, and finding 4's `matched == 0 && examined > 0` warning cannot fire
because `examined` is zero. The silent failure the level scheme exists to
catch, reintroduced one layer down with the detector blinded.

On a save that actually changes the list, and only then:

```sql
DELETE FROM squeezewax.discogs_no_match WHERE tier = 'strict';
UPDATE squeezewax.discogs_match SET source_timestamp = NULL
 WHERE match_tier = 'strict';
```

`DELETE` on the regenerable table, `UPDATE` on the other so that no decision is
discarded; NULL never compares equal, so those albums are re-examined next
scan. `match_tier = 'manual'` rows fall outside the predicate by construction.
The `stillScanning` refusal above is what makes both writes safe (finding 2b).
Cost is one cold pass on the next scan — the right price for a rare, deliberate
action. Why `UPDATE` and not `DELETE`, and the three rejected alternatives:
Appendix D.

**Do this in the handler, comparing old and new explicitly — not with
`$prefs->setChange`.** `Slim::Utils::Prefs::Base::set` dispatches onchange on
`... || ref $new`, which is unconditionally true for an arrayref pref, so a
`setChange` callback fires on every save whether the list changed or not, and
every settings save would trigger a full cold re-read pass. The symptom would
be "rescans got slow", which nobody traces back. Full reasoning, and the two
other rejected alternatives, in Appendix D.

### Commit 5 — `Importer.pm`: registration, the Strict pass, decision record §3a

Carries **§3a** into `docs/squeezewax-v1-decisions.md`, verbatim from
Appendix B. It lands here rather than with the schema because it is a
behavioural record about what `Match.pm` writes, and this is the commit that
writes it — so `git log`/`git blame` on `Match.pm` reaches the reasoning.
Migration 2 carries only a pointer comment to it (commit 2).

`initPlugin` gains, after the existing `Schema->init`:

```perl
Slim::Music::Import->addImporter( $class, {
    type   => 'post',
    weight => 120,
    # Not `use => 1`: an unconfigured install has nothing to look for, and
    # runImporter's `$log->error("Starting $importer scan")` plus a progress
    # row sit inside the `use` guard (Slim/Music/Import.pm:573-579). Gating
    # here is the only way to stay silent. Same pattern as
    # Slim/Music/ReleaseTypes.pm:32, which gates on its own pref.
    #
    # Step 4 must relax this: Structural needs no tag names, so the gate
    # becomes "Strict configured OR Structural enabled".
    use    => scalar @{ $prefs->get('discogsTagNames') || [] },
} );
```

`startScan`, guarded `if (main::SCANNER)` as
`refs/lms-plugin-tidal/Importer.pm:22` is:

1. `return 0` early unless `Plugins::SqueezeWax::Schema->isReady` — log at
   warn with `lastError` and let the scan continue. This is the fail-safe
   path step 2 could not reach on hardware; see verification.
2. `return 0` early if `discogsTagNames` is empty. Belt and braces behind the
   `use` gate, for the case where the pref is cleared after registration.
3. Stream `Library`'s iterator. Skip any album with no local tracks
   (commit 2). For each remaining album compute `album_key`, then skip when
   **either** a `discogs_match` row **or** a `discogs_no_match` row for tier
   `'strict'` exists whose `source_timestamp` equals the album's current
   `MAX(tracks.timestamp)`.
4. Otherwise read the primary local track with `Slim::Formats->readTags`; if
   no configured tag is present, read the fallback local track (one more,
   never all — decisions §3).
5. Write the outcome, then move on.
6. `$progress->update($albumTitle)` per album, no `every` — which is also the
   entire abort mechanism (finding 5); `Slim::Schema->forceCommit` every 200
   albums; `$progress->final`; `Slim::Music::Import->endImporter($class)`;
   `return $matched`.

`startScan` returns the match count as an integer. `runImporter` assigns the
return and `runScan` sums it into `$changes` (`Slim/Music/Import.pm:405-406`,
`:580`); the `post` pass discards it, so this is convention rather than
correctness — but returning something meaningful costs nothing and returning
`undef` into an `+=` is the kind of thing the XXX comment at `:403` exists
because of.

Write path, `SqueezeWax/Match.pm`, so step 5's server-side review queue and
manual re-match can reuse it:

- **A `match_tier = 'manual'` row is never overwritten.** This is the first
  thing the write path checks, before anything else. An in-place file change
  that has nothing to do with tags — artwork embedded, ReplayGain written —
  moves `tracks.timestamp` without moving `album_key`, so a manually
  re-matched album *will* be re-examined, and an unguarded UPSERT would
  silently restore the file's original tag over the pressing the user chose:
  no log line, wrong badge, and no way for them to tell what happened.
  On a manual row the importer may refresh `source_timestamp` and
  `lms_album_id` and nothing else, so it stops re-examining it without
  touching the decision. If retagging should ever beat a manual override,
  that is an explicit step-5 mechanism with its own UI, not a side effect of
  an UPSERT.
- **Clean hit** → `INSERT ... ON CONFLICT(album_key) DO UPDATE` with
  `discogs_release_id`, `discogs_master_id`, `match_tier = 'strict'`,
  `state = 'confirmed'`, `matched_at`, `lms_album_id`, `source_timestamp`,
  and the four `snapshot_*` columns. Auto-confirm is what design §3 specifies
  for Strict.
- **Conflict** → `match_tier = 'strict'`, `state = 'candidate'`,
  **`discogs_release_id = NULL`**, and one warn line naming the album and
  every competing value. NULL, not the highest-precedence tag's id: writing
  that id is first-wins under another name, which decisions §3 rejects — the
  candidate flag would stop it *acting*, but the column would still assert a
  release that nothing adjudicated. NULL says what actually happened.
  It is also the durable marker: step 2's finding 9 has the orphan-ambiguous
  branch carrying old values forward, which can itself produce
  `(strict, candidate)` for reasons unrelated to tags, so the pair is not
  distinctive but a NULL release id is. No `conflict_note` column and no
  fifth `match_tier` value in v1 — step 5 re-reads the tags when the queue
  entry is opened, because the tags are the source of truth and a stored note
  goes stale the moment the user edits the file.
- **No tag on either track** → a `discogs_no_match` row for tier `'strict'`
  with the album's `source_timestamp`, so the next scan skips it instead of
  re-reading the same two files. The album still falls through to Structural
  in step 4; that tier consults its own row. **This has no exceptions** — see
  the delete rule below, which is what keeps it unconditional.
- **Deletion is permitted for exactly one row shape**, and only when
  re-examination has found no configured tag:

  ```sql
  DELETE FROM squeezewax.discogs_match
   WHERE album_key = ?
     AND match_tier = 'strict'
     AND state = 'candidate'
     AND discogs_release_id IS NULL
     AND snapshot_track_count IS NULL
  ```

  This is the conflict row from §3a after the user has resolved the conflict
  by removing the tags from the files, or by deconfiguring the tag names.
  Without the delete it survives forever: §3b NULLs its `source_timestamp`,
  the next scan re-examines, no tag is found — and the album sits in the
  review queue advertising a conflict that no longer exists, which step 5
  cannot even render, because §3a deliberately stores no `conflict_note` and
  re-reads the tags to display the entry. There are none left to read. The
  only escape would be "clear & rebuild matches".

  **The rule is not "never delete" with a carve-out. It is: never delete a row
  that carries a decision or a recovery snapshot.** The predicate above is
  that reason written out — `manual` is a decision, `confirmed` is a decision,
  a non-NULL `discogs_release_id` is a proposal something adjudicated, and a
  non-NULL `snapshot_track_count` is orphan recovery's index material (step 2
  finding 9's ambiguous branch carries snapshots forward, which is exactly
  what the last clause excludes). A `(strict, candidate, NULL, NULL)` row is
  none of those: it records only "we looked and could not decide", and once
  the tags are gone it does not even record that truthfully.

  **Stated risk:** narrowing a never-delete rule creates a boundary someone
  can later widen. That is why the predicate is written out in full here and
  in §2a, and why the *reason* — absence of both a decision and a recovery
  snapshot — is named as the test. Anyone proposing to widen it must show
  their case passes that test, not that it resembles this row shape.
- Otherwise never `DELETE` from `discogs_match` — the one permitted shape is
  the predicate above and nothing else. Re-matching an album whose key is
  unchanged updates in place; an album whose key changed leaves the old row
  for orphan recovery, which is already a TODO item and is step 5's business.
  `discogs_no_match` has no such constraint — it is regenerable, so stale
  rows there may be deleted freely.

### Commit 6 — logging levels, docs, TODO

- `defaultLevel => 'WARN'` in both `Plugin.pm` and `Importer.pm` (they must
  match), with the comment rewritten to the finding-4 reasoning rather than
  the step-2 one it replaces.
- `strings.txt`: `PLUGIN_SQUEEZEWAX_MATCH_PROGRESS` plus the settings-page
  tokens.
- `docs/squeezewax-v1-decisions.md`: §2 gains finding 2b (the write lock) and
  the WAL cross-database atomicity caveat, and marks the "no rollback in the
  scan path" claim as inferred; §3's `CustomTagImporter` citation is replaced
  with `Slim/Schema.pm:1694`; §6's open handover question is re-scoped, not
  closed (see below).
- `docs/squeezewax-design.md` §8: state that scan-time resumability rides
  LMS's own commit cadence plus our 200-album `forceCommit`, and that
  server-side writes are unavailable during a scan.
- `docs/squeezewax-design.md` §9: the "clear & rebuild matches" maintenance
  action must clear `discogs_no_match` as well as `discogs_match`.
- `docs/squeezewax-design.md` §10: list `discogs_no_match`, one line noting
  it is regenerable and that orphan recovery must never read it.
- `TODO.md`: tick `addImporter`, the `postDBConnect` double-fire, the
  configurable tag names item, and the `defaultLevel` housekeeping item; add
  the new items listed at the end.
- **Do not tick the scanner→server handover question — re-scope it.**
  Finding 3 closes it for the importer, which is the half that blocked step
  3. The single-directory-rescan half is still open and is already in the
  TODO additions below. Ticking it would lose that.

- Copy this plan to `plans/build-order-step-3-*.md`, matching the step-2
  precedent.

**Neither decision record belongs in commit 6.** §2a ships with the schema in
commit 2, §3a with the write path in commit 5, both verbatim from the
appendices. Commit 6 carries only the doc edits listed above.

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

> **Do not let the server restart while the rename is in place.** This test
> leaves a fresh empty `squeezewax.db` at the real path. On a restart the
> server's own `postDBConnect` would run `_migrate` on it, take it 0 → 2, and
> from then on it is a perfectly valid *empty* database — while every match
> the user has is stranded in the renamed copy, with nothing in the logs
> saying so. Swap back before restarting, or use the version-skew test below
> instead, which has no such window.

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
one album. Expect `state = 'candidate'`, `discogs_release_id IS NULL` for
that album, and a warn line naming both values. Repeat with a single
unparseable value; same expectation.

**Abort.** Start a full rescan on a library big enough to take a minute and
hit abort in the scan-progress UI. Expect the scanner to exit, no
corruption, a partial set of rows corresponding to the last 200-album commit
boundary, and a following rescan that completes the rest.

**Manual match survives a non-tag file change.** Hand-write a
`match_tier = 'manual'` row for one album, then re-embed artwork on one of
its files (moves `tracks.timestamp`, leaves `album_key` alone) and rescan.

This is the step most likely to be waved through, because the failure leaves
a database that looks entirely plausible — a row is present, the tier says
`strict`, the release id is a real release. **The assertion that
discriminates is that `match_tier` is still `'manual'` AND
`discogs_release_id` is unchanged**, not merely that a row exists. Capture
both values before the rescan and diff them after; only `source_timestamp`
and `lms_album_id` may move.

```
sqlite3 squeezewax.db \
  "SELECT album_key, match_tier, discogs_release_id, source_timestamp
     FROM discogs_match WHERE match_tier = 'manual';"
```

**Conflict resolved by removing the tags.** Write two conflicting tag values
into one album's files, rescan, confirm the `(strict, candidate, NULL)` row.
Then strip both tags from the files and rescan. Expect **no `discogs_match`
row** for that album and **one strict `discogs_no_match` row**. Assert the
counts in both tables, not just that the scan completed — this is the branch
where the obvious implementation does the wrong thing, either by refreshing
the conflict row in place (leaving a permanent phantom review-queue entry) or
by writing to both tables (breaching Appendix A invariant 1).

```
sqlite3 squeezewax.db \
  "SELECT (SELECT COUNT(*) FROM discogs_match     WHERE album_key = 'KEY'),
          (SELECT COUNT(*) FROM discogs_no_match  WHERE album_key = 'KEY'
                                                    AND tier = 'strict');"
-- expect: 0|1
```

**Tag-list change invalidates.** Configure a deliberately wrong tag name, full
rescan, confirm `discogs_no_match` has a strict row for most albums and the
`matched == 0` warn fired. Then configure the correct tag name, save, rescan.
Expect the strict no-match rows gone, albums examined, and matches written.

The failure mode is that the second rescan is **instant and silent** — so the
assertion is that the examined count is non-zero, not merely that no error
appeared. A green-looking log is exactly what this test is here to reject.

**Unconfigured install is silent.** With `discogsTagNames` empty, rescan.
Expect no `Starting Plugins::SqueezeWax::Importer scan` line in
`scanner.log`, and no SqueezeWax row in the scan progress UI.

**Online-library albums.** On a box with Spotty or TIDAL installed:

```
sqlite3 library.db \
  "SELECT remote, COUNT(*), COUNT(timestamp) FROM tracks GROUP BY remote;"
```

Expect `COUNT(timestamp)` to be 0 for `remote = 1`, confirming the NULL that
correction 4 turns on. Then rescan twice and check that no streaming-only
album appears in the examined count either time.

**Album-id stability** (already a TODO item, cheap to fold in here): record
`lms_album_id` for a few rows, rescan, compare; then edit an album title and
rescan again. `album_key` must not move in either case.

---

# Design-chat answers — both settled

Both questions this plan opened were answered before implementation started;
the answers are folded into commits 2 and 5 above rather than left here.

1. **Conflicting tag row** — `match_tier = 'strict'`, `state = 'candidate'`,
   `discogs_release_id = NULL`. No `conflict_note` column, no fifth
   `match_tier` value in v1. Reasoning is in commit 5's write-path section.
2. **Examined, found nothing** — separate `discogs_no_match` table, defined
   now in migration 2, PK `(album_key, tier)` with `tier` CHECKed to
   `('strict','structural')`. Reasoning and DDL are in commit 2.

The verbatim text has arrived and is held in this document so implementation
never has to go back to the chat for it:

| Record | Appendix | Ships in |
|---|---|---|
| §2a — `discogs_no_match` | A | Commit 2 |
| §3a — conflicting Discogs tags | B | Commit 5 |
| `TODO.md` additions | C | Commit 6 |
| §3b — tag-name changes invalidate strict | D | Commit 4 |

**All four are to be pasted exactly as written — do not reword, re-wrap or
re-order them.**

---

# TODO.md additions — mine, from the planning session

These are the `TODO.md` items that originated here rather than in the design
chat. Three are now duplicates of Appendix C entries and are marked
**superseded**: for those three, write Appendix C's version and drop mine —
not because one arbitrates the other, but because two entries for one fact in
`TODO.md` is the defect the working agreement's §2 rule names.

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
- ~~**"Examined, found nothing" record** — blocked on the design answer.~~
  **Resolved**, not superseded: it is `discogs_no_match`, defined in
  migration 2. Drop; do not write to `TODO.md`.
- ~~**Single-directory rescans skip the importer.**~~ **Superseded** by
  Appendix C's "Scanner→server handover — re-scoped, not closed", which says
  the same thing and is correctly filed under *Open design questions*.
- **Artist ID has no column.** Captured by the parser for free but currently
  discarded. Add the column in the v3 artist-badge work, not before.
- **"No rollback in the scan path" is inferred, not proven.** Design §8's
  resumability promise leans on it. Worth one targeted check if a cheap one
  presents itself — a rollback would discard our uncommitted matches with
  LMS's uncommitted scan work, which is recoverable but changes what §8 can
  promise.
- ~~**Relaxing the `use` gate at step 4.**~~ **Superseded** — Appendix C's
  "Gate `use =>` on a non-empty `discogsTagNames`" already carries
  "**Step 4 must relax this**" in the same item.
- **v2 triage page must distinguish "unparseable tag" from "tags disagree".**
  Both write `(strict, candidate, NULL)` in v1, which is correct for v1 —
  neither is a match — but they are different user actions (fix one file's
  tag vs. decide between two). Recorded, not designed. **Keep this one** —
  Appendix C has no equivalent, so it is the only record of that v2 item.
- ~~**Structural no-match staleness policy.**~~ **Superseded** by
  Appendix C's item of the same name under *Open design questions*.

---

# Appendices — verbatim source text

Everything below is the design chat's own wording, reproduced exactly.
**Paste as-is.** Do not reword, re-wrap, renumber or merge with the
working-out above.

There is deliberately **no precedence rule** here. An earlier revision said
"if the body and an appendix disagree, the appendix is correct", which was a
mistake: when the correction-4 error appeared in the body *and* in Appendix C
in near-identical wording, the appendix was not more correct — it was a third
copy, and one fix became three. Precedence rules make duplication survivable
instead of removing it. Per the working agreement's §2, a disagreement between
two documents is a defect to delete, not to arbitrate. So the body states each
fact once and the appendices carry only text bound for a *different file*
(`docs/squeezewax-v1-decisions.md`, `TODO.md`). If you find the body
paraphrasing an appendix, cut the paraphrase.

## Appendix A — §2a, into `docs/squeezewax-v1-decisions.md`, commit 2

## 2a. `discogs_no_match` — the examined-and-found-nothing record

**Decided 2026-08-29 (design chat), during build-order step 3 planning.**

Migration 2 adds a second table alongside `discogs_match.source_timestamp`:

```
discogs_no_match
  album_key        TEXT NOT NULL CHECK (length(album_key) = 32)
  tier             TEXT NOT NULL CHECK (tier IN ('strict','structural'))
  source_timestamp INTEGER
  checked_at       INTEGER NOT NULL
  PRIMARY KEY (album_key, tier)
```

A row means: this tier was attempted for this album at this source state and
produced no candidate.

### Why a row at all

Without one, an album with no Discogs tag gets nothing written, so every
rescan re-reads one or two of its files forever. At step 3 that is disk
rather than API — but LMS reads *no* audio files on a no-change rescan, so
we would be adding one read per unmatched album where there were none. On a
mostly-untagged 5,000-album library on slow storage that is minutes per
rescan for no result. At step 4 the same albums would re-run a Discogs
search every scan, which is not merely slow.

### Why a separate table rather than a `'none'` tier in `discogs_match`

Three reasons, in order of weight:

- `discogs_match` is the one table that is **not** disposable (§2, design
  §10). Negative rows are pure regenerable cache; mixing them in couples
  cache lifetime to durable state.
- They would pollute the `(state, snapshot_track_count)` orphan-recovery
  index, whose whole population is meant to be confirmed matches with a
  snapshot.
- Every review-queue and badge query would need a new exclusion predicate,
  and forgetting one degrades to a wrong badge rather than an error.

`match_tier` is also defined as the provenance of *a match* (design §3).
There is no match here.

### Why now rather than at step 4

Nothing has shipped past `user_version` 1, so this rides migration 2 instead
of needing a migration 3; commit 5's skip logic is written once against both
tables instead of written and then rewritten; and step 4's strict negatives do
not need rebuilding (its own structural negatives are still built from
scratch, since `tier` is part of the key). The table is
entirely regenerable, so a wrong guess costs `DROP` and recreate — the same
argument design §10 makes for `discogs_collection`, and the reason deciding
early is safe here and would not be for `discogs_match`.

### Shape notes

- **PK `(album_key, tier)`, not `album_key`.** Strict-negative ("don't
  re-read the file") and Structural-negative ("don't re-run the search") are
  different facts with different costs, and step 4 needs both to be true of
  one album simultaneously.
- **`tier` carries a CHECK**, matching the `match_tier` convention and its
  reasoning: a typo'd value degrades to "not examined", which is
  indistinguishable from correct behaviour and therefore silent.
- **`'fuzzy'` is deliberately absent.** Fuzzy is v2. Widening the CHECK means
  `DROP` + recreate on a regenerable table, which is the cheapest migration
  available.
- **Skip semantics are identical to `discogs_match`**: skip when a row exists
  *and* `source_timestamp` equals the album's current `MAX(tracks.timestamp)`.
  A NULL `source_timestamp` therefore never skips, which is the correct
  behaviour for an album whose timestamp cannot be established (see the
  online-library case in TODO).
- **`checked_at NOT NULL`** is inert for Strict and load-bearing for
  Structural, where a search that found nothing today may find something in
  six months. The staleness policy itself is **step-4 scope and not decided
  here**; the column exists so step 4 can add one without a migration.

### Invariants

1. An album never has a row in both `discogs_match` and `discogs_no_match`
   for the same tier. Enforced in `Match.pm`; asserted in the offline suite.
   No constraint can express it — foreign keys are banned (§2) and SQLite
   has no cross-table CHECK.
2. A tag **conflict** is not a no-match. It writes to `discogs_match` per
   §3a. A `discogs_no_match` row means nothing was found at all.
   Where an album that already has a conflict row later loses its tags
   altogether, the conflict row is **deleted** and a `discogs_no_match` row
   written as normal, so invariant 1 holds without a special case and
   "no tag found → write a no-match row" has no exception. The deletion is
   permitted for exactly
   `match_tier = 'strict' AND state = 'candidate' AND
   discogs_release_id IS NULL AND snapshot_track_count IS NULL`.
   The governing rule is **never delete a row that carries a decision or a
   recovery snapshot** — that predicate is the rule written out, not an
   exemption from it. Refreshing the row in place instead was considered and
   rejected: it leaves the album in the review queue permanently advertising a
   conflict that no longer exists and that step 5 cannot render, since §3a
   stores no `conflict_note` and re-reads tags that are now absent.
   Narrowing a never-delete rule does create a boundary someone can widen, so
   the test to apply is the reason above, never resemblance to this row shape.
3. The table is entirely regenerable. Orphan recovery must never read it,
   and design §9's "clear & rebuild matches" action must clear it.
4. Rows orphaned by an `album_key` change are **not** swept in v1. Growth is
   bounded by library churn and the maintenance action is the escape hatch.
   Recorded in TODO rather than built.

## Appendix B — §3a, into `docs/squeezewax-v1-decisions.md`, commit 5

## 3a. Conflicting Discogs tags — what the row records

**Decided 2026-08-29 (design chat), during build-order step 3 planning.**
Implements §3's "disagreement is not Strict".

Two configured tags parsing to different release IDs, or a configured tag
whose value does not parse, writes a row in `discogs_match`:

- `match_tier = 'strict'` — provenance is honest; strict tag reading is the
  mechanism that ran.
- `state = 'candidate'` — auto-confirm is withheld, and the album is in the
  review queue.
- **`discogs_release_id = NULL`.**
- `source_timestamp` and `lms_album_id` set as normal.
- `snapshot_*` left NULL — the snapshot is captured at confirm time and
  nothing has been confirmed.

The competing values are logged once at `warn`, naming the album and every
value found. The row's `source_timestamp` means this does not re-warn on
every subsequent scan; fixing the tags moves the file mtime, the album is
re-examined, and the row is updated in place.

### Why NULL rather than the highest-precedence tag's ID

Writing the top-precedence ID is first-wins by another name, and §3 rejects
first-wins explicitly. The `candidate` state stops it *acting*, but the
column would still assert a release that nothing adjudicated — available to
any future query that reads `discogs_release_id` without also checking
`state`. NULL records what actually happened: strict ran and produced no
decidable answer.

It is also the more durable discriminator. Step 2's finding 9 established
that the orphan-recovery ambiguous branch carries an existing row's values
forward into the review queue, which can produce `(match_tier, state) =
('strict','candidate')` for reasons having nothing to do with tags. The pair
is therefore not a reliable conflict marker; a NULL release id on a
candidate row is.

So the review queue reads:

- `state='candidate' AND discogs_release_id IS NULL` → we examined and could
  not decide; show the user their competing tag values.
- `state='candidate' AND discogs_release_id IS NOT NULL` → we have a
  proposal; ask the user to confirm it.

### Why no `conflict_note` column

The file tags are the source of truth and can change between the scan that
would write the note and the review that reads it, so a stored copy needs
invalidating on `source_timestamp` change to stay honest. Re-reading is
simpler and always current: step 5's review queue calls
`Slim::Formats->readTags` (`Slim/Formats.pm:153`) on the album's primary and
fallback tracks when the user opens the entry — server process, user-
initiated, one or two reads, bounded. If the files are gone the queue
degrades to "conflict recorded, tags no longer readable", which is the
truth.

This also follows step 2's finding 8: do not add a column nothing reads yet.

### Why not a fifth `match_tier` value

`match_tier` is defined as provenance — which mechanism established the link
(design §3). A conflict is a state, not an origin, and this row's origin
genuinely is strict tag reading. A fifth value would require amending the
four-value vocabulary in design §3 and §10, the CHECK in migration 1, and
every future reader, to express something `state` already expresses.

### Why not fall through to Structural

Rejected outright, and more strongly than "it contradicts §3". At step 4 a
Structural search could auto-confirm a *third* release over the top of two
tags the user wrote deliberately, producing a silently wrong badge with no
trace of the disagreement that caused it.

### v1 invariant, and the trigger to revisit

`state='candidate' AND discogs_release_id IS NULL` means "examined, could not
decide". Step 4 must not produce a NULL-id candidate for any other reason —
Structural's partial-multi-disc candidate and Fuzzy's master-release
candidate both carry a proposed id. **If a later tier genuinely needs a
NULL-id candidate, that is the trigger to reopen `conflict_note`** — not a
reason to overload this one silently.


## Appendix C — `TODO.md` additions, commit 6

These are additions from the design chat. They do not replace your own
planning-session items — keep those, labelled as yours.

## Next — build-order step 3

- [ ] **Importer must never overwrite a `match_tier='manual'` row.** An
      in-place file change (artwork, ReplayGain, a tag editor rewriting the
      whole file) moves `tracks.timestamp` without moving `album_key`, so the
      album is re-examined and the original Discogs tag reverts the user's
      manual pressing choice — no log line, silently wrong badge. Refresh
      `source_timestamp` and `lms_album_id` only. "Retagging beats a manual
      override" is defensible but needs an explicit step-5 mechanism, not an
      UPSERT side effect.
- [ ] **Gate `use =>` on a non-empty `discogsTagNames`**, per
      `Slim/Music/ReleaseTypes.pm:32`. `runImporter` logs
      `Starting $importer scan` at error level inside the `use` guard
      (`Slim/Music/Import.pm:573-579`),
      so an unconfigured install writes two log lines and a progress row
      every scan; the gate is what suppresses them. **Step 4 must relax
      this** — Structural needs no tag names.
- [ ] **Never pass `every` to `Progress->new`.** The DB write and the
      scanner→server HTTP POST are both inside the 5-second throttle
      (`Slim/Utils/Progress.pm:221-245`); `every` makes both fire per album —
      5,000 synchronous round-trips on a 5,000-album library. Abort latency
      is ~5s as a direct consequence, and that is intended, not a bug to fix.
- [ ] **Online-library albums never skip.** Streaming tracks are real
      `tracks` rows with `audio = 1`. `Slim/Formats.pm:261` is the sole
      producer of a `TIMESTAMP` attribute and is guarded by
      `if (-e $filepath)` at `:259`; for a non-file URL `$filepath = $file`
      (`:165`), so the stat never happens and `tracks.timestamp` is
      structurally NULL. `MAX(timestamp)` is therefore NULL, and neither a
      match row nor a `discogs_no_match` row can ever skip them. Expose
      local/remote track counts per album from the iterator, skip
      no-local-track albums at Strict, prefer a local track for the
      primary/fallback pick. Do **not** hardcode `remote = 0` in the query —
      v2's Fuzzy tier is for exactly these albums. Note separately that
      `readTags` on a remote URL returns a **populated** hashref (`TITLE`,
      `CONTENT_TYPE`), not `{}`, so the tag parser must test for absence of
      the configured keys, never for an empty hash.
- [ ] **Anomalous-run summary at `warn`.** With `defaultLevel => 'WARN'` the
      "examined 4,800, matched 0" case is invisible, and LMS's own
      start/complete pair does not carry it. That is what a mistyped tag name
      produces. Emit the end summary at warn when
      `matched == 0 && examined > 0`.
- [ ] **`startScan` returns an integer** (matched count). `runImporter`
      assigns the return and `runScan` sums it
      (`Slim/Music/Import.pm:404-405`); the post pass discards it, so this is
      convention rather than correctness — but a hashref here would look fine
      until someone reuses the sub.
- [ ] **Changing `discogsTagNames` must invalidate the strict answer.** Both
      skip caches key on file state; the tag list is not in the key, so a
      corrected tag list changes nothing on the next scan and the
      `matched == 0` warning cannot fire because `examined` is zero. Settings
      save clears strict `discogs_no_match` rows and NULLs `source_timestamp`
      on strict `discogs_match` rows. See decisions §3b.

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

## Waiting — needs a real server

- [ ] **Remote-track timestamps across plugins other than TIDAL.**
      `SELECT remote, COUNT(*), COUNT(timestamp) FROM tracks GROUP BY remote`
      on a box with Spotty or another online-library plugin installed. The
      NULL is structural for the standard path
      (`Slim/Formats.pm:165` sets `$filepath = $file` for a non-file URL, so
      the `if (-e $filepath)` guard at `:259` never reaches the stat at
      `:261`), but a plugin that supplies its own
      `TIMESTAMP` attribute through `updateOrCreate` would populate it, and
      that changes whether the skip logic can ever apply.

## Housekeeping

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

## Appendix D — §3b, into `docs/squeezewax-v1-decisions.md`, commit 4

## 3b. Changing the configured tag names invalidates the strict answer

**Decided 2026-08-30 (design chat), during build-order step 3 review.**

Both skip caches — `discogs_match.source_timestamp` and every
`discogs_no_match` row — key on file state alone. The strict answer also
depends on `discogsTagNames`, which is not in that key. Without explicit
invalidation, changing the tag-name list changes nothing on the next scan:
every album is skipped because no file moved.

Three failures follow, all silent:

- The common one. A user ticks the wrong tag first, gets 4,800 no-match rows,
  corrects the list, rescans — and nothing happens. Finding 4's
  `matched == 0 && examined > 0` warning cannot catch it, because `examined`
  is zero.
- Removing one of two conflicting tag names leaves the album's
  `(strict, candidate, NULL)` row in place, so it stays in the review queue
  with a conflict that no longer exists.
- Adding a tag name that outranks the configured one can change which ID wins
  on an already-`confirmed` album, or create a conflict where there was none.
  Those albums skip too.

**On a Settings save that alters the list**, and only then:

```sql
DELETE FROM squeezewax.discogs_no_match WHERE tier = 'strict';
UPDATE squeezewax.discogs_match SET source_timestamp = NULL
 WHERE match_tier = 'strict';
```

`DELETE` on `discogs_no_match` because it is regenerable in full (§2a); the
rows cost re-reads, never a match.

`UPDATE` rather than `DELETE` on `discogs_match` because every row this
predicate touches may carry a decision — `state = 'confirmed'` is one, and any
non-NULL `discogs_release_id` is a proposal something adjudicated — and §2a's
rule is *never delete a row that carries a decision or a recovery snapshot*.
NULLing `source_timestamp` forces re-examination without discarding anything.
Where re-examination then finds no tag at all, §2a's narrow delete predicate
applies at that point, in the importer, not here: the two mechanisms compose,
and invalidation is never the thing that removes a row. `match_tier = 'manual'`
rows fall outside the predicate entirely and are untouched, consistent with the
write path's first rule.

The write is safe because the settings page already refuses to save while
`Slim::Music::Import->stillScanning` is true (finding 2b).

**Cost:** one cold pass over local files on the next scan. That is the correct
price for a rare, deliberate user action, and it is predictable.

Three alternatives were rejected, ordered by how likely each is to be proposed
again.

**Rejected — `$prefs->setChange`.** It is the obvious way to catch the change
wherever it happens, and in-tree plugins use it
(`Slim/Utils/Prefs/Namespace.pm:148`; callers at
`Slim/Plugin/PreventStandby/Plugin.pm:47-48`,
`Slim/Plugin/UPnP/MediaServer.pm:52`). But
`Slim::Utils::Prefs::Base::set` dispatches onchange on
`!defined $old || !defined $new || $old ne $new || ref $new` — and
`ref $new` is always true for an arrayref pref, so the callback fires on
*every* save, changed or not. The scalar "no change" short-circuit earlier
in `set` is likewise gated on `!ref $new`. A `setChange` implementation
would therefore force a full cold re-read pass on every settings save,
including one that only toggled a checkbox. `set` does pass an
undocumented fourth argument (`$func->($pref, $new, $obj, $old)`) that
would allow a comparison, but the POD documents three, and building this on
undocumented behaviour buys nothing the handler does not already give.

**Rejected — partial invalidation.** Clearing no-match rows and NULLing only
the `(candidate, NULL)` conflicts, leaving confirmed rows alone, is cheaper.
Its failure mode is chosen rather than accidental: a newly-added tag name
would never revisit an album that already matched, so it could never correct
a wrong pressing or surface a conflict that now exists.

**Rejected — a tag-list fingerprint per row.** More schema and more code for
an identical outcome. Recorded so it is not re-proposed.

**Coverage gap, accepted.** Hooking the handler misses a change made outside
the settings page — the CLI, or a hand-edited prefs file. Both require
deliberate action, and design §9's "clear & rebuild matches" is the escape
hatch. Recorded rather than solved.

**Step 4 note.** Structural does not read tag names, so `tier = 'structural'`
rows are correctly outside both statements. If a later tier ever derives its
answer from a pref, it needs its own invalidation clause here.
