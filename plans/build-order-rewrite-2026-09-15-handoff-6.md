# Build-order rewrite — Q4 ruling and step-4 housekeeping, 2026-09-15

**Drafted 2026-09-15 (design chat).** Sixth handoff of the session, after
`plans/build-order-rewrite-2026-09-15-handoff.md`, `-2.md`, `-3.md`, `-4.md` and
`-5.md`. Scaffolding; no authority once applied.

Paste fenced block **contents** exactly. No placeholders.

Block C corrects a gap in migration obligation (b) that Claude Code found:
obligation (h) told the test suite to flip its `discogs_no_match.tier` cases,
while (b) never said the same for `match_tier`. Same defect, one column over.

---

## Block A — append to `docs/squeezewax-v1-decisions.md`, after §15.6

````
### 15.7 `Various` and the LMS various-artists label are the same artist

**Decided 2026-09-15 (design chat).** Settles Q4 of the build-order rewrite, and
the `Various` / `Various Artists` item carried forward unresolved in §13.10.6.

**Decided: the ownership pass treats Discogs' various-artists name and LMS's
various-artists label as agreeing. The Discogs side is `Various` or `Various
Artists`, case-folded, after the ` (N)` disambiguator strip. The LMS side is
whatever `Slim::Music::Info::variousArtistString()` returns, case-folded — never
a hardcoded English string.**

#### Why this is a vocabulary mapping and not a number

§13.10.6 sets the test: an equivalence added later "is a **vocabulary mapping
between two catalogues**, the same class as stripping Discogs' trailing ` (N)`
disambiguator, and must be justified on that ground rather than on improving a
number."

It passes that test, and it visibly does not improve a number. **Measured on
page 1: zero impact**, because no compilation matched there (§13.10.6). The two
catalogues simply name the same entity differently — Discogs calls it `Various`,
LMS calls it by its own configurable label — and neither name is evidence about
which record the user owns.

The exposure it removes is on pages 2 and 3: **7 of 100 page-1 collection
entries are `Various`, against 95 LMS albums with `compilation = 1`**. Without
the equivalence, a matched compilation queues for a purely lexical reason.

#### The LMS side is not a literal string

**Verified in slimserver `a670a38c2b14ad42b86a39884bcb842121b35571`
(`public/9.1`, 2026-06-19):** `Slim::Music::Info::variousArtistString` returns
the `variousArtistsString` server pref, which defaults to `undef`, falling back
to the localized string `VARIOUSARTISTS`. The pref is user-editable
(`Slim/Web/Settings/Server/Behavior.pm`), and core itself compares through this
accessor (`Slim/Schema.pm`, `Slim/Schema/Album.pm`,
`Slim/Schema/Contributor.pm`).

**So `'Various Artists'` must never appear as a literal in the comparison.** A
hardcoded English string fails silently on a translated or customised install —
the album queues, no error, nothing in the log. This is the whole reason the
ruling names an accessor rather than a value.

The measurement script's own use of a literal was correct in its context: a
standalone script cannot call LMS accessors (§11.4), and it reported its
divergence set rather than hiding it — 5 of 765 albums, 2 actually diverging.

#### `albums.compilation = 1` is deliberately NOT sufficient

Treating the flag alone as agreement would let an LMS album with a specific
album artist agree with a Discogs `Various` entry on title alone. Combined with
§13.10.6's generic-title hazard — "Greatest Hits" and its kind — that is a route
to a wrong badge, which §14.4 says has no recovery path in v1.

The flag is not needed anyway: `Slim::Schema::Album::artists` already falls
through to the various-artists object for a compilation with no ALBUMARTIST when
`variousArtistAutoIdentification` is on (measured on: `server.prefs:642`), so the
pass sees the label without consulting the flag.

#### What carries the weight instead, and the risk this raises

§11's finding is that an LMS compilation's album artist is a **placeholder
rather than a name**. So for compilations, artist agreement carries almost no
evidence either way once this equivalence is in place: nearly every compilation
on both sides reads "various". What actually bounds a compilation badge is
§13.10.3's requirement of exactly one collection entry agreeing on title.

**That is a real increase in exposure to §13.10.6's generic-title hazard**, and
it is accepted here rather than hidden: two different compilations sharing a
normalised title now differ only in a field that says "various" on both sides.
The bound is unchanged — several candidates still queue — but the *class* of
album that reaches the single-candidate path has grown.

**Revisit trigger:** the pages 2–3 measurement. Any wrong badge on a compilation
reopens this record together with §14.4.

#### The gate: compilation auto-badging waits for the pages 2–3 measurement

