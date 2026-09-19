plans/build-order-step-5-collection-sync.md

# Build order step 5 — collection sync

## §0. What this step is, and is not

- **Server-side, async** fetch of the user's Discogs collection, on three
  triggers: `['rescan','done']` debounced, an interval pref, and a manual
  button (decisions §13.7, corrected §15.2 — server process, on scan
  *completion*, not start).
- **Testable on its own** (`TODO.md`, build-order item 5): `ceil(items/100)`
  requests for the collection (measured 3 for 203 items, §13.1/§9.4), a
  last-synced timestamp that advances, and **nothing written to
  `discogs_match`**.
- **Out of scope, by decision**: ownership computation, any `discogs_match`
  write, migration 3, the `ownership` column — all step 7, after step 6
  (§15.9). This step fetches and throttles; it concludes nothing. The
  ownership pass (step 7) will call this step's fetch again when it runs —
  nothing here is cached for it (§13.2, §13.6: "every completed sync
  re-derives every conclusion from scratch").
- **Out of scope, recorded not designed**: the `lms_album_id` refresh hook's
  own `['rescan','done']` subscription (build-order step 2 finding, still
  unbuilt). A shared debounce helper could serve both triggers. Not built
  here — flagged as scope creep if raised, not resolved by this step.

## §1. Preconditions

- None blocking on the code. `API.pm`'s pure functions (`buildRequest`,
  `classifyResponse`, `accountRequest`, `backoffFor`) and the token
  pref/settings field (`discogsToken`, `Settings.pm`) are already built
  (step 4) and reused here unchanged.
- One precondition on the **hardware pass**, not on writing or reviewing the
  code: `TODO.md`'s "abort a scan mid-run" check (confirm a second
  `['rescan','done']` fires after an aborted external scan, and that a
  pending sync then completes) should run on the reference server before
  this step's trigger code is exercised there. Decisions §15.2 obligation 1
  rests on this and is currently **inferred** from
  `Slim::Utils::SQLiteHelper`'s `_notifyFromScanner` `exit` branch, not
  observed. This step is the first code whose correctness actually depends
  on that inference.

## §2. Build order

Each commit independently reviewable, per this project's convention.

### Commit 1 — housekeeping sweep (`TODO.md`, no logic change)

Verified against real HEAD `d59a2b2a75ca0c35cb59257c038e4ed736a3e99d`
(`v1-buildout`, a descendant of the stated `21d6d16`) by cloning the repo and
dry-running every edit below: each anchor occurred **exactly once** in its
file at this HEAD, `scripts/syntax-check.sh` passed after (both processes,
all 8 modules), and `scripts/api-check.pl` (89 assertions) and
`scripts/tags-check.pl` (73 assertions) both passed after, unchanged in
count from before the edit.

**Re-verify the count before applying — the branch may have moved since this
was written. Report the actual count found for each anchor; do not treat the
counts in this table as confirmed.**

1. `SqueezeWax/strings.txt` (line 68 at this HEAD) — the token-description
   string. Old:
   ```
   	EN	Required for Structural matching and for the owned badge. Generate one at your Discogs Developer Settings and paste it here.
   ```
   New:
   ```
   	EN	Required for collection sync and the owned badge. Generate one at your Discogs Developer Settings and paste it here.
   ```
   (Rest of the string, after "paste it here.", unchanged.)

2. `SqueezeWax/Tags.pm` (line 126) — Old:
   ```
   letting it fall through to Structural - worse than simply missing it.
   ```
   New:
   ```
   letting it be treated as no tag at all - worse than simply missing it.
   ```

3. `SqueezeWax/API.pm` (line 4) — Old:
   ```
   # "Structural runs in the scanner... API/Async.pm is server-side and belongs
   ```
   New:
   ```
   # "Identification runs in the scanner... API/Async.pm is server-side and belongs
   ```

