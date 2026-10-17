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
# Two drivers. The suites load DBD::SQLite from refs/slimserver, which on a
# current perl is 1.76 / SQLite 3.46.1. The plugin's floor is SQLite 3.22.0
# (decisions §15.42), so when the repro image exists the whole run is repeated
# inside it against a real DBD::SQLite 1.58 (scripts/docker-sqlite322/check.sh).
# No image: the second pass is reported as skipped, not silently dropped.
#
# SQUEEZEWAX_DBD_INC (a colon-separated list of directories) puts a different
# DBD::SQLite ahead of refs/: each suite is started with those -I paths and
# -MDBI -MDBD::SQLite, so the suite's own BEGIN block finds the module already
# loaded. Setting it also suppresses the second pass, which is how the container
# run avoids recursing.
#
# Usage: scripts/check-all.sh

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)

SKIP="ownership-offline-check.pl"

PRELOAD=''
if [ -n "${SQUEEZEWAX_DBD_INC:-}" ]; then
	oldifs=$IFS; IFS=:
	for d in $SQUEEZEWAX_DBD_INC; do PRELOAD="$PRELOAD -I$d"; done
	IFS=$oldifs
	PRELOAD="$PRELOAD -MDBI -MDBD::SQLite"
fi

# Which driver the suites will actually load: the same @INC arrangement as their
# BEGIN blocks, with the preload in front.
# shellcheck disable=SC2086 # PRELOAD is a deliberate word-split list
driver=$(perl $PRELOAD -MConfig -e '
	my $p = shift;
	my $arch = $Config{archname};
	$arch =~ s/^i[3456]86-/i386-/;
	$arch =~ s/gnu-//;
	my $major = $Config{version};
	$major =~ s/\.\d+$//;
	unshift @INC, grep { -d } (
		"$p/CPAN/arch/$major/$arch", "$p/CPAN/arch/$major/$arch/auto",
		"$p/CPAN/arch/$major", "$p/lib", "$p/CPAN", $p );
	require DBI; require DBD::SQLite;
	my $v = DBI->connect("dbi:SQLite::memory:")->{sqlite_version};
	print "DBD::SQLite $DBD::SQLite::VERSION (sqlite $v) from $INC{q(DBD/SQLite.pm)}, perl $Config{version}";
' "$ROOT/refs/slimserver" 2>&1) || driver="unknown ($driver)"
printf 'driver: %s\n\n' "$driver"

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
	out=$(perl $PRELOAD "$suite" 2>&1)
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
else
	printf 'all green on this driver\n'
fi

rc=0
[ "$fail" -ne 0 ] && rc=1

# Second pass, on SQLite 3.22.0, unless this already is it.
if [ -z "${SQUEEZEWAX_DBD_INC:-}" ]; then
	printf '\n==> SQLite 3.22.0 pass\n'
	if command -v docker >/dev/null 2>&1 \
		&& docker image inspect squeezewax-sqlite322 >/dev/null 2>&1; then
		if sh "$ROOT/scripts/docker-sqlite322/check.sh"; then
			printf '3.22.0 pass: ok\n'
		else
			printf '3.22.0 pass: FAILED\n'
			rc=1
		fi
	else
		printf '3.22.0 pass skipped (no image)\n'
	fi
fi

[ "$rc" -eq 0 ] && printf 'all green\n'
exit $rc
