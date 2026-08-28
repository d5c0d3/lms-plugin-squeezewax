# SqueezeWax — Dev-Repo Workflow (replaces local install testing)

Companion to `CLAUDE.md` and `docs/squeezewax-design.md`. This document
covers *how iteration gets tested*: instead of copying `SqueezeWax/` into a
local LMS `Plugins/` folder and restarting the server, every build is
packaged, hosted on GitHub, and installed through LMS's own
Extension Downloader — the same mechanism used for the real release, just
pointed at a throwaway dev copy.

Two things ground this document, cited so nothing here is guessed:

- The **repository XML schema** and packaging rules, from Lyrion's own
  reference: `<plugin name version minTarget maxTarget><url>…</url><sha>…</sha>`,
  where `name` must match the Perl package naming, `sha` is a **sha1 digest
  of the zip** verified before extraction, and the **version string in the
  archive filename matters** because LMS can reuse cached data otherwise.
  Source: https://lyrion.org/reference/repository-dev/
- The **branch/dev-repo pattern** already proven on this account's
  FilterMusic plugin — a fully renamed duplicate package, its own small
  `repo-dev.xml`, hosted via `raw.githubusercontent.com` (not GitHub Pages,
  which only serves the default branch), added as a *second* Additional
  Repositories entry in LMS alongside the real one. Source: this repo's own
  `README.md`, "Testing a branch (dev build)" section.

---

## 1. Why this replaces local install testing

