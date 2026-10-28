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
- **Master's `repo.xml`** names the hardware-checked build users install. It
  is served by the website (GitHub Pages from `master`) at
  `https://d5c0d3.github.io/lms-plugin-squeezewax/repo.xml`; its zip `<url>`
  stays on `raw.githubusercontent.com` under `/master/dist/` (§5b, decisions
  §15.37 part 3).

Switching between "testing a branch" and "running the tester build" is one
edit to LMS's **Settings → Plugins → Additional Repositories** entry — never
both at once, per §1's finding.

```
lms-plugin-squeezewax/
├── CLAUDE.md
├── docs/
│   ├── squeezewax-design.md
│   └── dev-repo-workflow.md          ← this file
├── refs/                             (read-only, gitignored)
├── SqueezeWax/                       ← plugin source, only source of truth
├── repo.xml                          ← current branch's manifest
├── _config.yml                       ← website: excludes internal files
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

### Branches and the website — decided 2026-10-13 (§15.37), amended 2026-10-15 (§15.43), amended 2026-10-28 (§15.61)

| Branch | Holds | Written by | Versions |
|---|---|---|---|
| `master` | what users install; the website | `scripts/promote-master.sh` only | copies of checked builds |
| `v1-buildout` | the one development line: betas, 1.0.0, then every feature release and fix | `package-build.sh` | `1.0.0bN` → `1.0.0` → `1.1.0bN` → `1.1.0` → `1.1.1` … |
| `feature/<issue#>-<slug>`, `fix/<issue#>-<slug>` | one feature or fix, from an issue (workspace only) | hand | none built or published; merged into `v1-buildout` when ready |

There is no `v2-buildout`: `2.0.0` is reserved for a change that breaks existing
users, and would be decided then (§15.43 rulings 2, 3).

The website is GitHub Pages from `master`, root folder (enabled 2026-10-13).
Pages serves only the default branch, so a build line's `repo.xml` is reached
through `raw.githubusercontent.com/.../<branch>/repo.xml` and `master`'s through
the website. `_config.yml` is only an `exclude:` list, keeping internal files
(`CLAUDE.md`, `TODO.md`, `plans/`, `scripts/`, `SqueezeWax/`, and `docs/` except
`user-guide.md`) out of the site build, so a Liquid-like `{{` or `{%` in them
cannot break it. The home page is `index.html` (site work, PR #1,
committed on `master` only); it links to the README and `docs/user-guide.md`.

**Merges (§15.37 part 4).** Only promotion writes `master`. A fix lands on the
**oldest line still receiving fixes**, then is merged forward into every newer
line the same day. Never backward; `master` is never merged into a build line. With one line (§15.61) there is nothing to merge forward into.

**Feature branches (§15.43 rulings 4, 7).** Each feature lives on
`feature/<issue#>-<slug>` and is merged into `v1-buildout` only when it is ready
for beta, so a fix to the released version never ships half-finished work. At
most one feature is in beta at a time (through `beta.xml`). Feature and fix
branches are never built (`package-build.sh` refuses them, §15.61).
Issue numbers share GitHub's counter with pull requests; #1 is the closed site PR, so the first feature issue is #2.

**Fixes (§15.61).** Development is linear. A fix is merged into `v1-buildout` and
built there like any other build; while a beta runs, it ships with the beta's
code. Escape: revert the unfinished feature, ship the fix, re-apply (§15.61
item 4).

**Migrations (§15.43 ruling 6, replacing §15.37 part 5).** A database or prefs
migration number (`Schema` `@MIGRATIONS`, `$prefs->migrate`) is taken **at
merge** into `v1-buildout`, never on the feature branch. Two branches that each
took number N would leave servers that installed either build stuck, one-way and
silent (`Schema::_migrate` refuses a newer file). Features that share a
migration ship in one release.

**Retirement.** §15.37 part 6 no longer applies: there is one line.

**Issues (§15.43 rulings 8, 9).** Feature work is tracked as GitHub issues, one
milestone per release. An issue links to its decisions §, and the § closes it. A
refused request gets the `wont-do` label and a link to the ruling.

Labels in use since 2026-10-17: `enhancement` (feature), `bug`, `needs-design`
(a decision or migration is needed before building), `undecided` (owner has not
decided whether to build), `wontfix` (closed as not planned, with the reason),
`superseded` (made unnecessary by a later decision; closed as "duplicate" of the
issue that superseded it, because GitHub offers only completed / not planned /
duplicate). Issues filed from a Claude session get a "Generated by Claude Code"
footer appended; remove it by hand.

### Version numbers (§15.37 part 2)

`repo.xml`'s `<plugin version="...">` **is the user-visible version**, and the
packaged `install.xml` carries the same string. There is no `0.0.0.N` build
series any more.

