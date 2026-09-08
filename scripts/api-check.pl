#!/usr/bin/env perl
#
# Offline exercise of Plugins::SqueezeWax::API's pure functions - request
# construction, response classification, and rate-limit accounting.
#
# What this cannot prove: that Discogs actually behaves as documented, or
# that Slim::Networking::SimpleSyncHTTP/SimpleAsyncHTTP behave as read from
# refs/. SimpleSyncHTTP::new refuses to run outside the scanner
# (logBacktrace if !main::SCANNER, refs/slimserver/Slim/Networking/
# SimpleSyncHTTP.pm:58), so the transport itself - _request() and get() in
# API.pm - is not exercised here at all. Everything decision-shaped was
# deliberately pulled out of the transport into the pure functions this file
# does cover, the same split Match.pm's _writeRefusal uses for the same
# reason.
#
# Usage: scripts/api-check.pl

use strict;
use warnings;

use constant PERFMON  => 0;
use constant DEBUGLOG => 1;
use constant INFOLOG  => 1;

use Config;
use FindBin qw($Bin);

# Host Test::More, before refs goes on @INC - see library-check.pl.
use Test::More;

BEGIN {
	my $libPath = "$Bin/../refs/slimserver";
	die "refs/slimserver not found at $libPath\n" unless -d $libPath;

	my $arch = $Config::Config{archname};
	$arch =~ s/^i[3456]86-/i386-/;
	$arch =~ s/gnu-//;

	my $perlmajorversion = $Config{version};
	$perlmajorversion =~ s/\.\d+$//;

	unshift @INC, grep { -d } (
		"$libPath/CPAN/arch/$perlmajorversion/$arch",
		"$libPath/CPAN/arch/$perlmajorversion/$arch/auto",
		"$libPath/CPAN/arch/$perlmajorversion",
		"$libPath/lib",
		"$libPath/CPAN",
		$libPath,
	);

	# API.pm's own LMS dependencies: the logger (as every suite stubs it),
	# Slim::Networking::SimpleSyncHTTP (pulls in the Cache/Prefs/JSON::XS
	# chain syntax-check.sh's API_STUB documents, and is never called from
	# here - see the header above), and Slim::Utils::PluginManager
	# (_pluginVersion's dataForPlugin, made controllable per test below).
	$INC{'Slim/Utils/Log.pm'}                     = 1;
	$INC{'Slim/Networking/SimpleSyncHTTP.pm'}     = 1;
	$INC{'Slim/Utils/PluginManager.pm'}           = 1;

	no strict 'refs';

	*{'Slim::Utils::Log::logger'}   = sub { Test::StubLogger->new };
	*{'Slim::Utils::Log::logError'} = sub { };
	*{'Slim::Utils::Log::import'}   = sub {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::logger"}   = \&Slim::Utils::Log::logger;
		*{"${caller}::logError"} = \&Slim::Utils::Log::logError;
	};

	*{'main::SCANNER'}   = sub () { 0 };
	*{'main::INFOLOG'}   = sub () { 0 };
	*{'main::DEBUGLOG'}  = sub () { 0 };
	*{'main::ISWINDOWS'} = sub () { 0 };
}

{
	package Test::StubLogger;
	sub new      { bless {}, shift }
	sub error    { }
	sub warn     { }
	sub info     { }
	sub debug    { }
	sub is_info  { 0 }
	sub is_debug { 0 }
}

# _pluginVersion's only external dependency. A plain hash keyed by module
# name lets a test say "the scanner sees a different install.xml row than
# the server" without caring how PluginManager gets there.
{
	package Test::StubPluginManager;
	our %data;
	sub dataForPlugin { return $data{ $_[1] } }
}

{
	no strict 'refs';
	*{'Slim::Utils::PluginManager::dataForPlugin'} = \&Test::StubPluginManager::dataForPlugin;
}

# A minimal stand-in for an HTTP::Headers object: only ->header(name) is
# used by _parseRateHeaders.
{
	package Test::StubHeaders;
	sub new    { my $class = shift; bless { @_ }, $class }
	sub header { return $_[0]->{ $_[1] } }
}

use lib "$Bin/..";
require SqueezeWax::API;

my $A = 'Plugins::SqueezeWax::API';

# ---------------------------------------------------------------------------
# buildRequest
# ---------------------------------------------------------------------------

$Test::StubPluginManager::data{'Plugins::SqueezeWax::Plugin'} = { version => '0.4.2' };

{
	my ( $url, @headers ) = $A->buildRequest( '/oauth/identity', {}, undef );

	is( $url, 'https://api.discogs.com/oauth/identity', 'no params: bare path appended to the base URL' );

	my %h = @headers;
	is( $h{'User-Agent'}, 'SqueezeWax/0.4.2 +https://github.com/d5c0d3/lms-plugin-squeezewax',
		'User-Agent carries the version read from PluginManager, not a hardcoded one' );
	ok( !exists $h{Authorization}, 'no Authorization header when no token is given' );
}

