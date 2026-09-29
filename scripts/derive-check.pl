#!/usr/bin/env perl
#
# Offline exercise of Plugins::SqueezeWax::Derive - the master arm's backfill
# (build-order step 8c group A, decisions §15.22).
#
# WHAT THIS PROVES. Which releases a run selects and which it leaves alone; what
# each response outcome writes; that a run is bounded, yields to a scan, a sync
# and a spent budget, and re-arms only where work provably remains; that nothing
# Content-shaped reaches the database; and the join the whole step exists for -
# derive, load, node F, `version` - including the stale case that must NOT badge.
#
# WHAT IT CANNOT PROVE. Slim::Networking::SimpleAsyncHTTP and Slim::Utils::Timers
# are both stubbed, and the request stub is SYNCHRONOUS: a stubbed request calls
# its own callback before ->get returns. That is what makes the state machine
# testable in one process and it is exactly what production does not do. So this
# proves the sequence of requests, the writes and the state transitions, and
# nothing about whether the real Timers/SimpleAsyncHTTP interaction behaves as
# read from refs/. Same limitation, and the same reason, as scripts/sync-check.pl
# states for the collection sync; the plan's §6 hardware checks are where the real
# transport is exercised.
#
# The spacing timer fires synchronously so a whole slice runs inside one call to
# arm(). The RE-ARM timer deliberately does NOT fire - it is recorded instead -
# because firing it would start the next run inside the last one and a suite
# asserting "at most 30 requests per run" could never see a run end.
#
# Usage: scripts/derive-check.pl

use strict;
use warnings;

use constant SCANNER  => 0;
use constant PERFMON  => 0;
use constant DEBUGLOG => 1;
use constant INFOLOG  => 1;

use Config;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

# Host Test::More, before refs goes on @INC - see library-check.pl.
use Test::More;

our @REQUESTS;   # every stubbed request, oldest first, as { url, headers }
our @RESPONSES;  # canned responses, consumed in order
our @SPACING;    # every within-run spacing timer, as a delay in seconds
our @REARMS;     # every re-arm timer, as a delay in seconds - recorded, not fired
our @KILLS;      # every killTimers call
our @LOG;        # every info line
our @WARNINGS;   # every warn line
our %PREFS;
our $SCANNING = 0;
our $SYNCING  = 0;

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

	# Derive.pm's LMS dependencies. The transport and the timers are stubbed
	# because driving them is the point; the rest are the same incidental
	# file-scope dependencies every other suite here stubs.
	$INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = 1;
	$INC{'Slim/Utils/Log.pm'}                  = 1;
	$INC{'Slim/Utils/Prefs.pm'}                = 1;
	$INC{'Slim/Utils/PluginManager.pm'}        = 1;
	$INC{'Slim/Utils/Timers.pm'}               = 1;
	$INC{'Slim/Schema.pm'}                     = 1;
	$INC{'Slim/Music/Import.pm'}               = 1;
	$INC{'Slim/Music/Info.pm'}                 = 1;
	$INC{'Slim/Utils/OSDetect.pm'}             = 1;
	$INC{'Slim/Formats.pm'}                    = 1;

	no strict 'refs';
	no warnings 'redefine';

	*{'Slim::Utils::Log::logger'}         = sub { Test::StubLogger->new };
	*{'Slim::Utils::Log::addLogCategory'} = sub { Test::StubLogger->new };
	*{'Slim::Utils::Log::logError'}       = sub { };
	*{'Slim::Utils::Log::import'}         = sub {
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

	*{'Slim::Music::Import::stillScanning'} = sub { $main::SCANNING };

	# Two timers, two behaviours, and the split is deliberate - see the header.
	# \&_fire (the one-a-second spacing inside a run) fires immediately, so a
	# whole slice runs inside one call to arm(). \&_rearm (the next run, a minute
	# out) is recorded and never fired: firing it would start the next run inside
	# the last, and no assertion about a run's bounds could then hold.
	*{'Slim::Utils::Timers::setTimer'} = sub {
		my ( $obj, $when, $code, @args ) = @_;

		if ( $code == \&Plugins::SqueezeWax::Derive::_rearm ) {
			push @REARMS, $when - time();

			return;
		}

		push @SPACING, $when - time();

		$code->( $obj, @args );

		return;
	};

	*{'Slim::Utils::Timers::killTimers'} = sub {
		push @KILLS, { coderef => $_[1] };
		return 1;
	};

	*{'main::SCANNER'}   = sub () { 0 };
	# INFOLOG on, so every `main::INFOLOG && $log->is_info && $log->info(...)`
	# expression is EVALUATED rather than short-circuited away - those
	# expressions build strings from live counters (stub audit 2026-09-24).
	*{'main::INFOLOG'}   = sub () { 1 };
	*{'main::DEBUGLOG'}  = sub () { 0 };
	*{'main::ISWINDOWS'} = sub () { 0 };
}

{
	package Test::StubPrefs;
	sub new { bless {}, shift }
	sub get { return $main::PREFS{ $_[1] } }
	sub set { $main::PREFS{ $_[1] } = $_[2]; return 1 }
	sub init { 1 }
	sub migrate { 1 }
}

{
	package Test::StubLogger;
	sub new      { bless {}, shift }
	sub error    { shift; push @main::WARNINGS, "@_"; return }
	sub warn     { shift; push @main::WARNINGS, "@_"; return }
	sub info     { shift; push @main::LOG, "@_"; return }
	sub debug    { }
	sub is_info  { 1 }
	sub is_debug { 0 }
}

