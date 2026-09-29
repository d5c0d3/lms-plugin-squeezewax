# SqueezeWax — LMS Discogs Plugin

A Perl plugin for Lyrion Music Server (LMS) that links a user's physical
record collection on Discogs to their LMS library.

**Design spec: `docs/squeezewax-design.md` — read it before proposing
anything. It is the source of truth for scope and behaviour.**

---

## Naming — fixed, do not vary

- Plugin directory: `SqueezeWax/` — must match the Perl package namespace.
- Package namespace: `Plugins::SqueezeWax::`
- install.xml: `<module>Plugins::SqueezeWax::Plugin</module>`,
  `<importmodule>Plugins::SqueezeWax::Importer</importmodule>`
- Web paths: `plugins/SqueezeWax/...`
- String tokens: `PLUGIN_SQUEEZEWAX_*`

LMS requires the repository plugin name to match the Perl package naming, so
these are not stylistic choices. See `refs/lms-plugin-tidal/install.xml` for
the pattern (`Plugins::TIDAL::Plugin` ↔ `plugins/TIDAL/settings.html`).

**Never put "Discogs" in the plugin's own name, package, or branding.** Spec
§1 documents Discogs' Application Name and Description Policy. Descriptive
functional labels ("View on Discogs", "Discogs Collection") are fine; the
name is "SqueezeWax" everywhere. Never render the Discogs logo or "D"
logomark — the badge is a generic vinyl glyph (spec §4).

## Hard rule: no invented APIs

LMS internals are thinly represented in your training data. You WILL produce
plausible-looking `Slim::*` method names that do not exist if you work from
memory. Do not.

- Before using any `Slim::*` call, find it in `refs/slimserver/` and cite the
  file and line you found it in.
- Before writing any plugin file, read the equivalent file in
  `refs/Spotty-Plugin/` and `refs/lms-plugin-tidal/` first.
- If you cannot find a real API for something the spec asks for, STOP and ask
  me. Never guess, never approximate, never write a placeholder that looks
  like a real call.
- `refs/slimserver/DEVELOPERS.md` is the primary architecture reference.

## References are read-only

`refs/` exists for reading. Never edit it. Never copy files wholesale out of
it. Model the pattern, then write our own code.

`refs/lms-plugin-tidal/` is often the cleaner model — it is a newer, simpler
plugin without Spotty's helper-binary complexity.

## Architecture constraints (spec §13)

- LMS is single-threaded.
  - Server-side HTTP → `Slim::Networking::SimpleAsyncHTTP` (async)
  - Scanner/importer-side HTTP → `Slim::Networking::SimpleSyncHTTP` (synchronous)
    — matches the reference plugin (`refs/lms-plugin-tidal/API/Sync.pm`), and it
    is the sanctioned home for that class, which warns when used in the server
    (`Slim/Networking/SimpleSyncHTTP.pm:11`, `:58`). It gets LMS's own request
    logging and timeout conventions, unlike bare `LWP::UserAgent`. **Caching is
    opt-in and the collection must never ask for it** (`cache => 1`,
    `Slim/Networking/SimpleHTTP/Base.pm:81-95`): a cached page would defeat the
    sync's completeness gate silently. TIDAL does pass it; we do not.
- **This plugin never plays audio.** No ProtocolHandler, no streaming URI
  scheme, no transcoding entries. Spotty has all of these — do not copy them.
- Discogs API rate limit: see `docs/squeezewax-design.md` §13 for the
  authoritative figure and how it was verified. All matching must be
  batched, throttled, cached in SQLite, and resumable after interruption.
  **One process, one budget, one throttle.** The rate state lives in `API.pm`
  (`rateWait`, `noteResponse`) and every server-side consumer shares it - the
  collection sync and `Derive.pm`. A second independent throttle against one
  budget is how a 429 arrives that nobody can explain (§15.22).
- **Nothing Content-shaped is stored.** §9.5: store conclusions, not Content. A
  bare identifier is storable indefinitely; a title, an artist, a tracklist or a
  payload is not, and `discogs_release_cache` is never written in v1. Reading a
  payload in memory is permitted; keeping anything out of it but an identifier or
  our own verdict is not.
- A partial or interrupted scan must never corrupt or discard existing
  confirmed matches.

## Build order

**v1 only** (design §11), in this order. Steps 1-3 are done and
hardware-verified on Lyrion 9.1.1. The sequence from step 4 is
`docs/squeezewax-v1-decisions.md` §15.9, which also records why migration 3
sits where it does.

1. Plugin skeleton + `install.xml` that LMS actually loads — **done**
2. SQLite schema, migrations 1 and 2 — **done**. v1's tables are
   `discogs_match`, `discogs_no_match`, `discogs_release_cache` and
   `discogs_price_snapshot` (design §10). Migration 1 also creates
   `discogs_collection`, which v1 must not have — see below
3. Strict identification from file tags — **done**
4. **Identification rework** — stop writing `state = 'confirmed'` without a
   collection check (decisions §13.4, design §3 node E); write
   `snapshot_artist` from `albums.contributor` (§11.4) and build the
   unambiguous orphan relink (§15.5); remove the `discogsMaxTier` pref
   (§15.8). The importer's `use` gate does **not** change (§15.8), and
   neither does its `local_tracks` gate — there is nothing to read tags from
   in an all-remote album (§15.11) — **code complete** (`a50c9d0`); the plan §6
   hardware checks are open in `TODO.md`
5. **Collection sync** — two paths since step 8b: synchronous inside our scan
   step, and asynchronous in the server after `['rescan','done']` as the
   fallback, plus the manual button. There is no interval (§15.15). (§15.2 as
   reversed by §15.18, §13.7)
