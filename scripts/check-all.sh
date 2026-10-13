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
		*" $name "*) printf '==> %-28s skipped (needs arguments)\n' "$name"; continue ;;
	esac

	# Exit status AND the plan, not just the absence of "not ok". A suite that
	# dies partway prints no failures at all - it simply stops - and checking
	# only for "not ok" reported one as green on 2026-09-22. The plan line is
	# what catches a silent truncation: Test::More prints 1..N only if
	# done_testing() was reached.
	# errexit off around the run: a failing suite must be REPORTED, not abort
	# the runner before it can say which one failed.
	set +e
	out=$(perl "$suite" 2>&1)
	rc=$?
	set -e

	n=$(printf '%s\n' "$out" | grep -c '^ok' || true)
	bad=$(printf '%s\n' "$out" | grep -c '^not ok' || true)
	plan=$(printf '%s\n' "$out" | sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' | tail -1)
	total=$((total + n))

	why=''
	[ "$bad" -ne 0 ]                && why="${bad} failed"
	[ "$rc" -ne 0 ]                 && why="${why:+$why, }exit $rc"
	[ -z "$plan" ]                  && why="${why:+$why, }no plan - suite died before done_testing"
	[ -n "$plan" ] && [ "$plan" -ne "$((n + bad))" ] \
		&& why="${why:+$why, }plan says $plan, saw $((n + bad))"
	[ "$n" -eq 0 ]                  && why="${why:+$why, }no assertions ran"

	if [ -z "$why" ]; then
		printf '==> %-28s %4d assertions, ok\n' "$name" "$n"
	else
		printf '==> %-28s %4d assertions, FAILED (%s)\n' "$name" "$n" "$why"
		printf '%s\n' "$out" | grep -A3 '^not ok' | head -40
		printf '%s\n' "$out" | tail -5
		fail=$((fail + 1))
	fi
done

printf '\n%d assertions across the suites\n' "$total"

if [ "$fail" -ne 0 ]; then
	printf '%d suite(s) FAILED\n' "$fail"
	exit 1
fi

printf 'all green\n'
