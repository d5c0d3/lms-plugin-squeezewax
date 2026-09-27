#!/usr/bin/env perl
#
# Offline exercise of the scan-time sync (build-order step 8b, decisions
# §15.18): API/Sync.pm's blocking fetch.
#
# The transport is stubbed and modelled on the real one, as sync-check.pl's is
# on SimpleAsyncHTTP - because a simplified stub there hid a production defect
# for the whole of step 5. What Slim::Networking::SimpleSyncHTTP really does,
# read from refs/ (Slim/Networking/SimpleSyncHTTP.pm):
#
#   - code, mess and headers are set for EVERY response (:97-99);
#   - content is set only on success (:101-108 -> processResponse), and reads
#     as '' otherwise (:137);
#   - LWP never returns "no response": a timeout, a DNS failure or a refused
#     connection is LWP's own 500 carrying `Client-Warning: Internal response`
#     (CPAN/LWP/UserAgent.pm:205-219, :1131-1139).
#
# So there is no canned response with no code here, unlike sync-check.pl: that
# shape does not exist on this transport.
#
# The clock is controllable (CORE::GLOBAL::time, installed before the modules
# compile), so the 120 s budget is exercised without waiting for it. A canned
# response may carry `takes => N`, which advances the clock by N seconds while
# the "request" is in flight - how a slow response is staged.
#
# What this cannot prove: that SimpleSyncHTTP reaches api.discogs.com from the
# scanner's perl at all (SSL, proxy, LWP's timeout at scanner priority). Those
# are plan §7's hardware checks 5, 7 and TODO's proxy item.
#
# Usage: scripts/scan-sync-check.pl

use strict;
use warnings;

use Config;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

# Host Test::More, before refs goes on @INC - see library-check.pl.
use Test::More;

our $NOW;
BEGIN { *CORE::GLOBAL::time = sub () { defined $main::NOW ? $main::NOW : CORE::time() } }

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
		"$libPath/CPAN/arch/$Config{version}/$Config::Config{archname}",
		"$libPath/CPAN/arch/$Config{version}/$Config::Config{archname}/auto",
		"$libPath/CPAN/arch/$perlmajorversion/$Config::Config{archname}",
		"$libPath/CPAN/arch/$perlmajorversion/$Config::Config{archname}/auto",
		"$libPath/CPAN/arch/$Config::Config{archname}",
		"$libPath/CPAN/arch/$perlmajorversion",
		"$libPath/lib",
		"$libPath/CPAN",
		$libPath,
	);
}

our @REQUESTS;    # every stubbed request, as { url, headers, params }
our @RESPONSES;   # canned responses, consumed in order
our %PREFS;
our ( @LOG, @WARNINGS, @ERRORS );

BEGIN {
	$INC{'Slim/Utils/Log.pm'}                  = 1;
	$INC{'Slim/Utils/Prefs.pm'}                = 1;
	$INC{'Slim/Utils/PluginManager.pm'}        = 1;
	$INC{'Slim/Networking/SimpleSyncHTTP.pm'}  = 1;

	no strict 'refs';
	no warnings 'redefine', 'once';

	*{'Slim::Utils::Log::logger'}   = sub { Test::StubLogger->new };
	*{'Slim::Utils::Log::logError'} = sub { };
	*{'Slim::Utils::Log::import'}   = sub {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::logger"}   = \&Slim::Utils::Log::logger;
		*{"${caller}::logError"} = \&Slim::Utils::Log::logError;
	};

	*{'Slim::Utils::Prefs::preferences'} = sub { Test::StubPrefs->new };
	*{'Slim::Utils::Prefs::import'}      = sub {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::preferences"} = \&Slim::Utils::Prefs::preferences;
	};

	*{'Slim::Utils::PluginManager::dataForPlugin'} = sub { { version => '0.0.0.0' } };

	# The scanner: this whole path exists only there.
	*{'main::SCANNER'}   = sub () { 1 };
	# On, so every INFOLOG-guarded summary is actually built (stub audit
	# 2026-09-24, entry 5.3 / 4).
	*{'main::INFOLOG'}   = sub () { 1 };
	*{'main::DEBUGLOG'}  = sub () { 0 };
	*{'main::ISWINDOWS'} = sub () { 0 };
}