- `aN` = dev build, never promoted. `bN` = beta. Plain = release. A feature
  release is `1.N.0`, its fixes `1.N.M`, betas `1.N.0bK`, dev builds `1.N.0aK`
  (§15.43 ruling 2, superseding §15.37 part 2's "no minor series"). `2.0.0` is
  kept for a change that breaks existing users.
- **Never a hyphen:** `1.0.0-beta1` compares equal to `1.0.0` in LMS, so an
  update would silently not be offered.
- Order, verified with `Slim::Utils::Versions->compareVersions`:
  `0.0.0.24 < 1.0.0b1 < 1.0.0b9 < 1.0.0b10 < 1.0.0 < 1.0.9 < 1.1.0a1 <
  1.1.0b1 < 1.1.0 < 1.2.0 < 1.9.0 < 1.10.0 < 2.0.0` (the 1.N pairs checked
  against `public/9.1` @ `582a1b2`, §15.43 ruling 2).
- Every build takes the next number, dev builds included, so gaps between
  promoted versions are normal.
- The first number must match the branch (`v1-buildout` → `1.…`);
  `package-build.sh` enforces it. The minor number is not checked; inferred that
  `--version 1.1.0b1` passes the existing guard (§15.43 ruling 2).
- A branch build must be numbered **above** the version a server has, or LMS's
  `findUpdates` (§1) will not offer it, silently.

### What actually merges at promotion — decided 2026-10-13 (§15.36 part 1)

`v1-buildout` accumulates a `repo.xml` and a `dist/*.zip` for every build
pushed while v1 is in progress, because both have to be committed to be
raw-fetchable (§3). None of that belongs on master — same reasoning that
already kept an equivalent build artifact off master once (the
`packaging-rewrite` branch's test build wasn't merged forward; see
`docs/squeezewax-v1-decisions.md` §6a). So promoting a build is **not** a
merge of `v1-buildout` as it stands. The merge recipe now runs at **every
promotion**, not once at release, and `scripts/promote-master.sh` does it:

- Master takes the plugin source (`SqueezeWax/`), `LICENSE` and docs, by
  merging the **package commit** (`--no-ff`).
- Master's `repo.xml` is the package commit's with **only** the `<url>`'s
  branch changed from `/v1-buildout/` to `/master/`. Version, `<sha>` and zip
  name are untouched, because they describe the zip's bytes.
- Master's `dist/` holds the zips already on master plus the promoted one.
  Every other zip the merge brings in is removed.
- `TODO.md`, if it conflicts, is the package commit's, after a check that every
  line master added since its last promotion is already there; otherwise the
  script stops (decisions §15.41).

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
		<plugin name="SqueezeWax" version="1.0.0b1" minTarget="8.4" maxTarget="*">
			<title lang="EN">SqueezeWax</title>
			<desc lang="EN">Links your physical record collection to your LMS library.</desc>
			<creator>d5c0d3</creator>
			<category>musicservices</category>
			<url>https://raw.githubusercontent.com/d5c0d3/lms-plugin-squeezewax/<branch>/dist/SqueezeWax_1_0_0b1.zip</url>
			<link>https://d5c0d3.github.io/lms-plugin-squeezewax/</link>
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
- `url` — `raw.githubusercontent.com/.../<current-branch>/dist/<zip>`, always.
  On `master` it names `/master/dist/` (§5b); it is not moved to Pages.
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
2. Version: read `repo.xml`'s current `<plugin version="...">` (or bootstrap
   at `0.0.0.0` if `repo.xml` doesn't exist yet). Add 1 to the trailing number
   of the last part (`1.0.0b7`→`1.0.0b8`, `1.0.0`→`1.0.1`, `2.0.0a3`→`2.0.0a4`,
   `0.0.0.24`→`0.0.0.25`), or take `--version X`. Write it into the *packaged
   copy's* `install.xml` only — the committed `SqueezeWax/install.xml` is
   untouched. The branch's line guard applies (§2, "Version numbers").
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
- `--version X` — use X instead of bumping. X must match
  `^\d+\.\d+\.\d+([ab]\d+)?$` (no hyphen) and be higher than `repo.xml`'s
  version by `Slim::Utils::Versions->compareVersions`, loaded from
  `refs/slimserver/` (the script stops if that is missing).
- On a branch named `vN-buildout` the new version's first number must be N;
  other branch names warn and continue; `master` is refused.
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

**Pushes do not work from the Claude Code environment.** The remote is HTTPS
with no stored credential, no SSH identity and no `gh`, so `--publish` builds
the zip, writes `repo.xml`, commits both, and then fails at `git push` — and
says so rather than failing silently. The consequence to plan around: the
version is bumped and committed *before* anyone can see it served, so a build
that is never pushed still consumes its number. The user pushes by hand; until
they do, the `<url>` in `repo.xml` points at a zip GitHub does not yet have.

**Never leave a production repository and a branch repository configured
at the same time** — §1's `findUpdates` finding is the reason, and it fails
silently (a higher-versioned branch build gets offered to a production
install, or a production release is never offered because a branch's
number is still ahead) rather than with an error.

## 5b. User channel

Decided 2026-10-13, decisions §15.36 part 1, with the URL replaced by §15.37
part 3. Users and testers add
`https://d5c0d3.github.io/lms-plugin-squeezewax/repo.xml` (the website; the
README names only this URL; the dev URL in §5 stays here, so a user cannot pick
the one-way dev channel by mistake). Anyone who added the older
`raw.githubusercontent.com/.../master/repo.xml` address replaces it, never
keeps both. During the v1 beta this `repo.xml` carries the beta, so testers move
to 1.0.0 with no URL change; `beta.xml` is built at the first beta after 1.0.0.

**After the official listing (§15.43 ruling 10).** Once SqueezeWax is in
`LMS-Community/lms-plugin-repository`'s `include.json`, `repo.xml` carries
**releases only**. Betas go in `beta.xml` alone, and `beta.xml` is never added
to `include.json`. LMS always includes the official repository and keeps the
highest version across repositories, and never downgrades
(`ExtensionsManager.pm`, `findUpdates`), so a tester who leaves `beta.xml` stays
on the beta until the next release. The listing is rebuilt every 6 hours.

- **Promotion merges a checked package commit and copies its zip. It never
  rebuilds.** `package-build.sh` bumps the version on every run, so a rebuild
  would ship a version nobody hardware-checked. The zip is carried byte for
  byte; version and `<sha>` survive because both describe those bytes.
- **Every promotion includes a website review** (decisions §15.59). The pages the
  website serves live only on master and are edited by hand, so promotion never
  touches them; the owner reviews them against the promoted version and the
  README before pushing master. `promote-master.sh` runs `scripts/site-check.sh`
  on the merge result and warns, without stopping, when a release still mentions
  beta/alpha. The word scan does not replace the review.
- **Run `scripts/promote-master.sh <version> <report-no>`** on `v1-buildout`
  (never for an `a` build: dev builds are not promoted), after the hardware report for that build passes. `--dry-run` shows the diff
  and the new `repo.xml` and changes nothing. `--merge-head` merges
  `v1-buildout`'s HEAD instead of the package commit, and is allowed only when
  `SqueezeWax/` and `LICENSE` are identical to the package commit (a docs-only
  fix after the check needs no rebuild). The owner pushes `master`.
- **Forward only.** The script refuses a version not above the one already on
  `master`. Migrations are one-way (`Schema::_migrate` refuses a newer file)
  and LMS offers only a higher version (§1), so a bad build is fixed by
  promoting a newer checked one. Rollback of `master` itself is its previous
  promoted commit; testers who already updated cannot step back.
- **`package-build.sh` refuses to run on `master`.** A build there would
  publish an unchecked zip to testers.
- **Never configure the tester and dev repositories at once** (§1): LMS keeps
  the higher version whichever repository it came from.
- **Unverified:** how long GitHub's raw cache and LMS's repository cache delay
  a tester seeing a promotion (§5 step 3's `?v=` gotcha).

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

## 6a. Testing ownership without changing the collection

The ownership pass's most awkward behaviour to exercise is "a record left the
Discogs collection": its ownership-only row should be deleted, and a tagged
row should fall back to `absent` / `candidate` while keeping its release id.
Testing that for real means editing a collection the project does not own and
cannot restore if a step fails, so it is done offline, without touching one.

**Offline, on copies** — `scripts/ownership-offline-check.pl`. It takes a
`library.db` and a `squeezewax.db`, copies both through SQLite's online backup
from a read-only handle (safe against a running LMS), and runs the real pass
three times against the committed page-1 fixture: as given, minus some release
ids, then as given again. It needs no token and no network. It proves what the
pass does with a changed list; it cannot prove a real fetch produces one.

---

## 7. What's confirmed, and what this doesn't solve

- `sha1sum`'s digest is what LMS's Extension Downloader verifies before
  extracting — confirmed on a real install of an earlier (renamed) build.
- The top-level `<PluginName>/` zip structure is confirmed against
  `FilterMusic_2_1_2.zip`.
- The Pages-only-serves-default-branch behaviour is confirmed from
  `filtermusic_sb`'s own README; this repository's Pages site, enabled
  2026-10-13, serves `master` (§2, decisions §15.37 part 3).
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
