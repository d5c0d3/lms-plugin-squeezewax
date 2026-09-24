#!/usr/bin/env perl
#
# Offline exercise of Plugins::SqueezeWax::API::Async - the collection sync's
# pagination, its discard behaviour, its retry boundary and its "never
# partially advance the timestamp" rule.
#
# What this cannot prove, and the reason it is a separate file from a hardware
# check: nothing here touches a real event loop, a real timer or a real socket.
# Slim::Networking::SimpleAsyncHTTP and Slim::Utils::Timers are both stubbed,
# and both stubs are SYNCHRONOUS - a stubbed request calls its own callback
# before ->get returns, and a stubbed timer fires before setTimer returns. That
# is what makes the state machine testable in one process, and it is also
# exactly what production does not do. So this proves the sequence of requests,
# the arithmetic and the state transitions; it proves nothing about whether the
# real Timers/SimpleAsyncHTTP interaction behaves as read from refs/. Same
# limitation scripts/api-check.pl states for the transport it used to carry,
# and the same reason build-order step 5's §3 checks are on the hardware list.
#
# Usage: scripts/sync-check.pl

use strict;
use warnings;

use constant PERFMON  => 0;
use constant DEBUGLOG => 1;
use constant INFOLOG  => 1;

use Config;
use FindBin qw($Bin);

# Host Test::More, before refs goes on @INC - see library-check.pl.
use Test::More;

# Ordered pref writes, and the onchange callbacks registered against them.
# Ordered because ORDER was the 0.0.0.7 defect.
our @WRITES;
our %CHANGES;

# Every stubbed request that was issued, oldest first, as { url, headers }.
our @REQUESTS;

# Canned responses, consumed in order by the stub transport.
our @RESPONSES;

# Every stubbed timer, as { delay, fired }.
our @TIMERS;

# Every killTimers call.
our @KILLS;

# The stub preferences store, so a test can assert what a sync did and did not
# write.
our %PREFS;

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

	# Async.pm's LMS dependencies, all four stubbed. Timers and the transport
	# are stubbed because driving them is the point (see the header); Prefs and
	# PluginManager because they are the same incidental file-scope
	# dependencies every other suite here stubs.
	$INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = 1;
	$INC{'Slim/Utils/Log.pm'}                  = 1;
	$INC{'Slim/Utils/Prefs.pm'}                = 1;
	$INC{'Slim/Utils/PluginManager.pm'}        = 1;
	$INC{'Slim/Utils/Timers.pm'}               = 1;

	no strict 'refs';

	# The main:: constants below are declared at the top of this file so they
	# exist during compilation, and re-globbed here so they are the same
	# constants Async.pm sees. api-check.pl does the same and emits a pair of
	# "Constant subroutine redefined" warnings for it; suppressed here rather
	# than inherited.
	no warnings 'redefine';

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

	# Fires immediately rather than at $when, and records what the delay would
	# have been. Every assertion about backoff in this file is an assertion
	# about that recorded number, never about elapsed time.
	*{'Slim::Utils::Timers::setTimer'} = sub {
		my ( $obj, $when, $code, @args ) = @_;

		push @TIMERS, { delay => $when - time(), fired => 1 };

		$code->( $obj, @args );

		return;
	};

	*{'Slim::Utils::Timers::killTimers'} = sub {
		push @KILLS, { coderef => $_[1] };
		return 1;
	};

	*{'main::SCANNER'}   = sub () { 0 };
	# INFOLOG is ON, and is_info below returns true with it, so every
	# `main::INFOLOG && $log->is_info && $log->info(...)` expression is
	# EVALUATED rather than short-circuited away (stub audit 2026-09-24, entry
	# 5.3 / 4). Those expressions build strings from live counters; a summary
	# that dies while being built is a defect no suite could see while this was
	# 0, and the ownership pass's counts are what step 8 will size its queue
	# from.
	*{'main::INFOLOG'}   = sub () { 1 };
	*{'main::DEBUGLOG'}  = sub () { 0 };
	*{'main::ISWINDOWS'} = sub () { 0 };
}

our @LOG;

{
	package Test::StubLogger;
	sub new      { bless {}, shift }
	sub error    { }
	sub warn     { shift; push @main::WARNINGS, "@_"; return }
	sub info     { shift; push @main::LOG, "@_"; return }
	sub debug    { }
	sub is_info  { 1 }
	sub is_debug { 0 }
}

{
	package Test::StubPrefs;
	sub new { bless {}, shift }
	sub get { return $PREFS{ $_[1] } }

	# Models two behaviours of the real store that a plain hash write does not,
	# and whose absence is exactly what hid the 0.0.0.7 regression one file
	# over (stub audit 2026-09-24, entry 2.1):
	#
	#   1. refs/slimserver/Slim/Utils/Prefs/Base.pm:94-97 suppresses a scalar
	#      set that does not change the value - onchange included. A write that
	#      changes nothing is not an event.
	#   2. Base.pm:91 dispatches the onchange list registered through
	#      Prefs/Namespace.pm:148-164. Async.pm writes three prefs at its single
	#      exit, and a hook on any of them would fire here unmodelled.
	#
	# @WRITES is ordered, because ORDER was the defect: a pref write landing
	# after the thing it was meant to precede.
	sub set {
		my ( $self, $pref, $new ) = @_;

		my $old = $PREFS{$pref};

		return 1 if !ref $new
			&& defined $new
			&& defined $old
			&& $new eq $old;

		$PREFS{$pref} = $new;

		push @main::WRITES, $pref;

		if ( my $cb = $main::CHANGES{$pref} ) {
			$cb->( $pref, $new );
		}

		return 1;
	}

	sub init { 1 }
	sub migrate { 1 }
	sub setValidate { 1 }
	sub setChange { my ( $self, $cb, @prefs ) = @_; $main::CHANGES{$_} = $cb for @prefs; return 1 }
}

