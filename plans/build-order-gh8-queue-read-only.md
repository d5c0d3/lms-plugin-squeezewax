# GitHub #8: the review queue becomes read-only, manual matching removed

*Destination: `plans/build-order-gh8-queue-read-only.md`.*

Written 2026-10-18 by the design chat. Decisions §15.46, settled
2026-10-18 (parts 6–12). Base: `v1-buildout` @ `ec75033` + the B+C docs prompt.
Ships as the next beta, **1.0.0b6** (inferred from §15.37 part 2). Design only;
code by Claude Code. "Verify" below means read the code first; the citations are
from `ec75033` and line numbers may have moved.

## 1. Order (one commit per step; suites green after each)

1. **Migration 8** (`Schema.pm`) + `schema-check.pl`. §3.
2. **Importer rule** (`Match.pm` `_recordNoMatch`, part 9) + `match-check.pl`.
3. **Remove manual writes**: `Match.pm` `recordManual`, `rejectRow`, the manual
   guard in `recordStrict` (and its `'manual'` outcome); `Importer.pm` `manual`
   count, `decidable = examined − kept`, summary line. Tests: `match-check.pl`.
4. **Ownership pass**: `_reasonFor` loses rule 2 (manual); gone-row loop stops
   writing `'orphan'` (ownership-only delete stays); comments in `_decide`
   (the `$strict` guard stays: tier is now `strict` or NULL). Tests:
   `ownership-check.pl`.
5. **Queue page** (`Queue.pm`, `queue.html`): remove `rematch`, `link`, `reject`,
   `relink` and everything only they use (`_link`, `_reject`, `_relink`,
   `_rematch`, `_finishRematch`, `_choices`, `_albumFor`, `_forDisplay`,
   `_orphanList`, `%SYNC_FAILURE`, `$prefs` if unused, the orphan split in
   `beforeRender`). Keep `showtags`, `_refused`, `_display`, `_albumKey`,
   `_actionKey`, `_reviewList`, `_readTags`, `$QUEUE_SQL`. Add a fix line per item
   (§4). A request carrying an old action name writes nothing, makes no Discogs
   request, and renders the page. Header comment: one list, one read-only action.
   Tests: `queue-check.pl` rewritten (§5).
6. **#6** (`Tags.pm`): `decide` adds `unparsed => [...]` when any; the in-file
   branch of `examineCandidates` sets `kind` to `unreadable` (unparsed, no readable
   id), `unreadable-mixed` (unparsed, exactly one readable id) or `in-file`.
   Verdicts unchanged. `Queue.pm` `%CONFLICT_KIND_STRING` gains the two. Tests:
   `tags-check.pl`, `queue-check.pl`.
7. **Sync fields** (`API.pm` `entryFromRelease`: drop `year`, `formats`,
   `labels`; `_labelLabel` if unused; `API/Async.pm` `_finish`: drop the second
   callback argument after checking `Plugin.pm` `_syncDone` and the
   `Settings.pm` callback ignore it). Tests: `api-check.pl`, `sync-check.pl`,
   `scan-sync-check.pl` as needed.
8. **Strings** (`strings.txt`, §4) and the **guard** (`scripts/syntax-check.sh`:
   fail on a non-comment line in `SqueezeWax/` outside `Schema.pm` containing
   `'manual'` or `'orphan'`). Comments elsewhere (`Derive.pm`, `Settings.pm`
   count comment, `relinkOrphan` "both callers" → scanner only; its
   no-match pre-delete stays, commented as unreached since §15.46).
9. **Docs**: decisions, design, README, user guide, TODO (prompt parts B–D).
10. `scripts/check-all.sh` (both drivers), package build, hardware (§6).

## 2. Not changed
`$QUEUE_SQL` and the settings count SQL (same predicate); `relinkOrphan`'s
ownership-only pre-delete (reachable from the scanner); `LOGIC_VERSION` (no
verdict changes; part 9 reaches old rows through migration 8); `Menu.pm`
(already handles a row with ownership and no release id — add a test, §5).

## 3. Migration 8 (data only, one transaction, server handle is AutoCommit)

`begin_work` / `commit`, rollback and die on error (`_migrate` then refuses to
bump `user_version`). Each statement is guarded, so a re-run is safe.

```
-- a. manual rows that own nothing: nothing left to keep
DELETE FROM squeezewax.discogs_match
 WHERE match_tier = 'manual' AND ownership = 'absent';

-- b. the rest: keep the ownership conclusion only
UPDATE squeezewax.discogs_match SET
       match_tier = NULL, state = NULL,
       discogs_release_id = NULL, discogs_master_id = NULL, matched_at = NULL,
       snapshot_artist = NULL, snapshot_album_title = NULL,
       snapshot_track_count = NULL, source_timestamp = NULL,
       derived_master_id = NULL, derived_from_release_id = NULL, derived_at = NULL,
       review_reason = NULL
 WHERE match_tier = 'manual';

-- c. nothing writes 'orphan' any more
UPDATE squeezewax.discogs_match SET review_reason = NULL
 WHERE review_reason = 'orphan';

-- d. re-examine conflicts once under the new no-tag rule (part 9)
UPDATE squeezewax.discogs_match SET source_timestamp = NULL
 WHERE review_reason = 'conflict';
```

One info line with the four counts. No `discogs_no_match` change (manual rows
had none: `recordManual` → `_clearNoMatch`). No CHECK change. Column list:
verify against `pragma_table_info('discogs_match')` before writing (b); the list
above is from migrations 3, 4, 6.

## 4. Strings (EN)

Changed:
- `QUEUE_DESC`: Albums SqueezeWax could not decide on its own, and what to change
  in your files' tags or your Discogs collection to fix each one. Nothing on this
  page changes a match.