**This equivalence lands now; auto-badging a compilation on it does not ship
until the pages 2–3 measurement reports.** The identification and ownership work
proceeds; the ownership pass must not auto-badge an album with
`albums.compilation = 1` on a title-plus-various match until that measurement
answers four questions, listed against it in `TODO.md`: how many compilations
match at all, whether any normalised compilation title collides, whether
`albums.year` agrees with Discogs' `year` on the matches, and whether
`albums.label` or a LABEL tag is reachable without a per-album file read.

Until then a matched compilation queues, which is the behaviour before this
record — so the gate costs nothing that was not already being paid.

**Why a gate rather than confidence.** §13.10.4 fixed this project's posture:
"trading one missing badge for one wrong badge is a bad trade at 1:1 … and would
remain bad at 10:1." A queued compilation is not a lost badge — the user
confirms it and it badges. So this equivalence buys convenience and pays in
wrong-badge exposure on the one class §14.4 gives no recovery path. Both sides of
that trade are unmeasured: page 1 showed **zero** compilations matching, so even
the queue-flood it was meant to prevent is a projection.

#### What is not designed here

Adding a **confirmation test** — label, catalogue number or year checked against
the single remaining candidate — would catch the wrong-compilation case this
record exposes. It is not designed here, and it is not a build-order matter: it
adds a field to the badging rule and therefore amends §13.10.3.

Two findings bound it, both verified against slimserver
`a670a38c2b14ad42b86a39884bcb842121b35571`:

- **`albums.label` exists and is dead.** `SQL/SQLite/schema_23_up.sql` adds it;
  a repo-wide grep finds nothing in 9.1 that writes or reads it, no LABEL or
  ORGANIZATION tag mapping, and `Slim/Schema/Album.pm` does not declare the
  column, so DBIC cannot reach it. Comparing label therefore means a per-album
  file read — the cost §13.1 removed and §15.2 keeps out of the server.
- **`albums.year` and Discogs' `year` are different facts.** The LMS value comes
  from the file's YEAR tag, commonly the original release year; Discogs' is that
  pressing's year. Requiring agreement would queue matches for a reason as
  incidental as the vocabulary difference this record removes.

Recorded as a question in `TODO.md`, to be decided from the measurement rather
than from either of these guesses.

#### Scope

No general synonym table, and no user-editable mapping. This is one fixed
equivalence between two catalogues' names for one entity. A second such mapping
needs its own record and its own justification on §13.10.6's ground.
````

---

## Block B — close Q4 in `TODO.md`

Find this single line inside the build-order-rewrite item — it is the only
occurrence of "Not decided." in that item, which Claude Code counted on
2026-09-15:

```
        question is open and blocks step 7. Not decided.
```

Replace it with:

````
        question is open and blocks step 7.
        RESOLVED 2026-09-15 — decisions §15.7: they agree. The LMS side is
        `Slim::Music::Info::variousArtistString()`, never a literal; the
        Discogs side is `Various` or `Various Artists` after the ` (N)`
        strip, both case-folded. `albums.compilation` is deliberately not
        sufficient on its own. GATED: the ownership pass must not auto-badge
        a `compilation = 1` album on this equivalence until the pages 2–3
        measurement reports — see that item's four added questions, and Q9.
````

If "Not decided." occurs more than once in that item, STOP this block and
report — the count it relies on has changed since it was taken.

---

## Block C — amend migration obligation (b) in `TODO.md`

Find these two consecutive lines:

```
          Assert alongside the existing cases (rejects `'Strict'`,
          accepts `'manual'`).
```

Replace **both** with:

````
          Assert alongside the existing cases (rejects `'Strict'`,
          accepts `'manual'`). ALSO FLIP the existing cases that assert
          `match_tier` ACCEPTS `'structural'` and `'fuzzy'`
          (`scripts/schema-check.pl`, the `for my $tier (qw(strict
          structural fuzzy))` loop): after the narrowing both must be
          REJECTED. Added 2026-09-15 — obligation (h) carried this for
          `discogs_no_match.tier` and (b) did not for `match_tier`.
````

---

## Block D — add Q8 and Q9 to `TODO.md`'s build-order-rewrite item

Find this line:

```
      Dependencies the design chat believes are already in TODO.md, not
```

Insert immediately before it, at the same indentation as the other `Q` lines:

