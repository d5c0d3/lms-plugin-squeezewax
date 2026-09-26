#!/usr/bin/env perl
#
# The SEAM suite: queue -> sync -> link -> pass, end to end.
#
# Why this file exists, and why it is different from the others.
#
# The stub audit of 2026-09-24 found three defects that had shipped, and all
# three were the same KIND of defect: not a wrong rule inside a module, but a
# wrong assumption about what the module next door does. A transport stub that
# never called either callback made a whole error path look tested. A prefs stub
# that ignored suppression hid an ordering regression. Each suite was green
# about its own module while the join between them was broken. TODO 2026-09-24
# made naming and testing one such join a build-order obligation for step 8, and
# this is the discharge of it (decisions §15.16 part 10).
#
# So the point here is NOT to re-test Match.pm's predicates or Ownership.pm's
# rules - match-check.pl and ownership-check.pl own those, at far greater depth.
# The point is that a user pressing a button on the queue page ends up with the
# right row in discogs_match and the right badge after the next sync, with every
# module in that path REAL.
#
# Real, and driven for real: Queue.pm's handler (the actual dispatch chain, not
# an extracted one), API/Async.pm's full pagination state machine, API.pm's
# request construction and response classification, Match.pm's writes,
# Ownership.pm's pass, Schema.pm's migrations, and Library.pm's iterator over a
# real SQLite database.
#
# Stubbed ONLY at LMS's boundary, and each stub copied from the suite that
# already models it faithfully rather than re-invented:
#   Slim::Networking::SimpleAsyncHTTP  - the corrected routing from
#                                        sync-check.pl (stub audit §0a)
#   Slim::Utils::Prefs                 - the faithful StubPrefs from
#                                        settings-check.pl (stub audit §0b)
#   Slim::Utils::Timers                - fires synchronously, as sync-check does
#   Slim::Web::Settings::handler       - a render marker
#   Slim::Schema->dbh                  - the scratch database
#
# What it cannot prove: anything about a real event loop, a real socket, or a
# real browser. The transport and the timers are synchronous here and are not in
# production, and no assertion below is about elapsed time. Same limitation
# sync-check.pl states, for the same stubs.
#
# Caveat, carried from TODO 2026-09-24 and worth repeating rather than burying:
# three seam defects are a pattern, not a law. This suite is aimed at step 8's
# own joins. The fourth defect may be somewhere else entirely.
#
# Usage: scripts/queue-check.pl

use strict;
use warnings;

use constant PERFMON  => 0;
use constant DEBUGLOG => 1;
use constant INFOLOG  => 1;

use Config;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
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
}

require DBI;

use Digest::MD5 qw(md5_hex);
use JSON::PP qw(encode_json);

# Every token defined in strings.txt, so a token the page asks for and nobody
# defined is a failure here rather than a bare PLUGIN_SQUEEZEWAX_... on the page
# (the same guard settings-check.pl grew on 2026-09-24).
our %STRINGS;
our @MISSING_STRINGS;

BEGIN {
	my $path = "$Bin/../SqueezeWax/strings.txt";

	open my $fh, '<', $path or die "could not read $path: $!\n";

	while ( my $line = <$fh> ) {
		$STRINGS{$1} = 1 if $line =~ /^(PLUGIN_\S+)\s*$/;
	}

	close $fh;

	die "no strings loaded from $path\n" unless keys %STRINGS;
}

our @REQUESTS;   # every request the transport was asked to issue
our @RESPONSES;  # canned responses, consumed in order
our %PREFS;
our @LOG;
our @WARNINGS;
our %CALLS;
our $SCANNING = 0;
our $READ_TAGS = 0;   # every Slim::Formats->readTags call, so file I/O is countable

# ---------------------------------------------------------------------------
# Stubs, at LMS's boundary and nowhere else.
# ---------------------------------------------------------------------------

