# Build-order rewrite — §15.12, the step-4 plan, and §11.4, 2026-09-19

**Drafted 2026-09-19 (design chat).** Fifteenth handoff. Scaffolding; no
authority once applied.

Paste fenced block **contents** exactly. No placeholders.

**Every anchor here was cut from a clone at `a9b71b6` and counted against the
real file; each occurs exactly once. The whole handoff was then applied to a
scratch copy and read back.**

**This handoff also adds a new file,** `plans/build-order-step-4-identification-rework.md`,
supplied alongside it. Save it as-is; it is not pasted from a block.

---

## Block A — append to `docs/squeezewax-v1-decisions.md`, after §15.11

````
### 15.12 Four step-4 rulings: artist backfill, one-to-one relink, where the pref migration runs, master keys

**Decided 2026-09-19 (design chat), ruled on the draft of
`plans/build-order-step-4-identification-rework.md`,** which carries the detail
(§2.5 to §2.8). Each was put as a choice between options; the chosen option and
the reason the others lost are recorded here.

#### 1. Existing snapshots are backfilled with the artist

During the identification pre-pass, a row that has a snapshot
(`snapshot_track_count` non-NULL) and a NULL `snapshot_artist`, and whose album
is current, gets `snapshot_artist` filled from that album's
`albums.contributor` name. That column only, no file reads, through `_writeOk`,
and idempotent because it fills only NULLs.

**Why it is needed at all.** Nothing wrote `snapshot_artist` before step 4, so
every existing snapshot has NULL there, and §15.5's fit is exact equality — NULL
fits nothing. The skip contract means an unchanged album is never re-examined,
so the normal write path would never fill them in either. Without a backfill,
recovery would cover nothing that exists on the reference server today.

Rejected: **no backfill** — the largest silent gap, and it hides itself, since a
failed relink looks exactly like an album with no match. **Relaxing the fit to
title and track count when the artist is NULL** — recovers old rows without
writing to them, but weakens the predicate for exactly those rows and adds a
second predicate to test and reason about.

#### 2. A relink needs a unique fit in both directions

An orphaned row and a key-miss album are paired only when **the orphan fits
exactly one miss and that miss fits exactly one orphan**, decided on the whole
library in a pre-pass before the main loop. Every other orphan and miss is left
untouched and counted as unresolved.

Rejected: **uniqueness on the orphan side only** — one new album could claim two
orphans, and the outcome would depend on scan order. **Deferring the relink to
step 8** — lowest risk now, but recovery would do nothing at all until the review
queue ships. The ambiguous branch remains a step-8 obligation (§15.5 part 4).

#### 3. The `discogsMaxTier` migration runs from `Plugin.pm`, at file scope

`Plugin.pm` loads `Settings.pm` only under `main::WEBUI`, so a migration placed
there would never run on a headless server. File scope in `Plugin.pm` is the
core plugins' pattern (`Slim/Plugin/Podcast/Plugin.pm:40` at `a670a38`), and the
scanner never loads `Plugin.pm`, so one process writes the prefs file.

Rejected: **`Settings.pm`** — the dead key would survive forever on headless
servers. **No migration** — harmless, since nothing reads the key, but it leaves
exactly the kind of orphan §15.8 set out to remove.

#### 4. Detection excludes master-id keys entirely

A key naming a master — case-insensitively in `Tags.pm`'s `@MASTER_KEYS`, or
matching `/MASTER/i` — is not offered by detection at all, as a master URL
already is not. A master id is known not to be a release id, so the demoted list
("other numeric tags that might be one") is the wrong place for it.

Rejected: **demoting** them — inconsistent with the master-URL behaviour.
**Offering them with a warning** — most UI work, and still lets a user tick the
wrong key.

#### The artist source, and a finding against §11.4

The snapshot artist is `contributors.name` for `albums.contributor`, read by raw
SQL in the iterator, and stored and compared **as bytes on both sides**: no
`sqlite_unicode` or `sqlite_string_mode` is set anywhere in slimserver's
`Slim/`, and LMS decodes contributor names by hand
(`Slim/Schema/Album.pm:239`). Decoding one side only would make every
non-ASCII artist silently fail to fit.

Reading `Album::artists` at `a670a38` to confirm §11.4 found its rationale
false; §11.4 carries the correction in place. The snapshot is unaffected — it
compares LMS with LMS — but the ownership pass compares LMS with Discogs, and
must choose its artist source knowingly. That is `TODO.md` Q10.
````

---

## Block B — decisions §11.4 — correct the rationale in place

