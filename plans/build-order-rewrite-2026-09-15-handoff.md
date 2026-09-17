# Build-order rewrite — rulings and TODO text, 2026-09-15

**Drafted 2026-09-15 (design chat).** Scaffolding, like
`plans/design-reconciliation-replacement-text.md`: it exists so the text is
diffable against what lands. It has no authority once applied — decisions and
`TODO.md` are the records.

Every block below is fenced. Paste the **contents** of each fence exactly as
written — do not reword, re-wrap or re-order.

**Two placeholders, and only two.** `{D1C_LOCATIONS}` and `{D4_DEPENDENCIES}`
are filled from the prompt's Phase 0 findings, as the prompt specifies. Nothing
else in any fence is to be changed.

---

## Block A — append to `docs/squeezewax-v1-decisions.md`, after §14.10

````
---

## 15. Build-order rewrite rulings

Rulings taken while rewriting the build order from step 4 onward, after design
was reconciled against §13 and §14.

### 15.1 Master-id tag keys stay a fixed list

**Decided 2026-09-15 (design chat).**

**Decided: the master-id keys remain the fixed conventional list in `Tags.pm`
(`@MASTER_KEYS`). They are not added to `discogsTagNames` and get no Settings
list of their own.**

#### What was found

Read from `SqueezeWax/Tags.pm` and `scripts/tags-check.pl`, not observed
running:

- `discogsTagNames` defaults to `[]`, set at file scope, per §3's choice of
  detection over guessed defaults. Order and precedence are specified in §3,
  invalidation in §3b. The detection action is built in `Settings.pm` over
  `Tags::candidateKeys` (build-order step 3).
- Master keys are `DISCOGS_MASTER_ID`, `DISCOGS MASTER ID` and
  `DISCOGS_MASTER_RELEASE_ID`. They are matched case-insensitively with no
  separator folding, read by `_masterId` only on `decide()`'s clean-hit path,
  and written by `Match::_recordMatch` into `discogs_master_id`.
- Design §3 describes flowchart node F's master as coming "from a configured
  master tag". None exists. That wording is a defect in design, not a behaviour
  to build.

#### Why not make them configurable

§3 refused guessed defaults for release ids because a silent miss there loses an
identification. A silent miss on a master key costs much less: the album drops
from node F to node H (title and artist), which usually still badges it. Making
the keys configurable would reopen hardware-verified step-3 code — the UI, the
detection action and §3b invalidation — for a benefit nobody has measured.

#### What this does not settle

- Node F's reach is **unmeasured**. Custom tags never reach `library.db` (§3),
  so measuring it needs file reads on a real server. See `TODO.md`.
- `Tags.pm`'s stated reason for fixed keys, "no user-visible effect", no longer
  holds: node F makes master tags affect badges. The comment is corrected when
  that file is next touched. The decision stands on the cost-of-miss argument
  above, not on that comment.

**Revisit** if the node F measurement shows tagged albums that node H fails to
badge but node F would.

### 15.2 The collection sync and the ownership pass run in the server, after a scan

**Decided 2026-09-15 (design chat).** Corrects §13.7's first trigger.

**Decided: all three sync triggers run the sync and the ownership pass in the
server process, over asynchronous HTTP. The scan trigger fires on
`['rescan','done']`, debounced, not at scan start.**

#### What was verified

Checked against slimserver `a670a38c2b14ad42b86a39884bcb842121b35571`
(`public/9.1`, 2026-06-19), the same pin as `refs/`:

- `Slim/Networking/SimpleSyncHTTP.pm` `new` logs a backtrace outside the
  scanner: "DO NOT USE SYNCHRONOUS CALLS IN THE SERVER! Use SimpleAsyncHTTP
  instead!"
- `runScanPostProcessing`'s only live caller is `scanner.pl`. Single-directory
  rescans driven inside the server never reach it.
- `['rescan','done']` fires at six sites: `Slim/Utils/SQLiteHelper.pm`
  `_notifyFromScanner` on scanner exit, clean or aborted; three in
  `Slim/Utils/Scanner/Local.pm`, each inside `!main::SCANNER`;
  `Slim/Music/Import.pm` `stillScanning`'s crash cleanup; and
  `Slim/Music/Import.pm` `abortScan`. Five follow `setIsScanning(0)`.
  `abortScan` clears it only when no external scanner is running.
- No plugin-facing scan-start notification was found by grepping for
  `notifyFromArray` with `'rescan'`. Other event mechanisms were not searched.

