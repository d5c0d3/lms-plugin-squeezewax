# SqueezeWax — Implementation Plan

Companion to `docs/squeezewax-design.md` (the source of truth for scope and
behaviour). This document covers *how* v1 gets built: the file skeleton, what
each file is modeled on, and — critically — which capabilities the design
spec assumes that have **no confirmed LMS API**, found by reading
`refs/slimserver/`, `refs/lms-plugin-tidal/`, and `refs/Spotty-Plugin/`
directly rather than from memory (per `CLAUDE.md`'s hard rule against
invented APIs).

---

## 1. Build order

Per `CLAUDE.md` / spec §11, v1 only, in this order:

1. Plugin skeleton + `install.xml` that LMS actually loads
2. SQLite schema per spec §10 (`discogs_match`, `discogs_collection`,
   `discogs_price_snapshot`)
3. Strict-tier matching (release ID already in file tags)
4. Structural-tier matching (track count + per-track durations)
5. Review queue + manual re-match

OAuth, badges beyond the skeleton, marketplace lookup, and anything in
v2/v3 do not start until matching works end to end.

---

## 2. File skeleton

| File | What it does | Modeled on | Spec section |
|---|---|---|---|
| `install.xml` | Manifest LMS reads to load the plugin: `<module>`, `<importmodule>`, category, target version. | `refs/lms-plugin-tidal/install.xml:1-18` (root `<extensions>` — Spotty's own `install.xml` uses a different root tag, `<extension>` singular; TIDAL is the pattern CLAUDE.md names, so that's the one followed here) | §1 naming |
| `Plugin.pm` | Entry point. `initPlugin`: init prefs, register `Settings.pm`/`Settings/Auth.pm` under `main::WEBUI`, register the importer via `Slim::Music::Import->addImporter`, register `AlbumInfo`/`ArtistInfo`/`TrackInfo`/`GlobalSearch` menu providers for the badge context menu and cross-browse entries (§4, §6). No `ProtocolHandler` registration, no transcoding table — this plugin never plays audio. | `refs/lms-plugin-tidal/Plugin.pm:36-96` for shape; explicitly *not* Spotty's `Plugin.pm:121,157,236-289` (protocol handler / transcoding logic) | §2, §13 |
| `Importer.pm` | Scan-time matching cascade (Strict → Structural → Fuzzy). Runs in the scanner process (`main::SCANNER`), registered via `Slim::Music::Import->addImporter`. Does **not** subclass `Slim::Plugin::OnlineLibraryBase` — that base class exists to let a plugin *create* tracks for a service it streams from (TIDAL/Spotty's job); SqueezeWax never creates tracks, it annotates albums LMS already scanned from disk. Deliberate divergence from both reference plugins. | Structurally similar to `refs/lms-plugin-tidal/Importer.pm:21-49` (`startScan`, progress reporting via `Slim::Utils::Progress`) but without the `OnlineLibraryBase` inheritance | §3, §8 |
| `API.pm` | Shared Discogs constants/helpers: base URL, rate-limit constant (60/min), response-shape → internal-hash transforms, image URL helpers. | `refs/lms-plugin-tidal/API.pm:12-25`, `:79-118` | §1, §13 |
| `API/Async.pm` | Server-side (LMS process) Discogs calls — search, release lookup, marketplace lookup, OAuth-authenticated collection/wantlist pulls — via `Slim::Networking::SimpleAsyncHTTP` (confirmed: `refs/lms-plugin-tidal/API/Async.pm:13,801`). Handles the 60 req/min throttle. | `refs/lms-plugin-tidal/API/Async.pm:717-886` (`_call`, caching/throttling pattern) | §5, §7, §13 |
| `API/Sync.pm` | Scanner-side Discogs calls for the matching cascade, via `Slim::Networking::SimpleSyncHTTP` (resolved — see §4.4 below). | `refs/lms-plugin-tidal/API/Sync.pm:9,104` | §3, §13 |
| `Settings.pm` | Matching-tier selector, duration margin, badge colors/toggles, marketplace filter defaults, sync intervals. | `refs/lms-plugin-tidal/Settings.pm:1-51` | §9 |
| `Settings/Auth.pm` | Discogs OAuth flow page + credential storage. | `refs/lms-plugin-tidal/Settings/Auth.pm:1-89` — structural inspiration only; Discogs uses OAuth 1.0a, not TIDAL's device-code flow, so the actual handshake will differ | §5, §9 |
| `Schema.pm` | Owns `discogs_match` / `discogs_collection` / `discogs_price_snapshot`: creation, migration, query helpers. No reference plugin demonstrates *persistent* custom tables — see §4 below. | Primitive confirmed real (`Slim::Schema->dbh()->do('CREATE TABLE ...')`, `refs/slimserver/Slim/Plugin/OnlineLibraryBase.pm:47-52`), pattern itself unprecedented in refs/ | §10 |
| `InfoMenu.pm` | Badge context-menu actions (pressing details, credits, re-match, "View on Discogs") and the JSON-RPC dispatch for them. | `refs/lms-plugin-tidal/InfoMenu.pm:20-28` (`Slim::Control::Request::addDispatch`) | §4 |
| `HTML/EN/plugins/SqueezeWax/settings.html`, `auth.html` | TT templates for the settings pages above. | `refs/lms-plugin-tidal/HTML/EN/plugins/TIDAL/settings.html` | §9 |
| `strings.txt` | `PLUGIN_SQUEEZEWAX_*` string tokens. | `refs/lms-plugin-tidal/strings.txt` | naming rule |

Deliberately omitted, unlike Spotty: `ProtocolHandler.pm`, `Helper.pm` /
helper-binary management, transcoding-table logic, `LastMix.pm` — none apply
since this plugin never plays audio.

---

## 3. Verified-real APIs this plan relies on

(cited so nothing here is a guess — each confirmed by reading the file/line
in `refs/`)

- `Slim::Music::Import->addImporter` — `refs/slimserver/Slim/Plugin/OnlineLibraryBase.pm:34`
- `Slim::Schema->dbh()` (raw DBI handle to LMS's own SQLite db) — used directly by TIDAL: `refs/lms-plugin-tidal/Importer.pm:151-163`
- `Slim::Networking::SimpleAsyncHTTP` — `refs/lms-plugin-tidal/API/Async.pm:13,801`
- `Slim::Networking::SimpleSyncHTTP` — `refs/lms-plugin-tidal/API/Sync.pm:9,104`; module confirmed at `refs/slimserver/Slim/Networking/SimpleSyncHTTP.pm:1`
- `Slim::Menu::AlbumInfo` / `ArtistInfo` / `TrackInfo` / `GlobalSearch` `registerInfoProvider` — `refs/slimserver/Slim/Menu/Base.pm:89`, used in `refs/lms-plugin-tidal/Plugin.pm:74-88`
- `Slim::Control::Request::addDispatch` — `refs/lms-plugin-tidal/InfoMenu.pm:23-27`
- `Slim::Web::Settings` base class + `Slim::Web::HTTP::CSRF` — `refs/lms-plugin-tidal/Settings.pm:4,14,16`

---

## 4. Spec capabilities with no confirmed LMS API

### 4.1 Badge overlay on the native Albums grid — no confirmed hook

A real service-badge mechanism exists in LMS core:
`Slim::Plugin::OnlineLibrary::Plugin::addLibraryIconProvider` / `getServiceIcon`
(`refs/slimserver/Slim/Plugin/OnlineLibrary/Plugin.pm:298-319`), rendered via
`OnlineServices.getIconForId(item.extid)` as a 12–20px corner-positioned
`<img class="extIdImg">` (`refs/slimserver/HTML/Default/xmlbrowser.html:451`;
CSS at `refs/slimserver/HTML/Default/slimserver.css:552-568`).

Tracing its actual render path: it only fires in `xmlbrowser.html`, the
template used for OPML/app-feed browsing (what Spotty's "apps" menu uses).
The native library "Albums" grid template
(`browsedb.html` → `galleryitem` → `thumbnailItemImg`, in
`refs/slimserver/HTML/EN/hreftemplate:190-217`) has no
`extIdImg` / `getIconForId` call anywhere. Since SqueezeWax's badge needs to
render on locally-ripped albums browsed through the normal Albums grid — not
an app feed — this mechanism does not cover the spec's primary badge case.

Also checked the Now Playing screen: CSS exists for
`#ctrlCurrentArt img.extIdImg` but no template, and the shipped `Main.js`,
ever populates it — a dead/unused hook in this codebase.

**Verdict:** no confirmed generic badge/overlay API for what spec §4 needs.
The plugin will have to draw its own overlay (custom TT block override or
CSS/JS injection into the default skin's album-grid templates), and that
approach must be checked against Material Skin's own templates (not present
in `refs/`) before assuming it's skin-independent — exactly the risk spec
§4/§12 already flagged.

### 4.2 Two-color owned/wantlist badge — the existing API structurally can't do it

Even where `getServiceIcon` does fire, it returns one fixed icon URL per
service tag, parsed from `extid`'s prefix
(`refs/slimserver/Slim/Plugin/OnlineLibrary/Plugin.pm:316`:
`$id =~ s/^(\w+?):.*/$1/`). It carries no per-item state, so it can't
distinguish two Discogs-matched albums where one is owned (green) and one is
wantlist (amber). Spec §4 needs per-edition color; this API cannot provide
it even in the context where it does render.

### 4.3 Persistent plugin-owned SQLite tables — primitive confirmed, pattern unprecedented

`Slim::Schema->dbh()` is a real, confirmed raw DBI handle to LMS's own
database. `refs/slimserver/Slim/Plugin/OnlineLibraryBase.pm:47-52` confirms
`$dbh->do('CREATE TEMPORARY TABLE ...')` is a valid, used pattern — but only
for a temporary scratch table rebuilt every scan. Neither TIDAL nor Spotty,
nor any bundled `Slim::Plugin::*` searched, creates a *persistent* custom
table. The primitive
(`$dbh->do('CREATE TABLE IF NOT EXISTS discogs_match (...)')`) is grounded,
but the pattern spec §10 needs — versioned schema creation/migration that
survives plugin upgrades and server restarts, run at the correct point in
plugin lifecycle — has no example to model. Needs to be worked out carefully
at implementation time rather than copied from a reference.

### 4.4 Scanner-side HTTP client — CLAUDE.md and the reference plugin disagreed (resolved)

CLAUDE.md stated: "Scanner/importer-side HTTP → `LWP::UserAgent`
(synchronous)". The actual reference plugin's scanner-side code instead uses
`Slim::Networking::SimpleSyncHTTP`
(`refs/lms-plugin-tidal/API/Sync.pm:9,104`; confirmed real module at
`refs/slimserver/Slim/Networking/SimpleSyncHTTP.pm:1`, subclass of
`Slim::Networking::SimpleHTTP::Base`). `SimpleSyncHTTP` gets LMS's own
request logging, caching, and timeout conventions for free; bare
`LWP::UserAgent` would not.

**Resolved:** use `Slim::Networking::SimpleSyncHTTP`, matching the reference
plugin. `CLAUDE.md`'s architecture constraint has been updated to match.

### 4.5 FX-rate source for currency conversion (v3, not blocking v1)

Spec §5/§12 flags this as unselected. Not investigated yet since it's out of
v1 scope — noted here so it isn't forgotten.

### 4.6 Rescan change-detection hook for tag-change re-match trigger

Spec §3/§12 flags "verify how LMS's rescan flags changed files" as unverified.
Not yet investigated against `refs/slimserver/Slim/Utils/Scanner/` — needed
before the re-match-on-tag-change trigger (§3) can be implemented, but not
blocking for the Strict/Structural matching skeleton itself.

---

## 5. Immediate next step

Proceed with build-order step 1: the plugin skeleton and `install.xml` that
LMS actually loads.
