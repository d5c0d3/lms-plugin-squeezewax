# SqueezeWax — Build & Repository Workflow

Companion to `CLAUDE.md` and `docs/squeezewax-design.md`. Covers *how a
build gets onto a test server*: every build is packaged, hosted on GitHub,
and installed through LMS's own Extension Downloader, pointed at a
throwaway branch copy — the same mechanism used for the eventual real
release, just with a different URL.

This replaces an earlier "SqueezeWaxDev" arrangement (a renamed duplicate
package, `repo-dev.xml`, its own `scripts/package-dev-build.sh`) that ran
for ten builds before being dropped. §1 records why, because the reasoning
is worth more than the arrangement was.

---

## 1. Why the renamed duplicate was dropped

The dev/real split was meant to let a throwaway build and a real install
coexist on one server without colliding. It didn't fully deliver that, and
its existence was itself a source of untested risk:

**The rename never isolated the database.** `SqueezeWax/Schema.pm` has
`use constant DB_NAME => 'squeezewax.db'` and `DB_SCHEMA => 'squeezewax'`.
The old rename table substituted the package namespace, web paths, string
token prefix, prefs namespace, and progress-name prefix — none of which is
the bare string `squeezewax`. So a SqueezeWaxDev build and a real SqueezeWax
install would have shared one database file and one attached schema name
while running under separate prefs namespaces: shared data, split
configuration. A dev build carrying a newer schema migration would push the
file's `user_version` past what the real plugin's `_migrate` expects, and
the downgrade guard would kill it. Never observed, because nobody ran both
at once — which is the point: the one scenario the isolation existed for
was also the one scenario that would have caught its failure.

**Nothing hardware-tested was ever the shipping package.** Every hardware
test through build-order step 3 ran a *transformed* artifact, and the
transform produced three defects of its own, none reachable by the offline
suites: an `HTML/` directory that needed a second, manual rename pass
(caught in packaging, before it reached a server); a progress-name mismatch
that left the scan UI with no label at all (caught on hardware); and the
`DB_NAME`/`DB_SCHEMA` gap above (never caught, because the conditions never
arose). The residual risk was asymmetric — a bug present only in the
un-renamed form couldn't be caught by anything that only ever ran the
renamed one.

**One package name is what the update mechanism expects.**
`Slim::Utils::ExtensionsManager::findUpdates` (`Slim/Utils/ExtensionsManager.pm:366`,
branch `public/9.1`) keys candidates by plugin name and, for each name,
keeps whichever result has the higher version — `compareVersions` at
`:382` — regardless of which configured repository it came from. The
merge happens one level up, in `appsQuery` (`:261`): its `stepCb`
(`:281-284`) flattens every configured repository's plugin list into one
array before `findUpdates` ever runs (`:286`). A second, differently-named
package was never necessary to avoid a naming collision under this
mechanism; the actual rule is simpler and stricter — **never configure a
production repository and a branch repository at the same time**, because
LMS cannot tell which one you meant and will silently prefer the higher
version. This is also the reference project's (`d5c0d3/filtermusic_sb`)
documented rule, confirmed directly from its README:

> "Never configure both production and branch repositories simultaneously.
> LMS aggregates all repositories into a single list and silently keeps
> whichever entry has the highest version number, regardless of which repo
> it came from."

Its README cites `Slim::Plugin::Extensions::Plugin::findUpdates`; that
symbol has moved on `public/9.1` — the current one is
`Slim::Utils::ExtensionsManager::findUpdates`, cited above.

---

## 2. The shape that replaces it

One package, `SqueezeWax`. No renamed duplicate, no separate dev name. One
manifest, `repo.xml`, always at the repo root:

- **A feature branch's `repo.xml`** has a `<url>` on
  `raw.githubusercontent.com` pointing at that branch's own `dist/*.zip`.
- **Master's `repo.xml`** (once SqueezeWax has actually released) has a
  `<url>` on GitHub Pages pointing at the released zip.

Switching between "testing a branch" and "running the release" is one edit
to LMS's **Settings → Plugins → Additional Repositories** entry — never both
at once, per §1's finding.

```
lms-plugin-squeezewax/
├── CLAUDE.md
├── docs/
│   ├── squeezewax-design.md
│   └── dev-repo-workflow.md          ← this file
├── refs/                             (read-only, gitignored)
├── SqueezeWax/                       ← plugin source, only source of truth
├── repo.xml                          ← current branch's manifest
├── dist/                             ← built zips
└── scripts/
    └── package-build.sh              ← §4 below
```