BEGIN {
	$INC{'Slim/Web/Settings.pm'}               = 1;
	$INC{'Slim/Web/HTTP/CSRF.pm'}              = 1;
	$INC{'Slim/Utils/Log.pm'}                  = 1;
	$INC{'Slim/Utils/Prefs.pm'}                = 1;
	$INC{'Slim/Utils/Strings.pm'}              = 1;
	$INC{'Slim/Utils/PluginManager.pm'}        = 1;
	$INC{'Slim/Utils/Timers.pm'}               = 1;
	$INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = 1;
	$INC{'Slim/Schema.pm'}                     = 1;
	$INC{'Slim/Music/Import.pm'}               = 1;
	$INC{'Slim/Music/Info.pm'}                 = 1;
	$INC{'Slim/Formats.pm'}                    = 1;

	no strict 'refs';
	no warnings 'redefine';

	# The base class's handler is the generic prefs path. A marker: this suite
	# is about which branch of OUR handler runs and what it wrote, not about
	# core's rendering. It is also the assertion that the queue page reaches the
	# base handler at all, which is what makes beforeRender run in production.
	*{'Slim::Web::Settings::handler'} = sub {
		my ( $class, $client, $params ) = @_;

		$CALLS{super_handler}++;

		# beforeRender is called by core BETWEEN the prefs pass and the render
		# (Slim/Web/Settings.pm's POD: "after the prefs have been
		# processed/saved"). Calling it here is what makes the rendered lists
		# below real rather than a separate code path invented for the test.
		$class->beforeRender($params) if $class->can('beforeRender');

		return 'RENDERED';
	};

	*{'Slim::Web::HTTP::CSRF::protectName'} = sub { $_[1] };
	*{'Slim::Web::HTTP::CSRF::protectURI'}  = sub { $_[1] };

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
		*{ $caller . '::preferences' } = \&Slim::Utils::Prefs::preferences;
	};

	# Returns the token, so an assertion can name the string a branch chose -
	# and records a token nobody defined, which is assertion 8 below.
	*{'Slim::Utils::Strings::string'} = sub {
		my ($token) = @_;

		push @main::MISSING_STRINGS, $token
			unless exists $main::STRINGS{ $token // '' };

		return $token;
	};
	*{'Slim::Utils::Strings::import'} = sub {
		my $caller = caller;
		no strict 'refs';
		*{ $caller . '::string' } = \&Slim::Utils::Strings::string;
	};

	*{'Slim::Utils::PluginManager::dataForPlugin'} = sub { { version => '0.0.0-test' } };

	*{'Slim::Music::Import::stillScanning'} = sub { $main::SCANNING };

	# Fires immediately and records what the delay would have been, as
	# sync-check.pl's does. Async.pm's retry path is the only user.
	*{'Slim::Utils::Timers::setTimer'} = sub {
		my ( $obj, $when, $code, @args ) = @_;
		$code->( $obj, @args );
		return;
	};
	*{'Slim::Utils::Timers::killTimers'} = sub { 1 };

	*{'main::SCANNER'}   = sub () { 0 };
	*{'main::INFOLOG'}   = sub () { 1 };
	*{'main::DEBUGLOG'}  = sub () { 0 };
	*{'main::ISWINDOWS'} = sub () { 0 };
	*{'main::WEBUI'}     = sub () { 1 };
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

# The faithful one from settings-check.pl: suppression of a no-op scalar set,
# and the setChange dispatch. Copied rather than simplified, because a
# simplified prefs stub is one of the three defects this suite exists over.
{
	package Test::StubPrefs;
	sub new { bless {}, shift }
	sub get { return $PREFS{ $_[1] } }

	sub set {
		my ( $self, $pref, $new ) = @_;

		my $old = $PREFS{$pref};

		return 1 if !ref $new
			&& defined $new
			&& defined $old
			&& $new eq $old;

		$PREFS{$pref} = $new;

		if ( my $cb = $main::CHANGES{$pref} ) {
			$cb->( $pref, $new );
		}

		return 1;
	}

	sub init {
		my ( $self, $defaults ) = @_;
		for my $k ( keys %{ $defaults || {} } ) {
			$PREFS{$k} = $defaults->{$k} unless exists $PREFS{$k};
		}
		return 1;
	}
	sub migrate     { 1 }
	sub setValidate { 1 }
	sub setChange   {
		my ( $self, $cb, @prefs ) = @_;
		$main::CHANGES{$_} = $cb for @prefs;
		return 1;
	}
}

our %CHANGES;

# The corrected transport from sync-check.pl (stub audit §0a): every status that
# is not 2xx or 3xx reaches the ERROR callback, which sets neither code nor
# content on the object and passes the response as its third argument. The old
# simplification made four error classifications look reachable when they were
# not, for the whole of build-order step 5.
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
	package Test::StubHeaders;
	sub new { my $class = shift; bless { map { lc $_ } @_ }, $class }
	sub header { return $_[0]->{ lc $_[1] } }
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

# ---------------------------------------------------------------------------
# A real database, a real library, and the real migrations.
# ---------------------------------------------------------------------------

my $dir = tempdir( CLEANUP => 1 );

my $dbh = DBI->connect( "dbi:SQLite:dbname=$dir/library.db", '', '', {
	RaiseError => 1, PrintError => 0, AutoCommit => 1,
} );

$dbh->do('PRAGMA foreign_keys = ON');
$dbh->do("ATTACH '$dir/squeezewax.db' AS squeezewax");

my $VA = 'Various Artists';

{
	no warnings 'once', 'redefine';

	*Slim::Schema::dbh = sub { $dbh };

	# §15.7's label, read once per pass (Slim/Music/Info.pm:1540).
	*Slim::Music::Info::variousArtistString = sub { $VA };

	# The files themselves are the one thing here with no honest stand-in: this
	# suite has no audio. readTags returns nothing, which is how the queue page
	# renders "tags no longer readable" - and that case is asserted rather than
	# worked around.
	*Slim::Formats::readTags = sub { $main::READ_TAGS++; return {} };
}

# Only the columns Library reads. Types from SQL/SQLite/schema_16_up.sql.
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

my $incdir;

BEGIN {
	$incdir = tempdir( CLEANUP => 1 );
	mkdir "$incdir/Plugins";
	symlink "$Bin/../SqueezeWax", "$incdir/Plugins/SqueezeWax"
		or die "could not link the plugin into $incdir: $!\n";
	unshift @INC, $incdir;
}

require Plugins::SqueezeWax::Schema;
require Plugins::SqueezeWax::Queue;
require Plugins::SqueezeWax::Match;

Plugins::SqueezeWax::Schema->_migrate($dbh);

{
	no warnings 'once', 'redefine';

	# The suite migrated directly rather than through postDBConnect, so the
	# readiness flag was never set and every write would be refused.
	*Plugins::SqueezeWax::Schema::isReady = sub { 1 };
}

my $Q = 'Plugins::SqueezeWax::Queue';
my $M = 'Plugins::SqueezeWax::Match';

my $nextTrack = 0;

# One album, with its album_key derived by the real iterator rather than
# recomputed here, so the fixtures cannot drift from Library::_finish.
sub album {
	my ( $id, $title, $artist, %opt ) = @_;

	my $tracks = $opt{tracks} || 1;

	for my $n ( 1 .. $tracks ) {
		$nextTrack++;
		$dbh->do( 'INSERT INTO tracks VALUES (?,?,?,?,?,?,?,?,?,?)', undef,
			$nextTrack, $id, md5_hex("file:///a$id-t$n"), "file:///a$id-t$n",
			100, 1, $n, 0, 1, 'flc' );
	}

	$dbh->do( 'INSERT INTO albums (id, title) VALUES (?,?)', undef, $id, $title );

	if ( defined $artist ) {
		$dbh->do( 'INSERT INTO contributors (id, name) VALUES (?,?)', undef, $id, $artist );
		$dbh->do( 'INSERT INTO contributor_album (role, contributor, album) VALUES (5,?,?)',
			undef, $id, $id );
		$dbh->do( 'UPDATE albums SET contributor = ? WHERE id = ?', undef, $id, $id );
	}

	my $key;
	Plugins::SqueezeWax::Library->eachAlbum( sub {
		$key = $_[0]{album_key} if $_[0]{album_id} == $id;
		return 1;
	} );

	return $key;
}

sub rowFor {
	return $dbh->selectrow_hashref(
		'SELECT * FROM squeezewax.discogs_match WHERE album_key = ?', undef, $_[0] );
}

sub matchCount {
	my ($n) = $dbh->selectrow_array('SELECT COUNT(*) FROM squeezewax.discogs_match');
	return $n;
}

# ---------------------------------------------------------------------------
# Canned Discogs responses, in the shape the real API returns them.
# ---------------------------------------------------------------------------

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
		content => encode_json( { username => 'deschman' } ),
	};
}

