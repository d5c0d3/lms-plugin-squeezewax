# Build-order rewrite — Q8 ruling, 2026-09-18

**Drafted 2026-09-18 (design chat).** Eighth handoff of the session, after
`plans/build-order-rewrite-2026-09-15-handoff.md` and `-2.md` through `-7.md`.
Scaffolding; no authority once applied.

Paste fenced block **contents** exactly. No placeholders.

**On the dates.** §15.1 to §15.7 are dated 2026-09-15 and stay that way — this
session spans several days and each record is dated to when its decision was
taken. This one is 2026-09-18. The mismatch is correct; do not normalise it.

**Block A is conditional.** §15.8 rules that only `Settings.pm` and the settings
template read the pref. Phase 0 verifies that before Block A lands.

---

## Block A — append to `docs/squeezewax-v1-decisions.md`, after §15.7

````
### 15.8 The `discogsMaxTier` pref is removed; design already required it

**Decided 2026-09-18 (design chat).** Settles Q8 of the build-order rewrite.

**Decided: `discogsMaxTier` is removed — the pref, its entry in `sub prefs`, and
the selector in the settings template — by a `$prefs->migrate` step in the
identification rework. The importer's `use` gate is left exactly as it is.**

#### This is compliance, not a choice

Design §9, live spec since the reconciliation, reads: *"Matching itself is not
configurable. Which tag names are read is a setting (§3), but the comparison is
not."* The reconciliation deleted the maximum-tier bullet along with the
duration margin and the multi-disc auto-confirmation bullet.

`Settings.pm` still initialises `discogsMaxTier` and lists it in `sub prefs`,
and `HTML/EN/plugins/SqueezeWax/settings.html` still offers a `structural`
option. **The code contradicts the live spec**, and `docs/working-agreement.md`
§2 makes design win. Removing the pref brings code into line; keeping it would
need a change to design.

The question was framed in `TODO.md` as a choice with a cost on the removal
side. That framing was wrong, and is recorded here rather than quietly
abandoned: the cost is real but small (below), and it is the price of compliance
rather than of a preference.

#### The failure mode in user terms, which is the stronger argument

With the pref left in place, a v1 user opens Settings, selects Structural, saves,
and **nothing happens** — no matching changes, no error, no log line. They have
configured a tier that does not exist. The likely next step is a bug report
about a plugin that ignores its own settings.

§14.1 refused to leave a schema permitting values nothing writes, on the ground
that it is "a trap for the next reader". A settings control that can only be set
wrong is the same trap, pointed at the user instead of the maintainer.

#### The mechanism, verified

Read at slimserver `a670a38c2b14ad42b86a39884bcb842121b35571` (`public/9.1`,
2026-06-19), the same pin as `refs/`. Not observed running.

- **`Slim::Utils::Prefs::Base::remove( list )`** deletes each named key and its
  `_ts_`-prefixed timestamp twin, then saves the namespace.
- **`Slim::Utils::Prefs::Namespace::migrate( $version, $callback )`** runs the
  callback when the namespace's `_version` is below `$version`, and sets
  `_version` to `$version` if the callback returns true. This is the in-tree
  house pattern, not an improvisation: `$prefs->migrate(1, sub {…})` appears in
  Podcast, DateTime, CLI, iTunes, xPL, PreventStandby, FullTextSearch, Rescan,
  AudioScrobbler and RandomPlay.
- **The edge case that would otherwise have surfaced on hardware.**
  `Namespace::new` sets `_version => 0` **only when the prefs file does not
  exist**. On the reference server `squeezewax.prefs` does exist and was written
  before this plugin ever called `migrate`, so the key is *absent* rather than
  zero. `$version > undef` evaluates true, which is the behaviour wanted, and
  `Slim/Utils/Prefs/Namespace.pm` carries `use strict` **without** `use
  warnings`, so it is silent. The migration therefore runs correctly on a fresh
  install and on the reference server alike.