# Minimal stand-in for an HTTP::Headers object - only ->header(name) is reached,
# by API::_parseRateHeaders.
{
	package Test::StubHeaders;
	sub new { my $class = shift; bless { map { lc $_ } @_ }, $class }
	sub header { return $_[0]->{ lc $_[1] } }
}

# The stub transport, modelled on the real thing rather than simplified, for the
# reason sync-check.pl records: Slim/Networking/Async/HTTP.pm:434-436 routes EVERY
# status that is not 2xx or 3xx to _http_error, which reaches onError, and onError
# sets neither code nor headers on the SimpleAsyncHTTP object while passing the
# HTTP::Response as its third argument (SimpleAsyncHTTP.pm:76-101, :96). A stub
# that called the success callback with a code set would make Derive's 404
# handling - the whole of §15.21's "404 is an ordinary outcome" - look reachable
# while being unreachable in production.
{
	package Slim::Networking::SimpleAsyncHTTP;

	sub new {
		my ( $class, $cb, $ecb, $args ) = @_;
		return bless { cb => $cb, ecb => $ecb, args => $args }, $class;
	}

	sub get {
		my ( $self, $url, @headers ) = @_;

		push @REQUESTS, { url => $url, headers => \@headers };

		my $canned = shift @RESPONSES
			or die "stub transport: no canned response left for $url\n";

		# A connection that never produced a status at all: no response object
		# either. The only thing that should classify as no_response.
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

use DBI;
use Digest::MD5 qw(md5_hex);
use JSON::XS qw(encode_json);

# Derive.pm has real `use Plugins::SqueezeWax::*` lines, so like match-check.pl it
# needs the Plugins/SqueezeWax layout LMS resolves against rather than a
# by-file-path require. Build it, the same way syntax-check.sh does.
my $incdir;

BEGIN {
	$incdir = tempdir( CLEANUP => 1 );
	mkdir "$incdir/Plugins";
	symlink "$Bin/../SqueezeWax", "$incdir/Plugins/SqueezeWax"
		or die "could not link the plugin into $incdir: $!\n";
	unshift @INC, $incdir;
}

# API::Async is stubbed rather than loaded: the only thing Derive asks it is
# whether a sync is in flight, and loading it would drag in a second copy of the
# transport stubs for no assertion's benefit.
BEGIN {
	$INC{'Plugins/SqueezeWax/API/Async.pm'} = 1;
	no strict 'refs';
	*{'Plugins::SqueezeWax::API::Async::isRunning'} = sub { $main::SYNCING };
}

require Plugins::SqueezeWax::Schema;
require Plugins::SqueezeWax::Match;
require Plugins::SqueezeWax::Ownership;
require Plugins::SqueezeWax::Derive;

my $D   = 'Plugins::SqueezeWax::Derive';
my $O   = 'Plugins::SqueezeWax::Ownership';
my $API = 'Plugins::SqueezeWax::API';

my $dir = tempdir( CLEANUP => 1 );
my $dbh = DBI->connect( "dbi:SQLite:dbname=$dir/library.db", '', '', {
	RaiseError => 1, PrintError => 0, AutoCommit => 1,
} );
$dbh->do("ATTACH '$dir/squeezewax.db' AS squeezewax");

{
	no warnings 'once', 'redefine';

	*Slim::Schema::dbh         = sub { $dbh };
	*Slim::Schema::forceCommit = sub { 1 };

	# The suite migrates directly rather than through postDBConnect, so the
	# readiness flag was never set and Match::_writeOk would refuse everything.
	*Plugins::SqueezeWax::Schema::isReady = sub { 1 };

	# §15.7's label, read once per ownership pass (Slim/Music/Info.pm:1540).
	*Slim::Music::Info::variousArtistString = sub { 'Various Artists' };
}

Plugins::SqueezeWax::Schema->_migrate($dbh);

# Only the columns Library reads, for the join test at the end - the ownership
# pass walks the library, so it needs one.
$dbh->do(q{
	CREATE TABLE tracks (
		id INTEGER PRIMARY KEY, album INT, urlmd5 TEXT, url TEXT,
		timestamp INT, disc INT, tracknum INT, remote INT, audio INT,
		content_type TEXT
	)
});
$dbh->do('CREATE TABLE albums (id INTEGER PRIMARY KEY, title BLOB, contributor INT)');
$dbh->do('CREATE TABLE contributors (id INTEGER PRIMARY KEY, name BLOB)');
$dbh->do('CREATE TABLE contributor_album (role INT, contributor INT, album INT)');

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

my $nextTrack = 0;

# One album, with its album_key computed the way Library::_finish computes it.
sub album {
	my ( $id, $title, $artist ) = @_;

	$nextTrack++;
	my $url = "file:///a$id-t1";
	my $md5 = md5_hex($url);

	$dbh->do( 'INSERT INTO tracks VALUES (?,?,?,?,?,?,?,?,?,?)', undef,
		$nextTrack, $id, $md5, $url, 100, 1, 1, 0, 1, 'flc' );
	$dbh->do( 'INSERT INTO albums (id, title) VALUES (?,?)', undef, $id, $title );

	if ( defined $artist ) {
		$dbh->do( 'INSERT INTO contributors (id, name) VALUES (?,?)', undef, $id, $artist );
		$dbh->do( 'INSERT INTO contributor_album (role, contributor, album) VALUES (5,?,?)',
			undef, $id, $id );
	}

	return md5_hex($md5);
}

sub matchRow {
	my (%col) = @_;

	my @names = sort keys %col;

	$dbh->do(
		'INSERT INTO squeezewax.discogs_match (' . join( ',', @names ) . ') VALUES ('
			. join( ',', ('?') x @names ) . ')',
		undef, map { $col{$_} } @names
	);

	return;
}

sub rowFor {
	my $key = shift;

	return $dbh->selectrow_hashref(
		'SELECT * FROM squeezewax.discogs_match WHERE album_key = ?', undef, $key );
}

sub allRows {
	return $dbh->selectall_arrayref(
		'SELECT * FROM squeezewax.discogs_match ORDER BY album_key', { Slice => {} } );
}

sub wipe {
	$dbh->do('DELETE FROM squeezewax.discogs_match');

	return;
}

sub reset_state {
	@REQUESTS  = ();
	@RESPONSES = ();
	@SPACING   = ();
	@REARMS    = ();
	@KILLS     = ();
	@LOG       = ();
	@WARNINGS  = ();
	$SCANNING  = 0;
	$SYNCING   = 0;
	%PREFS     = ( discogsToken => 'token-abc' );

	# The rate state is API.pm's and outlives a run by design (§15.22), so a
	# spend in one block must not leak into the next.
	$API->_resetRate;

	$D->abort;

	return;
}

sub healthy_headers {
	return {
		'X-Discogs-Ratelimit'           => 60,
		'X-Discogs-Ratelimit-Used'      => 1,
		'X-Discogs-Ratelimit-Remaining' => 59,
	};
}

# A 200 carrying a release whose master is $master, plus every OTHER field a real
# /releases/{id} response carries. The extra fields are the point: §9.5 forbids
# storing them, and a suite whose fixture held only master_id could not tell a
# compliant writer from one that stored the lot.
sub release_response {
	my (%opt) = @_;

	my %body = (
		id                => $opt{id} || 1,
		title             => 'Gling-Glo',
		artists           => [ { name => 'Bjork Gudmundsdottir', id => 517951 } ],
		artists_sort      => 'Bjork Gudmundsdottir',
		year              => 1990,
		country           => 'Iceland',
		notes             => 'A long free-text note that must never reach the database.',
		labels            => [ { name => 'Smekkleysa', catno => 'SM33' } ],
		formats           => [ { name => 'Vinyl', descriptions => ['LP'] } ],
		tracklist         => [
			map { { position => $_, title => "Track $_", duration => '3:00' } } 1 .. 12
		],
		num_for_sale      => 4,
		lowest_price      => 12.34,
	);

	$body{master_id}  = $opt{master} if exists $opt{master};
	$body{master_url} = 'https://api.discogs.com/masters/' . ( $opt{master} || 0 )
		if exists $opt{master};

	return {
		code    => 200,
		headers => $opt{headers} || healthy_headers(),
		content => encode_json( \%body ),
	};
}

sub error_response {
	my ( $code, %opt ) = @_;

	return {
		code    => $code,
		headers => $opt{headers} || healthy_headers(),
		content => $opt{content} // '',
	};
}

# Which release each request asked about, in order.
sub asked {
	return map { $_->{url} =~ m{/releases/(\d+)} ? $1 : $_->{url} } @REQUESTS;
}

# ---------------------------------------------------------------------------
# §3.1 Selection
# ---------------------------------------------------------------------------

diag('selection: what a run picks up, and what it leaves alone');

my $K1 = 'a' x 32;
my $K2 = 'b' x 32;
my $K3 = 'c' x 32;
my $K4 = 'd' x 32;

{
	reset_state();
	wipe();

	# Nothing identified at all.
	matchRow( album_key => $K1, ownership => 'exact' );

	is( $D->arm, 0, 'a library with no identified release starts no run' );
	is( scalar @REQUESTS, 0, '  ...and issues no request' );
	ok( ( grep { /nothing to derive/ } @LOG ), '  ...and says so' );
}

{
	reset_state();
	wipe();

	# A SETTLED library: every identified release already has an answer, and one
	# of the answers is "there is no master". THE NORMAL CASE, and the reason
	# this job costs nothing on a library that has not changed.
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111,
		derived_master_id => 9001, derived_from_release_id => 111, derived_at => 500 );
	matchRow( album_key => $K2, match_tier => 'strict', discogs_release_id => 222,
		derived_master_id => undef, derived_from_release_id => 222, derived_at => 500 );

	is( $D->arm, 0, 'a settled library starts no run' );
	is( scalar @REQUESTS, 0, '  ...and issues no request at all' );

	# The one that matters most on the reference library, where 29 of 328
	# population releases have no master and 3 have been deleted outright.
	is( scalar( grep { m{/releases/222} } map { $_->{url} } @REQUESTS ), 0,
		'a release recorded as having NO master is never asked about again (§15.22)' );
}

{
	reset_state();
	wipe();

	# The stale case: the tags now name a different release from the one the
	# master was derived from.
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 333,
		derived_master_id => 9001, derived_from_release_id => 111, derived_at => 500 );

	@RESPONSES = ( release_response( id => 333, master => 7777 ) );

	is( $D->arm, 1, 'a row whose release id has changed re-selects' );
	is_deeply( [ asked() ], ['333'], '  ...and asks about the release the tags name NOW' );

	my $row = rowFor($K1);
	is( $row->{derived_master_id}, 7777, '  ...and the derivation is replaced' );
	is( $row->{derived_from_release_id}, 333, '  ...with the release it came from' );
}