{
	package Test::StubLogger;
	sub new      { bless {}, shift }
	sub error    { shift; push @main::ERRORS,   "@_"; return }
	sub warn     { shift; push @main::WARNINGS, "@_"; return }
	sub info     { shift; push @main::LOG,      "@_"; return }
	sub debug    { }
	sub is_info  { 1 }
	sub is_debug { 0 }
}

{
	package Test::StubPrefs;
	sub new { bless {}, shift }
	sub get { return $main::PREFS{ $_[1] } }
	sub set { $main::PREFS{ $_[1] } = $_[2]; return 1 }
}

# An HTTP::Headers stand-in: ->header(name), case-insensitive, as the real one.
{
	package Test::StubHeaders;
	sub new    { my $class = shift; my %h = @_; bless { map { lc($_) => $h{$_} } keys %h }, $class }
	sub header { return $_[0]->{ lc $_[1] } }
}

# The stub transport - see the header for what it models and why.
{
	package Slim::Networking::SimpleSyncHTTP;

	sub new {
		my ( $class, $params ) = @_;
		return bless { params => $params || {} }, $class;
	}

	sub get {
		my ( $self, $url, @headers ) = @_;

		push @main::REQUESTS, { url => $url, headers => \@headers, params => $self->{params} };

		# SimpleSyncHTTP.pm:87 - a falsy timeout returns before anything is sent.
		# Modelled, so a caller that forgets the timeout is seen to send nothing.
		return $self unless $self->{params}{timeout} || $self->{params}{Timeout};

		my $canned = shift @main::RESPONSES
			or die "stub transport: no canned response left for $url\n";

		$main::NOW += $canned->{takes} if $canned->{takes};

		$self->{code}    = $canned->{code};
		$self->{headers} = Test::StubHeaders->new( %{ $canned->{headers} || {} } );
		$self->{content} = ( $canned->{code} =~ /^2\d\d$/ ) ? $canned->{content} : undef;

		return $self;
	}

	sub code    { $_[0]->{code} }
	sub headers { $_[0]->{headers} }
	sub content { defined $_[0]->{content} ? $_[0]->{content} : '' }
}

use JSON::XS qw(encode_json);

my $incdir;

BEGIN {
	$incdir = tempdir( CLEANUP => 1 );
	mkdir "$incdir/Plugins";
	symlink "$Bin/../SqueezeWax", "$incdir/Plugins/SqueezeWax"
		or die "could not link the plugin into $incdir: $!\n";
	unshift @INC, $incdir;
}

require Plugins::SqueezeWax::API::Sync;

my $F = 'Plugins::SqueezeWax::API::Sync';

# ---------------------------------------------------------------------------
# Canned responses
# ---------------------------------------------------------------------------

sub healthy_headers {
	return {
		'X-Discogs-Ratelimit'           => 60,
		'X-Discogs-Ratelimit-Used'      => 1,
		'X-Discogs-Ratelimit-Remaining' => 59,
	};
}

sub spent_headers {
	return {
		'X-Discogs-Ratelimit'           => 60,
		'X-Discogs-Ratelimit-Used'      => 60,
		'X-Discogs-Ratelimit-Remaining' => 0,
	};
}

sub identity_response {
	my (%opt) = @_;

	return {
		code    => 200,
		headers => $opt{headers} || healthy_headers(),
		content => encode_json( { username => 'deschman' } ),
		%opt,
	};
}

# $n releases on $page of $pages, the collection claiming $items. Ids offset by
# page so they are unique across pages, as sync-check.pl's are.
sub page_response {
	my ( $n, $page, $pages, $items, %opt ) = @_;

	my $base = ( $page - 1 ) * 100;

	return {
		code    => 200,
		headers => $opt{headers} || healthy_headers(),
		takes   => $opt{takes},
		content => encode_json( {
			$opt{no_pagination} ? () : ( pagination => {
				page => $page, pages => $pages, items => $items, per_page => 100,
			} ),
			releases => [
				map { {
					id                => 1000 + $base + $_,
					instance_id       => 2000 + $base + $_,
					basic_information => {
						id        => 1000 + $base + $_,
						master_id => 9000 + $base + $_,
						title     => 'Album ' . ( $base + $_ ),
						artists   => [ { name => 'Artist ' . ( $base + $_ ) } ],
					},
				} } 1 .. $n
			],
		} ),
	};
}