# One page of a collection. @items is a list of [ instance, release, master,
# title, artist ] tuples, so a test can say exactly what the user owns.
sub page_response {
	my (@items) = @_;

	return {
		code    => 200,
		headers => healthy_headers(),
		content => encode_json( {
			pagination => { page => 1, pages => 1, items => scalar @items, per_page => 100 },
			releases   => [
				map { {
					id                => $_->[1],
					instance_id       => $_->[0],
					basic_information => {
						id        => $_->[1],
						master_id => $_->[2],
						title     => $_->[3],
						artists   => [ { name => $_->[4] } ],
						year      => 1990,
						formats   => [ { name => 'Vinyl', descriptions => ['LP'] } ],
						labels    => [ { name => 'A Label', catno => 'CAT-' . $_->[1] } ],
					},
				} } @items
			],
		} ),
	};
}

# One press of one button, through the REAL handler, with the render deferred
# exactly as core defers it. Returns the $params hash the page would render
# from, so an assertion can read what the user would see.
sub press {
	my (%params) = @_;

	@REQUESTS        = ();
	$READ_TAGS       = 0;
	@LOG             = ();
	@WARNINGS        = ();
	%CALLS           = ();
	@MISSING_STRINGS = ();

	my $rendered;

	$Q->handler( undef, \%params, sub {
		my ( $client, $p, $output ) = @_;
		$rendered = $output;
	} );

	return \%params;
}

# ---------------------------------------------------------------------------
# The fixture: one library, one collection.
# ---------------------------------------------------------------------------

my %K;

# The album the user will re-match by hand. Its title is owned twice in the
# collection, so the pass calls it ambiguous and it lands in the queue - which
# is the realistic way to arrive at the re-match button.
$K{ambiguous} = album( 1, 'Ciao Monkey', 'Someone' );

# A conflict, written by the real importer path so the row is exactly what a
# scan would leave behind rather than a hand-built approximation.
$K{conflict} = album( 2, 'Contested', 'Depeche Mode' );

# An album nobody owns and nothing is tagged on: it must never appear.
$K{quiet} = album( 3, 'Nothing Owned', 'Nobody' );

# The relink target: a key miss, standing where an orphan's snapshot points.
$K{target} = album( 4, 'Isolar', 'Amorph', tracks => 2 );

my @COLLECTION = (
	[ 2001, 1001, 9001, 'Ciao Monkey', 'Band One' ],
	[ 2002, 1002, 9002, 'Ciao Monkey', 'Band Two' ],
	[ 2003, 1003, 9003, 'Something Else', 'Third Band' ],
);

$PREFS{discogsToken}    = 'token-abc';
$PREFS{discogsTagNames} = ['DISCOGS_RELEASE_ID'];

# The conflict row, written through recordStrict so the whole importer path -
# _recordConflict's upsert, its mark, its no-match clearing - is what produced
# it. A hand-built INSERT here would test the page against a row shape nothing
# in production writes.
{
	local $main::SCANNING = 0;

	my $album;
	Plugins::SqueezeWax::Library->eachAlbum( sub {
		$album = $_[0] if $_[0]{album_key} eq $K{conflict};
		return 1;
	} );

	$M->recordStrict( $album, { conflict => [ 'TAG_A=111', 'TAG_B=222' ] }, undef );
}