{
	reset_state();
	wipe();

	# One release, several albums - a 2-LP set filed as two LMS albums is the
	# measured case. One fetch settles both.
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 444 );
	matchRow( album_key => $K2, match_tier => 'strict', discogs_release_id => 444 );

	@RESPONSES = ( release_response( id => 444, master => 1884 ) );

	$D->arm;

	is( scalar @REQUESTS, 1, 'two albums naming one release cost ONE request' );
	is( rowFor($K1)->{derived_master_id}, 1884, '  ...and both rows are written' );
	is( rowFor($K2)->{derived_master_id}, 1884, '  ...both of them' );
}

{
	reset_state();
	wipe();

	# A fresh conflict row has a NULL release id (§3a), so there is nothing to
	# ask about - which is the importer's half of step 8c doing its job before
	# this one gets a chance to spend a request on a contested tag.
	matchRow( album_key => $K1, match_tier => 'strict', state => 'candidate',
		review_reason => 'conflict' );

	is( $D->arm, 0, 'a fresh conflict row has no release id and is not selected' );
	is( scalar @REQUESTS, 0, '  ...so no request is spent on a contested tag' );
}

{
	reset_state();
	wipe();

	# Selection is by release id, so a manual link is derived too: node F is the
	# same node for both, and a manual row is the one case the user cared enough
	# to set by hand.
	matchRow( album_key => $K1, match_tier => 'manual', discogs_release_id => 555 );

	@RESPONSES = ( release_response( id => 555, master => 2002 ) );

	$D->arm;

	is( rowFor($K1)->{derived_master_id}, 2002, 'a manual row is derived too' );
}