#### Why not at scan start

The server cannot write while a scan runs (build-order step 3, finding 2b;
`Match::_writeRefusal`). A pass run at scan start would also read
identifications the scan has not yet refreshed. §13.7's reason for adding a scan
trigger — users already rescan when something changes — holds equally for the
end of a scan.

#### Why not in the scanner

- The interval and manual triggers have no scanner process, so the server needs
  its own sync anyway. Doing it in the scanner too means two sync
  implementations under a rule (design §3) that the pass be deterministic.
- In-server rescans never reach the importer.
- A Discogs stall would stall the scan: `API.pm` allows three 60-second
  backoffs per request.
- The importer's `use` gate is tied to tag names.

#### Obligations

1. A pass whose write is refused stays pending for the next notification. It is
   never dropped, and debouncing must not suppress the retry. Otherwise an
   aborted scan silently skips a sync.
2. Tag reads in the pass (§13.5) use a Scheduler task, as `Settings.pm`'s
   detection does, not a blocking loop.
3. The rate-limit wait is non-blocking. `API.pm`'s pure functions are reused;
   its `sleep`-based `get` is not.

**Unverified:** that a later `['rescan','done']` always follows an aborted
external scan. Inferred from `_notifyFromScanner`'s `exit` branch in
`Slim/Utils/SQLiteHelper.pm`, not observed. On the hardware list in `TODO.md`.
````

---

## Block B — insert into `docs/squeezewax-v1-decisions.md` §13.7

Insert immediately after the line
`### 13.7 Sync triggers, and the rule that stops badges vanishing`
and one blank line, before the paragraph beginning `**Decided: three triggers`:

````
**Corrected 2026-09-15 — see 15.2.** The scan trigger fires when a scan
completes, in the server, not at scan start. The completed-sync rule below is
unchanged.
````

---

## Block C — amend two existing `TODO.md` items in place

### C1 — the tag-names item

Find the item whose first line begins
`- [ ] **2026-09-13: v1's configurable tag names are promised twice and`.

1. Change its `[ ]` to `[x]`.
2. Wrap the sentence beginning `A v1 setting with no specification` and ending
   `in the default set.` in `~~` … `~~`. Do not delete it.
3. Append, as the last lines of the item, indented to match:

````
      2026-09-15, CORRECTED — the premise was false. Default and order are
      specified in decisions §3, invalidation in §3b, and all of it is built
      in step 3: pref `discogsTagNames`, default `[]` (`Tags.pm` file-scope
      init), user-set order, detection action (`Settings.pm` over
      `Tags::candidateKeys`). The residual is design text only: design
      carries none of it. Design-fix pass, not the build order. The
      master-id half is decisions §15.1.
````

### C2 — the master-id item

Find the item whose first line begins
`- [ ] **2026-09-13: is a master-id tag among the configurable tag names?**`.

1. Change its `[ ]` to `[x]`.
2. Append, as the last lines of the item, indented to match:

````
      2026-09-15, RESOLVED — decisions §15.1. No master tag is configurable:
      `Tags.pm`'s `@MASTER_KEYS` is a fixed list of three spellings, read only
      on `decide()`'s clean-hit path. The "near-dead if not configured by
      default" reasoning above was built on the wrong premise — node F is
      live for those spellings, and its real reach is unmeasured (see the
      node F measurement item).
````

---

## Block D — new `TODO.md` items

### D1 — under `## Open design questions`

````
- [ ] **2026-09-15: design-fix pass — wording defects recorded, not fixed,
      during the build-order rewrite.** The rewrite session was scoped away
      from design, so these wait for a bounded pass of their own
      (working-agreement §2 wants same-session fixes; the session brief
      overrode it deliberately).
      (a) Design §3, node F: "from a configured master tag". None exists —
          decisions §15.1.
      (b) Design §5: "Each page is matched against LMS albums in memory, the
          conclusion is written to the ownership column". Per-page writes
          break decisions §13.7 (recompute only from a completed sync) and
          §13.10.3 ("exactly one collection entry" needs the whole
          collection). The pass needs a whole-sync in-memory index, no writes
          until the last page, discarded after. INFERRED from reading.
      (c) Design's wording of the sync's scan trigger, if it places it at
          scan start: decisions §15.2 moves it to scan completion, in the
          server. Locations: {D1C_LOCATIONS}
      (d) Design carries none of decisions §3's tag-name specification (see
          the ticked tag-names item).