Only `SqueezeWax/` is ever hand-edited. The zip is a build artifact —
assembled into a temp directory by the packaging script from `git archive
HEAD`, never committed as loose files, never edited directly. `repo.xml`
is **scripted, never hand-edited** — its `<url>` depends on which branch
built it and (later) whether that build is a release, and that is exactly
the kind of thing that goes stale silently if a person is expected to
remember to edit it.

### The Pages/release variant doesn't exist yet

SqueezeWax has never been released, so there is no master release manifest
to write today — inventing one would document a release that hasn't
happened. Two things confirmed directly, not assumed:

- **GitHub Pages is not enabled for this repository.**
  `https://d5c0d3.github.io/lms-plugin-squeezewax/` returns 404, and there
  is no `_config.yml` at the repo root (the reference project,
  `filtermusic_sb`, has one — `theme: jekyll-theme-time-machine` — and its
  Pages site serves).
- **Pages only serves the default branch.** Confirmed from
  `filtermusic_sb`'s own README: branch testing there deliberately uses
  `raw.githubusercontent.com/.../<branch>/repo.xml` instead of the Pages
  URL, "since GitHub Pages only serves from the default branch."

So: the branch-build flow (§4) is what exists now. The release variant —
enabling Pages, and a script step that regenerates `repo.xml` with a Pages
`<url>` instead of a raw one — comes into existence at SqueezeWax's first
real release, not before. Tracked in `TODO.md`.

### What actually merges at release — decided now, while it's still design

`v1-buildout` will accumulate a `repo.xml` and a `dist/*.zip` for every
build pushed while v1 is in progress, because both have to be committed to
be raw-fetchable (§3). None of that belongs on master — same reasoning
that already kept an equivalent build artifact off master once this
session (the `packaging-rewrite` branch's test build wasn't merged
forward; see `docs/squeezewax-v1-decisions.md` §6a). So releasing v1 is
**not** a merge of `v1-buildout` as it stands. It's three separate things:

- Master takes the plugin source (`SqueezeWax/`) and docs, merged or
  cherry-picked from `v1-buildout` in the normal way.
- Master's `repo.xml` is **generated by the release script**, carrying a
  Pages `<url>`, and is never merged from the branch — the branch's
  `repo.xml` always carries a raw branch URL and a `0.0.0.N` version, which
  is meaningless on master (§2 above).
- `v1-buildout`'s accumulated `dist/*.zip` files stay on the branch. Master
  gets exactly the one zip the release script builds for the release
  itself.

Recording this now, while it's a design decision, is the point — at
release time this stops being something to decide and becomes an obstacle
if it's still undecided then. It composes directly with the "enable Pages
at first release" item already in `TODO.md`.

### Versioning, before and after release

`repo.xml`'s `<plugin version="...">` stays a `0.0.0.N` series for now,
bumped by the script on every build. This is disconnected from
`SqueezeWax/install.xml`'s own `<version>` (currently `0.1.0`, committed,
untouched by packaging) — with exactly one repository ever configured at a
time, there is nothing for the two numbers to out-rank each other on, so
there's no reason to keep them in sync yet.

That changes at the first real release: from then on, a branch build must
be numbered **above** the currently-released version, or LMS's
`findUpdates` (§1) will not offer it — silently, not with an error. And a
release's `install.xml` should carry its real, meaningful version rather
than a leftover `0.1.0`.

---

## 3. `repo.xml`

Same schema as the reference project's release manifest (confirmed by
fetching `https://raw.githubusercontent.com/d5c0d3/filtermusic_sb/master/repo.xml`
directly):

```xml
<?xml version="1.0"?>
<extensions>
	<details>
		<title lang="EN">d5c0d3 plug-in repository</title>
	</details>
	<plugins>
		<plugin name="SqueezeWax" version="0.0.0.1" minTarget="8.4" maxTarget="*">
			<title lang="EN">SqueezeWax</title>
			<desc lang="EN">Links your physical record collection to your LMS library.</desc>
			<creator>d5c0d3</creator>
			<category>musicservices</category>
			<url>https://raw.githubusercontent.com/d5c0d3/lms-plugin-squeezewax/<branch>/dist/SqueezeWax_0_0_0_1.zip</url>
			<link>https://github.com/d5c0d3/lms-plugin-squeezewax/issues</link>
			<sha>&lt;sha1 of that exact zip&gt;</sha>
		</plugin>
	</plugins>
</extensions>
```