6. **Migration 3** — the `discogs_match` rebuild. Reviewable on its own,
   but **ships with step 7 and is never merged ahead of it** (§15.9) —
   **code complete** (`e275221`); the plan §5 hardware checks are open in
   `TODO.md`
7. **Ownership pass** — design §3's flow, writing the `ownership` column.
   Covers **every** album, all-remote ones included (§13.10.1, §15.11) —
   **code complete** (`3b197cb`, wired at `c39acd2`); the plan §5 hardware
   checks are open in `TODO.md`. The completed sync hands the pass its
   collection in memory and never re-fetches (§15.13 part 1)
8. **Review queue + manual re-match** — **done** (`6b02c95`; hardware follow-up
   `076603f`, decisions §15.17); the plan §6 hardware checks **pass** on
   0.0.0.10, 2026-09-27, with two items recorded in `TODO.md`. Plan:
   `plans/build-order-step-8-review-queue.md`; decisions §15.16, §15.17
8b. **Sync and ownership pass inside the scan** — a second `post` importer of
   ours fetches the collection and derives ownership during the scan, so the
   badges are right when the scan finishes; the server-side sync survives as the
   fallback. Plan: `plans/build-order-step-8b-sync-in-scan.md`; decisions §15.18 —
   **done** (`cc43158`, packaged as 0.0.0.11); the plan §7 hardware checks
   **pass** on 0.0.0.11, 2026-09-27, with two checks unprovokable and recorded in
   `TODO.md`
8c. **The master arm, and tags that disagree across tracks** — two independent
   halves of one fix, an album the user owns being reported as not owned.
   **Group A**: migration 6's three derived columns, the shared rate state in
   `API.pm`, `Derive.pm`'s bounded server-side backfill, and node F reading the
   derived master. **Group B**: `Importer::_examine` compares both candidates, so
   a folder whose files name different releases becomes a conflict rather than a
   wrong identification. Plan: `plans/build-order-step-8c-master-arm.md`;
   decisions §15.19-§15.22 — **code complete**; the plan §6 hardware checks are
   open in `TODO.md`. One recorded deviation: the derive job is armed from
   `_syncTick`'s "the scan already synced" skip as well as from `_syncDone`,
   because on a server whose scan-time sync works the latter never runs
   (§15.18 part 8) and the job would never have fired at all.
9. **Owned badge + badge context menu**
10. **On-demand marketplace lookup**

**There is no Structural tier and no Fuzzy tier.** Decisions §13.8 replaced the
per-album Discogs search with collection-first ownership, and §14.3 deleted
Fuzzy from the roadmap. `plans/build-order-step-4-structural-matching.md` is
stale in its entirety: do not patch it, do not use it as a template, do not
mine it for shape.

**`discogs_collection` is not a v1 table.** Migration 1 creates it and
migration 3 drops it — done at `e275221` (§13.2, and `TODO.md` 2026-09-07).
Nothing may read or write it, and nothing ever did: Phase 0 grepped
`SqueezeWax/` and `scripts/` and found zero readers and no writers outside
migration 1's own DDL. Ownership is a column on `discogs_match`, not a
mirrored collection, and the sync keeps its collection in memory for the
length of one pass (§15.13 part 1).

v1 auth is a user-supplied Discogs personal access token (§9.1), never OAuth.
Token handling, request construction and rate-limit accounting are already
built; they serve the collection sync at step 5.

## Workflow split

- Design decisions, research, open questions → the claude.ai project (chat)
- Implementation and spec edits → here

## Sync reminder

`docs/squeezewax-design.md` is mirrored into a claude.ai project via
the GitHub connector. That connector does **not** auto-sync.

After you commit a change under `docs/`, or after any push, add one line:

> Pushed — hit "Sync now" in the claude.ai project before your next design chat.

One line only. Do not repeat it within the same session.

## Style

- Perl, matching the conventions in `refs/lms-plugin-tidal/`
- Prefer small, reviewable commits over large ones
- When the spec and your instinct disagree, follow the spec and tell me why
  you disagree

### Calling convention — fixed

In `Plugins::SqueezeWax::*`:

- **Public subs are class methods** and take `$class` as their first argument.
  Call them as `Plugins::SqueezeWax::Foo->bar(...)`.
- **`_`-prefixed helpers are plain functions** and take their arguments
  directly. Call them as `_bar(...)`, including from the offline suites.

This exists because the slip has happened twice: a helper declared as a plain
function but called method-style silently eats the class name as its first
argument. The suites caught it both times, which is the outcome that matters —
but the rule makes it greppable rather than a matter of care.

Existing mixed usage in `Schema.pm` (`_migration_1($dbh)` plain,
`_attachedFile` a method) is **grandfathered and not to be refactored**. The
churn would touch working, tested code to no behavioural end.

## TODO.md

`TODO.md` in the repo root is a shared reminder list — both of us read and
write it.

- Read it at the start of a session, before proposing what to work on.
- When something can't be done now — blocked on a real server, on an external
  answer, or deferred by decision — add it there rather than only mentioning
  it in chat.
- Tick items off as part of the commit that completes them.
- Don't restate the whole list back to me. Mention only what's relevant to
  what we're doing.

## tmp/

`tmp/` holds prompts and hand-off markdown served to Claude Code. It is
git-ignored, so nothing there is versioned and nothing there survives a
clean.

Anything durable that starts life in `tmp/` must reach a tracked file in
the same session — a plan appendix, a decision record, or `TODO.md`.
Never commit files under `tmp/`.

Hand-offs are served from `tmp/` and not committed anywhere else either —
their content lands in `docs/`, `plans/` or `TODO.md`, not as a file. The
2026-09-15..19 build-order hand-offs were removed from `plans/` for this
reason; they are in git history up to `21d6d16710cd4641fa36a1e63c774ce50a3464ba`.