# ---------------------------------------------------------------------------
# §3.2 Outcomes - each writes what §1.2's table says, and nothing else
# ---------------------------------------------------------------------------

diag('outcomes: 200 with a master, 200 without, 0, 404, 401, 500, no response');

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );

	@RESPONSES = ( release_response( id => 111, master => 1884 ) );

	$D->arm;

	my $row = rowFor($K1);
	is( $row->{derived_master_id}, 1884, '200 with a master writes it' );
	is( $row->{derived_from_release_id}, 111, '  ...with the release it came from' );
	ok( $row->{derived_at} > 0, '  ...and a timestamp' );
	is( $row->{discogs_master_id}, undef,
		'  ...and NEVER discogs_master_id, which stays tag-only (§15.22)' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );

	# master_id absent from the response entirely.
	@RESPONSES = ( release_response( id => 111 ) );

	$D->arm;

	my $row = rowFor($K1);
	is( $row->{derived_master_id}, undef, '200 with no master_id writes a NULL master' );
	is( $row->{derived_from_release_id}, 111,
		'  ...but DOES write the release id - "looked, and there is nothing there"' );
	ok( $row->{derived_at} > 0, '  ...and a timestamp' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );

	# master_id 0, Discogs' own sentinel for "no master".
	@RESPONSES = ( release_response( id => 111, master => 0 ) );

	$D->arm;

	my $row = rowFor($K1);
	is( $row->{derived_master_id}, undef,
		'master_id 0 is a sentinel, not a master - it is stored as NULL' );
	is( $row->{derived_from_release_id}, 111, '  ...and the release id is still written' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 1312977 );

	# 404, on one of the three release ids the measurement found deleted.
	@RESPONSES = ( error_response(404) );

	$D->arm;

	my $row = rowFor($K1);
	is( $row->{derived_from_release_id}, 1312977,
		'404 records "looked, and there is no master" (§15.21)' );
	is( $row->{derived_master_id}, undef, '  ...with a NULL master' );

	ok( ( grep { /no longer on Discogs/ } @LOG ),
		'  ...logged at INFO: a deleted release is an ordinary outcome' );
	is( scalar @WARNINGS, 0, '  ...and NOT at warn or error' );

	# And it is never asked again. This is the assertion that keeps 3 albums from
	# costing 3 requests on every run for the life of the library.
	reset_state();
	is( $D->arm, 0, 'a 404 is not retried on the next run' );
	is( scalar @REQUESTS, 0, '  ...which is what makes the run cost nothing' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );

	@RESPONSES = ( error_response(401) );

	$D->arm;

	my $row = rowFor($K1);
	is( $row->{derived_from_release_id}, undef,
		'401 records nothing - a rejected token is not a conclusion about a release' );

	is( scalar @WARNINGS, 0,
		'  ...and says nothing: a rejected token is the sync\'s to report (§15.15 part 2)' );
	ok( ( grep { /Discogs rejected the token/ } @LOG ), '  ...beyond one info line' );

	is( scalar @REARMS, 0,
		'  ...and the run is NOT re-armed: a minute changes nothing about a bad token' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );
	matchRow( album_key => $K2, match_tier => 'strict', discogs_release_id => 222 );

	@RESPONSES = ( error_response(500), release_response( id => 222, master => 5 ) );

	$D->arm;

	is( scalar @REQUESTS, 1, '500 stops the run rather than carrying on' );
	is( rowFor($K1)->{derived_from_release_id}, undef,
		'  ...leaving the row untouched, so the next run retries it' );
	is( rowFor($K2)->{derived_from_release_id}, undef,
		'  ...and the release it never reached untouched too' );
	ok( ( grep { /could not derive the master of release 111: server_error/ } @WARNINGS ),
		'  ...and warns, naming the release and the error' );
	is( scalar @REARMS, 0, '  ...and does not re-arm on an error' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );

	# A connection that never produced a status: no code and no response object.
	@RESPONSES = ( { code => undef } );

	$D->arm;

	is( rowFor($K1)->{derived_from_release_id}, undef,
		'a dropped connection records nothing' );
	ok( ( grep { /could not derive the master of release 111: no_response/ } @WARNINGS ),
		'  ...and is distinguishable from a 404 in the log' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );

	# A 200 whose body will not parse. classifyResponse's malformed_json.
	@RESPONSES = ( { code => 200, headers => healthy_headers(), content => '{not json' } );

	$D->arm;

	is( rowFor($K1)->{derived_from_release_id}, undef,
		'a body that will not parse records nothing rather than a NULL master' );
}