- `name="SqueezeWax"` — matches `Plugins::SqueezeWax::`. Same on every
  branch; §1 is why that's now correct rather than risky.
- `version`, `minTarget`, `maxTarget`, `category` — read by the script out
  of the packaged commit's own `install.xml`, never hand-typed.
- `title`, `desc` — read out of the packaged commit's own `strings.txt`
  (`PLUGIN_SQUEEZEWAX_NAME`/`_DESC`, `EN` line) — display text, not the
  string token.
- `url` — `raw.githubusercontent.com/.../<current-branch>/dist/<zip>`,
  always, until the release step in §2 exists.
- `link` — matches the reference project's field, points at this repo's
  issues.
- `sha` — sha1 of the zip. This is what LMS's Extension Downloader verifies
  before extracting — confirmed on a real install (§6).

---

## 4. Packaging script (`scripts/package-build.sh`)

Renamed from `package-dev-build.sh` — there's no "dev" build to distinguish
from a "real" one anymore, just a build.

What it does, in order:

1. `git archive HEAD -- SqueezeWax` into a temp dir. Building from the
   commit, never the working tree, means an uncommitted edit is invisible
   to the package — silently, not with an error. **Commit before
   packaging.**
2. Bump the version: read `repo.xml`'s current `<plugin version="...">`
   (or bootstrap at `0.0.0.0` if `repo.xml` doesn't exist yet), increment
   the last segment, write it into the *packaged copy's* `install.xml`
   only — the committed `SqueezeWax/install.xml` is untouched, per §2.
3. Read `minVersion`/`maxVersion`/`category` back out of that same packaged
   copy, and `title`/`desc` out of its `strings.txt`, so `repo.xml` can't
   drift from what's actually in the zip.
4. Zip: `cd <tmp> && zip -r SqueezeWax_<version-with-underscores>.zip
   SqueezeWax/` — a top-level `SqueezeWax/` directory holding
   `install.xml`/`Plugin.pm`/etc, not those files at the archive root.
   Confirmed against a real, known-working release (`FilterMusic_2_1_2.zip`)
   by comparing `unzip -l` on both. Underscored filename matches the
   reference project's released zips (`FilterMusic_2_3_1.zip`); the version
   **must** be in the filename or LMS may serve a cached copy on "upgrade."
5. Hash: `sha1sum` on the zip.
6. Print the build's file tree, a `grep -ri squeezewaxdev` over it (nothing
   should ever match again), and `unzip -l` — always, dry-run or not.
7. Unless `--dry-run`: write `repo.xml`, copy the zip into `dist/`.
8. Unless `--publish` is also given: stop there. `repo.xml` and the zip sit
   on disk, uncommitted, for review.

Flags:

- `--dry-run` — build and print the verification output only; never writes
  `repo.xml` or `dist/*.zip` to disk. Mutually exclusive with `--publish`.
- `--publish` — after building, `git add`/`commit`/`push` `repo.xml` and the
  new zip. **Without this flag the script never calls git.** The old
  script committed and pushed by default, which committed unasked at least
  once; this one requires the explicit flag every time.

A failed `git push` under `--publish` (bad credentials, no network, no
upstream) is reported as an explicit error naming the likely causes and
exits non-zero — not swallowed by a bare `set -e` abort. This failed
silently-ish twice under the old script; the guard is now in the script
itself, not left to memory.

---

## 5. Iteration loop

1. Edit `SqueezeWax/` (real source only). Commit it — the script builds
   from `git archive HEAD`, and an uncommitted edit is silently invisible
   to the package (§4 step 1).
2. Run `scripts/package-build.sh` (add `--publish` once you actually want it
   on GitHub). Prints the build tree, the leftover-naming grep, and the zip
   contents before doing anything else — inspect that output.
3. In LMS: **Settings → Plugins → Additional Repositories**, point the
   single entry at
   `https://raw.githubusercontent.com/d5c0d3/lms-plugin-squeezewax/<branch>/repo.xml`.
   If a stale version still shows after a version bump, both GitHub's raw
   CDN and LMS's own repository-list cache can be why — append a
   cache-busting query string (`?v=<n>`) before concluding something is
   broken. This is the reference project's documented gotcha, not a new
   one.
4. Install/update SqueezeWax from the Plugins page.
5. Check LMS's own log for load errors — packaging and hosting only gets
   the code *onto* the server, it doesn't confirm it's correct.
6. Repeat.