````
      Q8 — what happens to the `discogsMaxTier` pref? VERIFIED 2026-09-15:
        `Settings.pm` initialises it to `'strict'` and lists it in `sub
        prefs`, and `HTML/EN/plugins/SqueezeWax/settings.html` offers a
        `structural` option. Structural and Fuzzy do not exist (§13.8,
        §14.3), so the settings page lets a user select a tier that cannot
        run, and picking it does nothing at all — no error, no log line.
        Four things touch it: the importer's `use` gate (the stale step-4
        plan wanted `@discogsTagNames || ($maxTier ne 'strict' && $token)`),
        decisions §10.2 which lists "tier selector" among the prefs that
        survive clear & rebuild, design §9's settings list, and §3b's
        per-pref invalidation clauses. Design-chat leaning: REMOVE the pref —
        a selector with one valid value is a control that can only be set
        wrong. Against: it is shipped and hardware-verified, so removal needs
        a prefs migration or an accepted orphan key. Blocks step 4, because
        the `use` gate is part of the identification rework. Not decided.
        (The snapshot-column question informally numbered Q8 in chat is
        settled by §15.5; this is the only Q8 in the record.)
      Q9 — should the badging rule gain a CONFIRMATION TEST on the
        single-candidate path: label, catalogue number or year checked
        against the one remaining collection entry? Raised 2026-09-15 by
        §15.7: once `Various` agrees with the LMS label, artist carries no
        information for compilations (§11's placeholder finding), so title
        uniqueness alone bounds a compilation badge — and §14.4 gives a
        wrong version badge no recovery path. VERIFIED against slimserver
        `a670a38c2b14`: `albums.label` exists (`schema_23_up.sql`) but
        nothing in 9.1 writes or reads it and `Slim/Schema/Album.pm` does
        not declare it, so label means a per-album file read; and
        `albums.year` is the file's YEAR tag (often the original year) while
        Discogs' `year` is the pressing's. This AMENDS §13.10.3, so it is a
        decisions change, not build order. Decide from the pages 2–3
        measurement's four added questions, not from these two facts alone.
        Not decided.
````

---

## Block E — close two obsolete Structural items in `TODO.md`

### E1

Find the item whose first line is:

```
- [ ] **2026-09-07: `discogs_no_match` tier `'structural'` skip predicate.**
```

Change its `[ ]` to `[x]` and append, as its last lines, indented to match:

````
      2026-09-15, SUPERSEDED — Structural does not exist (§13.8), so there
      is no `'structural'` no-match row to expire and no TTL to set.
      Decisions §15.6 removes the value from the CHECK entirely. Closed by
      the build-order rewrite, not implemented.
````

### E2

Find the item whose first line is:

```
- [ ] **2026-09-07: §3b needs a `tier='structural'` invalidation clause
```

Change its `[ ]` to `[x]` and append, as its last lines, indented to match:

````
      2026-09-15, SUPERSEDED — the duration margin pref it keys on belongs
      to Structural, which does not exist (§13.8). §3b's "a pref-derived
      tier needs its own clause" note still stands for any future tier; it
      has no v1 subject. Closed by the build-order rewrite, not implemented.
      NOTE: §3b's note now applies to `discogsMaxTier` instead, if that pref
      survives Q8.
````

---

## Block F — add (h) to `TODO.md`'s design-fix item

Find this line:

```
          migration 3 rebuilds the index accordingly (obligation (g)).
```

Insert immediately after it, at the same indentation:

````
      (h) Design §3's artist gate says nothing about the `Various`
          equivalence decided in §15.7, and design §9's settings list may
          still carry the tier selector (Q8). Check both when the
          design-fix pass runs.
````

---

## Block G — add four questions to `TODO.md`'s pages 2–3 measurement item

Find the item whose first line begins:

```
- [ ] **2026-09-12: measure collection pages 2 and 3.
```

(Claude Code's 2026-09-15 report located it at line 613; the line may have
moved. Match on the text, not the number.)

Append, as the last lines of that item, indented to match:

````
      2026-09-15, SCOPE ADDED — decisions §15.7 gates compilation
      auto-badging on this measurement. Four questions it must answer, all
      answerable from the same fixture plus pages 2 and 3, at no extra
      request cost:
      (i)   how many LMS albums with `compilation = 1` match a collection
            entry at L2 — page 1 measured ZERO, so §15.7's premise that
            most matched compilations would queue is a projection;
      (ii)  whether any two collection entries, or a collection entry and a
            DIFFERENT LMS album, share a normalised compilation title —
            this is the wrong-badge exposure §15.7 accepts;
      (iii) for each matched compilation, whether `albums.year` equals the
            Discogs `basic_information.year` — is year usable as a
            confirmation test at all (Q9);
      (iv)  whether `albums.label` is populated on the reference server, and
            whether the files carry a LABEL or ORGANIZATION tag. VERIFIED in
            slimserver `a670a38c2b14` that nothing in 9.1 writes the column;
            (iv) checks that empirically and asks what a file read would
            cost to get it (Q9).
      Add no rule mid-run: report the numbers, decide afterwards. That is
      the same trap warning this measurement's first run honoured over the
      `Various` equivalence itself.
````
