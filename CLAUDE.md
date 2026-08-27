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
  - Scanner/importer-side HTTP → `LWP::UserAgent` (synchronous)
- **This plugin never plays audio.** No ProtocolHandler, no streaming URI
  scheme, no transcoding entries. Spotty has all of these — do not copy them.
- Discogs API: 60 requests/min authenticated. All matching must be batched,
  throttled, cached in SQLite, and resumable after interruption.
- A partial or interrupted scan must never corrupt or discard existing
  confirmed matches.

## Build order

**v1 only** (spec §11), in this order:

1. Plugin skeleton + `install.xml` that LMS actually loads
2. SQLite schema per spec §10 (`discogs_match`, `discogs_collection`,
   `discogs_price_snapshot`)
3. Strict-tier matching (release ID already in file tags)
4. Structural-tier matching (track count + per-track durations)
5. Review queue + manual re-match

Do not start OAuth, badges, marketplace lookup, or anything in v2/v3 until
matching works end to end.

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
