# Build-order rewrite — §15.11 and the corrections it forces, 2026-09-19

**Drafted 2026-09-19 (design chat).** Fourteenth handoff. Scaffolding; no
authority once applied.

Paste fenced block **contents** exactly. No placeholders.

**Every anchor in this file was checked against the repository at `285e312`
before it was sent, by counting its occurrences in the target file — each
occurs exactly once.** Four anchors earlier in this session failed because they
were written from memory or from a search result's rendering; these were cut
from a clone of the repository instead.

Block A is the decision record. B to L are corrections, most of them to text
this session wrote.

---

## Block A — append to `docs/squeezewax-v1-decisions.md`, after §15.10

````
### 15.11 The importer keeps its `local_tracks` gate; §13.10.1 lands on the ownership pass

**Decided 2026-09-19 (design chat).** Corrects where §13.10.1 applies, not what
it decided. Also corrects the gate in §15.7.

**Decided, in two parts:**

1. **The `local_tracks` gate in `Importer.pm` stays.** §13.10.1's decision —
   all albums, all-remote ones included, are in scope — is unchanged and is
   carried by the **ownership pass** (build-order step 7), which must iterate
   every album. It is not carried by the importer, which since §15.2 does
   identification only.
2. **§15.7's gate keys on the equivalence having fired, not on
   `albums.compilation`.** An album whose artist agreement is reached only
   through the `Various` mapping does not auto-badge until the pages 2–3
   measurement reports, whatever its compilation flag says.

#### Part 1 — two gates were merged into one

Decisions §8 stated a gate for Structural: "The only gate that holds is
`local_tracks == 0` — no local files means no evidence about a physical object.
It is Structural's own rule, not inherited from Strict." `Importer.pm` has
carried a *different* gate since `cec7a46` (2026-09-04), with a different
reason, in its own comment: **"Nothing to read tags from."**

§13.10.1 treated these as one: "The gate exists in `Importer.pm` and is stated in
§8. Its reason was Structural's duration fingerprint." Its reasoning is right
about §8's gate and wrong about the importer's. Structural's reason went with
Structural; the importer's reason is a property of Strict and still holds.

**Verified by reading, at `285e312`, not observed running:**

- `Library::_finish` builds `candidates` from local tracks only, and takes
  `source_timestamp` as the maximum over local tracks only.
- So with the gate removed, an all-remote album reaches `_examine` with no
  candidates, gets `{}` back, and is recorded by `_recordNoMatch` as a
  `discogs_no_match` row with a NULL `source_timestamp`.
- `Importer::_canSkip` never skips a NULL, so that row is rewritten on every
  scan — 186 albums on the reference library, every scan, reading nothing,
  recording a "no tag found" for an album that has no files to carry one.

**Where §13.10.1's measured gain actually comes from.** "Removing the gate
matched 10 additional owned records" was measured by
`scripts/title-agreement.pl` — title-and-artist matching against the
collection, which is **ownership**. §15.2 moved ownership out of the importer
into a server-side pass, and that pass walks `Library::eachAlbum`, which already
does not filter remote tracks. Its own comment anticipated this split: "remote is
selected, not filtered on … The Strict caller decides, not the iterator."

So the obligation moves to step 7, where it does what §13.10.1 measured, and the
importer keeps a gate that is correct for what the importer now does.

**This was caught by reading the code, after the wrong instruction had already
been written into `CLAUDE.md`, `TODO.md` and §15.9 by this same session.** It is
the pattern the session's calibration note names: a step treated as
transcription — carrying §13.10.1's instruction forward — rather than checked
against the artifact it instructs about.

#### Part 2 — the compilation flag cannot carry the gate

§11.3(c) measured `albums.compilation` as wrong in both directions: **11 albums
carry a Various-ish album artist with `compilation = 0`**, and 4 are
`compilation = 1` with a real artist. The cause is in source —
`Slim::Schema::mergeSingleVAAlbum` groups role-1 rows, and Picard-tagged albums
lose theirs — so `compilation = 0` on such an album means "not detected", not
"not a compilation".

§15.7 already says the flag is "deliberately not sufficient on its own" for
artist agreement, then used the flag to define the gate. Keyed on the flag, the
gate would let those 11 albums auto-badge through the `Various` equivalence
ungated — the exposure the gate exists to hold back.

**The gate keys on the mechanism, not on a proxy for it:** an album whose artist
agreement depends on the `Various` mapping is gated; one whose artists agree by
ordinary case-folded equality is not. On the reference library the second group
includes the 23 albums whose LMS album artist is literally `Various` (§11.3(a),
contributor 10001), which agree with Discogs' `Various` without the mapping.

