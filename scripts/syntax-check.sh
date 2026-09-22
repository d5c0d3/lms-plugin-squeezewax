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

# refs ships XS modules per perl-version and architecture, and the pure-perl
# halves in more than one place - CPAN/DBI.pm and CPAN/arch/<ver>/DBI.pm are
# different versions, and crossing them with the wrong .so is a DynaLoader
# mismatch rather than a clean failure. Mirror Slim::bootstrap's @SlimINC
# exactly (refs/slimserver/Slim/bootstrap.pm:90-127) rather than approximating.
SLIMINC=$(perl -MConfig -e '
	my $p = shift;
	my $arch = $Config::Config{archname};
	$arch =~ s/^i[3456]86-/i386-/;
	$arch =~ s/gnu-//;
	my $major = $Config{version};
	$major =~ s/\.\d+$//;
	print join " ", map { "-I$_" } grep { -d } (
		"$p/CPAN/arch/$major/$arch",
		"$p/CPAN/arch/$major/$arch/auto",
		"$p/CPAN/arch/$Config{version}/$Config::Config{archname}",
		"$p/CPAN/arch/$Config{version}/$Config::Config{archname}/auto",
		"$p/CPAN/arch/$major/$Config::Config{archname}",
		"$p/CPAN/arch/$major/$Config::Config{archname}/auto",
		"$p/CPAN/arch/$Config::Config{archname}",
		"$p/CPAN/arch/$major",
		"$p/lib",
		"$p/CPAN",
		$p,
	);
' "$REFS")

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

# Slim::Schema loses to the same JSON::XS problem, one layer further down
# (Slim::Schema -> Slim::Music::Info -> ... -> Slim::Utils::Prefs::Base ->
# JSON::XS::VersionOneAndTwo). Modules that talk to the database still `use
# Slim::Schema` - Slim/Plugin/OnlineLibraryBase.pm:11 does the same - so stub it
# here rather than dropping the honest declaration from our code.
#
# This costs nothing the check was already unable to do: its own header says it
# cannot prove a Slim::* method exists, only that the module containing it
# loads. Every Slim::Schema call still has to be found in refs/ and cited.
SCHEMA_STUB='BEGIN {
	$INC{q(Slim/Schema.pm)} = 1;
}'

# Tags.pm reaches Slim::Utils::Prefs, which is the module the JSON::XS problem
# actually lives in, and Slim::Formats, which pulls in Slim::Music::Info and from
# there most of the server. Stub both, and supply the two symbols Tags.pm uses at
# compile time (preferences() at file scope, readTags only at runtime).
TAGS_STUB='BEGIN {
	$INC{q(Slim/Utils/Prefs.pm)} = 1;
	$INC{q(Slim/Formats.pm)}     = 1;

	*Slim::Utils::Prefs::preferences = sub { StubPrefs->new };
	*Slim::Utils::Prefs::import      = sub {
		my $caller = caller;
		no strict q(refs);
		*{$caller . q(::preferences)} = \&Slim::Utils::Prefs::preferences;
	};

	package StubPrefs;
	sub new  { bless {}, shift }
	sub init { 1 }
	sub get  { [] }
	sub set  { 1 }
	sub migrate { 1 }
	sub setValidate { 1 }
	sub setChange { 1 }
	sub remove { 1 }
}'

# Settings.pm inherits Slim::Web::Settings, which reaches the same web stack
# Plugin.pm's base class does. Slim::Utils::Scheduler and Slim::Music::Import are
# only called at runtime, so a marker in %INC is enough for the compile.
#
# Slim::Utils::DateTime is stubbed for the same reason IMPORT_STUB stubs the
# module that reaches it: it goes straight to Slim::Utils::Unicode, which needs
# an initialised OSDetect to answer localeDetails. Settings.pm calls shortDateF
# and timeF only at render time.
SETTINGS_STUB='BEGIN {
	$INC{q(Slim/Web/Settings.pm)}   = 1;
	$INC{q(Slim/Utils/Scheduler.pm)} = 1;
	$INC{q(Slim/Utils/Strings.pm)}  = 1;
	$INC{q(Slim/Utils/DateTime.pm)} = 1;

	@Slim::Web::Settings::ISA = ();
	*Slim::Web::Settings::new     = sub { 1 };
	*Slim::Web::Settings::handler = sub { 1 };
	*Slim::Utils::Strings::string = sub { $_[0] };
	*Slim::Utils::Strings::import = sub {
		my $caller = caller;
		no strict q(refs);
		*{$caller . q(::string)} = \&Slim::Utils::Strings::string;
	};

	package Slim::Web::HTTP::CSRF;
	sub protectName { $_[1] }
	sub protectURI  { $_[1] }
}'

