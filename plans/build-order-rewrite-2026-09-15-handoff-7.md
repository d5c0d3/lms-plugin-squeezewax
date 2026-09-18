# Build-order rewrite — repair of handoff 6's two stopped blocks, 2026-09-15

**Drafted 2026-09-15 (design chat).** Seventh handoff of the session. Repairs
Blocks B and G of `plans/build-order-rewrite-2026-09-15-handoff-6.md`, both of
which stopped correctly on their own conditions. Scaffolding; no authority once
applied.

Paste fenced block **contents** exactly. No placeholders.

**Why they stopped, recorded so the pattern is visible:**

- **Block B** required "Not decided." to occur exactly once in the
  build-order-rewrite item. It occurs three times, because handoff-5's Block D
  added the phrase twice inside the CONVENTION note it introduced. The design
  chat wrote that note and then set a precondition on a count taken before it
  existed. Block B2 below uses a unique full-line anchor and no count.
- **Block G** quoted its target item's first line with `**` bold markers. Claude
  Code's 2026-09-15 report had quoted that line verbatim without them; the
  design chat typed the shape of the neighbouring items instead of the quote.
  Block G2 below uses the reported text.

**Two loose ends this handoff closes:**

1. Decisions §15.7 landed in `273cf3b` naming four measurement questions as
   "listed against it in `TODO.md`". Block G2 puts them there.
2. Commit `8d25828`'s message claims it closed Q4 and added measurement scope.
   It did neither, because both blocks stopped. History is not rewritten; the
   Phase 2 commit below carries the correction in its own message.

---

## Block B2 — close Q4 in `TODO.md`

Find this single line. It is the Q4 marker, distinguished from the CONVENTION
note's two mentions by the text preceding the phrase on the same line:

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

If that line does not occur exactly once, STOP and report the occurrences. Do
not substitute a shorter anchor.

---

## Block G2 — add four questions to `TODO.md`'s pages 2–3 measurement item

Find the item whose first line is, with no bold markers:

```
- [ ] 2026-09-12: measure collection pages 2 and 3. Page 1 is 100 of 203
```

Append, as the last lines of that item, indented to match its continuation
lines:

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

---

## Block C2 — make the CONVENTION note's own grep advice usable

The note tells a reader to grep for the marker phrase, and contains that phrase
twice itself, so the grep returns two hits that are not open questions. That is
what made handoff 6's Block B stop.

Find this single line:

```
      marker had not been applied consistently.
```

Replace it with:

````
      marker had not been applied consistently. The two occurrences of the
      phrase inside THIS note are expected hits; count from the Q lines
      below, not from a raw grep total.
````
