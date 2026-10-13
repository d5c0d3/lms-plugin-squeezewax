# Build-order step 9b: the menu after hardware

Written 2026-09-30 by the design chat. Input: hardware report 41, diagnosis 44,
the owner's requests and answers (hand-off 43). Records: decisions §15.26.
Base: `v1-buildout` at `d9798fb`, plugin 0.0.0.14, `check-all.sh` 1885 green.
Pin: slimserver `a670a38`.

**What it does.** The menu shows **links to apps that can open them** and **one
ownership line to players**. It links the **release and the master** where each
is stored. The settings page gains a plain discogs.com link.

**What it does not do.** No Discogs request, no Discogs data in the menu (pressing
details are step 10's), no schema change, no change to the view or its triggers
(44: they work).

## §0. Rulings (hand-off 43)

1. Release + master links, each only where its id is usable.
2. Labels say what is true: the release is "your pressing" only for `exact`.
3. Split by what the app can open.
4. Pressing details → step 10. Owned version(s) → v2.
5. Settings: add a plain discogs.com link.

## §1. What the menu shows (`Menu.pm`)

The providers already receive `( $client, $url, $obj, $remoteMeta, $tags, … )`
(`AlbumInfo.pm` `menu`, `TrackInfo.pm` `menu`). Pass `$client` and `$tags` down to
`_itemFor`.

**Links**, computed from the row as now:

| link | when | label (`exact`) | label (`version`) | URL |
|---|---|---|---|---|
| release | `discogs_release_id` defined, not `conflict` | "On Discogs: your pressing" | "On Discogs: the pressing your files name" | `/release/{id}` |
| master | `_effectiveMaster($row)` defined, not `conflict` | "On Discogs: all versions" | same | `/master/{id}` |

Order: release, then master. `_effectiveMaster` is called, not copied.

**Who gets what:**

```
linkCapable = !$tags->{menuMode}                       # Default UI template, plain CLI
           || !$client                                 # menu mode with no player (DEFAULT, 43)
           || Slim::Utils::Misc::canFollowWeblinks($client)
```

- linkCapable **and** at least one link → **links only**.
- otherwise → **one text line**: "You own a pressing" (`exact`) / "You own a
  version" (`version`). This covers players, and link-capable apps where no link
  exists (a `version` matched by title). **Ownership is never shown as nothing.**
- `absent`, no row, no library album → nothing, as now.

Verified at the pin: `canFollowWeblinks` (`Slim/Utils/Misc.pm:413-418`) is true
for a browser User-Agent or iPeng / SqueezePad / OrangeSqueeze / Squeeze-Control /
Squeezer / OpenSqueeze / SqueezeClient (`:68-69`), and false without a controller
UA. Core uses it for the same purpose (`Slim/Control/XMLBrowser.pm:1180`).
**Limit, accepted (43):** it reads the UA of the app that last **controlled** the
player, not the one asking.

**Strings:** `MENU_OWN_PRESSING` → "You own a pressing"; `MENU_OWN_VERSION` → "You
own a version"; `MENU_LINK` is replaced by `MENU_LINK_OWNED`, `MENU_LINK_FILES`,
`MENU_LINK_MASTER`. Labels are descriptive, not brand use (design §1).

## §2. Settings (`settings.html`, `strings.txt`)

In the attribution block, a third line: a plain link to `https://www.discogs.com/`,
label `PLUGIN_SQUEEZEWAX_ATTRIBUTION_SITE` = "discogs.com". No `rel`, as the other
one. "Data provided by Discogs." keeps its collection target and its fallback.

## §3. Suite (`menu-check.pl`)

Replace part 2's table with the §1 matrix, asserted cell by cell:

- `exact` / `version` × release present or not × master present, stale or absent ×
  `conflict` or not;
- × app: non-menu mode; menu mode with no client; menu mode with a
  link-capable UA; menu mode with a player UA (e.g. `SqueezePlay`).

Plus: **a link-capable app never gets an empty entry for an owned album** (the V2
case), and **a player never gets a `weblink`**. Part 5 (zero requests) unchanged.
`canFollowWeblinks` is exercised through a stub client with a `controllerUA`, not
by stubbing the function, so the suite tests the real rule.

## §4. Phasing (Sonnet: the design is settled and the change is small)

| | |
|---|---|
| P | hand-off 46's doc edits (this plan into `plans/`, §15.26, design §4, TODO, working agreement) |
| A | `Menu.pm` + strings + `menu-check.pl` |
| B | settings link + string + `settings-check.pl` |

Then package, 0.0.0.15.

## §5. Hardware (short, owner-led)

1. **Material**, album E (2886): two links, no text line. V1 (2927): release
   ("files name") + master. V2 (3204): the text line.
2. **Default UI**: the same, via album info.
3. **SqueezePlay**: E and V2 each show one text line and **no** link row.
4. **The limit, observed:** control a player from Material, open its track menu on
   SqueezePlay, and record which variant shows.
5. **Settings**: the discogs.com link, no `rel`.
6. **Log level first** (working agreement §4.1, new rule): read the running level
   of `plugin.squeezewax` on the logging page before any check that reasons from
   the log.

## §6. Where the evidence is thin

- `canFollowWeblinks`'s UA list is core's, from source. How Material and
  SqueezePlay identify themselves is **not read**; §5.1 and §5.3 settle it.
- Which variant a shared player shows is inferred from the function's shape.