- [ ] **2026-09-15: detection likely offers a bare master id as a RELEASE
      candidate.** `Tags::candidateKeys` corroborates a bare integer when the
      key matches `/DISCOG/i`, and bare digits parse through
      `_parseReleaseId`, so `DISCOGS_MASTER_ID=999` would be listed as a
      corroborated release-id key. A user who ticks it alone stores master ids
      as release ids. INFERRED from reading, untested — `tags-check.pl`
      covers only the master-URL form. Step-3 code; schedule in the build
      order.
- [ ] **2026-09-15, recorded not acted on: `API.pm`'s synchronous `get` has no
      v1 caller** once Structural is gone and the sync is server-side
      (decisions §15.2). Keep it, or record why it stays, when the sync step
      is planned.
````

### D2 — under `## Next — build-order steps 3–5 (matching)`

````
- [ ] **2026-09-15, BUILD ORDER MUST HANDLE: `Match::_recordMatch` writes
      `state = 'confirmed'` on every clean tag hit, with no collection
      check.** VERIFIED: the SQL literal is `'strict','confirmed'`, and
      `match-check.pl` asserts "a clean hit auto-confirms". Design §3 node E
      and decisions §13.4 confirm only when the tagged id is in the
      collection. INFERRED, not observed in the database: reference-server
      rows are therefore confirmed regardless of ownership. Knock-ons: existing strict rows need their state re-derived
      (Q1 in the build-order rewrite item below); `hasAnyStrictMatch`
      keys on strict+confirmed, so the anomaly warning changes meaning
      (INFERRED); snapshots are captured at confirm time, which moves if
      confirmation moves to the server-side pass; comments saying "the badge
      join is state='confirmed'" are stale.
- [ ] **2026-09-15: size of decisions §13.5's all-tags read** (albums both
      owned and tagged). It now runs server-side in a Scheduler task
      (decisions §15.2), so its size bounds how long the ownership pass takes.
      Unmeasured.
````

### D3 — real-server items

Place under the section whose heading contains `Waiting` if one exists;
otherwise under `## Open design questions`, and say which in the report.

````
- [ ] **2026-09-15, NEEDS A REAL SERVER: node F's reach.** Custom tags are not
      in `library.db` (decisions §3), so count from files: albums with a clean
      release tag AND a master key (`Tags.pm` `@MASTER_KEYS`) AND release id
      not in the collection AND master in the collection; of those, how many
      node H would NOT badge. Decisions §15.1's revisit trigger.
- [ ] **2026-09-15, NEEDS A REAL SERVER: abort a scan mid-run** and confirm a
      second `['rescan','done']` arrives after the scanner exits, and that a
      pending ownership pass then completes. Decisions §15.2 obligation 1
      rests on this; inferred from `_notifyFromScanner`'s `exit` branch,
      not observed.
````

### D4 — under `## Next — build-order steps 3–5 (matching)`, after D2's items

````
- [ ] **2026-09-15: build-order rewrite from step 4 — in progress, NOT
      decided.** The design chat has proposed a sequence; no plan file exists
      yet. Recorded so it is not re-derived from scratch, not as a ruling.
      Proposed, in order:
      4 identification rework (importer stops writing `confirmed`; drop the
        `local_tracks == 0` gate; detection bare-master fix; stale comments;
        `hasAnyStrictMatch` semantics);
      5 migration 3 (its obligations as already recorded in this file);
      6 collection sync (server-side, async — decisions §15.2);
      7 ownership pass (design §3 nodes C–K, decisions §14.8, §13.5);
      8 review queue and manual re-match (decisions §13.10.5, §14.9);
      9 owned badge and context menu (design §4, decisions §14.5, §14.10);
      10 on-demand marketplace lookup (design §7).
      Open questions blocking it:
      Q1 — existing `strict`/`confirmed` rows: migration 3 demotes them all
        and the first ownership pass re-promotes owned ones, or the ownership
        pass demotes the unowned ones. Demoting first removes them from
        orphan recovery (`state = 'confirmed'`) until a sync completes.
        Leaning: the pass does it, now that §15.2 runs it after identification.
        Not decided.
      Q2 — `discogs_no_match.tier`'s CHECK still allows `'structural'`. Does
        it narrow in migration 3? The table is regenerable, so it could be
        dropped and recreated rather than rebuilt. Not in migration 3's
        recorded obligations as far as the design chat read.
      Q3 — RESOLVED, decisions §15.2.
      Dependencies the design chat believes are already in TODO.md, not
      verified by it: {D4_DEPENDENCIES}
````

