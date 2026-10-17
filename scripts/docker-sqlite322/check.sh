#!/bin/sh
#
# Run scripts/check-all.sh inside the repro image, against its DBD::SQLite 1.58
# (SQLite 3.22.0) instead of refs/slimserver's. The repo is mounted read-only;
# no suite writes to it. Called by check-all.sh when the image exists.
#
# Output goes through `cat`: the snap docker CLI loses it otherwise (README).

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
A=/opt/lms/CPAN/arch/5.32

docker run --rm -v "$ROOT":/src:ro --entrypoint sh squeezewax-sqlite322 -c \
	"SQUEEZEWAX_DBD_INC=$A/x86_64-linux-thread-multi:$A sh /src/scripts/check-all.sh; echo __rc=\$?" \
	2>&1 | cat > "${TMPDIR:-/tmp}/swx-322.$$"

cat "${TMPDIR:-/tmp}/swx-322.$$"
rc=$(sed -n 's/^__rc=//p' "${TMPDIR:-/tmp}/swx-322.$$" | tail -1)
rm -f "${TMPDIR:-/tmp}/swx-322.$$"

[ "$rc" = 0 ]
