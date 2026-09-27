#!/usr/bin/env perl
#
# Offline exercise of the scan-time sync (build-order step 8b, decisions
# §15.18): API/Sync.pm's blocking fetch, ScanSync.pm's importer, and the
# second registration in Importer.pm.
#
# ScanSync runs against a real scratch database with AutoCommit OFF, set after
# connect exactly as scanner.pl:295 sets it, and the real Schema, Library,
# Match and Ownership modules - so its commits, the pass's transaction and the
# marker are the real ones. A second connection with AutoCommit on is the
# observer: what it can read is what is committed. The LMS pieces around them
# are stubbed and recorded: Slim::Music::Import's importer registry,
# Slim::Utils::Progress, and Slim::Schema's dbh / forceCommit (the latter
# modelled on Slim/Schema.pm:2364-2388, swallowed failure included).
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
our @EVENTS;      # ScanSync's observable steps, in order
our @IMPORTERS;   # every addImporter call, as [ class, params ]
our $DB_READY = 1;

# scanner.pl's own mode flags (scanner.pl:112, :129-130), which ScanSync reads.
our ( $playlists, $onlineLibrary );
our @RESPONSES;   # canned responses, consumed in order
our %PREFS;
our ( @LOG, @WARNINGS, @ERRORS );

BEGIN {
	$INC{'Slim/Utils/Log.pm'}                  = 1;
	$INC{'Slim/Utils/Prefs.pm'}                = 1;
	$INC{'Slim/Utils/PluginManager.pm'}        = 1;
	$INC{'Slim/Networking/SimpleSyncHTTP.pm'}  = 1;
	$INC{'Slim/Schema.pm'}                     = 1;
	$INC{'Slim/Music/Import.pm'}               = 1;
	$INC{'Slim/Music/Info.pm'}                 = 1;
	$INC{'Slim/Utils/Progress.pm'}             = 1;
	$INC{'Slim/Formats.pm'}                    = 1;
	$INC{'Slim/Utils/OSDetect.pm'}             = 1;

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

	*{'Slim::Utils::Log::addLogCategory'} = sub { Test::StubLogger->new };

	# The importer registry (Slim/Music/Import.pm:551-556, :702-720).
	*{'Slim::Music::Import::addImporter'} = sub {
		my ( $class, $importer, $params ) = @_;
		push @main::IMPORTERS, [ $importer, $params ];
		return;
	};
	*{'Slim::Music::Import::endImporter'} = sub {
		my ( $class, $importer ) = @_;
		push @main::EVENTS, "endImporter:$importer";
		return 1;
	};
	*{'Slim::Music::Import::stillScanning'} = sub { 1 };

	*{'Slim::Music::Info::variousArtistString'} = sub { 'Various Artists' };

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

	# Tags.pm's file-scope calls, reached when Importer.pm loads it.
	sub init        { 1 }
	sub migrate     { 1 }
	sub setValidate { 1 }
	sub setChange   { 1 }
}