is( rowFor( $K{conflict} )->{review_reason}, 'conflict',
	'the fixture conflict row was written by the real importer path' );

# ===========================================================================
# 1. rematch: the requests, the choices, and what it must not write
# ===========================================================================
{
	@RESPONSES = ( identity_response(), page_response(@COLLECTION) );

	my $before = matchCount();

	my $params = press( rematch => 1, album_key => $K{ambiguous} );

	is( scalar @REQUESTS, 2,
		'rematch issues the identity request and one page request' );
	like( $REQUESTS[0]{url}, qr{/oauth/identity},
		'  ...identity first, as every sync does' );
	like( $REQUESTS[1]{url}, qr{/users/[^/]+/collection/folders/0/releases},
		'  ...then the collection folder' );

	# API.pm built the request for real, so the token is where it belongs.
	# A flat name-then-value list, as buildRequest returns it (API.pm:78-87).
	my %h = @{ $REQUESTS[0]{headers} };
	is( $h{Authorization}, 'Discogs token=token-abc',
		'  ...with the token in an Authorization header, from the real API.pm' );
	like( $h{'User-Agent'}, qr{^SqueezeWax/}, '  ...and §9.3\'s User-Agent' );

	ok( $params->{choices}, 'the page has a re-match list to render' );

	# The shortlist is the entries whose title key matches the album's, by
	# Ownership's OWN rule - a different rule here would put the album's actual
	# record outside the shortlist it was offered.
	is( scalar @{ $params->{choices}{matching} }, 2,
		'both entries sharing the album title come first' );
	is( scalar @{ $params->{choices}{rest} }, 1,
		'  ...and the rest of the collection follows' );
	is( $params->{choices}{total}, 3, '  ...with nothing dropped between them' );

	# R6's fixed field set, flattened by the sync and rendered by the page.
	my ($first) = @{ $params->{choices}{matching} };
	is( $first->{title},   'Ciao Monkey', 'a choice carries its title' );
	is( $first->{artists}, 'Band One',    '  ...its artists' );
	is( $first->{year},    1990,          '  ...its year' );
	is( $first->{formats}, 'Vinyl, LP',   '  ...its format' );
	is( $first->{labels},  'A Label (CAT-1001)', '  ...and its label with catalogue number' );
	is( $first->{url}, 'https://www.discogs.com/release/1001',
		'  ...and a discogs.com link built from the release id (§9.6)' );

	# Nothing was written here BY THE PAGE. The pass ran, because a re-match is
	# a normal sync and §15.2 says a completed sync derives ownership - so the
	# table may have changed, but only in the pass's own columns.
	ok( !rowFor( $K{quiet} ), 'an album owning nothing still has no row' );
	is( rowFor( $K{conflict} )->{review_reason}, 'conflict',
		"the pass did not disturb the importer's conflict mark" );
	is( rowFor( $K{ambiguous} )->{match_tier}, undef,
		'the album being re-matched is still unidentified - re-match writes nothing' );
	is( rowFor( $K{ambiguous} )->{review_reason}, 'ambiguous',
		'  ...and the pass marked it ambiguous, which is why it is in the queue' );

	cmp_ok( matchCount(), '>=', $before, 'the pass may add rows; nothing was deleted' );
}

# ===========================================================================
# 2. link: what confirming actually writes
# ===========================================================================
{
	my $params = press(
		link       => 1,
		album_key  => $K{ambiguous},
		release_id => 1001,
		master_id  => 9001,
	);

	is( scalar @REQUESTS, 0, 'confirming issues no Discogs request at all' );

	my $row = rowFor( $K{ambiguous} );

	is( $row->{match_tier},         'manual',    'link writes a manual row' );
	is( $row->{state},              'confirmed', '  ...confirmed' );
	is( $row->{discogs_release_id}, 1001,        '  ...with the chosen release' );
	is( $row->{discogs_master_id},  9001,        '  ...and its master' );
	is( $row->{review_reason},      undef,       '  ...and no review reason' );

	# D5: a manual link is an identification, so it snapshots. This is the row
	# orphan recovery will need if the folder ever moves.
	is( $row->{snapshot_album_title}, 'Ciao Monkey', '  ...carrying the snapshot title' );
	is( $row->{snapshot_artist},      'Someone',     '  ...artist' );
	is( $row->{snapshot_track_count}, 1,             '  ...and track count' );

	# The badge is the pass's, and the page says so rather than implying the
	# link changed it.
	is( $row->{ownership}, 'absent',
		'ownership is untouched - the badge is the pass\'s to write' );
	like( $params->{actionResult}, qr/PLUGIN_SQUEEZEWAX_QUEUE_BADGE_LATER/,
		'  ...and the page says the badge changes at the next sync' );
}