#### What changes

- `CLAUDE.md` step 4 no longer says to drop the gate; step 7 carries the
  all-albums obligation. Same in `TODO.md`'s sequence.
- `TODO.md`'s 2026-09-12 gate item is closed as corrected, not as done.
- §13.10.1, §15.7 and §15.9 are corrected in place.
- The pages 2–3 measurement's question (i) is widened to count albums matched
  through the equivalence, not only `compilation = 1` albums.
````

---

## Block B — CLAUDE.md step 4 — the gate stays

File: `CLAUDE.md`. 
Replace this run of consecutive whole lines:

```
4. **Identification rework** — stop writing `state = 'confirmed'` without a
   collection check (decisions §13.4, design §3 node E); drop the
   `local_tracks == 0` gate (§13.10.1); write `snapshot_artist` and build the
   unambiguous orphan relink (§15.5); remove the `discogsMaxTier` pref
   (§15.8). The importer's `use` gate does **not** change (§15.8)
```

with:

````
4. **Identification rework** — stop writing `state = 'confirmed'` without a
   collection check (decisions §13.4, design §3 node E); write
   `snapshot_artist` from `albums.contributor` (§11.4) and build the
   unambiguous orphan relink (§15.5); remove the `discogsMaxTier` pref
   (§15.8). The importer's `use` gate does **not** change (§15.8), and
   neither does its `local_tracks` gate — there is nothing to read tags from
   in an all-remote album (§15.11)
````

---

## Block C — CLAUDE.md step 7 — carries §13.10.1

File: `CLAUDE.md`. 
Replace this run of consecutive whole lines:

```
7. **Ownership pass** — design §3's flow, writing the `ownership` column
```

with:

````
7. **Ownership pass** — design §3's flow, writing the `ownership` column.
   Covers **every** album, all-remote ones included (§13.10.1, §15.11)
````

---

## Block D — TODO.md sequence, step 4

File: `TODO.md`. 
Replace this run of consecutive whole lines:

```
      4 identification rework (importer stops writing `confirmed`; drop the
        `local_tracks == 0` gate; write `snapshot_artist`, §15.5; build the
        unambiguous orphan relink, §15.5; remove `discogsMaxTier`, §15.8;
        detection bare-master fix; stale comments; `hasAnyStrictMatch`
        semantics. The `use` gate does NOT change, §15.8);
```

with:

````
      4 identification rework (importer stops writing `confirmed`; write
        `snapshot_artist` from `albums.contributor`, §11.4 and §15.5; build
        the unambiguous orphan relink, §15.5; remove `discogsMaxTier`, §15.8;
        detection bare-master fix; stale comments; `hasAnyStrictMatch`
        semantics. Neither the `use` gate nor the `local_tracks` gate
        changes, §15.8 and §15.11);
````

---

## Block E — TODO.md sequence, step 7

File: `TODO.md`. 
Replace this run of consecutive whole lines:

```
      7 ownership pass (design §3 nodes C–K, decisions §14.8, §13.5);
```

with:

````
      7 ownership pass (design §3 nodes C–K, decisions §14.8, §13.5).
        Iterates EVERY album, all-remote included — this is where §13.10.1
        lands, not in the importer (§15.11);
````

---

## Block F — TODO.md 2026-09-12 gate item — closed as corrected

File: `TODO.md`. 
Replace this run of consecutive whole lines:

```
- [ ] 2026-09-12: Importer.pm's local_tracks == 0 gate and the comment above
      it now contradict decisions 13.10.1 and must be changed by the build
      order. The gate came from Structural's duration fingerprint, which no
      longer runs. It excluded 186 of 765 albums, 24%.
```

with:

````
- [x] 2026-09-12: Importer.pm's local_tracks == 0 gate and the comment above
      it now contradict decisions 13.10.1 and must be changed by the build
      order. ~~The gate came from Structural's duration fingerprint, which no
      longer runs.~~ It excluded 186 of 765 albums, 24%.
      2026-09-19, CORRECTED AND CLOSED — decisions §15.11. The struck reason
      belongs to decisions §8's Structural gate, a different gate. The
      importer's own comment gives its reason as "nothing to read tags from",
      which still holds: all-remote albums have no local candidates. The gate
      STAYS in the importer; §13.10.1's all-albums scope is carried by the
      ownership pass (step 7). Closed without a code change.
````

---

