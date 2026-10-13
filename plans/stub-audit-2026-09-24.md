# Stub audit — 2026-09-24

Read-only survey of every stub, fake and monkey-patch in `scripts/`, made after
three regressions in one round were found on hardware rather than offline
(prompt-D report §1.1). Each of those three had the same shape: the suite
asserted something true about the piece it owned, and the **seam** between two
pieces went untested because a stub had smoothed it over.

So this looks hardest at anything that fakes **a callback, a timer, a pref
write, an HTTP response, or another of our own modules**.

Scope: `scripts/*-check.pl` (api, library, match, ownership, plugin, schema,
settings, sync, tags), plus `ownership-offline-check.pl`, `title-agreement.pl`
and `fetch-fixtures.pl`. Nothing here is fixed. Ranking and uncertainty are at
the end.

---

## 0. The two worked examples

Both were corrected this round, after the defect they were hiding had already
shipped. They are the reason for the audit and the model for judging the rest.

### 0a. `sync-check.pl`'s transport — CORRECTED

Set `code` on every canned response and always called the **success** callback.
The real `Slim/Networking/Async/HTTP.pm:434-436` sends every status that is not
2xx/3xx to `_http_error`, and `SimpleAsyncHTTP`'s `onError` (`:76-101`) sets
neither code nor headers, passing the response as a third argument (`:96`).

**What the correction taught:** four branches of `classifyResponse` looked
reachable in the suite and were dead in production — `unauthorized`,
`rate_limited`, `not_found`, `server_error`. The rate-limit back-off had never
run against a real 429. With the stub honest and the fix reverted, **7
pre-existing assertions fail**. They were correct all along and could not fire.
A passing assertion is not evidence that the path it names can happen.

### 0b. `settings-check.pl`'s `StubPrefs` — CORRECTED

Neither suppressed a no-op scalar write (`Slim/Utils/Prefs/Base.pm:94-97`) nor
dispatched `setChange` (`:91`, registered via `Prefs/Namespace.pm:148-164`).

**What the correction taught:** the 0.0.0.7 regression lived precisely in the
ordering between a pref write and a sync, and no suite could express the
question. With it modelled, ordering became assertable against an event log;
with the fix reverted, **3 assertions fail**.

---

## 1. Callbacks and transports

| # | Stub | Stands in for | The one thing it does NOT model | On hardware | Cheap? |
|---|---|---|---|---|---|
| **1.1** | `settings-check.pl:222-225` `SimpleAsyncHTTP::get` | `Slim/Networking/SimpleAsyncHTTP.pm` `get` → `onBody`/`onError` | **It never calls either callback.** It counts the request and returns. | `_testToken`'s entire result path is unreachable: `_tokenTested`, `_tokenTestFailureString`, and the third-argument status fix PART 3 put inside its `$done` closure. A wrong token could report the wrong message, or die, and every suite stays green. | **Yes** — reuse `sync-check.pl`'s corrected transport shape. |
| 1.2 | `sync-check.pl:164-225` `SimpleAsyncHTTP` | same | Nothing material any more (see §0a). Still synchronous: the callback fires before `get` returns. | Re-entrancy or ordering that depends on returning to the event loop first. | No — needs a real loop. |
| 1.3 | `sync-check.pl:110-119` `Timers::setTimer` | `Slim/Utils/Timers.pm:66-90` | Fires the callback **immediately and inline**, rather than after returning to the event loop. | A back-off that works in the suite but re-enters `_fire` from inside `_handle` on a real server. Stated in the file's own header. | No. |
| 1.4 | `plugin-check.pl:91-98` `Timers::setTimer`/`killTimers` | same | Records and **never fires**. The opposite simplification to 1.3. | A timer armed with a bad delay or a wrong coderef is recorded as armed and never proven to run. | Partly — firing on demand is easy; a real loop is not. |
| 1.5 | `settings-check.pl:146-147` `Scheduler::add_task`/`remove_task` | `Slim/Utils/Scheduler.pm` | The task is recorded and **never run**. | `_detectionTick` is never driven by its real driver; a tick that dies or never terminates looks identical to one that works. `tags-check.pl` covers the tag logic, not the scheduling. | Partly. |

## 2. Pref stores