File: `docs/squeezewax-v1-decisions.md`. INSERT after these two lines. They end the paragraph; the blank line and the paragraph beginning `This means the first search` that follow are untouched.

```
`TRACKARTIST` 6 — `Slim/Schema/Contributor.pm:76-84`) are LMS's business, not
ours.
```

Inserted text:

````
**Corrected 2026-09-19 (§15.12), from source at slimserver `a670a38`.** Two
claims in the paragraph above are false. `Album::artists` does **not** build on
`albums.contributor`: it reads role rows (`ALBUMARTIST`, then `BAND` if the pref
is set, then `ARTIST`) and falls back to `Album::contributors` — every
contributor via `contributor_album` (`Slim/Schema/Album.pm:95-100`) — never the
`albums.contributor` column, which is the separate `belongs_to` at `:44`. And
`Album::artists` can call `Slim::Schema->variousArtistsObject` for a compilation
with no usable artist, which §11.3(d) forbids because it writes to the library.
**So the recommendation to use `Album::artists` is withdrawn; the
`albums.contributor` column stands as the source**, read by raw SQL. That column
is set per track by `_createOrUpdateAlbum` from the primary contributor
`_postCheckAttributes` passes it (`Slim/Schema.pm:1283-1296`, `:3060-3091`), so
the last track written wins. Where the choice matters — the ownership pass,
comparing against Discogs — it is `TODO.md` Q10.
````

---

## Block C — TODO.md — the build-order item now has a plan

File: `TODO.md`. Replace this run of consecutive whole lines:

```
      decided.** The design chat has proposed a sequence; no plan file exists
      yet. Recorded so it is not re-derived from scratch, not as a ruling.
```

with:

````
      decided.** ~~The design chat has proposed a sequence; no plan file exists
      yet.~~ **2026-09-19: the sequence is decided (decisions §15.9, and
      `CLAUDE.md`'s Build order), and step 4's plan is
      `plans/build-order-step-4-identification-rework.md`. The item stays
      open for Q9 and Q10.** Recorded so it is not re-derived from scratch,
      not as a ruling.
````

---

## Block D — TODO.md — add Q10

File: `TODO.md`. INSERT before this line, at the same indentation as the other Q lines.

```
      Dependencies the design chat believes are already in TODO.md, not
```

Inserted text:

````
      Q10 — which LMS album artist does the ownership pass compare with
        Discogs'? Decisions §11.4 recommended `Slim::Schema::Album::artists`,
        and §15.12 found its rationale false at slimserver `a670a38`:
        `artists` never reads `albums.contributor`, and it can reach
        `variousArtistsObject`, which §11.3(d) forbids because it writes to
        the library. Step 4 uses the `albums.contributor` column for the
        snapshot, which compares LMS with LMS only. Step 7 compares with
        Discogs, where the choice decides which albums badge — including the
        11 Various-ish albums §11.3(c) measured with `compilation = 0`, and
        §15.11's equivalence gate. Must not be `Album::artists`. Blocks
        step 7. Not decided.
````

---

## Block E — TODO.md — two step-4 follow-ons

File: `TODO.md`. INSERT after these two lines — the last lines of the `snapshot_artist` item — so the two new items are the last of the section, before its blank line and `## Open design questions`.

```
      snapshot columns; a conflict row's snapshot columns are NULL; the
      narrow delete still fires on a conflict row whose tags were removed.
```

Inserted text:

````
- [ ] **2026-09-19: the ambiguous orphan relink is a step-8 obligation.**
      Decisions §15.5 part 4 and §15.12 part 2: step 4 relinks only
      one-to-one fits. An orphan fitting several new albums, or a new album
      fitting several orphans, is left untouched and counted as unresolved
      in the importer's summary. Step 8's review queue must offer it,
      pre-filled with the previous answer (decisions §2). Until then those
      rows stay orphaned: no loss, no automatic relink.
- [ ] **2026-09-19: the artist snapshot is order-dependent for mixed-artist
      albums with no album artist.** VERIFIED at slimserver `a670a38`:
      `Slim::Schema::_createOrUpdateAlbum` sets `albums.contributor` per
      track from `_postCheckAttributes`'s primary contributor (`ALBUMARTIST`,
      else `ARTIST`, else `TRACKARTIST`, first entry), so the last track
      written wins. A rescan in a different order can change it; the snapshot
      then does not fit, which fails safe for a tagged album
      (identification recovers it) and loses a manual row's choice. Same
      shape as the retagged-title hole. Recorded, not solved — revisit if
      seen on hardware.
````

---