# Slim::Music::Import reaches Slim::Utils::DateTime -> Slim::Utils::Unicode,
# which needs an initialised OSDetect to answer localeDetails. Only stillScanning
# is called, and only at runtime.
IMPORT_STUB='BEGIN {
	$INC{q(Slim/Music/Import.pm)} = 1;
	*Slim::Music::Import::stillScanning = sub { 0 };
}'

# Slim::Utils::Progress reaches Slim::Schema; only new/update/final are called,
# and only at runtime.
PROGRESS_STUB='BEGIN {
	$INC{q(Slim/Utils/Progress.pm)} = 1;
}'

# API.pm reaches the same JSON::XS/Unicode/OSDetect problem through
# Slim::Utils::PluginManager -> Slim::Utils::Misc -> Slim::Music::Info ->
# ... -> Slim::Utils::DateTime -> Slim::Utils::Unicode, the same chain
# IMPORT_STUB stops one hop earlier for Slim::Music::Import. Only
# dataForPlugin is called (by _pluginVersion, at runtime), so a bare stub
# returning {} is enough for the compile check - as always, this cannot
# prove the real dataForPlugin behaves as API.pm assumes, only that the
# module loads.
#
# It used to reach it two more ways, via Slim::Networking::SimpleSyncHTTP ->
# SimpleHTTP::Base -> Slim::Utils::Cache and Slim::Utils::Prefs, which is why
# this stub also carried a Cache marker and reused TAGS_STUB's StubPrefs.
# Build-order step 5 deleted API.pm's synchronous transport, and with it that
# whole chain; both were verified unnecessary by removing them and re-running.
API_STUB='
BEGIN {
	$INC{q(Slim/Utils/PluginManager.pm)} = 1;
	*Slim::Utils::PluginManager::dataForPlugin = sub { {} };
}'

MODULES="Schema Library Tags Match Ownership API API::Async Importer Settings Plugin"
STATUS=0

for scanner in 0 1; do
	if [ "$scanner" = 0 ]; then mode=server; else mode=scanner; fi

	for m in $MODULES; do
		# Plugin.pm is the server's entry point and the scanner never loads it
		# (Slim/Utils/PluginManager.pm:204). Settings.pm is required only from
		# Plugin.pm under main::WEBUI, so it never reaches the scanner either.
		# API/Async.pm is the server-side Discogs client - the scanner has no
		# event loop to run SimpleAsyncHTTP on, which is the entire reason it
		# exists separately from API.pm. Ownership.pm runs after a scan, in the
		# server, off a completed collection sync (decisions §15.2), so the
		# scanner never loads it either.
		if [ "$scanner" = 1 ] && { [ "$m" = "Plugin" ] || [ "$m" = "Settings" ] || [ "$m" = "API::Async" ] || [ "$m" = "Ownership" ]; }; then
			continue
		fi

		case "$m" in
			Plugin)
				# Plugin.pm calls preferences()->migrate, ->init and ->setValidate at
				# file scope, so it needs TAGS_STUB's StubPrefs as well as the base
				# class stub, and Slim::Music::Import->stillScanning at runtime, hence
				# IMPORT_STUB.
				#
				# Its two sync triggers add two more: Slim::Control::Request, which
				# reaches most of the server through the dispatch table, and
				# Slim::Utils::Timers, which needs the same bare Slim::Utils::Misc
				# marker API::Async's case documents. subscribe and setTimer/killTimers
				# are both runtime calls, so markers are enough - which does mean, as
				# with every stub here, that this proves the module loads and not that
				# those names are spelled right. They were read from refs/ instead:
				# Slim/Control/Request.pm:788 and Slim/Utils/Timers.pm:66-120.
				prelude="$STUB$TAGS_STUB$IMPORT_STUB"'