# ---------------------------------------------------------------------------
# §3.5 Nothing Content-shaped is written (§9.5)
# ---------------------------------------------------------------------------
#
# §9.5's rule is "store conclusions, not Content", and the release response
# carries a title, credited artists, a 12-track tracklist, notes, labels, formats
# and a price. This is that rule made a test rather than a promise: the fixture
# holds every one of those fields, and afterwards the ONLY difference in the row
# is the three integer columns.

diag('§9.5: three columns, and not one byte of Content');

{
	reset_state();
	wipe();

	matchRow( album_key => $K1, lms_album_id => 7, match_tier => 'strict',
		state => 'candidate', discogs_release_id => 111, discogs_master_id => undef,
		matched_at => 900, source_timestamp => 800, snapshot_album_title => 'Gling-Glo',
		snapshot_artist => 'Bjork', snapshot_track_count => 12, ownership => 'absent',
		review_reason => undef );

	my $before = rowFor($K1);

	@RESPONSES = ( release_response( id => 111, master => 1884 ) );

	$D->arm;

	my $after = rowFor($K1);

	my @changed = sort grep {
		( defined $before->{$_} ? $before->{$_} : "\0" )
			ne ( defined $after->{$_} ? $after->{$_} : "\0" )
	} keys %$after;

	is_deeply( \@changed,
		[qw(derived_at derived_from_release_id derived_master_id)],
		'exactly three columns change, and they are the three (§15.4 still holds)' );

	# Named individually as well, because is_deeply on a sorted list would also
	# pass if two of them were swapped with two others of the same names.
	for my $c (qw(ownership state match_tier review_reason discogs_master_id
	              discogs_release_id snapshot_album_title snapshot_artist
	              snapshot_track_count source_timestamp matched_at lms_album_id)) {
		is( $after->{$c}, $before->{$c}, "  ...$c is untouched" );
	}

	# Every string in the fixture, against every column of the row. Not "the
	# columns we remembered to check" - all of them, which is what makes this an
	# assertion about the writer rather than about this test's imagination.
	my $dump = join "\x00", map { defined $_ ? $_ : '' } values %$after;

	for my $content ( 'Gling', 'Smekkleysa', 'Track 1', 'free-text note',
		'Vinyl', 'api.discogs.com', '12.34', 'Iceland' ) {
		# snapshot_album_title legitimately holds 'Gling-Glo', which the fixture
		# also uses as the Discogs title; the loop above already proved it was not
		# rewritten, so only the columns the job writes are searched here.
		my $written = join "\x00", map { defined $_ ? $_ : '' }
			@{$after}{qw(derived_master_id derived_from_release_id derived_at)};

		unlike( $written, qr/\Q$content\E/,
			"no Content reaches the derived columns: '$content'" );
	}

	# The three hold integers and nothing else. The hardware check dumps these
	# columns and asks the same question of the real database (plan §6 check 6).
	for my $c (qw(derived_master_id derived_from_release_id derived_at)) {
		like( $after->{$c}, qr/^\d+$/, "$c holds an integer" );
	}

	# And the table §9.5 forbids writing is still empty. It has no writer, here
	# or anywhere in v1, and "the table exists" and "the table is written" are
	# different statements.
	my ($cached) = $dbh->selectrow_array('SELECT COUNT(*) FROM squeezewax.discogs_release_cache');
	is( $cached, 0, 'discogs_release_cache is still unwritten (§9.5)' );
}

# ---------------------------------------------------------------------------
# §3.3 Pacing and yielding
# ---------------------------------------------------------------------------

diag('pacing: bounded, spaced, yielding, and re-armed only where work remains');

