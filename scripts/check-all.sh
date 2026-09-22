#!/bin/sh
#
# Run every offline check: the compile check, then each suite.
#
# There was no such runner before 2026-09-22 - the suites were run by hand,
# one at a time, and a new one was easy to forget. This exists so that
# "offline suites green" is one command with one exit status.
#
# Excluded, deliberately:
#   title-agreement.pl        a measurement, not a suite; takes a library.db,
#                             a collection fixture and a server.prefs
#   ownership-offline-check.pl  takes copies of a real library.db and
#                             squeezewax.db; there is nothing to run it
#                             against on a machine with no LMS
#   fetch-fixtures.pl         a one-time capture tool that talks to Discogs
#   api-check.pl et al        ARE included - they need no arguments
#
# Anything else matching scripts/*-check.pl is picked up automatically, so a
# new suite is run by existing.
#
# Usage: scripts/check-all.sh

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)

SKIP="ownership-offline-check.pl"

fail=0
total=0

printf '==> syntax-check.sh\n'
if sh "$ROOT/scripts/syntax-check.sh" >/dev/null 2>&1; then
	printf '    ok\n'
else
	printf '    FAILED\n'
	sh "$ROOT/scripts/syntax-check.sh" 2>&1 | tail -20
	fail=$((fail + 1))
fi

for suite in "$ROOT"/scripts/*-check.pl; do
	name=$(basename "$suite")

	case " $SKIP " in
		*" $name "*) printf '==> %-24s skipped (needs arguments)\n' "$name"; continue ;;
	esac

	out=$(perl "$suite" 2>&1) || true

	n=$(printf '%s\n' "$out" | grep -c '^ok' || true)
	bad=$(printf '%s\n' "$out" | grep -c '^not ok' || true)
	total=$((total + n))

	if [ "$bad" -eq 0 ] && [ "$n" -gt 0 ]; then
		printf '==> %-24s %4d assertions, ok\n' "$name" "$n"
	else
		printf '==> %-24s %4d assertions, %d FAILED\n' "$name" "$n" "$bad"
		printf '%s\n' "$out" | grep -A3 '^not ok' | head -40
		fail=$((fail + 1))
	fi
done

printf '\n%d assertions across the suites\n' "$total"

if [ "$fail" -ne 0 ]; then
	printf '%d suite(s) FAILED\n' "$fail"
	exit 1
fi

printf 'all green\n'