BEGIN {
	$INC{q(Slim/Control/Request.pm)} = 1;
	$INC{q(Slim/Utils/Timers.pm)}    = 1;
	$INC{q(Slim/Utils/Misc.pm)}      = 1;
}'
				note=" (Slim::Plugin::Base, Slim::Utils::Prefs, Slim::Control::Request, Slim::Utils::Timers stubbed)"
				;;
			Library)
				prelude="$SCHEMA_STUB"
				note=" (Slim::Schema stubbed)"
				;;
			Ownership)
				# Ownership.pm pulls in our own Library.pm and Match.pm, so it
				# inherits their stubs. Its own LMS dependency is
				# Slim::Music::Info, for variousArtistString - which reaches
				# Slim::Utils::Unicode and needs an initialised OSDetect, the
				# same chain IMPORT_STUB cuts one module earlier. The call is at
				# runtime, so a bare %INC marker is enough; the name itself was
				# read from refs (Slim/Music/Info.pm:1540) rather than assumed.
				prelude="$SCHEMA_STUB$IMPORT_STUB$TAGS_STUB"'
BEGIN {
	$INC{q(Slim/Music/Info.pm)} = 1;
}'
				note=" (Slim::Schema, Slim::Music::Info stubbed)"
				;;
			Tags)
				prelude="$TAGS_STUB"
				note=" (Slim::Utils::Prefs, Slim::Formats stubbed)"
				;;
			Match)
				prelude="$SCHEMA_STUB$IMPORT_STUB$TAGS_STUB"
				note=" (Slim::Schema, Slim::Music::Import stubbed)"
				;;
			API)
				prelude="$API_STUB"
				note=" (Slim::Utils::PluginManager stubbed)"
				;;
			API::Async)
				# Async.pm pulls API.pm in, hence API_STUB. Its own two LMS
				# dependencies are the transport and the timers, and both reach
				# the JSON::XS/Unicode/OSDetect chain the other stubs here exist
				# to cut - by different routes.
				#
				# Slim::Networking::SimpleAsyncHTTP is stubbed rather than loaded:
				# it goes Slim::Networking::Async -> Async::DNS -> Slim::Utils::Misc
				# -> Slim::Music::Info -> ... -> Slim::Utils::Unicode, which needs a
				# real Slim::Utils::OSDetect and dies at Unicode.pm:100 without one.
				# That is the same trade scripts/api-check.pl documents for the
				# synchronous transport it used to stub: a compile check cannot
				# exercise a transport anyway, and the cost is that this does not
				# prove the class name is spelled right.
				#
				# Slim::Utils::Timers is loaded for real, so setTimer and killTimers
				# are genuinely resolved against refs/ rather than assumed. It needs
				# one cut of its own: `use Slim::Utils::Misc` at Timers.pm:42 reaches
				# Slim::Utils::Prefs -> Prefs::Namespace -> the same Unicode. Timers
				# calls nothing in Misc (grepped: no Slim::Utils::Misc:: references
				# anywhere in the file), so a bare %INC marker is enough, and
				# TAGS_STUB supplies the preferences() symbol Prefs would export.
				prelude="$API_STUB$TAGS_STUB"'
BEGIN {
	$INC{q(Slim/Networking/SimpleAsyncHTTP.pm)} = 1;
	$INC{q(Slim/Utils/Misc.pm)}                 = 1;
}'
				note=" (SimpleAsyncHTTP, Slim::Utils::Misc, Slim::Utils::Prefs stubbed; Timers real)"
				;;
			Importer)
				prelude="$SCHEMA_STUB$IMPORT_STUB$TAGS_STUB$PROGRESS_STUB"
				note=" (Slim::Schema, Slim::Music::Import stubbed)"
				;;
			Settings)
				# Slim::Web::Settings is a web-UI class; stub the base the same
				# way Plugin.pm's is stubbed, and reuse the other stubs.
				prelude="$SCHEMA_STUB$IMPORT_STUB$TAGS_STUB$SETTINGS_STUB"
				note=" (Slim::Web::Settings and friends stubbed)"
				;;
			*)
				prelude=""
				note=""
				;;
		esac

		# shellcheck disable=SC2086 # SLIMINC is a deliberate word-split list
		out=$(perl -I"$INCDIR" $SLIMINC \
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