#### The `use` gate does not change, and that is a finding

The importer's `use` gate is `scalar @{discogsTagNames}`. Identification is
tag-driven and nothing else runs in the importer, so gating on tag names is
exactly right and needs no revision.

`plans/build-order-step-4-structural-matching.md` §0.7 prescribed
`@discogsTagNames || ($maxTier ne 'strict' && $token)`, and `TODO.md` carried an
item saying the current gate "becomes wrong the moment step 4 lands". Both exist
to let a user with no tag names run Structural. There is no Structural, so the
gate is correct as written. That `TODO.md` item is closed as superseded by this
record, and the work it described is removed from the identification step's
scope.

#### What goes with it

- `HTML/EN/plugins/SqueezeWax/settings.html`: the selector and its options.
- `Settings.pm`: the `$prefs->init` entry and the `discogsMaxTier` element of
  `sub prefs`, which becomes `discogsToken` alone.
- §10.2's list of preferences that survive "clear & rebuild matches" names a
  "tier selector"; corrected in place.
- §3b's note that "a pref-derived tier needs its own invalidation clause" had
  been provisionally pointed at `discogsMaxTier` when the two obsolete
  Structural items were closed. The pref does not survive, so that note has no
  v1 subject at all.

#### Scope

If a tier concept ever returns in v2, the pref name is free to reuse. A user's
prefs file will simply not carry it, which is the normal state for a new pref
and needs no further handling.
````

---

## Block B — close Q8 in `TODO.md`

Find this single line. The phrase "Not decided." is NOT unique in this item, so
match the whole line:

```
        the `use` gate is part of the identification rework. Not decided.
```

Replace it with:

````
        the `use` gate is part of the identification rework.
        RESOLVED 2026-09-18 — decisions §15.8: the pref is REMOVED, by a
        `$prefs->migrate` step in the identification rework. Design §9 already
        says matching is not configurable, so this is compliance rather than a
        choice, and the code was the thing out of line. The `use` gate does NOT
        change — it stays `scalar @{discogsTagNames}`, which is correct for
        tag-driven identification.
````

If that line does not occur exactly once, STOP and report the occurrences.

---

## Block C — close the `use` gate item in `TODO.md`

Find the item whose first line is:

```
- [ ] **Step 4 must relax the `use` gate.** It is currently
```

Change its `[ ]` to `[x]` and append, as its last lines, indented to match its
continuation lines:

````
      2026-09-18, SUPERSEDED — decisions §15.8. The replacement gate existed
      to let a user with no tag names run Structural; Structural does not
      exist (§13.8). `scalar @{discogsTagNames}` is correct for tag-driven
      identification and is left alone. Closed by the build-order rewrite,
      not implemented.
````

---

## Block D — narrow design-fix item (h) in `TODO.md`

Find these three consecutive lines:

```
          equivalence decided in §15.7, and design §9's settings list may
          still carry the tier selector (Q8). Check both when the
          design-fix pass runs.
```

Replace **all three** with:

````
          equivalence decided in §15.7 — check that when the design-fix pass
          runs. The other half of this item is ANSWERED and needs no pass:
          design §9 does NOT carry the tier selector, because the
          reconciliation deleted it. That is precisely why decisions §15.8
          rules the pref out of the code rather than out of design.
````

---

## Block E — correct the preferences line in decisions §10.2

Find these two consecutive lines in `docs/squeezewax-v1-decisions.md`:

```
- **Preferences** — tag names, margin, TTL, tier selector. This action clears
  results, not configuration.
```

Replace **both** with:

````
- **Preferences** — tag names, ~~margin, TTL, tier selector~~ — **corrected
  2026-09-18: the duration margin and the no-match TTL belonged to Structural
  and were never built; the tier selector is removed by §15.8. What survives is
  the tag-name list and the access token** — this action clears results, not
  configuration.
````