# The policy, directly. A pure function over the four conditions, for the reason
# Match::_writeRefusal is one: the conditions are process state a suite would have
# to fake, while the ORDER between them is what has to be right.
{
	my $why = \&Plugins::SqueezeWax::Derive::_yieldReason;

	is( $why->( 0, 0, 0, 0 ), undef, 'nothing in the way: no reason to yield' );
	is( $why->( 0, 0, 0, 29 ), undef, '  ...and 29 requests is still under the cap' );

	like( $why->( 0, 0, 0, 30 ), qr/had its share/, '30 requests is the cap' );
	like( $why->( 0, 0, 0, 31 ), qr/had its share/, '  ...and over it' );

	like( $why->( 0, 1, 0, 0 ), qr/sync is running/, 'a running sync yields (§15.22 ruling 3)' );
	like( $why->( 0, 0, 1, 0 ), qr/budget is spent/, 'a spent budget yields' );
	like( $why->( 1, 0, 0, 0 ), qr/scan is running/, 'a running scan yields' );

	# The ORDER, which is the only thing in here that could be wrong quietly. A
	# scan means the write at the end of the request would be refused anyway, so
	# paying Discogs for an answer we must throw away is the outcome worth
	# ordering against.
	like( $why->( 1, 1, 1, 99 ), qr/scan is running/,
		'a scan is reported first: it is the reason not to spend the request at all' );
	like( $why->( 0, 1, 1, 99 ), qr/sync is running/,
		'  ...then the sync, whose budget this would be taking' );
}

{
	reset_state();
	wipe();

	# 35 releases, one run. PER_RUN is 30.
	for my $n ( 1 .. 35 ) {
		matchRow( album_key => sprintf( '%032d', $n ), match_tier => 'strict',
			discogs_release_id => 1000 + $n );
		push @RESPONSES, release_response( id => 1000 + $n, master => 9000 + $n );
	}

	$D->arm;

	is( scalar @REQUESTS, 30, 'a run issues at most PER_RUN requests' );
	is( scalar @SPACING, 29,
		'  ...spaced by a timer between each pair, never a sleep (LMS is single-threaded)' );
	ok( !( grep { $_ != 1 } @SPACING ), '  ...one second apart' );

	is( scalar @REARMS, 1, '  ...and is re-armed, because work provably remains' );
	is( $REARMS[0], 60, '  ...a minute later' );
	ok( ( grep { /resuming in 60s/ } @LOG ), '  ...and says so' );

	# killTimers before setTimer, every time: Timers keys pending timers by
	# (coderef, obj) and setTimer APPENDS, so arming without killing is how a
	# self-rescheduling timer silently doubles its own frequency.
	ok( ( grep { $_->{coderef} == \&Plugins::SqueezeWax::Derive::_rearm } @KILLS ),
		'  ...having killed any re-arm already pending first' );

	my ($done) = $dbh->selectrow_array(
		'SELECT COUNT(*) FROM squeezewax.discogs_match WHERE derived_from_release_id IS NOT NULL' );
	is( $done, 30, '30 of the 35 releases are settled' );

	# The next run picks up where this one stopped, and takes the remaining five.
	reset_state();
	push @RESPONSES, release_response( id => 1000 + $_, master => 9000 + $_ ) for 31 .. 35;

	$D->arm;

	is( scalar @REQUESTS, 5, 'the next run takes exactly the releases left over' );
	is_deeply( [ asked() ], [ map { 1000 + $_ } 31 .. 35 ],
		'  ...in order, resuming rather than restarting' );
	is( scalar @REARMS, 0, '  ...and does not re-arm once there is nothing left' );
	ok( ( grep { /every identified release now has an answer/ } @LOG ),
		'  ...saying the work is done' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );

	$SYNCING = 1;

	is( $D->arm, 1, 'a run that starts while a sync is in flight still starts' );
	is( scalar @REQUESTS, 0, '  ...but issues no request: it yields to the sync' );
	is( scalar @REARMS, 1, '  ...and re-arms, because the sync will end' );
	ok( ( grep { /a collection sync is running/ } @LOG ), '  ...saying why' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );
	matchRow( album_key => $K2, match_tier => 'strict', discogs_release_id => 222 );

	# A sync starts between the first request and the second.
	@RESPONSES = ( release_response( id => 111, master => 1 ) );

	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::API::Async::isRunning = sub {
		return scalar( @main::REQUESTS ) >= 1 ? 1 : 0;
	};

	$D->arm;

	is( scalar @REQUESTS, 1, 'a sync starting mid-run stops the run after the request in flight' );
	is( rowFor($K1)->{derived_master_id}, 1, '  ...keeping the answer it already had' );
	is( rowFor($K2)->{derived_from_release_id}, undef, '  ...and leaving the rest for later' );
	is( scalar @REARMS, 1, '  ...re-armed' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );

	# The shared budget, spent by someone else - a collection sync, in
	# production. Standing in for it with the accounting call the sync makes is
	# branching on data rather than on which module made it (§15.22).
	$API->noteResponse( { limit => 60, used => 60, remaining => 0 }, time() );

	$D->arm;

	is( scalar @REQUESTS, 0, 'a budget spent by the sync stops the run before it asks' );
	is( scalar @REARMS, 1, '  ...and re-arms, because the window will pass' );
	ok( ( grep { /the rate budget is spent/ } @LOG ), '  ...saying why' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );
	matchRow( album_key => $K2, match_tier => 'strict', discogs_release_id => 222 );

	# The job's own spend is accounted against the same budget, so a response
	# that reports the window empty stops this run too.
	@RESPONSES = ( release_response( id => 111, master => 1,
		headers => {
			'X-Discogs-Ratelimit'           => 60,
			'X-Discogs-Ratelimit-Used'      => 60,
			'X-Discogs-Ratelimit-Remaining' => 0,
		} ) );

	$D->arm;

	is( scalar @REQUESTS, 1, 'the job accounts for its own requests against the shared budget' );
	is( $API->rateWait, 60,
		'  ...and leaves the spent window where the collection sync will see it' );
	is( scalar @REARMS, 1, '  ...re-armed' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );

	$SCANNING = 1;

	is( $D->arm, 1, 'a run armed during a scan starts' );
	is( scalar @REQUESTS, 0, '  ...and issues nothing: the write would be refused anyway' );
	is( scalar @REARMS, 0,
		'  ...and does NOT re-arm - the scan ends in a rescan-done, which brings a sync' );
	ok( ( grep { /a scan is running/ } @LOG ), '  ...saying why' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );
	matchRow( album_key => $K2, match_tier => 'strict', discogs_release_id => 222 );

	# A scan that starts between the request and the write. The answer is dropped
	# and the run ends - without this it would spend all 30 requests re-asking the
	# one question whose answer it cannot keep, because nothing was recorded.
	@RESPONSES = ( release_response( id => 111, master => 1 ) );

	# Refused only AFTER the first request has gone out - _yieldNow consults the
	# same predicate before one, so a flat 0 would stop the run before it asked
	# and this branch would never run.
	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Match::_writeOk = sub {
		return scalar( @main::REQUESTS ) >= 1 ? 0 : 1;
	};

	$D->arm;

	is( scalar @REQUESTS, 1,
		'a write refused mid-run ends the run rather than re-asking 29 more times' );
	is( rowFor($K1)->{derived_from_release_id}, undef, '  ...having written nothing' );
	is( scalar @REARMS, 0, '  ...and not re-armed' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );

	delete $PREFS{discogsToken};

	is( $D->arm, 0, 'a server with no token starts no run' );
	is( scalar @REQUESTS, 0, '  ...and issues nothing' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );
	matchRow( album_key => $K2, match_tier => 'strict', discogs_release_id => 222 );

	# One run at a time. The second trigger is not an error - it means the
	# trigger did its job and something else got there first.
	@RESPONSES = ( release_response( id => 111, master => 1 ) );

	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Derive::isRunning = sub { 1 };

	is( $D->arm, 0, 'a second trigger while a run is in flight starts no second run' );
	is( scalar @REQUESTS, 0, '  ...and issues nothing' );
	ok( ( grep { /already in flight/ } @LOG ), '  ...saying so at info, not at warn' );
}

