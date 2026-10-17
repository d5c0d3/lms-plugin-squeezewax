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