4. `SqueezeWax/API.pm` (lines 47-54, the `MAX_RETRIES` rationale comment) —
   Old:
   ```
   # 429 retry bound (§3.2). Three retries (four attempts total) at
   # WINDOW_SECONDS each is up to 4 minutes stalled on one request. Structural
   # runs unattended over hundreds of albums (plan §13's "~9 minutes at 60/min
   # for 500 albums" is the scale this competes with), so a single wedged
   # request must not be allowed to stall the scan indefinitely - a 429 that
   # survives the local throttle three times in a row means something is wrong
   # beyond ordinary pacing (concurrent use of the same token from elsewhere, or
   # a genuinely stuck window), and the right response is to give up on this one
   # request and let the album fall to the review queue, not to retry forever.
   ```
   New:
   ```
   # 429 retry bound (§3.2), shared by the pure backoffFor here and the async
   # collection sync's retry loop (API/Async.pm). Three retries (four attempts
   # total) at WINDOW_SECONDS each is up to 4 minutes stalled on one request -
   # a 429 that survives the local throttle three times in a row means
   # something is wrong beyond ordinary pacing (concurrent use of the same
   # token from elsewhere, or a genuinely stuck window), and the right response
   # is to give up and let this sync fail for the interval, not retry forever.
   ```
   Note: this rewrite is substantive, not a word-swap — its old rationale
   (per-album, scan-time framing) no longer describes anything once commit 2
   deletes its only current caller. `API.pm:266`'s "Structural" mention (the
   `$rateState` module comment) is **not** fixed here — it is deleted whole
   in commit 2 along with the code it documents.

5. `scripts/title-agreement.pl` (around line 226-227) — Old:
   ```
   	# "local_tracks == 0" skip is deliberately not reproduced: it came from
   	# Structural's duration fingerprint, which needed local files to read
   ```
   New:
   ```
   	# "local_tracks == 0" skip is deliberately not reproduced: it came from
   	# the old Structural tier's duration fingerprint (removed by decisions
   	# §13.8), which needed local files to read
   ```

6. `scripts/api-check.pl` (around lines 386-390) — Old:
   ```
   	# Paired fixture: the reference LMS library (hardware-tested throughout
   	# decisions/TODO.md) has this album at albums.id 3359, discc = 2, 25
   	# local tracks. Both sides of a future Structural comparison test are
   	# available once build-order item 5 needs them - not written here, per
   	# instruction; this block only asserts the Discogs side's own shape.
   ```
   New:
   ```
   	# Paired fixture: the reference LMS library (hardware-tested throughout
   	# decisions/TODO.md) has this album at albums.id 3359, discc = 2, 25
   	# local tracks - recorded in case a duration-based disambiguator is ever
   	# built (decisions §13.10, left open, not v1); this block only asserts
   	# the Discogs side's own shape.
   ```
   Note: the old text's forward-reference to "build-order item 5" (this
   step) needing a Structural comparison test was already wrong on two
   counts — Structural doesn't exist, and this step needs no duration
   comparison at all. Corrected rather than merely de-Structural-ed.

7. `scripts/tags-check.pl` (around lines 112-114) — Old:
   ```
   	# would be worse than a miss: decide() treats unparseable as a conflict, so
   	# the album would land in the review queue as a false conflict instead of
   	# falling through to Structural.
   ```
   New:
   ```
   	# would be worse than a miss: decide() treats unparseable as a conflict, so
   	# the album would land in the review queue as a false conflict instead of
   	# being treated as no tag at all.
   ```

8. `SqueezeWax/Importer.pm` (line 373, inside `_prePass`) — the `my $b` loop
   variable masks `sort`'s `$b` in scope. Old:
   ```
   	for my $b (@backfill) {
   		$count{backfilled} += Plugins::SqueezeWax::Match->backfillArtist(@$b);
   	}
   ```
   New:
   ```
   	for my $entry (@backfill) {
   		$count{backfilled} += Plugins::SqueezeWax::Match->backfillArtist(@$entry);
   	}
   ```

After this commit: `grep -rn Structural SqueezeWax/ scripts/` should show
only `API.pm`'s `$rateState` comment (deleted next commit) and
`title-agreement.pl`'s now-historical "the old Structural tier" mention
(intentionally kept, clearly marked as removed).