| # | Stub | Stands in for | The one thing it does NOT model | On hardware | Cheap? |
|---|---|---|---|---|---|
| **2.1** | `sync-check.pl:143-150` `StubPrefs` | `Slim/Utils/Prefs/Base.pm` `set`/`get` | No no-op suppression (`:94-97`), no `setChange` dispatch (`:91`) — **the exact gap 0b closed in the other suite, still open in the one that owns the sync.** | `Async.pm` writes `discogsLastSynced`, `discogsLastSyncItems` and `discogsLastSyncError` at its single exit. An onchange hook on any of them, now or later, would fire unmodelled — the 0.0.0.7 shape again. | **Yes** — port 0b's version. |
| 2.2 | `plugin-check.pl:130-149` `StubPrefs` | same | `set` does not dispatch `setChange`; the suite fires the recorded callback by hand. | If the `setChange` registration were deleted, the hand-fired assertions would still pass — the suite proves the callback's body, not that it is wired. | **Yes.** |
| 2.3 | `match-check.pl:94-101`, `ownership-check.pl:99-104`, `tags-check.pl` `StubPrefs` | same | `get`/`set` only; no validation, no suppression, no onchange. | Lower: these modules read prefs far more than they write them. | Yes, if wanted. |
| 2.4 | `ownership-offline-check.pl:~130` `Stub::Prefs::get` | same | Returns `[]` for **every** pref. | The harness cannot exercise anything pref-dependent; it happens not to need one. Reads as a store, is a constant. | Yes. |

## 3. Our own modules, replaced wholesale

These are the seams by construction: each hides the join between two of our
files, which is where all three regressions lived.

| # | Stub | Stands in for | The one thing it does NOT model | On hardware | Cheap? |
|---|---|---|---|---|---|
| 3.1 | `sync-check.pl:264-270` `Ownership::apply` | `SqueezeWax/Ownership.pm` | Records the entry list and returns a canned verdict; never reads or writes a database. | A sync that hands the pass something it cannot use. `ownership-check.pl` drives the real pass with hand-built entries, so the **handover shape** is asserted twice and agreed by neither. | No — joining them is a new integration suite. |
| 3.2 | `plugin-check.pl:169-188` `Async::sync`, `tokenRejected`, `noteSkipped`, `clearTokenRejected` | `SqueezeWax/API/Async.pm` | The pause is a suite variable, not Async's own state. | Plugin and Async could disagree about when the pause is set — which is exactly what 0.0.0.7 was, one layer over. | No. |
| 3.3 | `settings-check.pl:244-260` `Async::sync`, `status`, `tokenRejected`, `clearTokenRejected` | same | Same. `sync` also invokes its callback **synchronously**, so `_finishSyncNow` runs inside `_syncNow`. | The real sync is asynchronous; the render ordering the suite proves is not the ordering that happens. | No. |
| 3.4 | `settings-check.pl:268-280` `Library::sample_albums`, `Match::invalidateStrict`, `Tags::tagNames`, `Schema::isReady`/`lastError` | our modules | Return canned values; no database. | Fine for dispatch, which is what that suite is for. Worth listing so nobody reads it as coverage of those modules. | n/a — deliberate. |

## 4. Database

| # | Stub | Stands in for | The one thing it does NOT model | On hardware | Cheap? |
|---|---|---|---|---|---|
| 4.1 | `Slim::Schema::dbh` → plain `DBI` handle (`library-check.pl:111`, `match-check.pl:144`, `ownership-check.pl:332`, `ownership-offline-check.pl:207`) | `Slim::Schema->dbh` | LMS's own connection settings — notably `sqlite_use_immediate_transaction` (`Slim/Utils/SQLiteHelper.pm:358`), which makes `BEGIN` take a write lock on **every attached database**. The suites attach their own file with plain defaults. | Lock contention against a running scanner: finding 2b, the whole reason `_writeOk` exists. The refusal is asserted by overriding `_writeOk`, not by producing a real lock. | No. |
| 4.2 | `match-check.pl:147` `Slim::Schema::forceCommit` | `Slim::Schema` | A no-op. | Scanner-side commit semantics. Low. | Yes. |

## 5. Strings, rendering, environment

| # | Stub | Stands in for | The one thing it does NOT model | On hardware | Cheap? |
|---|---|---|---|---|---|
| 5.1 | `settings-check.pl:134` `Strings::string` | `Slim::Utils::Strings::string` | Returns the **token itself**; a token absent from `strings.txt` is indistinguishable from one present. | A typo'd token renders as `PLUGIN_SQUEEZEWAX_...` on the page. Partly mitigated — the suite now checks a handful of tokens against `strings.txt`, but only those it names. | **Yes** — assert every token the template and module use exists. |
| 5.2 | `settings-check.pl:108-111` `Slim::Web::Settings::handler` | `Slim/Web/Settings.pm:134-176` | Returns a marker. The real one **saves every scalar in `prefs()`** when `saveSettings` is present. | The save-side of the 0.0.0.7 regression. Now partly modelled via `StubPrefs`, but the base handler's own logic — validation, `validated`/`warning` params — is absent. | Partly. |
| 5.3 | `main::INFOLOG => 0` (api, library, match, plugin, schema, settings, sync, tags) | LMS's compile-time constant | Every `main::INFOLOG && ...` expression is **not evaluated**. | A side effect inside a log-gated expression never runs under test and does run in production. This nearly bit us: `noteSkipped`'s marker was briefly inside one. | **Yes** — run at least one suite with it on. |
| 5.4 | `Test::StubLogger` (all suites) with `is_info => 0` | `Slim::Utils::Log` | Discards text; most suites never assert a log line. `ownership-check.pl` and `sync-check.pl` capture. | A wrong or missing log line — which for this plugin is a user-visible diagnostic (§14.2). | Yes. |
| 5.5 | `main::SCANNER`, `ISWINDOWS`, `WEBUI` | LMS constants | Fixed per suite; `syntax-check.sh` compiles both `SCANNER` modes but the suites pick one. | A branch that only exists in the other mode. | Yes. |

