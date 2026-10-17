#!/bin/sh
# Build (if needed) and start the SQLite 3.22.0 LMS container.
#   ./run.sh            start, web UI on http://127.0.0.1:19000/
#   ./run.sh reset      stop and delete the container and its prefs/cache/logs
# Prefs, cache, logs and music live in tmp/sqlite322/ (git-ignored). No Discogs
# token, username or prefs file is ever put there.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
data=$root/tmp/sqlite322
name=squeezewax-sqlite322

# The snap docker CLI prints nothing for some commands unless stdout is a pipe
# (unexplained); `| cat` is the workaround. It also cannot read a Dockerfile
# under /mnt by path, so the Dockerfile goes in on stdin (it has no COPY).
if [ "$1" = reset ]; then
	docker rm -f $name 2>&1 | cat || true
	rm -rf "$data/prefs" "$data/cache" "$data/logs"
	exit 0
fi

if ! docker image inspect $name >/dev/null 2>&1; then
	docker build -t $name - < "$here/Dockerfile" 2>&1 | cat
fi

mkdir -p "$data/prefs" "$data/cache" "$data/logs" "$data/music"
if [ ! -f "$data/prefs/server.prefs" ]; then
	printf -- '---\nmediadirs:\n  - /music\ncheckVersion: 0\nhttpport: 9000\n' > "$data/prefs/server.prefs"
fi

docker rm -f $name >/dev/null 2>&1 || true
docker run -d --name $name -p 127.0.0.1:19000:9000 \
	-v "$data":/data -v "$data/music":/music "$@" $name 2>&1 | cat