- `REASON_AMBIGUOUS`: You own more than one record with this title and artist.
- `QUEUE_TAGS_RESOLVED`: The tags no longer disagree. The next scan will clear
  this.

New:
- `QUEUE_FIX` (label): What to do
- `FIX_CONFLICT`: Give every file of this album the same Discogs release ID, then
  rescan. "Show tags" shows which files differ.
- `FIX_AMBIGUOUS`: Tag the files with the Discogs release ID of the record you
  own, then rescan.
- `FIX_ARTIST_DISAGREE`: If this is that record, tag the files with its Discogs
  release ID or correct the album artist in the tags, then rescan. If it is a
  different record, you can ignore this.
- `FIX_ARTIST_ABSENT`: Add the album artist to the files' tags, or tag them with
  the Discogs release ID, then rescan.
- `FIX_VARIOUS_GATED`: Tag the files with the Discogs release ID, then rescan.
- `QUEUE_STREAMING_NOTE`: Albums with only streaming tracks cannot be tagged. If
  their title or artist differs from your Discogs collection, they stay not owned.
- `QUEUE_TAGS_UNREADABLE`: A Discogs tag holds a value that is not a release ID
  SqueezeWax can read. Correct it to the release number or its Discogs address,
  or delete it, then rescan.
- `QUEUE_TAGS_UNREADABLE_MIXED`: This file names a release, but another Discogs
  tag on it cannot be read. Delete or correct that value, then rescan.

Removed (grep each first; remove only if unused): `QUEUE_REMATCH_BUTTON`,
`_RUNNING`, `QUEUE_REMATCH_COST`, `QUEUE_CHOOSE`, `_MATCHING`, `_ALL`, `_NONE`,
`QUEUE_FILTER`, `QUEUE_LINK_BUTTON`, `_RUNNING`, `QUEUE_RELEASE_ID`,
`QUEUE_TRACKS`, `QUEUE_ATTRIBUTION`, `QUEUE_VIEW_ON_DISCOGS`,
`QUEUE_BADGE_LATER`, `QUEUE_LINKED`, `QUEUE_REJECTED`, `QUEUE_RELINKED`,
`QUEUE_FAILED`, `QUEUE_CONFIRM_REQUIRED`, `QUEUE_REJECT_BUTTON`, `_RUNNING`,
`QUEUE_REJECT_CONFIRM`, `QUEUE_ORPHANS`, `_DESC`, `_EMPTY`, `QUEUE_ORPHAN_MOVE_TO`,
`_NOFIT`, `_FIT_IDENTIFIED`, `QUEUE_RELINK_BUTTON`, `_RUNNING`, `REASON_ORPHAN`.
Kept: `QUEUE_NOT_FOUND` (showtags). The page shows no Discogs data, so no
attribution line is needed (§9.6).

## 5. Offline tests

- `schema-check.pl`: migration 8 on a v7 file holding a manual+exact,
  manual+absent, gone manual (`'orphan'`), strict `'orphan'`, fresh and incumbent
  conflict rows: assert each outcome; re-run is a no-op; `user_version = 8`; CHECK
  still accepts `'manual'`.
- `match-check.pl`: drop `recordManual`/`rejectRow`/manual-guard cases; add
  incumbent conflict + no tag → row deleted, strict no-match row written,
  invariant 1 holds; fresh conflict + no tag unchanged; identified strict + no tag
  → `kept` (pin existing behaviour); scanner relink unchanged.
- `ownership-check.pl`: drop manual cases; a gone identified row gets no
  `'orphan'`; ownership-only row (converted manual) → title route decides, deleted
  if absent with no reason.
- `queue-check.pl`: rewrite as queue → render: one item per reason with its fix
  text; no orphan list; old action names write nothing and issue no request;
  showtags kinds incl. `unreadable` and `unreadable-mixed`.
- `tags-check.pl`: `unparsed` returned; kinds; verdicts unchanged.
- `menu-check.pl`: ownership-only `exact` row → ownership line, no links.
- `api-check.pl`, `sync-check.pl`: entry shape without the three fields.
- `derive-check.pl`, `plugin-check.pl`, `settings-check.pl`: fix any manual
  fixtures; nothing else expected (most "reject" hits there are the token).
- `scripts/check-all.sh` green on bundled SQLite and on 3.22.0
  (`scripts/docker-sqlite322`).

## 6. Hardware (TODO, "Waiting — needs a real server")

1. Repro container (SQLite 3.22.0): on b5, insert a manual row with `sqlite3`;
   update to b6 from the dev `repo.xml`; restart: `user_version = 8`, migration 8's
   info line, no SQL error; the row is ownership-only.
2. Reference server, before update: dump
   `SELECT album_key, discogs_release_id, ownership, review_reason FROM
   discogs_match WHERE match_tier = 'manual' OR review_reason IN
   ('orphan','conflict');`.
3. Update to b6, restart: manual rows ownership-only (or gone if absent), no
   `'orphan'`, conflict rows `source_timestamp` NULL.
4. Menu of the formerly manual album: ownership line, no Discogs links.
5. Queue page: no orphan list, no choose/remove/move buttons; each item has why
   + what to do; Show tags works; settings count vs list length noted.
6. Rescan (share mounted): log shows the formerly manual and conflict albums
   examined; after the scan's sync the reference album is back as
   `artist-disagree`; exact back to 151 (inferred).

## 7. As built

`137efda`..`0be60ba`, 2026-10-18. Deviations (steps 3 and 5 swapped, strings
landed with their first user, migration 8 (d)'s extra guard, `relinkOrphan`'s
`CASE` removed, the streaming note's placement, part 9 on unreadable files) are
recorded in decisions §15.46, "As built, 2026-10-18".