## 6. Domain fakes

| # | Stub | Stands in for | The one thing it does NOT model | On hardware | Cheap? |
|---|---|---|---|---|---|
| 6.1 | `tags-check.pl` hand-built tag hashrefs; `Slim::Formats` stubbed entirely | `Slim/Formats.pm:153` `readTags` | That `readTags` returns what we assume. The file's own header says so. | A real tagger's output shaped differently from every fixture. The detection button exists to find this out on a real library. | No. |
| 6.2 | `Test::StubHeaders` (`api-check.pl:105`, `sync-check.pl:155`) | `HTTP::Headers` | api-check's is **case-sensitive**; sync-check's lowercases. Real `HTTP::Headers->header` is case-insensitive. | Low, and in the safe direction — Discogs sends lowercase (observed), and the real accessor is case-insensitive, so the stub is stricter than reality rather than laxer. | Yes. |
| 6.3 | `ownership-check.pl:336`, `ownership-offline-check.pl:211` `variousArtistString` | `Slim/Music/Info.pm:1540-1543` | The pref-vs-localized-string fallback. ownership-check varies it deliberately; the offline harness hardcodes `'Various Artists'`. | An install with a configured label, on the offline harness only. | Yes. |
| 6.4 | `api-check.pl:92-99`, `fetch-fixtures.pl` `PluginManager::dataForPlugin` | `Slim/Utils/PluginManager.pm:478-487` | `$loaded` keyed by module type — the reason `_pluginVersion` is fragile across server/scanner. | A User-Agent with no version in one process. | Yes. |
| 6.5 | `fetch-fixtures.pl` uses `LWP::UserAgent` | `Slim::Networking::SimpleSyncHTTP` | A different transport entirely. Deliberate and documented: SimpleSyncHTTP refuses to run outside the scanner. | n/a — a capture tool, ships nothing. | n/a |
| 6.6 | `title-agreement.pl --step7` stubs | Slim modules | Loads `Ownership.pm` for its pure functions only. | n/a — measurement, ships nothing. | n/a |

---

## 7. Ranked: which would hide the worst defect

1. **1.1 — `settings-check.pl`'s transport never calls back.** The only entry
   that hides a change *made this round and never executed anywhere*: PART 3's
   status fix inside `_testToken`. It is untested offline **and** unverified on
   hardware — the round-C wrong-token test used that button, but nobody
   recorded what it displayed. Cheap, and the corrected shape already exists
   next door.
2. **2.1 — `sync-check.pl`'s `StubPrefs`.** The precise gap that produced the
   0.0.0.7 regression, still open in the suite that owns the sync's pref
   writes. Cheap, by porting 0b.
3. **2.2 — `plugin-check.pl`'s `StubPrefs` does not dispatch `setChange`.**
   Deleting the registration would leave the suite green. Cheap.
4. **5.3 — `INFOLOG => 0` everywhere.** A whole class of expression is never
   evaluated under test. Cheap, and it nearly bit us already.
5. **1.5 — the Scheduler task never runs.** The detection worker's real driver
   is untested.
6. **5.1 — `string()` cannot tell a missing token from a present one.**
7. **3.1-3.3 — whole-module replacements.** The biggest real risk and the only
   entries that are *not* cheap: they hide seams by construction, and all three
   regressions were seams. No stub edit fixes this; it needs a suite whose
   subject is a join. Out of scope for a time-boxed pass, and the honest
   mitigation meanwhile is that these joins get exercised on hardware.
8. **4.1 — plain DBI instead of LMS's immediate-transaction connection.**
9. **6.1 — `readTags` fixtures.** Real, known, not cheap, and the detection
   button is the designed answer.

## 8. Where my judgement is uncertain

- **1.5 and 5.3 I have ranked on principle, not on evidence.** I found no
  current defect behind either. 5.3 is ranked as high as it is because of a
  near-miss I created myself this round, which may be over-weighting a habit of
  mine rather than a property of the code.
- **4.1 may be unfixable at proportionate cost, and may not matter.** The
  refusal it would test is already asserted by overriding `_writeOk`, and the
  real lock behaviour was observed on hardware in round B. I am not confident
  a suite could add anything.
- **3.1-3.3 are ranked 7th by cheapness, not by severity.** By severity they
  are first. If the choice is "three items fixed" versus "one integration
  suite started", I do not know which is the better trade, and that is a
  design-chat call rather than mine.
- **I may be over-fitting to the last three failures.** Every entry above is
  framed by seams because the last three defects were seams. A fourth may not
  be.