### Commit 2 — delete `API.pm`'s synchronous path

No v1 caller once Structural is gone and the sync is server-side (`TODO.md`,
"recorded not acted on: `API.pm`'s synchronous `get` has no v1 caller... keep
it, or record why it stays, when the sync step is planned" — this is that
decision, made in this session: **delete it**).

- Delete `sub get`, `sub _request`, `my $rateState`/`my $rateWait`, and the
  "transport shims" banner comment — `API.pm:243-304` at post-commit-1 HEAD
  (recount before deleting; the file was 306 lines before commit 1's edits
  changed line counts slightly).
- Rewrite the file header comment (`:1-24`-ish) to describe what the file
  now is: pure request-construction, response-classification and
  rate-limit-accounting functions only, with two callers — the scanner's
  Strict identification (step 3/4, calling `buildRequest`/`classifyResponse`
  directly, unchanged by this step) and the new async client (commit 3).
- Grep `scripts/api-check.pl` for any reference to the deleted `get`/`_request`
  and update its own header comment if it describes exercising them (it
  shouldn't — its header already says the transport is untestable in-process
  — but confirm).

### Commit 3 — `SqueezeWax/API/Async.pm` (new file)

Server-side Discogs client. Reuses `API.pm`'s pure functions; never
`Slim::Networking::SimpleSyncHTTP`.

- **Non-blocking retry/backoff.** `Slim::Utils::Timers::setTimer( $obj,
  $when, $coderef, @args )` in place of `API.pm::get`'s `sleep($rateWait)` —
  verified against `refs/slimserver@a670a38c2b14ad42b86a39884bcb842121b35571`
  (the same pin used elsewhere in this project), `Slim/Utils/Timers.pm:66-`:
  event-loop-driven (`use EV`), not a thread, not a blocking call.
  `Slim::Utils::Timers::killTimers($obj, $coderef)` cancels a pending one —
  needed for teardown if a sync is superseded mid-run (e.g. a second trigger
  fires while one is still paginating; see the sync-state guard in commit 4).
- **Paginated collection fetch**, `GET
  /users/{username}/collection/folders/0/releases`, `ceil(items/100)`
  requests. **Before writing the pagination loop, read the actual Discogs
  collection-listing documentation at discogs.com/developers** for the exact
  `sort`/`sort_order`/`page`/`per_page` parameter names. Decisions §9.4
  verifies the *hazard* (the default sort — `sort=label&sort_order=asc` per
  that section — is mutable and non-unique, so paging over it can drop or
  duplicate rows) but this project has not yet verified against the docs
  which alternative sort key is both stable and offered. Do not guess a
  parameter name; cite the docs section you used.