## Block G — TODO.md Q4 — the gate keys on the equivalence

File: `TODO.md`. 
Replace this run of consecutive whole lines:

```
        sufficient on its own. GATED: the ownership pass must not auto-badge
        a `compilation = 1` album on this equivalence until the pages 2–3
        measurement reports — see that item's four added questions, and Q9.
```

with:

````
        sufficient on its own. GATED: the ownership pass must not auto-badge
        an album whose artist agreement is reached only through this
        equivalence until the pages 2–3 measurement reports — see that item's
        four added questions, and Q9. Corrected 2026-09-19 (§15.11): the gate
        first keyed on `compilation = 1`, which §11.3(c) measured as wrong for
        11 Various-ish albums.
````

---

## Block H — TODO.md pages 2–3 measurement, question (i)

File: `TODO.md`. 
Replace this run of consecutive whole lines:

```
      (i)   how many LMS albums with `compilation = 1` match a collection
            entry at L2 — page 1 measured ZERO, so §15.7's premise that
            most matched compilations would queue is a projection;
```

with:

````
      (i)   how many LMS albums match a collection entry at L2 with artist
            agreement reached only through the `Various` equivalence —
            counted separately from `compilation = 1`, which §11.3(c)
            measured as unreliable (corrected 2026-09-19, §15.11). Page 1
            measured ZERO compilations matching, so §15.7's premise that most
            matched compilations would queue is a projection;
````

---

## Block I — decisions §13.10.1 — correct where it applies

File: `docs/squeezewax-v1-decisions.md`. 
Replace this run of consecutive whole lines:

```
`Importer.pm`'s gate and the comment above it now contradict this record and
must be changed by the build order.
```

with:

````
~~`Importer.pm`'s gate and the comment above it now contradict this record and
must be changed by the build order.~~ — **corrected 2026-09-19 by §15.11: the
decision above stands and is carried by the ownership pass, which must iterate
every album. `Importer.pm`'s gate is a different gate with a different reason —
"nothing to read tags from", in its own comment since `cec7a46` — and it stays.
This record merged it with §8's Structural gate; the reasoning here is right
about that one only.**
````

---

## Block J — decisions §15.9 — the gate is not step-4 work

File: `docs/squeezewax-v1-decisions.md`. 
Replace this run of consecutive whole lines:

```
- Removing `discogsMaxTier` (§15.8), removing the `local_tracks == 0` gate
  (§13.10.1), redefining `hasAnyStrictMatch`, and the detection bare-master fix
  — none touches the schema.
```

with:

````
- Removing `discogsMaxTier` (§15.8), ~~removing the `local_tracks == 0` gate
  (§13.10.1),~~ redefining `hasAnyStrictMatch`, and the detection bare-master
  fix — none touches the schema. **Corrected 2026-09-19: the gate is not
  removed; see §15.11.**
````

---

## Block K — decisions §15.7 — the gate keys on the equivalence

File: `docs/squeezewax-v1-decisions.md`. 
Replace this run of consecutive whole lines:

```
proceeds; the ownership pass must not auto-badge an album with
`albums.compilation = 1` on a title-plus-various match until that measurement
```

with:

````
proceeds; the ownership pass must not auto-badge an album ~~with
`albums.compilation = 1` on a title-plus-various match~~ **whose artist agreement
is reached only through this equivalence — corrected 2026-09-19 by §15.11, since
§11.3(c) measured the flag as wrong for 11 Various-ish albums** until that measurement
````

---

## Block L — decisions §15.10 — the correction was itself wrong

File: `docs/squeezewax-v1-decisions.md`. 
**Substring** replacement. Substring replacement spanning four lines: it begins with `~~(verified` on one line and ends with `all three.**` partway through a later line. The text after it on that line — ` It is a test rather than` — is untouched.

Replace this text:

```
~~(verified 2026-09-18 by Claude Code, two insert sites)~~ — **corrected
2026-09-18: three sites, not two. Two inserts plus the "expected tables exist"
loop. The count was taken from a summary that named two of the three as "the
insert sites", rather than from the grep that had already listed all three.**
```

with:

````
(verified 2026-09-18 by Claude Code, two insert sites) — **note 2026-09-19: a
2026-09-18 edit struck "two insert sites" as wrong and replaced it with "three
sites". That correction was itself wrong. This sentence counts writers, and there
are two: the inserts. The suite's third reference, the "expected tables exist"
loop, writes nothing — it asserts presence — and belongs in obligation (i)'s
update list, where it now is, not in a count of writers.**
````

---