# LWP's self-made 500: what a timeout, a DNS failure or a refused connection
# looks like on this transport.
sub lwp_internal_500 {
	return {
		code    => 500,
		headers => { 'Client-Warning' => 'Internal response' },
		content => "500 read timeout\n",
	};
}

sub reset_state {
	@REQUESTS  = ();
	@RESPONSES = ();
	@LOG       = ();
	@WARNINGS  = ();
	@ERRORS    = ();
	%PREFS     = ();
	$NOW       = 1_000_000;
}

# Run one fetch against @responses, returning the result and every
# onResponse notification as [ $requests, $pages ].
sub run_fetch {
	my (@responses) = @_;

	@RESPONSES = @responses;

	my @notified;
	my $result = $F->fetch( 'token-abc', sub { push @notified, [@_] } );

	return ( $result, \@notified );
}

# ===========================================================================
# API/Sync.pm - the fetch on its own
# ===========================================================================

diag('API/Sync.pm: the walk');

{
	reset_state();

	my ( $result, $notified ) = run_fetch(
		identity_response(),
		page_response( 100, 1, 3, 203 ),
		page_response( 100, 2, 3, 203 ),
		page_response( 3,   3, 3, 203 ),
	);

	ok( $result->{ok}, 'a complete three-page collection fetches' );
	is( $result->{items},    203, '  ...reporting pagination.items' );
	is( $result->{counted},  203, '  ...and as many distinct entries' );
	is( $result->{pages},    3,   '  ...over three pages' );
	is( $result->{requests}, 4,   '  ...in four requests: the identity lookup and three pages' );
	is( scalar @{ $result->{entries} }, 203, '  ...handing back every entry' );

	like( $REQUESTS[0]{url}, qr{/oauth/identity$}, 'the identity is asked for first' );
	like( $REQUESTS[1]{url}, qr{/users/deschman/collection/folders/0/releases\?},
		'  ...then the collection, folder 0' );
	like( $REQUESTS[1]{url}, qr{sort=added}, '  ...with the pinned sort (§9.4)' );
	like( $REQUESTS[3]{url}, qr{page=3},     '  ...and the last request is the last page' );

	my %h = @{ $REQUESTS[1]{headers} };
	is( $h{Authorization}, 'Discogs token=token-abc', 'the token is sent' );
	like( $h{'User-Agent'}, qr{^SqueezeWax/}, '  ...with our User-Agent' );
	is( scalar( @{ $REQUESTS[1]{headers} } ) % 2, 0,
		'  ...as an even-length header list, or the last element would become the body (Base.pm:109-111)' );

	is( $REQUESTS[0]{params}{timeout}, 15, 'every request passes the 15 s timeout explicitly' );
	ok( !( grep { ( $_->{params}{timeout} || 0 ) != 15 } @REQUESTS ), '  ...every one of them' );
	ok( !( grep { exists $_->{params}{cache} } @REQUESTS ),
		'  ...and none asks for cache - a cached page would defeat the completeness gate' );

	my ($one) = grep { $_->{instance_id} == 2001 } @{ $result->{entries} };
	is_deeply(
		[ sort keys %$one ],
		[ sort qw(instance_id id master_id title artists year formats labels) ],
		'each entry is API.pm\'s entryFromRelease shape - the one the async path builds'
	);

	is_deeply( $notified, [ [ 1, undef ], [ 2, 3 ], [ 3, 3 ], [ 4, 3 ] ],
		'onResponse fires once per response, with the page count from page 1 on' );

	ok( ( grep { /fetch starting for Discogs user deschman/ } @LOG ), 'the start is logged at info' );
	is( scalar @ERRORS, 0, '  ...and nothing at error' );
}

