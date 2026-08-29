#!/bin/sh
#
# Compile-check the plugin's Perl modules against refs/slimserver.
#
# This catches syntax errors, typo'd package names and calls into modules that
# do not exist. It does NOT prove that a Slim::* method exists - only that the
# module containing it loads. Per CLAUDE.md, every Slim::* call still has to be
# found in refs/slimserver/ and cited.
#
# Modules are loaded in both server (SCANNER=0) and scanner (SCANNER=1) modes,
# since the plugin behaves differently in each and a mistake in one branch would
# otherwise go unseen.
#
# Usage: scripts/syntax-check.sh

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REFS="$ROOT/refs/slimserver"

if [ ! -d "$REFS" ]; then
	echo "refs/slimserver not found at $REFS" >&2
	exit 1
fi

# LMS resolves plugins as Plugins::<Name>::*, so the plugin directory has to be
# reachable as Plugins/SqueezeWax. Build that layout in a temp dir.
INCDIR=$(mktemp -d)
trap 'rm -rf "$INCDIR"' EXIT
mkdir -p "$INCDIR/Plugins"
ln -s "$ROOT/SqueezeWax" "$INCDIR/Plugins/SqueezeWax"

# refs ships XS modules per perl-version and architecture; add the matching
# dirs the same way LMS does at Slim/Utils/PluginManager.pm:276-289, including
# its archname normalisation.
PERLVER=$(perl -e 'printf "%vd", $^V' | cut -d. -f1,2)
ARCH=$(perl -MConfig -e 'my $a = $Config{archname}; $a =~ s/^i[3456]86-/i386-/; $a =~ s/gnu-//; print $a')
ARCHINC=""
for d in "$REFS/CPAN/arch/$PERLVER/$ARCH/auto" "$REFS/CPAN/arch/$PERLVER/$ARCH"; do
	[ -d "$d" ] && ARCHINC="$ARCHINC -I$d"
done

# Plugin.pm inherits from Slim::Plugin::Base, which transitively loads a large
# part of LMS including XS modules whose refs-shipped versions do not match an
# arbitrary host perl (JSON::XS is the usual casualty). That is a limitation of
# running against a bare refs checkout, not a property of our code, so stub the
# base class out for Plugin.pm. Everything of ours still gets compiled; only the
# inherited LMS behaviour is skipped, and it is unchanged from upstream anyway.
STUB='BEGIN {
	$INC{q(Slim/Plugin/Base.pm)} = 1;
	@Slim::Plugin::Base::ISA = ();
	*Slim::Plugin::Base::initPlugin = sub { 1 };
}'

MODULES="Schema Importer Plugin"
STATUS=0

for scanner in 0 1; do
	if [ "$scanner" = 0 ]; then mode=server; else mode=scanner; fi

	for m in $MODULES; do
		# Plugin.pm is the server's entry point and the scanner never loads it
		# (Slim/Utils/PluginManager.pm:204), so don't check it in scanner mode.
		if [ "$scanner" = 1 ] && [ "$m" = "Plugin" ]; then continue; fi

		if [ "$m" = "Plugin" ]; then
			prelude="$STUB"
			note=" (Slim::Plugin::Base stubbed)"
		else
			prelude=""
			note=""
		fi

		# shellcheck disable=SC2086 # ARCHINC is a deliberate word-split list
		out=$(perl \
			-I"$INCDIR" -I"$REFS" -I"$REFS/lib" -I"$REFS/CPAN" $ARCHINC \
			-e "
				package main;
				use constant SCANNER      => $scanner;
				use constant RESIZER      => 0;
				use constant ISWINDOWS    => 0;
				use constant ISMAC        => 0;
				use constant TRANSCODING  => 1;
				use constant PERFMON      => 0;
				use constant DEBUGLOG     => 1;
				use constant INFOLOG      => 1;
				use constant STATISTICS   => 1;
				use constant SB1SLIMP3SYNC=> 1;
				use constant WEBUI        => 1;
				use constant NOMYSB       => 1;
				use constant LOCALFILE    => 0;
				use constant NOBROWSECACHE=> 0;
				use constant SLIM_SERVICE => 0;
				use constant NOUPNP       => 0;
				use constant ISACTIVEPERL => 0;
				$prelude
				require Plugins::SqueezeWax::$m;
			" 2>&1) && result=ok || result=fail

		if [ "$result" = ok ]; then
			printf '  ok    %-8s %s%s\n' "$mode" "$m" "$note"
		else
			printf '  FAIL  %-8s %s%s\n' "$mode" "$m" "$note"
			echo "$out" | sed 's/^/          /'
			STATUS=1
		fi
	done
done

exit $STATUS
