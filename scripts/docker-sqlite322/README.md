# docker-sqlite322

A disposable Lyrion Music Server 9.2 container whose DBD::SQLite is 1.58 on
SQLite 3.22.0, the pairing a forum tester's piCorePlayer reported
(decisions §15.42). For reproducing and confirming the no-UPSERT fix.

- Base: `debian:bullseye-slim` (perl 5.32.1, x86_64-linux-gnu-thread-multi).
  Bullseye is end-of-life, so apt points at archive.debian.org.
- LMS: slimserver `public/9.2` pinned at `eb59bbf8c828` (Dockerfile `LMS_COMMIT`).
- DBD::SQLite 1.58 is built with cpanm and overlaid onto LMS's own
  `CPAN/arch/5.32` tree (the .pm, `DBD/SQLite/`, the x86_64 .so). LMS's DBI
  (1.628) is untouched. LMS does not retry DBD::SQLite from the system perl
  (it is not in `bootstrap.pm`'s module lists), which is why it is overlaid.
- Gate: Settings -> Information must read `DBD::SQLite: 1.58 (sqlite 3.22.0)`:
  `curl -s http://127.0.0.1:19000/settings/server/status.html | grep DBD`

`./run.sh` starts it (web UI on http://127.0.0.1:19000/). State lives in the
git-ignored `tmp/sqlite322/`. Never put a Discogs token or a real prefs file
there. Phase 3 of the hand-off extends this README.

Snap docker: output is lost unless stdout is a pipe (`| cat`; unexplained), and
the CLI cannot read a Dockerfile under /mnt by path, so it is fed on stdin.

## Build, run, reset

```sh
scripts/docker-sqlite322/run.sh          # builds the image on first use, starts it
scripts/docker-sqlite322/run.sh reset    # remove container, prefs, cache, logs
```

The image is `squeezewax-sqlite322`; rebuild after changing the Dockerfile with
`docker rmi squeezewax-sqlite322`. Logs: `tmp/sqlite322/logs/{server,scanner}.log`.
`tmp/sqlite322/music/` is the music folder (mounted at `/music`). Note that
`reset` keeps the music.

## Installing SqueezeWax

As a user does, on the Plugins settings page (`/settings/server/plugins.html`):
add `https://d5c0d3.github.io/lms-plugin-squeezewax/repo.xml`, tick SqueezeWax,
apply, then `docker restart squeezewax-sqlite322`. Over HTTP this is a POST of
`repos`, `saveSettings=1`, the page's hidden `rand`, `install:SqueezeWax=1` and
`SqueezeWax=1` (keep `repos` in the POST or the repository is removed). Tag
names: the plugin's own settings page, `pref_discogsTagNames0=DISCOGS_RELEASE_ID`.
Leave the token empty.

A full scan: `curl -s http://127.0.0.1:19000/jsonrpc.js -d
'{"id":1,"method":"slim.request","params":["",["wipecache"]]}'`.

## Swapping in a local build

Replace the installed plugin directory with the zip's contents (the zip has a
top-level `SqueezeWax/`) and restart:

```sh
p=tmp/sqlite322/cache/InstalledPlugins/Plugins
rm -rf $p/SqueezeWax && unzip -q dist/SqueezeWax_<version>.zip -d $p
docker restart squeezewax-sqlite322
```

`squeezewax.db` in `tmp/sqlite322/prefs/` survives that; delete it (or `reset`)
for a clean first-install.

## Known differences from the tester

- x86_64 here, aarch64 there; Debian 11 here, piCorePlayer there.
- The tester's DBD::SQLite 1.58 came from somewhere outside LMS's own tree
  (unverified where); here it is overlaid into LMS's tree.
- Docker CLI is the snap build: see the note above.