# ===========================================================================
# 3. THE SEAM. A second sync, the same collection, the real pass - and the
#    album the user linked by hand now badges and leaves the queue.
#
#    This is the assertion the whole file is for. Every module in the path is
#    real, and nothing between the button press and the badge is asserted by
#    proxy.
# ===========================================================================
{
	@RESPONSES = ( identity_response(), page_response(@COLLECTION) );

	my $params = press( rematch => 1, album_key => $K{conflict} );

	my $row = rowFor( $K{ambiguous} );

	is( $row->{ownership}, 'exact',
		'THE SEAM: the hand-linked album badges exact after the next sync' );
	is( $row->{match_tier}, 'manual', '  ...still manual' );
	is( $row->{state}, 'confirmed',
		'  ...and the pass did not move its state: a manual link is not cross-checked' );
	is( $row->{review_reason}, undef, '  ...and it carries no reason' );

	# And it is gone from the list the page renders.
	ok( !( grep { $_->{album_key} eq $K{ambiguous} } @{ $params->{review} } ),
		'  ...so it is no longer in the review queue' );
}

# ===========================================================================
# 4. A 401 on rematch: the unauthorized string, and no write
# ===========================================================================
{
	@RESPONSES = ( { code => 401, headers => healthy_headers(), content => '{}' } );

	my $before = $dbh->selectall_arrayref(
		'SELECT * FROM squeezewax.discogs_match ORDER BY album_key', { Slice => {} } );

	my $params = press( rematch => 1, album_key => $K{conflict} );

	is( $params->{warning}, 'PLUGIN_SQUEEZEWAX_SYNC_FAIL_UNAUTHORIZED',
		'a 401 renders the settings page\'s own unauthorized string' );
	# NOT $params->{rematch}: the button's own field is still in the hash, and
	# a list written over it would leave a failed re-match indistinguishable
	# from a successful one whose collection happened to be empty. Found by
	# this suite.
	ok( !$params->{choices}, '  ...and there is no list to choose from' );

	is_deeply(
		$dbh->selectall_arrayref(
			'SELECT * FROM squeezewax.discogs_match ORDER BY album_key', { Slice => {} } ),
		$before,
		'  ...and not one column of discogs_match changed'
	);
}

# ===========================================================================
# 5. Every action is refused while a scan is running
# ===========================================================================
{
	local $main::SCANNING = 1;

	my $before = $dbh->selectall_arrayref(
		'SELECT * FROM squeezewax.discogs_match ORDER BY album_key', { Slice => {} } );

	for my $case (
		[ 'rematch', { rematch => 1, album_key => $K{conflict} } ],
		[ 'link',    { link => 1, album_key => $K{conflict}, release_id => 4242 } ],
		[ 'reject',  { reject => 1, album_key => $K{conflict}, confirm => 1 } ],
		[ 'relink',  { relink => 1, album_key => $K{conflict}, target_key => $K{target} } ],
	) {
		my ( $name, $params ) = @$case;

		my $out = press(%$params);

		is( $out->{warning}, 'PLUGIN_SQUEEZEWAX_BUSY_SCANNING',
			"$name is refused while scanning" );
		is( scalar @REQUESTS, 0, "  ...$name issues no request either" );
	}

	is_deeply(
		$dbh->selectall_arrayref(
			'SELECT * FROM squeezewax.discogs_match ORDER BY album_key', { Slice => {} } ),
		$before,
		'  ...and nothing was written by any of them'
	);
}

# ===========================================================================
# 6. saveSettings alongside an action does not swallow it
#
#    This is the 0.0.0.3 defect, re-asked on the new page. The settings form's
#    hidden saveSettings reaches here too - the footer emits it whether or not
#    nosubmit is set (settings/footer.html:38-39) - and on the settings page
#    testing it before the named actions killed two buttons. Here it is not
#    tested at all, which is the stronger position; this asserts that.
# ===========================================================================
{
	my $params = press(
		saveSettings => 1,
		reject       => 1,
		confirm      => 1,
		album_key    => $K{conflict},
	);

	is( rowFor( $K{conflict} ), undef,
		'a reject arriving beside saveSettings still runs (the 0.0.0.3 defect)' );
	is( $params->{actionResult}, 'PLUGIN_SQUEEZEWAX_QUEUE_REJECTED',
		'  ...and reports what it did' );
	ok( $CALLS{super_handler}, '  ...having still reached the base handler to render' );
}

# ===========================================================================
# 7. reject refuses what it must, and takes exactly one row when it acts
# ===========================================================================
{
	# A computed item: the ambiguity is re-derived from the collection at every
	# sync, so deleting the row would change nothing and the item would come
	# straight back. There is no stored dismiss (§15.16 part 7).
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match (album_key, lms_album_id, ownership, review_reason)
		 VALUES (?, 1, 'absent', 'ambiguous')", undef, $K{ambiguous} );

	my $params = press( reject => 1, confirm => 1, album_key => $K{ambiguous} );

	ok( rowFor( $K{ambiguous} ), 'reject on a computed item deletes nothing' );
	is( $params->{warning}, 'PLUGIN_SQUEEZEWAX_QUEUE_FAILED', '  ...and says so' );

	# The confirm field is required at the handler, not only in the browser: a
	# deletion from the one non-regenerable table must not be one press away
	# from a mis-click.
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match
		 (album_key, lms_album_id, discogs_release_id, match_tier, state,
		  snapshot_album_title, snapshot_track_count, snapshot_artist, review_reason)
		 VALUES (?, 4, 888888, 'manual', 'confirmed', 'Isolar', 2, 'Amorph', 'orphan')",
		undef, 'ab' x 16 );

	my $unconfirmed = press( reject => 1, album_key => 'ab' x 16 );

	ok( rowFor( 'ab' x 16 ), 'reject without the confirm field deletes nothing' );
	is( $unconfirmed->{warning}, 'PLUGIN_SQUEEZEWAX_QUEUE_CONFIRM_REQUIRED',
		'  ...and names the missing confirmation' );

	my $confirmed = press( reject => 1, confirm => 1, album_key => 'ab' x 16 );

	is( rowFor( 'ab' x 16 ), undef, 'reject on a manual orphan deletes exactly that row' );
	is( $confirmed->{actionResult}, 'PLUGIN_SQUEEZEWAX_QUEUE_REJECTED', '  ...and says so' );
}