{
	reset_state();

	my ($result) = run_fetch( identity_response(), page_response( 0, 1, 1, 0 ) );

	ok( $result->{ok}, 'an empty collection is a success' );
	is( $result->{requests}, 2, '  ...costing the identity lookup and one page' );
	is_deeply( $result->{entries}, [], '  ...with an empty entry list' );
}

# --- failures that are the async path's too, by the same names -------------

diag('API/Sync.pm: one error vocabulary with the async path');

{
	reset_state();

	my ($result) = $F->fetch('');
	is( $result->{error}, 'no_token', 'no token fails as no_token' );
	is( scalar @REQUESTS, 0, '  ...without a request' );
}

{
	reset_state();

	my ($result) = run_fetch( { code => 200, headers => healthy_headers(), content => '{}' } );
	is( $result->{error}, 'no_username', 'an identity with no username fails as no_username' );
	is( scalar @REQUESTS, 1, '  ...before asking for a collection' );
}

{
	reset_state();

	my ($result) = run_fetch( identity_response(), page_response( 1, 1, 5000, 500000 ) );
	is( $result->{error}, 'too_many_pages', 'an absurd page count fails as too_many_pages' );
	is( scalar @REQUESTS, 2, '  ...having issued only the first page' );
}

{
	reset_state();

	my ($result) = run_fetch( identity_response(), page_response( 2, 1, 1, 2, no_pagination => 1 ) );
	is( $result->{error}, 'count_unknown', 'no pagination block fails as count_unknown' );
	ok( !$result->{entries}, '  ...handing back no list' );
}

{
	reset_state();

	my ($result) = run_fetch(
		identity_response(),
		page_response( 100, 1, 2, 203 ),
		page_response( 2,   2, 2, 203 ),
	);
	is( $result->{error}, 'count_mismatch', 'a short collection fails as count_mismatch' );
	ok( !$result->{entries}, '  ...handing back no list' );
}

{
	reset_state();

	my ($result) = run_fetch( { code => 401, headers => healthy_headers(), content => '' } );
	is( $result->{error}, 'unauthorized', 'a 401 is unauthorized' );
	is( $result->{requests}, 1, '  ...after one request' );
}

{
	reset_state();

	my ($result) = run_fetch( lwp_internal_500() );
	is( $result->{error}, 'no_response',
		'LWP\'s own 500 (Client-Warning: Internal response) is no_response, not server_error' );
}

{
	reset_state();

	my ($result) = run_fetch( { code => 500, headers => healthy_headers(), content => 'boom' } );
	is( $result->{error}, 'server_error', 'a real Discogs 500 is still server_error' );
}

{
	reset_state();

	my ($result) = run_fetch(
		{ code => 500, headers => { 'Client-Warning' => 'Something else' }, content => '' } );
	is( $result->{error}, 'server_error', '  ...and so is a 500 whose Client-Warning is not LWP\'s' );
}

# --- no retries: a 429 fails once -------------------------------------------

diag('API/Sync.pm: no retries, no waiting (§15.18 part 11)');

{
	reset_state();

	my ($result) = run_fetch(
		identity_response(),
		{ code => 429, headers => healthy_headers(), content => '' },
		page_response( 5, 1, 1, 5 ),    # never reached
	);

	is( $result->{error}, 'rate_limited', 'a 429 fails the fetch as rate_limited' );
	is( scalar @REQUESTS, 2, '  ...on the first 429 - backoffFor is never consulted' );
	is( scalar @RESPONSES, 1, '  ...leaving the retry the async path would make unmade' );
}

{
	reset_state();

	# backoffFor is not merely unused by the flow above; it is never called.
	no warnings 'redefine', 'once';
	my $called = 0;
	local *Plugins::SqueezeWax::API::backoffFor = sub { $called++; 60 };

	run_fetch( identity_response(), { code => 429, headers => healthy_headers(), content => '' } );

	is( $called, 0, 'backoffFor is never called on the scan path' );
}