- **Username**: fetch fresh from `GET /oauth/identity` at the start of every
  sync run — do not cache it as a pref. This is a decision made in this
  session, not previously recorded: caching the username at Test-token time
  saves one request per sync but creates a silent-staleness failure mode
  (user swaps Discogs accounts, forgets to re-test the token, sync quietly
  keeps fetching the old account's collection) of exactly the kind this
  project has repeatedly ruled against (§13.6, §13.7, §14.2). Flag if you
  see a reason to reopen it.
- Reuses `backoffFor`/`accountRequest`/`MAX_RETRIES` from `API.pm` unchanged.
- **Collection page contents are discarded** once counted — no
  `discogs_collection` write (§13.2; the table is dropped in step 6 anyway),
  no `discogs_match` write. The only durable output of a sync is the item
  count (for the settings-page display) and the last-synced timestamp.
- Failure handling, per §13.7/§14.2: a transient failure (network, 5xx, a
  rate-limit stall that exhausts `MAX_RETRIES`) logs at `warn` and leaves
  `discogsLastSynced` untouched; a rejected token (401) logs at `error`,
  distinctly, and likewise leaves prior state untouched. Never partially
  advance the timestamp for a sync that didn't complete.

### Commit 4 — `Settings.pm`

- New prefs: `discogsSyncInterval` (seconds; **no existing decision sets a
  default — proposing 86400 (24h) as a product call, not a verified fact;
  confirm or override**) and `discogsLastSynced` (epoch integer, 0/undef =
  never synced).
- Settings page additions: last-synced display (human-readable, or "sync
  failed — see log" on the error path per §14.2), a "Sync collection now"
  button, an interval field. Same page as the token field, per your
  decision.
- A module-level sync-state guard mirroring `%detection`'s existing shape
  (`Settings.pm`'s tag-name-detection guard, including its staleness
  backstop) — so the interval timer, the button, and a debounced
  `['rescan','done']` cannot start two overlapping syncs, and a wedged run
  cannot block every future trigger forever.
- Button handler follows `_testToken`'s existing async-render-via-`$callback`
  shape in the same file.

### Commit 5 — `Plugin.pm`

- Subscribe to `['rescan','done']` via `Slim::Control::Request::subscribe`
  (verified present at `refs/slimserver@a670a38c2b14`,
  `Slim/Control/Request.pm:788`), debounced with `Slim::Utils::Timers`.
  Server process only — `Plugin.pm` never loads in the scanner
  (`Slim::Utils::PluginManager.pm:204`, already relied on elsewhere in this
  codebase), so no `main::WEBUI` guard is needed here (unlike `Settings.pm`,
  which is UI-only and already so guarded).
- Register the recurring interval timer at `initPlugin`. Guard against
  double-registration on a re-`initPlugin` (check `Slim::Utils::Timers`'
  semantics for a repeating `setTimer` before wiring it — a naive
  self-rescheduling timer registered twice silently doubles the sync
  frequency).

### Commit 6 — offline suite: `scripts/sync-check.pl` (new file)

Mirrors `scripts/api-check.pl`'s stub shape (stub
`Slim::Networking::SimpleAsyncHTTP`, `Slim::Utils::Timers`,
`Slim::Control::Request`; nothing here exercises a real event loop or real
network — the same limitation `api-check.pl`'s own header already states for
the sync transport, restated for this file). Covers, as pure-function
assertions: the `ceil(items/100)` pagination-count math across a range of
collection sizes; that nothing accumulates across pages beyond a count (the
discard behavior); and the retry/give-up boundary, reusing `backoffFor`'s
existing offline coverage rather than re-deriving it. Does not and cannot
prove the real `Timers`/`SimpleAsyncHTTP` interaction — that is a hardware-list
item, same as `API.pm`'s own transport already is.

## §3. Verification (hardware, `TODO.md`)

Not blocking the build or the review of these commits; blocking "this step is
done."

1. A collection sync produces exactly `ceil(items/100)` requests, and
   `discogsLastSynced` advances; `discogs_match` row count is unchanged
   before/after.
2. The manual button, the interval timer, and a rescan's `['rescan','done']`
   do not start overlapping syncs (exercise the guard, or note that it
   simply wasn't hit in practice — say which).
3. A revoked token produces the `error`-level log line and
   `discogsLastSynced` stops advancing; a simulated transient failure (kill
   the network mid-sync, or similar) produces `warn` and leaves prior state
   untouched.
4. `TODO.md`'s existing "abort a scan mid-run" check becomes load-bearing
   for the first time here — if not already run, run it now: abort an
   external scan mid-run, confirm a second `['rescan','done']` arrives, and
   confirm a pending sync then completes.

## §4. `TODO.md` additions

- This step's hardware checks (§3).
- The shared-debounce-helper scope-creep note (§0) — a future session could
  factor the `['rescan','done']` debounce here and the still-unbuilt
  `lms_album_id` refresh hook into one helper; not done in this step.
- The Discogs collection-listing pagination-parameter documentation read
  (commit 3) — record what was read and what was decided, so it isn't
  re-derived.
- The `discogsSyncInterval` default (86400s) is a product call made in this
  plan, not sourced from any prior decision — worth a one-line entry so a
  later reader doesn't mistake it for a measured or specified figure.