# Minimal stand-in for an HTTP::Headers object, as api-check.pl's own
# Test::StubHeaders is - only ->header(name) is reached, by _parseRateHeaders.
{
	package Test::StubHeaders;
	sub new { my $class = shift; bless { map { lc $_ } @_ }, $class }
	sub header { return $_[0]->{ lc $_[1] } }
}

# The stub transport. Pops the next canned response, records the request, and
# calls back synchronously - see the header for why that is both the point and
# the limitation.
{
	package Slim::Networking::SimpleAsyncHTTP;

	sub new {
		my ( $class, $cb, $ecb, $args ) = @_;
		return bless { cb => $cb, ecb => $ecb, args => $args }, $class;
	}

	# Which callback fires, and what is populated when it does, is modelled on
	# the real thing rather than simplified - because the simplification hid a
	# production defect for the whole of build-order step 5.
	#
	# refs/slimserver/Slim/Networking/Async/HTTP.pm:434-436 sends EVERY status
	# that is not 2xx or 3xx to _http_error, which reaches SimpleAsyncHTTP's
	# onError. onError (:76-101) sets neither code nor content nor headers on
	# the SimpleAsyncHTTP object; it passes the HTTP::Response as the error
	# callback's THIRD argument (:96). Only onBody sets them (:112-114), and it
	# then calls the success callback.
	#
	# The old stub set code on every response and always called the success
	# callback, so `unauthorized`, `rate_limited`, `not_found` and
	# `server_error` all appeared reachable here while being unreachable in
	# production (decisions §15.15 part 2).
	sub get {
		my ( $self, $url, @headers ) = @_;

		push @REQUESTS, { url => $url, headers => \@headers };

		my $canned = shift @RESPONSES
			or die "stub transport: no canned response left for $url\n";

		# A connection that never produced a status at all: no response object
		# either. This is the only thing that should classify as no_response.
		if ( !defined $canned->{code} ) {
			$self->{ecb}->( $self, 'connection failed', undef );

			return;
		}

		my $response = Test::StubResponse->new($canned);

		if ( $canned->{code} !~ /^[23]\d\d$/ ) {
			$self->{ecb}->( $self, "HTTP $canned->{code}", $response );

			return;
		}

		$self->{code}    = $canned->{code};
		$self->{content} = $canned->{content};
		$self->{headers} = $response->headers;

		$self->{cb}->($self);

		return;
	}

	sub code    { $_[0]->{code} }
	sub content { $_[0]->{content} }
	sub headers { $_[0]->{headers} }
}

# What onError hands over as its third argument. Only code/content/headers are
# reached.
{
	package Test::StubResponse;

	sub new {
		my ( $class, $canned ) = @_;

		return bless {
			code    => $canned->{code},
			content => $canned->{content},
			headers => Test::StubHeaders->new( %{ $canned->{headers} || {} } ),
		}, $class;
	}

	sub code    { $_[0]->{code} }
	sub content { $_[0]->{content} }
	sub headers { $_[0]->{headers} }
}

use JSON::XS qw(encode_json);

# Loaded by file path, as api-check.pl loads API.pm: the repository directory
# is SqueezeWax/ while the package namespace is Plugins::SqueezeWax:: (CLAUDE.md
# - LMS requires the two to correspond at install time, not in a checkout).
# Async.pm's own `use Plugins::SqueezeWax::API` then has to be satisfied by
# hand, since that file has already been loaded under its other name.
use lib "$Bin/..";

require SqueezeWax::API;
BEGIN { $INC{'Plugins/SqueezeWax/API.pm'} = 1 }

# The ownership pass is exercised in full by scripts/ownership-check.pl. What
# this suite is about is the WIRING: whether the pass is called at all, what it
# is handed, and what its answer does to the prefs. So it is stubbed, and the
# stub records every call.
BEGIN {
	$INC{'Plugins/SqueezeWax/Ownership.pm'} = 1;

	no strict 'refs';
	*{'Plugins::SqueezeWax::Ownership::apply'} = sub {
		my ( $class, $entries ) = @_;

		push @main::APPLIED, $entries;

		# Recorded in the same ordered list as the pref writes, so "the pass
		# runs before any pref is set" (§15.13 part 1) is assertable rather
		# than merely commented.
		push @main::WRITES, '<pass>';

		return $main::APPLY_RESULT;
	};
}

our @APPLIED;
our @WARNINGS;
our $APPLY_RESULT = 'ok';

require SqueezeWax::API::Async;

my $A = 'Plugins::SqueezeWax::API::Async';

# Rate headers that say "budget is fine", so the throttle stays out of the way
# of every test that is not about the throttle.
sub healthy_headers {
	return {
		'X-Discogs-Ratelimit'           => 60,
		'X-Discogs-Ratelimit-Used'      => 1,
		'X-Discogs-Ratelimit-Remaining' => 59,
	};
}