Local testing means: copy/symlink `SqueezeWax/` into LMS's `Plugins/`
directory on the machine actually running LMS, restart the server, check the
log. That's fine if Claude Code has shell access to that machine. If it
doesn't (remote server, different host, sandboxed dev environment), the
dev-repo approach lets LMS pull the build itself over HTTP — no filesystem
access to the LMS host required, and no server restart triggered from the
dev side (LMS's own plugin installer handles that).

The trade-off, stated plainly: every iteration requires a zip + sha1 +
version bump + git push, then a wait for LMS's Additional-Repositories list
to refresh, versus local testing's copy-and-restart. This is slower per
cycle but works when Claude Code cannot touch the LMS host directly, and
matches a workflow already validated on FilterMusic.

---

## 2. Naming & isolation for the dev build

Per the FilterMusic README, **everything identifying must be renamed**, not
just the directory, so the dev build can never collide with or corrupt a
real `SqueezeWax` install on the same server:

| Real | Dev |
|---|---|
| Directory: `SqueezeWax/` | `SqueezeWaxDev/` |
| Package: `Plugins::SqueezeWax::` | `Plugins::SqueezeWaxDev::` |
| `install.xml` `<module>` | `Plugins::SqueezeWaxDev::Plugin` |
| `install.xml` `<importmodule>` | `Plugins::SqueezeWaxDev::Importer` |
| Web paths | `plugins/SqueezeWaxDev/...` |
| String tokens | `PLUGIN_SQUEEZEWAXDEV_*` |
| `Slim::Utils::Prefs` namespace | dev-specific, not shared with the real plugin's prefs |
| Log category | dev-specific |
| Display title | "SqueezeWax (Dev)" |

This is the same reasoning as `CLAUDE.md`'s existing naming-fixed rule for
the real plugin — LMS keys the repository listing off the package name, so a
half-renamed dev copy risks LMS treating it as an update to (or conflict
with) the real one, or SQLite table/pref collisions between the two if they
ever run on the same server. `SqueezeWaxDev` must be fully independent, not
a flag or setting on the real package.

**Do not** derive `SqueezeWaxDev` by copying the real `SqueezeWax/` and
renaming — that's exactly the failure mode already caught once in this
project (a stale copy plus a rename made stale content look current). Build
the dev zip **from the real source tree at the current commit**, applying
the renames as a packaging step, so the dev build always reflects the actual
current code.

---

## 3. Repo layout addition

```
lms-plugin-squeezewax/
├── CLAUDE.md
├── docs/
│   ├── squeezewax-design.md
│   └── dev-repo-workflow.md          ← this file
├── refs/                             (read-only, gitignored)
├── SqueezeWax/                       ← real plugin source, only source of truth
├── repo.xml                          ← real repo, default branch, GitHub Pages
├── repo-dev.xml                      ← dev repo, raw.githubusercontent.com
└── scripts/
    └── package-dev-build.sh          ← §5 below
```

Only `SqueezeWax/` is ever hand-edited. `SqueezeWaxDev/` is a build
artifact — generated into a temp directory by the packaging script, never
committed as loose files, never edited directly.

---

## 4. `repo-dev.xml`

Same root schema as your real `repo.xml` (confirmed at
https://lyrion.org/reference/repository-dev/), just one `<plugin>` entry,
`name` matching the *dev* package:

```xml
<?xml version="1.0"?>
<extensions>
	<details>
		<title lang="EN">SqueezeWax dev builds</title>
	</details>
	<plugins>
		<plugin name="SqueezeWaxDev" version="0.0.0.1" minTarget="8.0" maxTarget="9.*">
			<title lang="EN">SqueezeWax (Dev)</title>
			<desc lang="EN">Development build of SqueezeWax — not for general use.</desc>
			<creator>you</creator>
			<category>musicservices</category>
			<url>https://raw.githubusercontent.com/&lt;you&gt;/lms-plugin-squeezewax/&lt;branch&gt;/dist/SqueezeWaxDev_0.0.0.1.zip</url>
			<sha>&lt;sha1 of that exact zip&gt;</sha>
		</plugin>
	</plugins>
</extensions>
```

Notes tying each field back to the confirmed schema:
- `name="SqueezeWaxDev"` — must match `Plugins::SqueezeWaxDev::`.
- `version` — bumped on **every** rebuild pushed to the branch; LMS compares
  this string to decide whether to offer an update, it does not inspect zip
  contents.
- `minTarget`/`maxTarget` — copy whatever the real plugin's `install.xml`
  targets once that's decided; not invented here.
- `category` — one of the fixed values LMS defines
  (`hardware|information|misc|musicservices|playlists|radio|scanning|skin|tools`);
  `musicservices` fits SqueezeWax's spec, but confirm against the real
  `install.xml`/`repo.xml` category once written, don't let this drift.
- `url` — **raw.githubusercontent.com, not github.io** — GitHub Pages
  (`repo.xml`'s host) only serves the default branch; a feature branch under
  test needs the raw-content URL instead, per the FilterMusic README.

---

## 5. Packaging script (`scripts/package-dev-build.sh`)

Responsibilities, matching §2's isolation rules and the official packaging
requirement (zip → sha1 → versioned filename):

1. Copy `SqueezeWax/` into a temp dir as `SqueezeWaxDev/`.
2. Apply the renames from the §2 table (package namespace, `install.xml`
   module/importmodule, string token prefix, prefs namespace, log category,
   display title) — mechanically, via a defined substitution list, not
   ad hoc edits.
3. Bump the version — read the current `<version>` out of `repo-dev.xml`,
   increment the last segment, write it back to both `repo-dev.xml` and the
   dev copy's `install.xml`.
4. Zip: `cd <tmp> && zip -r SqueezeWaxDev_<version>.zip SqueezeWaxDev/`
   — version **in the filename**, per the official requirement, or LMS may
   serve a cached copy on "upgrade."
5. Hash: sha1 of the zip. On the Linux dev container this is
   `sha1sum SqueezeWaxDev_<version>.zip`; the official docs only mention a
   Windows GUI tool (HashMyFiles) — `sha1sum` isn't itself confirmed against
   Lyrion's docs, so treat it as a standard-toolchain assumption to verify
   the first time LMS actually accepts (or rejects) the resulting sha,
   rather than something guaranteed by the reference.
6. Write the new `<version>` and `<sha>` into `repo-dev.xml`.
7. Move the zip into `dist/` (gitignored except via explicit `git add`, or
   committed directly — your call, but it must end up reachable at the exact
   `raw.githubusercontent.com` URL `repo-dev.xml` references).
8. `git add repo-dev.xml dist/SqueezeWaxDev_<version>.zip && git commit && git push`.

I haven't written the actual script content yet — this is the spec for it.
Say the word and I'll write it, but I'd want to confirm the exact `zip`/
`sha1sum` invocations behave as expected in your actual dev container before
calling that step "done," rather than asserting it working from here.

---

## 6. LMS-side setup (one-time)

In LMS: **Settings → Plugins → Additional Repositories**, add a **second**
entry (leave the real `repo.xml` entry, if any, untouched):

```
https://raw.githubusercontent.com/<you>/lms-plugin-squeezewax/<branch>/repo-dev.xml
```

"SqueezeWax (Dev)" then appears in the plugin list, installable/updatable
independently of any real SqueezeWax install on the same server — same
pattern as "FilterMusic (Dev)."

---

## 7. Iteration loop

1. Edit `SqueezeWax/` (real source only).
2. Run the packaging script (§5) → new `SqueezeWaxDev_<version>.zip`,
   updated `repo-dev.xml`, pushed.
3. In LMS: **Settings → Plugins → Additional Repositories**, re-save (or use
   a cache-busting query string on the dev repo URL, e.g. `?v=<n>`) if the
   new version doesn't show up — both GitHub's raw CDN and LMS's own
   repository-list cache can serve a stale copy even after the version bump,
   per the FilterMusic README's explicit gotcha.
4. Install/update "SqueezeWax (Dev)" from the Plugins page.
5. Check LMS's own log (`Settings → Information` / server log file) for
   load errors — this is still the actual verification step; packaging and
   hosting only gets the code *onto* the server, it doesn't confirm it's
   correct.
6. Repeat.

---

## 8. What this workflow does *not* solve

- It doesn't remove the need for `refs/slimserver/`,
  `refs/lms-plugin-tidal/`, and `refs/Spotty-Plugin/` to write correct
  `Slim::*` calls in the first place — `CLAUDE.md`'s hard rule against
  invented APIs applies exactly the same whether the result is tested
  locally or via this dev-repo path.
- It doesn't give Claude Code a faster inner loop than local testing would —
  if Claude Code *does* have shell access to the actual LMS host, local
  copy + restart is still simpler for rapid iteration. This workflow is for
  the case where it doesn't.
- SQLite schema changes (`discogs_match` etc., spec §10) will still need
  their own migration testing once persistent tables are implemented —
  packaging/hosting doesn't change that, flagged for later since it's
  build-order step 2, not step 1.

---

## 9. Open items before this is fully actionable

- `scripts/package-dev-build.sh` itself isn't written yet (§5) — say so and
  I'll write it once you confirm the rename list is complete/correct.
- `minTarget`/`maxTarget`/`category` in `repo-dev.xml` are placeholders
  until the real `install.xml` (build-order step 1, still not started) sets
  them for real.
- `sha1sum` as the hashing tool is an assumption, not something Lyrion's
  docs confirm outright (they only document a Windows tool) — worth a quick
  sanity check the first time a dev build actually installs successfully.