# Slim::Utils::Progress, recorded. The real one writes the progress table and,
# in the scanner, can exit from update() on an abort; neither is modelled - the
# abort ordering is Ownership's to guarantee and ownership-check.pl asserts it.
{
	package Slim::Utils::Progress;

	sub new {
		my ( $class, $args ) = @_;
		push @main::EVENTS, "progress:new:$args->{name}";
		return bless { args => $args, total => $args->{total} || 0, done => 0 }, $class;
	}
	sub total  { my ( $s, $n ) = @_; if ( defined $n ) { $s->{total} = $n; push @main::EVENTS, "progress:total:$n" } $s->{total} }
	sub update { my $s = shift; $s->{done}++; push @main::EVENTS, 'progress:update'; return }
	sub done   { $_[0]->{done} }
	sub final  { my ( $s, $d ) = @_; push @main::EVENTS, 'progress:final:' . ( defined $d ? $d : 'undef' ); return }
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
# The scanner's database: real migrations, AutoCommit off after connect
# ---------------------------------------------------------------------------

require DBI;
use Digest::MD5 qw(md5_hex);

my $dir = tempdir( CLEANUP => 1 );

sub connect_db {
	my $h = DBI->connect( "dbi:SQLite:dbname=$dir/library.db", '', '', {
		RaiseError => 1, PrintError => 0, AutoCommit => 1,
	} );
	$h->do('PRAGMA foreign_keys = ON');
	$h->do("ATTACH '$dir/squeezewax.db' AS squeezewax");
	return $h;
}

my $obs = connect_db();    # the observer: sees only what is committed

# Only the columns Library reads. Types from SQL/SQLite/schema_16_up.sql.
$obs->do(q{
	CREATE TABLE tracks (
		id INTEGER PRIMARY KEY, album INT, urlmd5 TEXT, url TEXT,
		timestamp INT, disc INT, tracknum INT, remote INT, audio INT,
		content_type TEXT
	)
});
$obs->do('CREATE TABLE albums (id INTEGER PRIMARY KEY, title BLOB, contributor INT)');
$obs->do('CREATE TABLE contributors (id INTEGER PRIMARY KEY, name BLOB)');
$obs->do('CREATE TABLE contributor_album (role INT, contributor INT, album INT)');

require Plugins::SqueezeWax::Schema;
Plugins::SqueezeWax::Schema->_migrate($obs);

# Three albums. 'Album 1' by 'Artist 1' and 'Album 2' by 'Artist 2' are titles
# page_response's collection carries, so the title route badges them; the third
# owns nothing.
my %ALBUM_KEY;
{
	my $track = 0;
	my @albums = ( [ 1, 'Album 1', 'Artist 1' ], [ 2, 'Album 2', 'Artist 2' ], [ 3, 'Not Owned', 'Nobody' ] );

	for my $a (@albums) {
		my ( $id, $title, $artist ) = @$a;
		my $url = "file:///a$id-t1";
		my $md5 = md5_hex($url);

		$obs->do( 'INSERT INTO tracks VALUES (?,?,?,?,?,?,?,?,?,?)', undef,
			++$track, $id, $md5, $url, 100, 1, 1, 0, 1, 'flc' );
		$obs->do( 'INSERT INTO albums (id, title) VALUES (?,?)', undef, $id, $title );
		$obs->do( 'INSERT INTO contributors (id, name) VALUES (?,?)', undef, $id, $artist );
		$obs->do( 'INSERT INTO contributor_album (role, contributor, album) VALUES (5,?,?)',
			undef, $id, $id );

		$ALBUM_KEY{$id} = md5_hex($md5);
	}
}

my $sdbh = connect_db();
$sdbh->{AutoCommit} = 0;    # scanner.pl:295

our $COMMIT_FAILS = 0;

{
	no warnings 'redefine', 'once';

	*Slim::Schema::dbh = sub { $sdbh };

	# Slim/Schema.pm:2364-2388: commit when not AutoCommit, and SWALLOW a
	# failure with a warning. $COMMIT_FAILS stages that swallowed failure: the
	# commit is refused, the transaction rolled back, and nobody told.
	*Slim::Schema::forceCommit = sub {
		my $h = Slim::Schema->dbh;
		push @main::EVENTS, 'commit';
		return if $h->{AutoCommit};
		if ($main::COMMIT_FAILS) { eval { $h->rollback }; return }
		eval { $h->commit };
		return;
	};

	# Migrated directly rather than through postDBConnect.
	*Plugins::SqueezeWax::Schema::isReady   = sub { $main::DB_READY };
	*Plugins::SqueezeWax::Schema::lastError = sub { 'db broken' };
}

require Plugins::SqueezeWax::ScanSync;

{
	no warnings 'redefine', 'once';

	# Recorded in @EVENTS and then performed, so ordering is assertable and the
	# rows read back are the ones the code wrote.
	my $realMarker = \&Plugins::SqueezeWax::Schema::recordSync;
	*Plugins::SqueezeWax::Schema::recordSync = sub {
		push @main::EVENTS, 'marker';
		return $realMarker->(@_);
	};

	my $realApply = \&Plugins::SqueezeWax::Ownership::apply;
	*Plugins::SqueezeWax::Ownership::apply = sub {
		push @main::EVENTS, 'pass';
		push @main::APPLIED, $_[1];
		return $realApply->(@_);
	};
}

our @APPLIED;

my $SS = 'Plugins::SqueezeWax::ScanSync';

# What the observer can see: committed rows and the committed marker.
sub committed_marker {
	return $obs->selectrow_hashref(
		'SELECT last_synced, items, source FROM squeezewax.discogs_sync_state WHERE id = 0' );
}

sub committed_rows {
	return $obs->selectall_arrayref(
		'SELECT album_key, ownership, review_reason FROM squeezewax.discogs_match ORDER BY album_key',
		{ Slice => {} } );
}

# A clean slate between cases: nothing open on the scanner side, no rows, no
# marker. The observer may write only while the scanner holds no transaction.
sub reset_db {
	$sdbh->rollback unless $sdbh->{AutoCommit};
	$obs->do('DELETE FROM squeezewax.discogs_match');
	$obs->do('DELETE FROM squeezewax.discogs_sync_state');
	return;
}

# One scan-time sync, start to finish, against @responses.
sub run_scan {
	my (@responses) = @_;

	@RESPONSES = @responses;
	@EVENTS    = ();
	@APPLIED   = ();

	my $rc = eval { $SS->startScan };
	my $err = $@;

	# Anything left uncommitted belongs to a scan that has "ended"; roll it
	# back so the observer can write the next fixture.
	$sdbh->rollback unless $sdbh->{AutoCommit};

	return ( $rc, $err );
}

sub count_events {
	my ($re) = @_;
	return scalar grep { $_ =~ $re } @EVENTS;
}

sub index_of {
	my ($re) = @_;
	my ($i) = grep { $EVENTS[$_] =~ $re } 0 .. $#EVENTS;
	return $i;
}

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

# ===========================================================================
# ScanSync.pm - the importer
# ===========================================================================

diag('ScanSync: a successful scan-time sync');

{
	reset_state();
	reset_db();
	$PREFS{discogsToken} = 'token-abc';

	my ( $rc, $err ) = run_scan( identity_response(), page_response( 3, 1, 1, 3 ) );

	is( $err, '', 'startScan does not die' );
	is( $rc, 1, '  ...and returns 1: ownership was derived' );

	is_deeply( committed_marker(), { last_synced => $NOW, items => 3, source => 'scan' },
		"the marker is committed as source 'scan', with the item count (§15.18 part 7)" );

	is_deeply( [ map { $_->{album_key} } grep { ( $_->{ownership} || '' ) eq 'version' } @{ committed_rows() } ],
		[ sort $ALBUM_KEY{1}, $ALBUM_KEY{2} ],
		'  ...and the pass\'s conclusions are committed with it - the two owned albums badge' );

	is( count_events(qr/^endImporter:Plugins::SqueezeWax::ScanSync$/), 1, 'endImporter is called exactly once' );
	is( $EVENTS[-1], 'endImporter:Plugins::SqueezeWax::ScanSync', '  ...last' );

	is( $EVENTS[0], 'progress:new:plugin_squeezewax_ownership', 'the progress row is created first' );
	is( $EVENTS[1], 'commit', '  ...and made visible by a commit before any request' );
	ok( !( grep { /progress:total/ } @EVENTS[ 0 .. 2 ] ), '  ...with no total: the page count is not known yet' );

	is( count_events(qr/^progress:total:5$/), 1,
		'the total is set once, to 1 identity + 1 page + 3 albums' );
	is( count_events(qr/^progress:update$/), 5,
		'  ...and the row is ticked once per request and once per album' );

	my $pass   = index_of(qr/^pass$/);
	my $marker = index_of(qr/^marker$/);
	my ($commitAfterMarker) = grep { $EVENTS[$_] eq 'commit' && $_ > $marker } 0 .. $#EVENTS;

	ok( defined $pass && defined $marker && $pass < $marker, 'the pass runs before the marker is written' );
	ok( defined $commitAfterMarker, '  ...and the marker is written BEFORE the commit that makes both durable' );
	ok( index_of(qr/^progress:final/) > $commitAfterMarker, '  ...then the row is closed' );
	is( count_events(qr/^progress:final:5$/), 1, '  ...with an explicit done, all five' );

	ok( ( grep { /scan-time collection sync: 3 items in 2 requests, fetch [\d.]+s, pass [\d.]+s; ownership derived/ } @LOG ),
		'one summary line at info says the scan badged the library' );
	is( scalar @ERRORS, 0, '  ...and nothing at error' );
}

diag('ScanSync: the gates, each returning 0 with endImporter once');

{
	reset_state();
	reset_db();
	$PREFS{discogsToken} = 'token-abc';

	local $main::playlists = 1;

	my ( $rc, $err ) = run_scan( identity_response(), page_response( 3, 1, 1, 3 ) );

	is( $rc, 0, 'a playlist-only rescan skips the sync (§15.18 part 16)' );
	is( scalar @REQUESTS, 0, '  ...issuing no request' );
	ok( !committed_marker(), '  ...writing no marker' );
	is( count_events(qr/^progress:new/), 0, '  ...and creating no progress row' );
	is( count_events(qr/^endImporter:/), 1, '  ...with endImporter called once' );
}

{
	reset_state();
	reset_db();
	$PREFS{discogsToken} = 'token-abc';

	local $main::onlineLibrary = 1;

	my ($rc) = run_scan( identity_response(), page_response( 3, 1, 1, 3 ) );

	is( $rc, 1, 'an online-library-only rescan runs the sync - it adds the albums only the pass can badge' );
	ok( committed_marker(), '  ...and writes the marker' );
}

{
	reset_state();
	reset_db();
	$PREFS{discogsToken} = '';

	my ($rc) = run_scan();

	is( $rc, 0, 'no token: returns 0 (belt and braces behind the use gate)' );
	is( scalar @REQUESTS, 0, '  ...issuing no request' );
	is( count_events(qr/^endImporter:/), 1, '  ...with endImporter called once' );
}

{
	reset_state();
	reset_db();
	$PREFS{discogsToken} = 'token-abc';

	local $DB_READY = 0;

	my ($rc) = run_scan();

	is( $rc, 0, 'a schema that is not ready: returns 0' );
	is( scalar @REQUESTS, 0, '  ...before spending a request' );
	ok( ( grep { /skipping the scan-time collection sync: db broken/ } @ERRORS ),
		'  ...logged at error, with the reason' );
	is( count_events(qr/^endImporter:/), 1, '  ...with endImporter called once' );
}

diag('ScanSync: failures are logged only (§15.18 part 3)');

{
	reset_state();
	reset_db();
	$PREFS{discogsToken}         = 'token-abc';
	$PREFS{discogsLastSyncError} = 'previous';

	my ($rc) = run_scan( { code => 401, headers => healthy_headers(), content => '' } );

	is( $rc, 0, 'a rejected token fails the scan-time sync, returning 0' );
	ok( ( grep { /scan-time collection sync failed: unauthorized \(after 1 requests\)/ } @ERRORS ),
		'  ...logged at error with the error name' );
	ok( !committed_marker(), '  ...with no marker' );
	is_deeply( committed_rows(), [], '  ...and no rows' );
	is( count_events(qr/^pass$/), 0, '  ...never reaching the pass' );
	is( $PREFS{discogsLastSyncError}, 'previous',
		'  ...and nothing on the settings page: the error pref is the server\'s alone' );
	is( count_events(qr/^progress:final:0$/), 1, '  ...closing the row with what was done - nothing' );
	is( count_events(qr/^endImporter:/), 1, '  ...with endImporter called once' );
}

{
	reset_state();
	reset_db();
	$PREFS{discogsToken} = 'token-abc';

	# Page 1 answers (total set), page 2 does not: the row must not close as
	# complete. final() with no argument, or 0, would take the total as done.
	my ($rc) = run_scan(
		identity_response(),
		page_response( 100, 1, 2, 150 ),
		lwp_internal_500(),
	);

	is( $rc, 0, 'a fetch that fails after the total is set returns 0' );
	is( count_events(qr/^progress:final:2$/), 1,
		'  ...and closes the row at what was done, 2 - not at the total (Progress.pm:263)' );
	ok( ( grep { /failed: no_response/ } @ERRORS ), '  ...logging no_response for LWP\'s own 500' );
}

{
	reset_state();
	reset_db();
	$PREFS{discogsToken} = 'token-abc';

	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Ownership::apply = sub { push @EVENTS, 'pass'; 'refused' };

	my ($rc) = run_scan( identity_response(), page_response( 3, 1, 1, 3 ) );

	is( $rc, 0, 'a pass that declines fails the scan-time sync' );
	ok( ( grep { /fetched the collection, but the ownership pass refused/ } @ERRORS ),
		'  ...logged at error' );
	ok( !committed_marker(), '  ...with no marker' );
	is( count_events(qr/^marker$/), 0, '  ...never attempting one' );
	is( count_events(qr/^endImporter:/), 1, '  ...with endImporter called once' );
}

{
	reset_state();
	reset_db();
	$PREFS{discogsToken} = 'token-abc';

	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Schema::recordSync = sub { push @EVENTS, 'marker'; die "disk full\n" };

	my ($rc) = run_scan( identity_response(), page_response( 3, 1, 1, 3 ) );

	# The harmless direction: the pass commits without its marker, and with no
	# marker the fallback syncs again after the scan.
	is( $rc, 1, 'a marker write that dies still returns the pass\'s success' );
	ok( ( grep { /marker was not written \(disk full/ } @ERRORS ), '  ...logged at error' );
	ok( !committed_marker(), '  ...with no marker, so the fallback will sync' );
	is( scalar( grep { ( $_->{ownership} || '' ) eq 'version' } @{ committed_rows() } ), 2,
		'  ...and the pass committed, not rolled back' );
	is( count_events(qr/^endImporter:/), 1, '  ...with endImporter called once' );
}

{
	reset_state();
	reset_db();
	$PREFS{discogsToken} = 'token-abc';

	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Library::albumCount = sub { die "no such table: albums\n" };

	my ( $rc, $err ) = run_scan( identity_response(), page_response( 3, 1, 1, 3 ) );

	is( $err, '', 'a die inside the importer does not escape startScan (scanner.pl:348)' );
	is( $rc, 0, '  ...it returns 0' );
	ok( ( grep { /scan-time collection sync died: no such table/ } @ERRORS ), '  ...logged at error' );
	is( count_events(qr/^progress:final/), 1, '  ...closing the row it had opened' );
	is( count_events(qr/^endImporter:/), 1, '  ...with endImporter called once' );
}

# ===========================================================================
# Importer.pm - the second registration (§15.18 part 14)
# ===========================================================================

diag('Importer.pm: ScanSync registered beside identification');

require Plugins::SqueezeWax::Importer;

{
	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Schema::init = sub { 1 };

	reset_state();
	@IMPORTERS = ();
	$PREFS{discogsToken}    = 'token-abc';
	$PREFS{discogsTagNames} = [];

	Plugins::SqueezeWax::Importer->initPlugin;

	is( scalar @IMPORTERS, 2, 'initPlugin registers two importers' );
	is( $IMPORTERS[0][0], 'Plugins::SqueezeWax::Importer', '  ...identification first' );
	is_deeply( [ @{ $IMPORTERS[0][1] }{qw(type weight use)} ], [ 'post', 120, 0 ],
		'  ...unchanged: post, 120, gated on tag names alone - none here, so off (§15.18 part 9)' );
	is( $IMPORTERS[1][0], 'Plugins::SqueezeWax::ScanSync', '  ...then the scan-time sync' );
	is_deeply( [ @{ $IMPORTERS[1][1] }{qw(type weight use)} ], [ 'post', 130, 1 ],
		'  ...post, 130, and on for a token-only user' );

	@IMPORTERS = ();
	$PREFS{discogsToken} = '';

	Plugins::SqueezeWax::Importer->initPlugin;

	is( $IMPORTERS[1][1]{use}, 0, 'with no token the scan-time sync is registered off' );

	# A ScanSync that will not load must not take identification with it.
	@IMPORTERS = ();
	@ERRORS    = ();
	$PREFS{discogsToken} = 'token-abc';

	{
		local $INC{'Plugins/SqueezeWax/ScanSync.pm'};
		delete $INC{'Plugins/SqueezeWax/ScanSync.pm'};
		local @INC = ( sub { die "syntax error at ScanSync.pm line 1\n" if $_[1] eq 'Plugins/SqueezeWax/ScanSync.pm'; return }, @INC );

		ok( eval { Plugins::SqueezeWax::Importer->initPlugin; 1 },
			'a ScanSync that fails to load does not fail initPlugin' ) or diag($@);
	}

	is( scalar @IMPORTERS, 1, '  ...identification is still registered' );
	is( $IMPORTERS[0][0], 'Plugins::SqueezeWax::Importer', '  ...and only identification' );
	ok( ( grep { /scan-time collection sync could not be loaded.*syntax error/ } @ERRORS ),
		'  ...and the failure is logged at error' );
}

done_testing();