# --- the rate wait abandons BEFORE the next request -------------------------
{
	reset_state();

	# The scanner starts cold: a first response with no rate headers leaves
	# accountRequest assuming the budget spent, so there is a wait - and it is
	# checked before the page request, which is therefore never issued.
	my ($result) = run_fetch(
		identity_response( headers => {} ),
		page_response( 5, 1, 1, 5 ),
	);

	is( $result->{error}, 'rate_wait', 'a computed wait abandons the fetch as rate_wait' );
	is( scalar @REQUESTS, 1, '  ...before issuing the next request' );
	ok( ( grep { /rate budget spent.*abandoning/ } @ERRORS ), '  ...logged at error' );
}

{
	reset_state();

	# A spent budget reported by the LAST page computes a wait, and there is no
	# next request for it to refuse: it costs nothing.
	my ($result) = run_fetch(
		identity_response(),
		page_response( 5, 1, 1, 5, headers => spent_headers() ),
	);

	ok( $result->{ok}, 'a wait computed after the last page costs nothing' );
	is( scalar @ERRORS, 0, '  ...and logs nothing' );
}

{
	reset_state();

	# ...whereas the same spent budget one page earlier stops the walk.
	my ($result) = run_fetch(
		identity_response(),
		page_response( 100, 1, 2, 150, headers => spent_headers() ),
		page_response( 50,  2, 2, 150 ),
	);

	is( $result->{error}, 'rate_wait', 'a wait computed with a page still to fetch abandons' );
	is( scalar @REQUESTS, 2, '  ...without requesting page 2' );
}

# --- the 120 s budget, checked between requests ------------------------------

diag('API/Sync.pm: the whole-fetch budget (§15.18 part 10)');

{
	reset_state();

	# Page 1 takes 125 s - one slow-but-alive response, which nothing can
	# interrupt. The budget is checked before page 2, which is not issued.
	my ($result) = run_fetch(
		identity_response(),
		page_response( 100, 1, 2, 150, takes => 125 ),
		page_response( 50,  2, 2, 150 ),
	);

	is( $result->{error}, 'timeout_budget', 'a fetch past 120 s abandons as timeout_budget' );
	is( scalar @REQUESTS, 2, '  ...between requests: page 2 is never issued' );
	ok( ( grep { /taken 125s, past its 120s budget/ } @ERRORS ), '  ...logged at error with the time' );
}

{
	reset_state();

	# The same 125 s on the LAST page: nothing follows it, so the fetch is
	# complete and stands.
	my ($result) = run_fetch(
		identity_response(),
		page_response( 5, 1, 1, 5, takes => 125 ),
	);

	ok( $result->{ok}, 'a budget crossed by the last response costs nothing' );
}

{
	reset_state();

	# 119 s in is still inside.
	my ($result) = run_fetch(
		identity_response( takes => 119 ),
		page_response( 5, 1, 1, 5 ),
	);

	ok( $result->{ok}, 'a fetch 119 s in still issues its next request' );
}

# --- _testFilter applies on this path -----------------------------------------

diag('API/Sync.pm: the test filter, after the gate');

{
	reset_state();
	$PREFS{discogsTestExcludeReleases} = '1001';

	my ($result) = run_fetch( identity_response(), page_response( 3, 1, 1, 3 ) );

	ok( $result->{ok}, 'a filtered fetch still passes the completeness gate' );
	is( $result->{counted}, 3, '  ...which counted the unfiltered list' );
	is_deeply( [ sort map { $_->{id} } @{ $result->{entries} } ], [ 1002, 1003 ],
		'  ...and the filter hides the named release from the list the pass gets' );
	ok( !( grep { $_->{url} =~ /1001/ } @REQUESTS ), '  ...without it reaching Discogs' );
}

# --- nothing escapes -----------------------------------------------------------
{
	reset_state();

	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::API::buildRequest = sub { die "kaboom\n" };

	my $result = eval { $F->fetch('token-abc') };

	ok( $result, 'a die inside the fetch does not escape it' );
	is( $result->{error}, 'failed', '  ...it is a failed result' );
	ok( ( grep { /fetch died: kaboom/ } @ERRORS ), '  ...logged at error' );
}

done_testing();