# ===========================================================================
# 8. relink from the orphan list, onto an album a regenerable row is sitting on
#
#    Both halves of TODO 2026-09-19 at once, through the page rather than
#    through relinkOrphan directly: the target must be OFFERED (it would not
#    have been, because a NULL-tier row made it look taken), and the relink must
#    SUCCEED (it would not have, because album_key is the primary key).
# ===========================================================================
{
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');

	my $orphanKey = 'ab' x 16;

	# The orphan: snapshot 'Amorph' / 'Isolar' / 2 tracks, which is exactly what
	# album 4 looks like to Match::_fitKey.
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match
		 (album_key, lms_album_id, discogs_release_id, match_tier, state, matched_at,
		  source_timestamp, snapshot_album_title, snapshot_track_count, snapshot_artist,
		  review_reason)
		 VALUES (?, 99, 888888, 'manual', 'confirmed', 500, 900, 'Isolar', 2, 'Amorph', 'orphan')",
		undef, $orphanKey );

	# The blocker: a row the ownership pass wrote on the target key.
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match (album_key, lms_album_id, ownership, review_reason)
		 VALUES (?, 4, 'absent', 'ambiguous')", undef, $K{target} );

	# The page offers it, which before step 8 it could not have.
	my $listed = press();

	my ($orphan) = grep { $_->{album_key} eq $orphanKey } @{ $listed->{orphans} };

	ok( $orphan, 'the orphan is listed' );
	is( $orphan->{title}, 'Isolar', '  ...from its snapshot, since its album is gone' );
	is( $orphan->{url}, 'https://www.discogs.com/release/888888',
		'  ...with a discogs.com link' );
	is( scalar @{ $orphan->{candidates} }, 1,
		'  ...and the fitting album is offered, though a pass row sits on it' );
	is( $orphan->{candidates}[0]{album_key}, $K{target}, '  ...and it is the right album' );

	# And the move itself lands.
	my $params = press( relink => 1, album_key => $orphanKey, target_key => $K{target} );

	is( $params->{actionResult} && 1, 1, 'the relink reports success' ) or diag( $params->{warning} );

	my $moved = rowFor( $K{target} );

	is( $moved->{discogs_release_id}, 888888, 'the orphan moved onto the target album' );
	is( $moved->{match_tier}, 'manual', '  ...still manual' );
	is( $moved->{lms_album_id}, 4, '  ...with the current lms_album_id' );
	is( $moved->{review_reason}, undef, "  ...with 'orphan' cleared by the relink" );
	is( rowFor($orphanKey), undef, '  ...and nothing left under the old key' );

	my ($onKey) = $dbh->selectrow_array(
		'SELECT COUNT(*) FROM squeezewax.discogs_match WHERE album_key = ?', undef, $K{target} );
	is( $onKey, 1, '  ...one row on the key, not a primary-key collision' );
}