{
	my ( $url, @headers ) = $A->buildRequest( '/oauth/identity', {}, '' );
	my %h = @headers;
	ok( !exists $h{Authorization}, 'no Authorization header for an empty-string token either' );
}

{
	my ( $url, @headers ) = $A->buildRequest( '/database/search', {}, 'abc123' );
	my %h = @headers;
	is( $h{Authorization}, 'Discogs token=abc123', 'Authorization header carries the token in Discogs form' );
}

{
	my ( $url ) = $A->buildRequest( '/database/search', { type => 'master', q => 'a b' }, undef );
	like( $url, qr{^https://api\.discogs\.com/database/search\?}, 'params produce a query string on the right base' );
	like( $url, qr{type=master}, 'a param key/value appears in the query string' );
	like( $url, qr{q=a(?:\+|%20)b}, 'a space-containing value is escaped, not left raw' );
}

{
	# decisions §3 item 2: version comes from install.xml at runtime via
	# PluginManager, never a literal string in the code. Changing the stub's
	# answer must change the header - if it didn't, buildRequest would have
	# to be hardcoding the version instead of reading it.
	local $Test::StubPluginManager::data{'Plugins::SqueezeWax::Plugin'} = { version => '9.9.9' };
	my ( undef, @headers ) = $A->buildRequest( '/oauth/identity', {}, undef );
	my %h = @headers;
	like( $h{'User-Agent'}, qr{^SqueezeWax/9\.9\.9 \+}, 'a different PluginManager answer changes the User-Agent version' );
}

{
	local $Test::StubPluginManager::data{'Plugins::SqueezeWax::Plugin'} = undef;
	my ( undef, @headers ) = $A->buildRequest( '/oauth/identity', {}, undef );
	my %h = @headers;
	like( $h{'User-Agent'}, qr{^SqueezeWax/unknown \+}, 'a missing PluginManager entry degrades to "unknown", not a crash' );
}

# NOT independently tested here: that _pluginVersion asks for the
# importmodule entry instead of the module entry when main::SCANNER is true.
# main::SCANNER is defined above as a ()-prototyped stub, the same shape
# `use constant` produces, and Perl constant-folds it into _pluginVersion at
# API.pm's compile time - confirmed empirically (a `local *main::SCANNER =
# sub () { 1 }` here left the User-Agent unchanged and printed "Constant
# subroutine main::SCANNER redefined"). This is exactly CLAUDE.md's own
# description of why Match.pm's scanner branch needed _writeRefusal pulled
# out as a pure function: one test process fixes main::SCANNER for its
# whole life and cannot exercise both branches. _pluginVersion's module
# selection is a single ternary, not independently decision-shaped the way
# _writeRefusal is, and isn't in step 4 §3 item 2 or §4's minimum coverage
# list - read the source (SqueezeWax/API.pm's own _pluginVersion) rather
# than trust this file for that one branch.

# ---------------------------------------------------------------------------
# classifyResponse
# ---------------------------------------------------------------------------

{
	my $result = $A->classifyResponse( 200, '{"username":"d5c0d3"}' );
	ok( $result->{ok}, '200 with valid JSON: ok' );
	is( $result->{data}->{username}, 'd5c0d3', '...and the body is decoded' );
}

for my $content ( undef, '' ) {
	my $label = defined $content ? "''" : 'undef';
	my $result = $A->classifyResponse( 200, $content );
	ok( !$result->{ok}, "200 with $label content: not ok" );
	is( $result->{error}, 'empty_body', "...classified as empty_body (decisions §9.3's documented symptom)" );
}

{
	my $result = $A->classifyResponse( 200, '{not json' );
	ok( !$result->{ok}, '200 with malformed JSON: not ok' );
	is( $result->{error}, 'malformed_json', '...classified as malformed_json' );
}

{
	my $result = $A->classifyResponse( 200, 'null' );
	ok( !$result->{ok}, '200 with JSON null: not ok (a defined-but-useless body)' );
	is( $result->{error}, 'malformed_json', '...classified as malformed_json, not treated as a valid empty result' );
}

my %codeToError = (
	401 => 'unauthorized',
	404 => 'not_found',
	429 => 'rate_limited',
	500 => 'server_error',
	503 => 'server_error',
);

for my $code ( sort keys %codeToError ) {
	my $result = $A->classifyResponse( $code, 'irrelevant body' );
	ok( !$result->{ok}, "$code: not ok" );
	is( $result->{error}, $codeToError{$code}, "$code classified as $codeToError{$code}" );
	is( $result->{code}, $code, "$code: code is carried through" );
}

{
	my $result = $A->classifyResponse( 302, 'irrelevant' );
	ok( !$result->{ok}, '302 (unlisted code): not ok' );
	is( $result->{error}, 'unknown', '...classified as unknown rather than silently matching a listed case' );
}

for my $code ( 0, undef ) {
	my $label = defined $code ? '0' : 'undef';
	my $result = $A->classifyResponse( $code, undef );
	ok( !$result->{ok}, "code $label (no response at all): not ok" );
	is( $result->{error}, 'no_response', "...classified as no_response" );
}

# ---------------------------------------------------------------------------
# accountRequest - rate-limit accounting
# ---------------------------------------------------------------------------

{
	my ( $state, $wait ) = $A->accountRequest( { limit => 60, used => 12, remaining => 48 }, 1000, undef );
	is( $state->{limit}, 60, 'good headers: limit carried through' );
	is( $state->{remaining}, 48, '...remaining carried through' );
	is( $state->{checked_at}, 1000, '...checked_at is the time given' );
	is( $wait, 0, '...remaining > 0 means no wait before the next request' );
}

{
	my ( $state, $wait ) = $A->accountRequest( { limit => 60, used => 60, remaining => 0 }, 1000, undef );
	is( $state->{remaining}, 0, 'remaining = 0: state reflects it' );
	is( $wait, 60, '...wait is the full window (decisions §9.2: resets after 60 idle seconds)' );
}

for my $headers ( undef, {}, { limit => 60 }, { limit => 'sixty', used => 12, remaining => 48 } ) {
	my ( $state, $wait ) = $A->accountRequest( $headers, 1000, undef );
	is( $state->{remaining}, 0, 'unusable headers with no prior state: conservative remaining=0' );
	is( $state->{limit}, 60, '...conservative limit is the documented default, not undef' );
	is( $wait, 60, '...forces the full window before the next request' );
}

{
	# §3.4's actual hazard: must never divide by an undef/non-numeric value.
	# If accountRequest did `$used / $limit` anywhere, this would warn or die
	# under `use warnings`.
	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, $_[0] };
	$A->accountRequest( { limit => undef, used => 'x', remaining => undef }, 1000, undef );
	is( scalar @warnings, 0, 'malformed headers produce no warnings (no implicit numeric op on undef/non-numeric)' );
}

{
	my $prior = { limit => 60, used => 55, remaining => 5, checked_at => 900 };
	my ( $state, $wait ) = $A->accountRequest( {}, 1000, $prior );
	is( $state->{remaining}, 4, 'missing headers with a prior state: remaining decrements by one, not reset to full' );
	is( $wait, 0, '...still budget left, so no wait yet' );
}

{
	my $prior = { limit => 60, used => 60, remaining => 0, checked_at => 900 };
	my ( $state, $wait ) = $A->accountRequest( {}, 1000, $prior );
	is( $state->{remaining}, 0, 'missing headers with a prior state already at 0: stays at 0, never goes negative' );
	is( $wait, 60, '...still forces the full window' );
}

{
	# A corrupt prior state (itself unusable) must not be trusted either -
	# falls all the way back to the fully conservative default.
	my $prior = { limit => 60, used => 'x', remaining => 'y' };
	my ( $state, $wait ) = $A->accountRequest( {}, 1000, $prior );
	is( $state->{remaining}, 0, 'unusable headers AND an unusable prior state: falls back to the conservative default' );
	is( $wait, 60, '...and still forces the full window' );
}

{
	my ( $state ) = $A->accountRequest( { limit => 60, used => 0, remaining => 60 }, undef, undef );
	ok( defined $state->{checked_at}, 'an undef $now is filled in rather than stored as undef' );
}

# ---------------------------------------------------------------------------
# backoffFor - 429 retry bound
# ---------------------------------------------------------------------------

{
	is( $A->backoffFor(0), 60, 'attempt 0: backs off the full window' );
	is( $A->backoffFor(1), 60, 'attempt 1: same backoff' );
	is( $A->backoffFor(2), 60, 'attempt 2 (last allowed retry): still backs off' );
	is( $A->backoffFor(3), undef, 'attempt 3 (MAX_RETRIES): gives up rather than retrying forever' );
	is( $A->backoffFor(4), undef, 'attempt beyond the bound: still gives up' );
	is( $A->backoffFor(undef), undef, 'an undef attempt count is treated as "give up", not as attempt 0' );
}

# ---------------------------------------------------------------------------
# _parseRateHeaders - the one place a headers object is touched
# ---------------------------------------------------------------------------

{
	my $headers = Test::StubHeaders->new(
		'X-Discogs-Ratelimit'           => '60',
		'X-Discogs-Ratelimit-Used'      => '12',
		'X-Discogs-Ratelimit-Remaining' => '48',
	);
	my $parsed = Plugins::SqueezeWax::API::_parseRateHeaders($headers);
	is_deeply( $parsed, { limit => 60, used => 12, remaining => 48 },
		'_parseRateHeaders reads the three documented header names into the accountRequest shape' );
}

{
	is_deeply( Plugins::SqueezeWax::API::_parseRateHeaders(undef), {},
		'_parseRateHeaders degrades to an empty hashref when there is no headers object at all' );
}

done_testing();