sub identity_response {
	return {
		code    => 200,
		headers => healthy_headers(),
		content => encode_json( { username => shift // 'deschman' } ),
	};
}

# One page of a collection: $n release rows, and a pagination block claiming
# $items items over $pages pages.
#
# Ids are offset by page, so they are unique ACROSS pages. Until step 7 every
# page returned ids 1001.. and it did not matter, because releases were counted
# and discarded. They are now keyed by instance_id, so three identical pages
# would de-duplicate to one page's worth and fail the completeness check - a
# fixture that was quietly describing an impossible collection.
sub page_response {
	my ( $n, $page, $pages, $items, %opt ) = @_;

	my $base = ( $page - 1 ) * 100;

	return {
		code    => 200,
		headers => healthy_headers(),
		content => encode_json( {
			$opt{no_pagination} ? () : ( pagination => {
				page     => $page,
				pages    => $pages,
				items    => $items,
				per_page => 100,
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

sub reset_state {
	@REQUESTS     = ();
	@RESPONSES    = ();
	@TIMERS       = ();
	@KILLS        = ();
	%PREFS        = ( discogsLastSynced => 0 );
	@APPLIED      = ();
	@WARNINGS     = ();
	@LOG          = ();
	@WRITES       = ();
	%CHANGES      = ();
	$APPLY_RESULT = 'ok';
}

# Run one sync to completion and return its result. Safe because every stub is
# synchronous: by the time sync() returns, the callback has fired.
sub run_sync {
	my (@responses) = @_;

	@RESPONSES = @responses;

	my $result;
	$A->sync( 'token-abc', sub { $result = shift } );

	return $result;
}

# ---------------------------------------------------------------------------
# _pageCount - the figure step 5's hardware check measures (plan §3 check 1)
# ---------------------------------------------------------------------------

{
	is( Plugins::SqueezeWax::API::Async::_pageCount(203), 3,
		'203 items costs 3 requests - the figure decisions §9.4 measured on real hardware' );

	is( Plugins::SqueezeWax::API::Async::_pageCount(100), 1,
		'an exactly-full single page costs 1, not 2' );

	is( Plugins::SqueezeWax::API::Async::_pageCount(101), 2,
		'one item past a full page costs 2' );

	is( Plugins::SqueezeWax::API::Async::_pageCount(200), 2,
		'an exact multiple of the page size does not round up' );

	is( Plugins::SqueezeWax::API::Async::_pageCount(1), 1,
		'a single item costs 1' );

	is( Plugins::SqueezeWax::API::Async::_pageCount(0), 1,
		'an empty collection still costs the request that discovered it was empty' );

	is( Plugins::SqueezeWax::API::Async::_pageCount(undef), 1,
		'...as does a missing item count' );

	is( Plugins::SqueezeWax::API::Async::_pageCount('lots'), 1,
		'...and a non-numeric one, rather than dying inside ceil' );

	is( Plugins::SqueezeWax::API::Async::_pageCount( 203, 50 ), 5,
		'the page size is a parameter, so the docs\' 50-item default is expressible' );

	is( Plugins::SqueezeWax::API::Async::_pageCount( 203, 0 ), 3,
		'a zero page size falls back to PER_PAGE rather than dividing by zero' );
}

# ---------------------------------------------------------------------------
# _collectionParams - decisions §9.4's pinned sort
# ---------------------------------------------------------------------------

{
	my $params = Plugins::SqueezeWax::API::Async::_collectionParams(1);

	is( $params->{per_page}, 100,
		'per_page is the documented maximum, which the whole ceil(items/100) cost model rests on' );

	is( $params->{sort}, 'added',
		'the sort is pinned to added - the only key on the documented list that is not editable metadata' );

	is( $params->{sort_order}, 'asc',
		'...with an explicit order, so the endpoint default is never relied on' );

	is( $params->{page}, 1, 'page 1 is page 1' );

	is( Plugins::SqueezeWax::API::Async::_collectionParams(7)->{page}, 7,
		'a later page is passed through' );

	is( Plugins::SqueezeWax::API::Async::_collectionParams(0)->{page}, 1,
		'page 0 is corrected to 1 - Discogs pages are 1-based' );

	is( Plugins::SqueezeWax::API::Async::_collectionParams(undef)->{page}, 1,
		'...as is a missing page' );
}

# ---------------------------------------------------------------------------
# _collectionPath
# ---------------------------------------------------------------------------

{
	is( Plugins::SqueezeWax::API::Async::_collectionPath('deschman'),
		'/users/deschman/collection/folders/0/releases',
		'folder 0 is the whole collection' );

	is( Plugins::SqueezeWax::API::Async::_collectionPath('a b'),
		'/users/a%20b/collection/folders/0/releases',
		'a username is escaped - it is interpolated into the path, not passed as a parameter' );

	is( Plugins::SqueezeWax::API::Async::_collectionPath('a/b'),
		'/users/a%2Fb/collection/folders/0/releases',
		'...including a slash, which would otherwise change which endpoint is called' );
}

# ---------------------------------------------------------------------------
# A whole sync: the request sequence, and what it does and does not keep
# ---------------------------------------------------------------------------

{
	reset_state();

	my $result = run_sync(
		identity_response(),
		page_response( 100, 1, 3, 203 ),
		page_response( 100, 2, 3, 203 ),
		page_response( 3,   3, 3, 203 ),
	);

	ok( $result->{ok}, 'a three-page sync succeeds' );

	is( scalar @REQUESTS, 4,
		'203 items costs ceil(203/100) + 1 requests - the three pages plus the identity lookup' );

	is( $result->{requests}, 4, '...and the result says so' );

	is( $result->{items}, 203, 'the reported count is the server\'s own pagination.items' );

	is( $result->{counted}, 203,
		'...and it agrees with the rows actually seen' );

	like( $REQUESTS[0]->{url}, qr{/oauth/identity},
		'the username is looked up first, every run, rather than read from a pref' );

	like( $REQUESTS[1]->{url}, qr{/users/deschman/collection/folders/0/releases},
		'...and the path is built from what it returned' );

	like( $REQUESTS[1]->{url}, qr{sort=added},
		'every page request pins the sort' );

	like( $REQUESTS[3]->{url}, qr{page=3},
		'the last request is for the last page' );

	is( scalar( grep { $_->{url} =~ /page=4/ } @REQUESTS ), 0,
		'and there is no page 4 - the loop stops on pagination.pages, not on an empty page' );
}

{
	reset_state();

	run_sync(
		identity_response(),
		page_response( 100, 1, 2, 150 ),
		page_response( 50,  2, 2, 150 ),
	);

	# The discard rule, checked the only way an offline suite can check it:
	# nothing a page carried is reachable afterwards. §13.2 - ownership is a
	# column on discogs_match computed at step 7, not a mirrored collection,
	# and discogs_collection is not a v1 table.
	is_deeply( [ sort keys %PREFS ],
		[ qw(discogsLastSyncError discogsLastSyncItems discogsLastSynced) ],
		'a completed sync writes exactly three prefs and nothing else - no release survives it' );

	is( $PREFS{discogsLastSyncItems}, 150,
		'what it keeps is a count' );

	ok( $PREFS{discogsLastSynced} > 0, 'and a timestamp' );

	is( $PREFS{discogsLastSyncError}, '',
		'and success clears any previous error' );
}

{
	reset_state();

	my $result = run_sync(
		identity_response(),
		page_response( 0, 1, 1, 0 ),
	);

	ok( $result->{ok}, 'an empty collection is a success, not a failure' );

	is( $result->{items}, 0, '...reporting zero items' );

	is( scalar @REQUESTS, 2, '...at the cost of one identity lookup and one page' );
}

# ---------------------------------------------------------------------------
# The retry boundary (§3.2, MAX_RETRIES)
# ---------------------------------------------------------------------------

{
	reset_state();

	my $rate_limited = {
		code    => 429,
		headers => healthy_headers(),
		content => '',
	};

	my $result = run_sync(
		identity_response(),
		$rate_limited,
		page_response( 5, 1, 1, 5 ),
	);

	ok( $result->{ok}, 'a 429 that clears on retry does not fail the sync' );

	is( scalar @REQUESTS, 3, '...and costs one extra request' );

	is( $TIMERS[0]->{delay}, 60,
		'the retry waits WINDOW_SECONDS, from backoffFor - and waits on a timer, not a sleep' );
}

{
	reset_state();

	my $rate_limited = {
		code    => 429,
		headers => healthy_headers(),
		content => '',
	};

	# MAX_RETRIES is 3, so four attempts at the same request and then give up.
	my $result = run_sync(
		identity_response(),
		($rate_limited) x 4,
	);

	ok( !$result->{ok}, 'a 429 that never clears fails the sync' );

	is( $result->{error}, 'rate_limited', '...as rate_limited, not as something vaguer' );

	is( scalar @REQUESTS, 5,
		'...after MAX_RETRIES + 1 attempts at the page, plus the identity lookup - it gives up rather than retrying forever' );

	is( $PREFS{discogsLastSynced}, 0,
		'and the timestamp does not move for a sync that did not complete' );

	is( $PREFS{discogsLastSyncError}, 'rate_limited',
		'...while the failure itself is recorded, so the settings page has something to show' );
}

# ---------------------------------------------------------------------------
# Failure handling (§13.7/§14.2): never partially advance
# ---------------------------------------------------------------------------

{
	reset_state();
	$PREFS{discogsLastSynced}    = 1_700_000_000;
	$PREFS{discogsLastSyncItems} = 203;

	my $result = run_sync( {
		code    => 401,
		headers => healthy_headers(),
		content => '',
	} );

	ok( !$result->{ok}, 'a rejected token fails the sync' );

	is( $result->{error}, 'unauthorized',
		'...distinguishably, so the caller can log it at error level per §14.2' );

	is( $PREFS{discogsLastSynced}, 1_700_000_000,
		'the previous timestamp is left exactly as it was' );

	is( $PREFS{discogsLastSyncItems}, 203,
		'...and so is the previous count - a transient failure must not make a working collection look like it vanished' );
}

{
	reset_state();
	$PREFS{discogsLastSynced} = 1_700_000_000;

	# Page 1 arrives, page 2 does not. The half-finished sync must leave no
	# trace at all - this is the "a partial scan must never corrupt confirmed
	# state" rule applied to the sync.
	my $result = run_sync(
		identity_response(),
		page_response( 100, 1, 2, 150 ),
		{ code => undef, headers => {}, content => undef },
	);

	ok( !$result->{ok}, 'a sync that dies mid-pagination fails' );

	is( $result->{error}, 'no_response',
		'...as no_response, which is what an unanswered request classifies as' );

	is( $PREFS{discogsLastSynced}, 1_700_000_000,
		'and it does not advance the timestamp for the pages it did get' );

	ok( !defined $PREFS{discogsLastSyncItems},
		'...nor record a count from a partial walk' );
}

{
	reset_state();

	my $result;
	$A->sync( '', sub { $result = shift } );

	ok( !$result->{ok}, 'a missing token fails immediately' );
	is( $result->{error}, 'no_token', '...as no_token' );
	is( scalar @REQUESTS, 0, '...without issuing a request' );
}

{
	reset_state();

	my $result = run_sync( {
		code    => 200,
		headers => healthy_headers(),
		content => '{}',
	} );

	ok( !$result->{ok}, 'an identity response with no username fails' );
	is( $result->{error}, 'no_username', '...as no_username' );

	is( scalar @REQUESTS, 1,
		'...before asking for a collection it would not know the owner of' );
}

# ---------------------------------------------------------------------------
# The guard (§13.7: three triggers, one sync)
# ---------------------------------------------------------------------------

{
	reset_state();

	ok( !$A->isRunning, 'nothing is running to start with' );

	my $result = run_sync(
		identity_response(),
		page_response( 100, 1, 2, 150 ),
		page_response( 50,  2, 2, 150 ),
	);

	ok( $result->{ok}, 'a sync completes' );

	ok( !$A->isRunning,
		'and the guard is clear afterwards, so the next trigger is not blocked' );
}

{
	# A failed sync must clear the guard too, or one bad token would block
	# every future trigger for the life of the server.
	reset_state();

	my $result = run_sync( {
		code    => 401,
		headers => healthy_headers(),
		content => '',
	} );

	ok( !$result->{ok}, 'a sync fails' );

	ok( !$A->isRunning, 'and the guard is still clear afterwards' );
}

{
	# already_running, tested the only way it can be without a real event loop:
	# by calling sync() from inside a callback that runs while the guard is set.
	reset_state();

	my $second;

	@RESPONSES = (
		identity_response(),
		page_response( 5, 1, 1, 5 ),
	);

	# The identity response's handler runs while %sync says running => 1.
	# Hooking in there is equivalent to a second trigger arriving mid-sync.
	my $firstResult;
	my $probe = sub {
		$A->sync( 'token-abc', sub { $second = shift } );
	};

	# Drive it by wrapping the transport for one call.
	{
		no warnings 'redefine';
		my $realGet = \&Slim::Networking::SimpleAsyncHTTP::get;
		local *Slim::Networking::SimpleAsyncHTTP::get = sub {
			my $self = shift;
			$probe->() if @REQUESTS == 1 && !$second;
			return $realGet->( $self, @_ );
		};

		$A->sync( 'token-abc', sub { $firstResult = shift } );
	}

	ok( $firstResult->{ok}, 'the first sync still completes' );

	ok( !$second->{ok},
		'a second trigger arriving mid-sync is refused - §13.7 wants three triggers and one sync' );

	is( $second->{error}, 'already_running',
		'...distinguishably from a failure, because it is not one' );
}

# ---------------------------------------------------------------------------
# Step 7's wiring: the completed sync hands the ownership pass its list
# ---------------------------------------------------------------------------
#
# Decisions §15.13 part 1. The pass is stubbed here; what is under test is that
# it is called at the right moment, with the whole collection, and that
# discogsLastSynced advances only when it succeeded - because that timestamp
# now means "ownership last derived", not "the collection was read".

{
	reset_state();

	my $result = run_sync(
		identity_response(),
		page_response( 100, 1, 3, 203 ),
		page_response( 100, 2, 3, 203 ),
		page_response( 3,   3, 3, 203 ),
	);

	ok( $result->{ok}, 'a complete sync succeeds' );

	# Reachable only since INFOLOG was turned on. The line carries the two
	# figures the settings page and the hardware checks are read against.
	my ($done) = grep { /collection sync complete/ } @LOG;

	ok( $done, 'a complete sync logs its summary at info' );
	like( $done, qr/203 items over 4 requests/,
		'  ...carrying the item count and the request count' );

	is( scalar @APPLIED, 1, 'the ownership pass is called exactly once per sync' );

	my $entries = $APPLIED[0];
	is( scalar @$entries, 203, '  ...and is handed every collection entry' );

	# The five fields the pass needs, and no more. A sixth would be a mirrored
	# collection by accretion, which is what §13.2 rules out.
	my ($one) = grep { $_->{instance_id} == 2001 } @$entries;
	is_deeply(
		[ sort keys %$one ],
		[ sort qw(instance_id id master_id title artists) ],
		'each entry carries exactly the five fields the pass reads'
	);
	is( $one->{id},        1001,       '  ...the release id' );
	is( $one->{master_id}, 9001,       '  ...the master id, from basic_information' );
	is( $one->{title},     'Album 1',  '  ...the title' );
	is_deeply( $one->{artists}, ['Artist 1'], '  ...and the artist names, flattened' );

	# Entries from the LAST page are there too: the list is the whole
	# collection, not the page the walk happened to end on.
	ok( ( grep { $_->{instance_id} == 2201 } @$entries ),
		'entries from the final page are in the list' );

	ok( $PREFS{discogsLastSynced}, 'discogsLastSynced advances when the pass succeeded' );
	is( $PREFS{discogsLastSyncItems}, 203, '  ...along with the item count' );
}

# --- the pass declines: the timestamp must not move ------------------------
for my $outcome (qw(refused failed)) {
	reset_state();

	$APPLY_RESULT = $outcome;

	my $result = run_sync(
		identity_response(),
		page_response( 2, 1, 1, 2 ),
	);

	ok( !$result->{ok}, "a sync whose pass returned '$outcome' is not a success" );
	is( $result->{error}, $outcome, '  ...and reports why' );
	is( scalar @APPLIED, 1, '  ...having actually called the pass' );
	ok( !$PREFS{discogsLastSynced},
		'  ...but discogsLastSynced does NOT advance - it means "ownership last derived"' );
	is( $PREFS{discogsLastSyncError}, $outcome, '  ...and the error is recorded' );
}

# --- completeness: the pass is never called on a list that cannot be shown
#     complete ------------------------------------------------------------
{
	reset_state();

	# Two pages promised, 203 items claimed, 102 delivered. §9.4's pagination
	# hazard: rows moved under us, and a dropped row silently removes a badge.
	my $result = run_sync(
		identity_response(),
		page_response( 100, 1, 2, 203 ),
		page_response( 2,   2, 2, 203 ),
	);

	ok( !$result->{ok}, 'a count mismatch fails the sync rather than warning' );
	is( $result->{error}, 'count_mismatch', '  ...as count_mismatch' );
	is( scalar @APPLIED, 0, '  ...and the pass is never called' );
	ok( !$PREFS{discogsLastSynced}, '  ...so the timestamp does not advance' );
}

{
	reset_state();

	my $result = run_sync(
		identity_response(),
		page_response( 2, 1, 1, 2, no_pagination => 1 ),
	);

	ok( !$result->{ok}, 'a response with no pagination block fails the sync' );
	is( $result->{error}, 'count_unknown',
		'  ...as count_unknown - completeness that cannot be shown is not shown' );
	is( scalar @APPLIED, 0, '  ...and the pass is never called' );
}

# --- the same release owned twice ------------------------------------------
#
# Two instances of one release are two collection entries and must both reach
# the pass: counted is instances, and pagination.items counts instances too.
# Whether they are one candidate or two is the pass's question (§0.2).
{
	reset_state();

	my $page = {
		code    => 200,
		headers => healthy_headers(),
		content => encode_json( {
			pagination => { page => 1, pages => 1, items => 2, per_page => 100 },
			releases   => [
				{ id => 777, instance_id => 111,
				  basic_information => { id => 777, title => 'Twice Owned' } },
				{ id => 777, instance_id => 222,
				  basic_information => { id => 777, title => 'Twice Owned' } },
			],
		} ),
	};

	my $result = run_sync( identity_response(), $page );

	ok( $result->{ok}, 'one release owned twice is a complete collection, not a mismatch' );
	is( $result->{counted}, 2, '  ...counted as two entries, because items counts two' );
	is( scalar @{ $APPLIED[0] }, 2, '  ...and both are handed to the pass' );
}

# --- a duplicated instance_id -----------------------------------------------
#
# The same instance twice is the server repeating itself, not two records. It
# de-duplicates, which then fails the completeness check - which is the right
# answer, because a repeat means something else was dropped.
{
	reset_state();

	my $page = {
		code    => 200,
		headers => healthy_headers(),
		content => encode_json( {
			pagination => { page => 1, pages => 1, items => 2, per_page => 100 },
			releases   => [
				{ id => 777, instance_id => 111,
				  basic_information => { id => 777, title => 'Once' } },
				{ id => 777, instance_id => 111,
				  basic_information => { id => 777, title => 'Once' } },
			],
		} ),
	};

	my $result = run_sync( identity_response(), $page );

	ok( !$result->{ok}, 'a repeated instance_id de-duplicates and fails the count' );
	is( $result->{error}, 'count_mismatch', '  ...as count_mismatch' );
	is( scalar @APPLIED, 0, '  ...with the pass never called' );
}

# --- a superseded run never reaches the pass (W3) --------------------------
#
# _finish's first act is the superseded check, and the pass sits after it: a
# newer sync owns the prefs and the guard, and it owns the badges too. Driven
# directly, because this suite's transport is synchronous and a real overlap
# cannot be staged through it.
{
	reset_state();

	my $result;

	Plugins::SqueezeWax::API::Async::_finish(
		{
			id      => -1,
			cb      => sub { $result = shift },
			entries => { 1 => { instance_id => 1, id => 7, title => 'X', artists => [] } },
		},
		{ ok => 1, items => 1, counted => 1, pages => 1, requests => 2 },
	);

	is( $result->{error}, 'superseded', 'a superseded run reports superseded' );
	is( scalar @APPLIED, 0, '  ...and never reaches the ownership pass' );
	# Was `!$PREFS{discogsLastSynced}` - absence of a VALUE, which would also
	# pass if the pref had been written with a falsy one, and which said
	# nothing about the other two. Now absence of a WRITE, for all of them.
	is( scalar @WRITES, 0, '  ...and touches no pref at all' );
}

# ---------------------------------------------------------------------------
# The test-only collection filter (2026-09-22)
# ---------------------------------------------------------------------------
#
# A development aid that hides release ids from the ownership pass so that "a
# record left the collection" can be exercised without altering a real
# collection. What these assert is where it sits: after the completeness gate,
# before the pass, and never on the fetch.

diag('the test-only collection filter');

{
	reset_state();

	my $result = run_sync(
		identity_response(),
		page_response( 100, 1, 3, 203 ),
		page_response( 100, 2, 3, 203 ),
		page_response( 3,   3, 3, 203 ),
	);

	ok( $result->{ok}, 'with the pref unset the sync succeeds as before' );
	is( scalar @{ $APPLIED[0] }, 203, '  ...and the pass gets every entry' );
	ok( !( grep { /test filter active/ } @WARNINGS ),
		'  ...and nothing warns about a filter' );
}

{
	reset_state();
	$PREFS{discogsTestExcludeReleases} = '1001';

	my $result = run_sync(
		identity_response(),
		page_response( 100, 1, 3, 203 ),
		page_response( 100, 2, 3, 203 ),
		page_response( 3,   3, 3, 203 ),
	);

	ok( $result->{ok}, 'a filtered sync still succeeds' );

	my $entries = $APPLIED[0];

	is( scalar @$entries, 202, 'the pass receives one entry fewer' );
	ok( !( grep { ( $_->{id} || 0 ) == 1001 } @$entries ),
		'  ...and the listed release id is not among them' );

	# The gate ran on the unfiltered list, which is the whole reason the
	# filter sits where it does: hiding a release must never be able to make
	# a sync look incomplete, or mask a genuinely short page.
	is( $result->{items},   203, 'the completeness check still sees the unfiltered count' );
	is( $result->{counted}, 203, '  ...on both sides of its comparison' );

	ok( ( grep { /^test filter active: hiding 1 releases from the ownership pass$/ } @WARNINGS ),
		'and every filtered sync warns, at warn level, naming the count' );
}

{
	reset_state();
	$PREFS{discogsTestExcludeReleases} = '1001, 1002';

	run_sync(
		identity_response(),
		page_response( 100, 1, 3, 203 ),
		page_response( 100, 2, 3, 203 ),
		page_response( 3,   3, 3, 203 ),
	);

	is( scalar @{ $APPLIED[0] }, 201, 'a comma-separated list hides each id' );
	ok( ( grep { /hiding 2 releases/ } @WARNINGS ), '  ...and the count says two' );
}

{
	reset_state();
	# An id this collection does not contain. The filter is still ON, so it
	# must still warn - otherwise a wrong id looks exactly like a wrong
	# conclusion.
	$PREFS{discogsTestExcludeReleases} = '999999999';

	run_sync(
		identity_response(),
		page_response( 100, 1, 3, 203 ),
		page_response( 100, 2, 3, 203 ),
		page_response( 3,   3, 3, 203 ),
	);

	is( scalar @{ $APPLIED[0] }, 203, 'an id that matches nothing hides nothing' );
	ok( ( grep { /hiding 0 releases/ } @WARNINGS ),
		'  ...and still warns, so a wrong id cannot look like a wrong conclusion' );
}

{
	reset_state();
	$PREFS{discogsTestExcludeReleases} = '1001';

	run_sync(
		identity_response(),
		page_response( 100, 1, 3, 203 ),
		page_response( 100, 2, 3, 203 ),
		page_response( 3,   3, 3, 203 ),
	);

	# Nothing about the filter reaches Discogs: the requests are identical to
	# an unfiltered run, and the collection itself is never written to.
	is( scalar @REQUESTS, 4, 'the filter does not change the fetch' );
	ok( !( grep { $_->{url} =~ /999|exclude|1001/ } @REQUESTS ),
		'  ...and no request mentions a filtered id' );
}

# ---------------------------------------------------------------------------
# The error path carries the status (decisions §15.15 part 2)
# ---------------------------------------------------------------------------
#
# Every status that is not 2xx or 3xx reaches the ERROR callback with nothing
# populated on the SimpleAsyncHTTP object. Until 2026-09-22 _handle read only
# $http->code, so all of these classified as no_response and the whole lower
# half of classifyResponse was unreachable in production. The stub transport
# above now models that routing, so these assertions mean what they say.

diag('§15.15 part 2: every non-2xx status survives the error path');

{
	reset_state();

	my $result = run_sync( {
		code    => 500,
		headers => healthy_headers(),
		content => 'upstream exploded',
	} );

	ok( !$result->{ok}, 'a 5xx fails the sync' );
	is( $result->{error}, 'server_error',
		'  ...as server_error - transient, so the caller logs at warn' );
}

{
	reset_state();

	my $result = run_sync( {
		code    => 404,
		headers => healthy_headers(),
		content => '',
	} );

	is( $result->{error}, 'not_found', 'a 404 survives the error path as not_found' );
}

# The one thing that must STILL be no_response: a connection that produced no
# status at all. If this ever starts classifying as something else, the fix
# above has over-reached.
{
	reset_state();

	my $result = run_sync( { code => undef } );

	ok( !$result->{ok}, 'a connection that never answered fails the sync' );
	is( $result->{error}, 'no_response',
		'  ...as no_response, which now means only that' );
}

# The headers come across too, not just the status. A 429 whose headers say the
# budget is spent must be accounted for, or the back-off throttles on stale
# state - and a 429 is exactly when the headers matter most.
{
	reset_state();

	my $spent = {
		code    => 429,
		headers => {
			'X-Discogs-Ratelimit'           => 60,
			'X-Discogs-Ratelimit-Used'      => 60,
			'X-Discogs-Ratelimit-Remaining' => 0,
		},
		content => '',
	};

	my $result = run_sync(
		identity_response(),
		$spent,
		page_response( 5, 1, 1, 5 ),
	);

	ok( $result->{ok}, 'a 429 with spent-budget headers still recovers' );
	ok( scalar @TIMERS >= 1, '  ...having waited rather than hammered' );
	ok( ( grep { $_->{delay} && $_->{delay} > 0 } @TIMERS ),
		'  ...on a real delay taken from the error response, not a zero wait' );
}

# ---------------------------------------------------------------------------
# The rejection pause
# ---------------------------------------------------------------------------

diag('a rejected token pauses scan-triggered syncs until something changes');

{
	reset_state();
	Plugins::SqueezeWax::API::Async->clearTokenRejected;

	ok( !Plugins::SqueezeWax::API::Async->tokenRejected,
		'nothing is paused to begin with' );

	run_sync( { code => 401, headers => healthy_headers(), content => '' } );

	ok( Plugins::SqueezeWax::API::Async->tokenRejected,
		'a rejected token sets the pause' );

	ok( Plugins::SqueezeWax::API::Async->noteSkipped,
		'  ...and the first skip reports itself as the first' );
	ok( !Plugins::SqueezeWax::API::Async->noteSkipped,
		'  ...while later ones do not, so it is logged once' );
}

{
	reset_state();

	# A sync that completes proves the token works, whatever triggered it.
	run_sync(
		identity_response(),
		page_response( 5, 1, 1, 5 ),
	);

	ok( !Plugins::SqueezeWax::API::Async->tokenRejected,
		'a successful sync clears the pause' );
	ok( Plugins::SqueezeWax::API::Async->noteSkipped,
		'  ...and resets the log-once marker with it' );
}

{
	reset_state();
	Plugins::SqueezeWax::API::Async->clearTokenRejected;

	run_sync( { code => 401, headers => healthy_headers(), content => '' } );
	ok( Plugins::SqueezeWax::API::Async->tokenRejected, 'paused again' );

	# What Settings.pm calls when the token pref changes (§15.15 part 3).
	Plugins::SqueezeWax::API::Async->clearTokenRejected;

	ok( !Plugins::SqueezeWax::API::Async->tokenRejected,
		'  ...and a token change clears it' );
}

# A transient failure must NOT pause: the whole point of the distinction is
# that one of these is worth retrying and the other is not.
{
	reset_state();
	Plugins::SqueezeWax::API::Async->clearTokenRejected;

	run_sync( { code => undef } );

	ok( !Plugins::SqueezeWax::API::Async->tokenRejected,
		'a dropped connection does NOT pause scan-triggered syncs' );
}

{
	reset_state();
	Plugins::SqueezeWax::API::Async->clearTokenRejected;

	run_sync( { code => 500, headers => healthy_headers(), content => '' } );

	ok( !Plugins::SqueezeWax::API::Async->tokenRejected,
		'nor does a server error' );
}

# ---------------------------------------------------------------------------
# Pref writes: what, in what order (stub audit 2026-09-24, entry 2.1)
# ---------------------------------------------------------------------------
#
# The store now suppresses a no-op scalar write and dispatches setChange, as
# Slim/Utils/Prefs/Base.pm:91,94-97 do. Until 2026-09-24 it was a plain hash
# write, which is the gap that let the 0.0.0.7 regression through one file
# over: a pref write landing AFTER the thing it was meant to precede, and an
# onchange hook firing unmodelled.

diag('the single exit: which prefs are written, and when');

{
	reset_state();

	run_sync(
		identity_response(),
		page_response( 5, 1, 1, 5 ),
	);

	# §15.13 part 1: the pass runs before any pref is set, so a timestamp can
	# never claim ownership was derived when it was not.
	my ($passAt)  = grep { $WRITES[$_] eq '<pass>' }            0 .. $#WRITES;
	my ($syncAt)  = grep { $WRITES[$_] eq 'discogsLastSynced' } 0 .. $#WRITES;

	ok( defined $passAt, 'a successful sync runs the ownership pass' );
	ok( defined $syncAt, '  ...and writes discogsLastSynced' );
	ok( defined $passAt && defined $syncAt && $passAt < $syncAt,
		'  ...the pass FIRST, then the timestamp (§15.13 part 1)' );

	is_deeply(
		[ grep { $_ ne '<pass>' } @WRITES ],
		[qw(discogsLastSynced discogsLastSyncItems discogsLastSyncError)],
		'  ...and writes exactly those three prefs, in that order'
	);
}

{
	reset_state();
	$PREFS{discogsLastSynced}    = 1_700_000_000;
	$PREFS{discogsLastSyncItems} = 203;

	run_sync( { code => 401, headers => healthy_headers(), content => '' } );

	is_deeply( [ grep { $_ ne '<pass>' } @WRITES ], ['discogsLastSyncError'],
		'a failed sync writes ONLY the error' );
	ok( !( grep { $_ eq '<pass>' } @WRITES ),
		'  ...and never reaches the pass' );
	is( $PREFS{discogsLastSynced}, 1_700_000_000,
		'  ...leaving the previous figures exactly as they were' );
}

# A second identical failure must not re-write the error: Base.pm:94-97
# suppresses a scalar set that changes nothing, so an unchanged error is not an
# event and cannot re-trigger anything hung off it.
{
	reset_state();
	$PREFS{discogsLastSyncError} = 'unauthorized';

	run_sync( { code => 401, headers => healthy_headers(), content => '' } );

	is( scalar @WRITES, 0,
		'the same error twice is suppressed, not written again' );
}

# And an onchange hook on one of Async's own prefs fires when it writes - the
# mechanism that, hung off discogsToken, caused the 0.0.0.7 regression.
{
	reset_state();

	my @fired;
	$CHANGES{discogsLastSyncError} = sub { push @fired, $_[1] };

	run_sync( { code => 401, headers => healthy_headers(), content => '' } );

	is_deeply( \@fired, ['unauthorized'],
		'a setChange hook on a pref Async writes does fire, with the new value' );
}

done_testing();