**Never leave a production repository and a branch repository configured
at the same time** — §1's `findUpdates` finding is the reason, and it fails
silently (a higher-versioned branch build gets offered to a production
install, or a production release is never offered because a branch's
number is still ahead) rather than with an error.

### `TODO.md`'s `Synced branch:` line

Documentation now, not a guard. It used to gate a re-pointing step that ran
at every build-order step boundary; now there is one branch
(`v1-buildout`) for the whole v1 build-out, project knowledge is pointed at
it once, and isn't re-pointed again until v1 ships. With one branch for
months, the silent-staleness risk the line was written to catch is close to
zero — a "guard" nobody needs is one nobody reads, so it's kept as a plain
record of what's current rather than dressed up as a check.

Two things about the claude.ai GitHub connector came up while that re-
pointing procedure still existed, and are recorded here though neither is
on the critical path anymore:

- **Does the per-file/folder selection survive re-pointing to a different
  branch, or must it be redone?** Not documented (checked the official
  GitHub-integration support article; it doesn't address branch changes at
  all).
- **Can the same repository be added twice to one project, on two
  different branches?** Also not documented.

Worth answering eventually — the second one in particular would make
master and the active branch visible at once — but nothing about v1 is
blocked on either.

---

## 6. The development server

Testing runs against a local LMS on the dev machine, pointed at the same
music sources as production, so behaviour is realistic without touching
anything real. Two things about that setup are worth naming, because their
absence would be invisible rather than loud:

- **It also needs an online-library plugin** (Spotty or similar) installed
  and enabled. Without one, remote tracks never appear in the library at
  all, which is what falsified a remote-track-timestamp claim during
  build-order step 3 — the claim looked confirmed only because nothing
  remote was present to contradict it.
- **Keep a copy of `squeezewax.db` at each shipped schema version.** A
  migration path can't be tested against a database that's already current
  — the only way to exercise `_migrate` from version N is to hand it a real
  version-N file.

`sha1sum`, the zip-structure requirement, and the Extension Downloader's
verify-before-extract behaviour are all confirmed against this server, not
assumed — see §7.

---

## 7. What's confirmed, and what this doesn't solve

- `sha1sum`'s digest is what LMS's Extension Downloader verifies before
  extracting — confirmed on a real install of an earlier (renamed) build.
- The top-level `<PluginName>/` zip structure is confirmed against
  `FilterMusic_2_1_2.zip`.
- The Pages-only-serves-default-branch behaviour is confirmed from
  `filtermusic_sb`'s own README and from this repository's own Pages URL
  currently 404ing (§2).
- This workflow doesn't remove the need for `refs/slimserver/`,
  `refs/lms-plugin-tidal/`, and `refs/Spotty-Plugin/` to write correct
  `Slim::*` calls — `CLAUDE.md`'s hard rule against invented APIs applies
  exactly the same regardless of how a build gets tested.
- SQLite schema migrations still need their own testing against a
  version-N database (§6) — packaging doesn't change that.

---

## 8. The transition off SqueezeWaxDev

**Archived record of a completed migration.** Written while the transition
was still pending; TODO.md records it done 2026-09-07. Kept in present
tense below as the plan-as-written, not as current state.

The dev server currently runs `SqueezeWaxDev`: prefs under
`plugin.squeezewaxdev`, database `squeezewax.db` (never renamed — §1).
Uninstalling it and installing `SqueezeWax` in its place means:

- **Matches carry over** — same file, same schema name, same rows.
- **Tag-name configuration does not** — `plugin.squeezewax` is a different
  prefs namespace than `plugin.squeezewaxdev`, so `discogsTagNames` comes
  back empty.

This self-heals correctly, and the mechanism is worth stating so it reads
as an expected consequence rather than a bug the first time it's seen: with
`discogsTagNames` empty, the importer's `use` gate is `0` and it doesn't
run — existing rows sit untouched. Reconfiguring the tag names makes
`_setChanged` see empty → populated, `invalidateStrict` NULLs every strict
`source_timestamp`, and the next scan does one cold pass over the library
and rebuilds from there. Right outcome, but only if it was written down
before it happened.

The nine `SqueezeWaxDev_*.zip` files that accumulated in `dist/` are
deleted, not kept: they're unreachable the moment `repo-dev.xml` is gone
(nothing points at them, and nothing ever will again), and a build artifact
that can no longer be installed by anything has no reason to stay in git
history-adjacent working tree state. `git log` still has every commit that
produced them if one is ever needed.