# ===========================================================================
# 8a. Which albums an orphan may be moved onto (§15.17 part 2 and 3)
#
# Report §2.2's matrix, driven through the real page. The old rule - "a key
# miss, no row in EITHER table" - was right for the scanner and wrong here,
# because the page renders AFTER the scan that gives every album a row. Cases
# B, C and D are the ones that used to offer nothing.
# ===========================================================================
{
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');

	my $orphanKey = 'ab' x 16;

	# Two current albums that both fit the orphan's snapshot exactly.
	my $fitA = album( 20, 'Relink Target', 'Testband', tracks => 2 );
	my $fitB = album( 21, 'Relink Target', 'Testband', tracks => 2 );

	my $seedOrphan = sub {
		$dbh->do('DELETE FROM squeezewax.discogs_match');
		$dbh->do('DELETE FROM squeezewax.discogs_no_match');
		$dbh->do(
			"INSERT INTO squeezewax.discogs_match
			 (album_key, lms_album_id, discogs_release_id, match_tier, state, matched_at,
			  source_timestamp, snapshot_album_title, snapshot_track_count, snapshot_artist,
			  review_reason)
			 VALUES (?, 99, 888888, 'manual', 'confirmed', 500, 900, 'Relink Target', 2, 'Testband', 'orphan')",
			undef, $orphanKey );
	};

	my $offered = sub {
		my $p = press();
		my ($o) = grep { $_->{album_key} eq $orphanKey } @{ $p->{orphans} };
		return ( $o, $p );
	};

	# --- A: two fresh copies, no rows at all -----------------------------
	$seedOrphan->();
	my ($oA) = $offered->();
	is( scalar @{ $oA->{candidates} }, 2, 'A: two fresh copies are both offered' );
	is( scalar @{ $oA->{identified} }, 0, '  ...and none is withheld as identified' );

	# --- B: after a scan, both untagged -> strict no-match rows ----------
	#
	# THE case report §2.2 found. This offered nothing before.
	$seedOrphan->();
	$dbh->do("INSERT INTO squeezewax.discogs_no_match (album_key,tier,checked_at) VALUES (?,'strict',1)",
		undef, $_ ) for $fitA, $fitB;
	my ($oB) = $offered->();
	is( scalar @{ $oB->{candidates} }, 2,
		'B: untagged copies carrying no-match rows are offered (§15.17 part 2)' );

	# --- C: after a scan, both tagged -> identification rows -------------
	$seedOrphan->();
	$dbh->do("INSERT INTO squeezewax.discogs_match (album_key,lms_album_id,discogs_release_id,match_tier,state)
	          VALUES (?,?,4242,'strict','candidate')", undef, $_->[0], $_->[1] )
		for [ $fitA, 20 ], [ $fitB, 21 ];
	my ( $oC, $pC ) = $offered->();
	is( scalar @{ $oC->{candidates} }, 0, 'C: albums that identify themselves are NOT targets' );
	is( scalar @{ $oC->{identified} }, 2, '  ...but they are reported as fitting' );

	# §15.17 part 3: the page must not claim nothing fits when something does.
	my $html = $pC->{_html} // '';
	ok( ( grep { $_ eq 'PLUGIN_SQUEEZEWAX_QUEUE_ORPHAN_FIT_IDENTIFIED' } @MISSING_STRINGS ) == 0,
		'  ...and the identified-fit string exists' );

	# --- D: a reason-only row (three NULLs) ------------------------------
	$seedOrphan->();
	$dbh->do("INSERT INTO squeezewax.discogs_match (album_key,lms_album_id,ownership,review_reason)
	          VALUES (?,?,'absent','ambiguous')", undef, $_->[0], $_->[1] )
		for [ $fitA, 20 ], [ $fitB, 21 ];
	my ($oD) = $offered->();
	is( scalar @{ $oD->{candidates} }, 2, 'D: reason-only rows are regenerable, so still targets' );

	# --- no fit at all ----------------------------------------------------
	$seedOrphan->();
	$dbh->do( "UPDATE squeezewax.discogs_match SET snapshot_album_title='Nothing Fits This'" );
	my ($oNone) = $offered->();
	is( scalar @{ $oNone->{candidates} }, 0, 'an orphan fitting nothing offers no target' );
	is( scalar @{ $oNone->{identified} }, 0, '  ...and reports no fitting-but-identified album either' );

	# --- the relink from case B actually lands ---------------------------
	$seedOrphan->();
	$dbh->do("INSERT INTO squeezewax.discogs_no_match (album_key,tier,checked_at) VALUES (?,'strict',1)",
		undef, $_ ) for $fitA, $fitB;

	my $done = press( relink => 1, album_key => $orphanKey, target_key => $fitA );
	like( $done->{actionResult}, qr/PLUGIN_SQUEEZEWAX_QUEUE_RELINKED/,
		'a relink from case B succeeds end to end' );
	like( $done->{actionResult}, qr/PLUGIN_SQUEEZEWAX_QUEUE_BADGE_LATER/,
		'  ...and still says the badge waits for the next sync' );

	my $moved = rowFor($fitA);
	is( $moved->{discogs_release_id}, 888888, '  ...the orphan landed on the target' );
	is( $moved->{review_reason}, undef, "  ...with 'orphan' cleared" );

	my ($nm) = $dbh->selectrow_array(
		'SELECT COUNT(*) FROM squeezewax.discogs_no_match WHERE album_key = ?', undef, $fitA );
	is( $nm, 0, '  ...and no no-match row left on the key (invariant 1)' );

	my ($cnt) = $dbh->selectrow_array(
		'SELECT COUNT(*) FROM squeezewax.discogs_match WHERE album_key = ?', undef, $fitA );
	is( $cnt, 1, '  ...exactly one match row there' );

	is( rowFor($orphanKey), undef, '  ...and nothing under the old key' );
}

# ===========================================================================
# 9. The review list as the page renders it
# ===========================================================================
{
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');

	# A marked conflict, and a fresh one with no mark - the shape a conflict
	# written before migration 4 has, which D3's second predicate is what finds.
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match
		 (album_key, lms_album_id, match_tier, state, discogs_release_id, review_reason)
		 VALUES (?, 2, 'strict', 'candidate', 111, 'conflict')", undef, $K{conflict} );

	$dbh->do(
		"INSERT INTO squeezewax.discogs_match
		 (album_key, lms_album_id, match_tier, state)
		 VALUES (?, 1, 'strict', 'candidate')", undef, $K{ambiguous} );

	# A plain identification, which is NOT a queue item: 305 of the reference
	# server's 329 candidates are this shape, and the queue must not key on
	# state (§13.4, §14.3).
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match
		 (album_key, lms_album_id, match_tier, state, discogs_release_id,
		  snapshot_album_title, snapshot_track_count)
		 VALUES (?, 3, 'strict', 'candidate', 777, 'Nothing Owned', 1)", undef, $K{quiet} );

	my $params = press();

	is( scalar @{ $params->{review} }, 2,
		'the review list holds the two conflicts and nothing else' );

	ok( !( grep { $_->{album_key} eq $K{quiet} } @{ $params->{review} } ),
		'  ...a plain strict candidate is not a queue item' );

	my ($unmarked) = grep { $_->{album_key} eq $K{ambiguous} } @{ $params->{review} };
	is( $unmarked->{reason}, 'conflict',
		"D3: an unmarked fresh conflict is found by §3a's own predicate and reads as one" );

	# --- §15.17 part 1: the LIST READS NO FILES -----------------------------
	#
	# This is the assertion the whole change exists for. On the reference
	# server's CIFS library a single tag read cost 19-137 ms, and the previous
	# build did up to 50 of them per render - about 7 s of synchronous I/O in a
	# single-threaded server. Counting the calls at the LMS boundary is the only
	# way to state "no file I/O" as a fact rather than a hope.
	is( $READ_TAGS, 0,
		'rendering the list with conflict rows reads NO tag files (§15.17 part 1)' );

	my ($marked) = grep { $_->{album_key} eq $K{conflict} } @{ $params->{review} };
	ok( !$marked->{tags}, '  ...so no conflict row carries tags on a plain render' );
	ok( $marked->{canShowTags}, '  ...but it offers to show them' );

	is( $params->{openItems}, 2, 'the open-item count is what the page shows' );

	# --- showtags: the per-entry read (§15.17 part 1) ---------------------
	#
	# At most two files, and only for the album asked about - the primary
	# candidate and one fallback, which is what _readTags reads.
	my $shown = press( showtags => 1, album_key => $K{conflict} );

	cmp_ok( $READ_TAGS, '<=', 2,
		'showtags reads at most two files - the album\'s own candidates' );
	ok( $READ_TAGS > 0, '  ...and it does actually read' );

	my ($expanded) = grep { $_->{album_key} eq $K{conflict} } @{ $shown->{review} };
	ok( $expanded->{tags}, '  ...the asked-for row now carries its tags' );

	# The fixtures have no audio behind them, so readTags gives nothing back -
	# which is precisely the "files no longer readable" branch, now reachable
	# only after the button is pressed.
	is( $expanded->{tags}{read}, 0,
		'  ...and an unreadable conflict reports zero read, as before' );

	my ($other) = grep { $_->{album_key} ne $K{conflict} } @{ $shown->{review} };
	ok( !$other->{tags}, 'showtags expands ONLY the album it was given' );

	# Refused while scanning, like every other action - check 8 stays uniform.
	{
		local $main::SCANNING = 1;
		my $busy = press( showtags => 1, album_key => $K{conflict} );
		is( $busy->{warning}, 'PLUGIN_SQUEEZEWAX_BUSY_SCANNING',
			'showtags is refused while scanning, like the other four' );
		is( $READ_TAGS, 0, '  ...and reads nothing' );
	}

	# The 0.0.0.3 defect, asked of the fifth action too.
	my $both = press( saveSettings => 1, showtags => 1, album_key => $K{conflict} );
	my ($still) = grep { $_->{album_key} eq $K{conflict} } @{ $both->{review} };
	ok( $still->{tags}, 'a saveSettings beside showtags does not swallow it' );

}

# ===========================================================================
# 9a. Every reason renders a sentence
#
# Through the page, not by reading the module's map: what matters is that a
# user meets a sentence, and the map is only how. A reason with no sentence
# would reach them as a bare PLUGIN_SQUEEZEWAX_... - or, worse, as the internal
# word 'various-gated'.
# ===========================================================================
{
	for my $reason (qw(ambiguous artist-disagree artist-absent various-gated)) {
		$dbh->do('DELETE FROM squeezewax.discogs_match');
		$dbh->do(
			"INSERT INTO squeezewax.discogs_match (album_key, lms_album_id, ownership, review_reason)
			 VALUES (?, 1, 'absent', ?)", undef, $K{ambiguous}, $reason );

		my $params = press();
		my ($item) = @{ $params->{review} };

		ok( $item, "a '$reason' row reaches the review list" );
		like( $item->{reasonText}, qr/^PLUGIN_SQUEEZEWAX_REASON_/,
			"  ...and renders a sentence, not the internal word" );
		isnt( $item->{reasonText}, $reason, "  ...which is not '$reason' itself" );
	}

	# orphan is the other list, and must never appear in this one.
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match
		 (album_key, lms_album_id, discogs_release_id, match_tier, state,
		  snapshot_album_title, snapshot_track_count, snapshot_artist, review_reason)
		 VALUES (?, 99, 888888, 'manual', 'confirmed', 'Isolar', 2, 'Amorph', 'orphan')",
		undef, 'cd' x 16 );

	my $params = press();

	is( scalar @{ $params->{review} }, 0, 'an orphan is not a review item' );
	is( scalar @{ $params->{orphans} }, 1, '  ...it is in the orphan list' );
	like( $params->{orphans}[0]{title}, qr/Isolar/, '  ...shown from its snapshot' );
}

# ===========================================================================
# 10. Every string token the page asked for exists
# ===========================================================================
#
# Accumulated across every press above, through the real string() call. A token
# nobody defined reaches the user as a bare PLUGIN_SQUEEZEWAX_... at the moment
# they most need a sentence.
{
	# One more render, so the tokens from the last press are in hand.
	press();

	is_deeply( [ sort keys %{ { map { $_ => 1 } @MISSING_STRINGS } } ], [],
		'every string token this run asked for exists in strings.txt' );
}

done_testing();