{
	reset_state();
	wipe();
	matchRow( album_key => $K1, match_tier => 'strict', discogs_release_id => 111 );

	@RESPONSES = ( release_response( id => 111, master => 1 ) );

	$D->arm;

	# The token goes into the Authorization header and nowhere else - the request
	# is built by API->buildRequest, so this is one assertion that the job is not
	# constructing requests of its own.
	my %headers = @{ $REQUESTS[0]->{headers} };
	is( $headers{Authorization}, 'Discogs token=token-abc',
		'the request carries the token API.pm puts on it' );
	like( $headers{'User-Agent'}, qr{^SqueezeWax/\S+ \+https://},
		'  ...and §9.3\'s User-Agent, which is the difference between working and silently blocked' );
	like( $REQUESTS[0]->{url}, qr{^https://api\.discogs\.com/releases/111$},
		'  ...at /releases/{id}, with no query string' );
}

# ---------------------------------------------------------------------------
# §3.4 The join: derive -> _loadRows -> node F -> version
# ---------------------------------------------------------------------------
#
# This is what the whole step is for. Everything above could pass with node F
# still never firing, which is exactly the situation §15.19 describes: a route
# that has never once run is not a design, it is an intention.
#
# The shape is the measured one. The owner's collection holds release 28711 of
# master 1884; the ripped files are tagged release 1990647, which the collection
# does NOT hold. Before step 8c that album read `absent`, with a review-queue item
# asking the user to adjudicate a question their own collection already answered.

diag('§15.19\'s Gling-Glo: derive the master, and node F finally fires');

my $GLING = album( 1, 'Gling-Glo', 'Bjork' );
my $OTHER = album( 2, 'Something Else', 'Nobody' );

# One collection entry: a pressing the user owns, of the master the tagged
# release shares. Its TITLE deliberately does not match the album, so the title
# route cannot rescue it and node F is the only road to a badge.
my @collection = ( {
	instance_id => 1001,
	id          => 28711,
	master_id   => 1884,
	title       => 'Gling-Glo (Original Pressing)',
	artists     => ['Bjork Gudmundsdottir'],
} );

{
	reset_state();
	wipe();

	matchRow( album_key => $GLING, lms_album_id => 1, match_tier => 'strict',
		state => 'candidate', discogs_release_id => 1990647, snapshot_track_count => 1 );

	# Before: the defect itself, so the assertion below is a change and not a
	# coincidence.
	is( $O->apply( \@collection ), 'ok', 'the pass runs before anything is derived' );
	is( rowFor($GLING)->{ownership}, 'absent',
		'BEFORE: an album the owner owns reads absent - §15.19\'s false not-owned' );

	@RESPONSES = ( release_response( id => 1990647, master => 1884 ) );

	$D->arm;

	is( rowFor($GLING)->{derived_master_id}, 1884, 'the master is derived' );

	is( $O->apply( \@collection ), 'ok', 'the pass runs again over the same collection' );

	is( rowFor($GLING)->{ownership}, 'version',
		'AFTER: node F fires from the derived master and the album badges (§15.22)' );
	is( rowFor($GLING)->{state}, 'candidate',
		'  ...as a candidate: node F is a different pressing, not this one (design §3)' );
	is( rowFor($GLING)->{discogs_master_id}, undef,
		'  ...and the tag-derived column is still NULL - the badge came from the derived one' );
}

{
	reset_state();
	wipe();

	# THE STALENESS CASE, and the one that would be silent. The album was
	# retagged after the master was derived, so the derivation describes a
	# release these files no longer name. Trusting it would badge this album from
	# the master of a record it used to be - a wrong badge, with nothing in any
	# log to say so.
	matchRow( album_key => $GLING, lms_album_id => 1, match_tier => 'strict',
		state => 'candidate', discogs_release_id => 1990647, snapshot_track_count => 1 );

	@RESPONSES = ( release_response( id => 1990647, master => 1884 ) );
	$D->arm;
	is( rowFor($GLING)->{derived_from_release_id}, 1990647, 'the master is derived, and from where' );

	# The user retags the album: the release id changes, the derivation does not.
	$dbh->do( 'UPDATE squeezewax.discogs_match SET discogs_release_id = ? WHERE album_key = ?',
		undef, 9999999, $GLING );

	is( $O->apply( \@collection ), 'ok', 'the pass runs over the retagged album' );

	is( rowFor($GLING)->{ownership}, 'absent',
		'a STALE derivation does not badge: it describes a release these tags no longer name' );

	# And the next run re-derives it rather than leaving it stale forever.
	reset_state();
	@RESPONSES = ( error_response(404) );

	is( $D->arm, 1, 'the stale row re-selects on the next run' );
	is_deeply( [ asked() ], ['9999999'], '  ...asking about the release the tags name now' );
	is( rowFor($GLING)->{derived_master_id}, undef,
		'  ...and the stale master is replaced, not kept beside the new answer' );
	is( rowFor($GLING)->{derived_from_release_id}, 9999999,
		'  ...so the pair describes one release, which is what makes the test meaningful' );
}

{
	reset_state();
	wipe();

	# A tag-derived master WINS. The tag names a master the user does not own;
	# the derived one names a master they do. If the derived value leaked past the
	# tag this would badge - so 'absent' here is the assertion that a tag is the
	# user's assertion and ours never overrides it (§15.22).
	matchRow( album_key => $GLING, lms_album_id => 1, match_tier => 'strict',
		state => 'candidate', discogs_release_id => 1990647,
		discogs_master_id => 7777, derived_master_id => 1884,
		derived_from_release_id => 1990647, derived_at => 500,
		snapshot_track_count => 1 );

	$O->apply( \@collection );

	is( rowFor($GLING)->{ownership}, 'absent',
		'a tag-derived master wins, even where the derived one would have badged' );

	# The control, so the assertion above is about precedence and not about
	# something else quietly failing.
	$dbh->do( 'UPDATE squeezewax.discogs_match SET discogs_master_id = NULL WHERE album_key = ?',
		undef, $GLING );

	$O->apply( \@collection );

	is( rowFor($GLING)->{ownership}, 'version',
		'  ...and with the tag gone, the derived master badges it' );
}

{
	reset_state();
	wipe();

	# The two sentinels on the DERIVED side. A derived master of 0 must behave as
	# no master, exactly as the tag-derived one does - and an owned entry with no
	# master must not collide with it on masters{0}.
	matchRow( album_key => $GLING, lms_album_id => 1, match_tier => 'strict',
		state => 'candidate', discogs_release_id => 1990647,
		derived_master_id => 0, derived_from_release_id => 1990647, derived_at => 500,
		snapshot_track_count => 1 );

	$O->apply( [ { instance_id => 1, id => 28711, master_id => 0,
		title => 'Masterless', artists => ['Nobody'] } ] );

	is( rowFor($GLING)->{ownership}, 'absent',
		'a derived master of 0 is not a master, and does not collide on masters{0}' );

	$dbh->do( 'UPDATE squeezewax.discogs_match SET derived_master_id = NULL WHERE album_key = ?',
		undef, $GLING );

	$O->apply( \@collection );

	is( rowFor($GLING)->{ownership}, 'absent',
		'  ...and a NULL derived master with the release id set behaves as no master too' );
}

{
	reset_state();
	wipe();

	# §15.4, at the level that matters: the PASS never writes the derived
	# columns. It derives ownership and a review reason, and _write's column
	# table does not know these three exist.
	matchRow( album_key => $GLING, lms_album_id => 1, match_tier => 'strict',
		state => 'candidate', discogs_release_id => 1990647,
		derived_master_id => 1884, derived_from_release_id => 1990647, derived_at => 500,
		snapshot_track_count => 1 );

	$O->apply( \@collection );

	my $row = rowFor($GLING);
	is( $row->{ownership}, 'version', 'the pass badges from the derived master' );
	is( $row->{derived_master_id}, 1884, '  ...and does not rewrite it' );
	is( $row->{derived_from_release_id}, 1990647, '  ...nor the release it came from' );
	is( $row->{derived_at}, 500,
		'  ...nor the timestamp: the pass is not a writer of these columns (§15.4)' );

	# Determinism (§13.2): a second pass over the same inputs changes nothing,
	# derived columns included.
	my $snapshot = allRows();
	$O->apply( \@collection );
	is_deeply( allRows(), $snapshot, 'a second pass changes nothing at all' );
}

done_testing();
