#!/usr/bin/env perl
#
# The SEAM suite: sync -> pass -> queue render, end to end.
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
# The join was queue -> sync -> link -> pass until §15.46 (GitHub #8) removed
# manual matching. The queue now lists and never decides, so the seam runs the
# other way: a real sync runs the real pass, the pass writes its reasons, and the
# page renders each one with why and what to do - and nothing on the page writes,
# whatever it is sent.
#
# So the point here is NOT to re-test Ownership.pm's rules - ownership-check.pl
# owns those, at far greater depth. The point is that what the pass concluded is
# what the user reads, with every module in that path REAL.
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
our %FILES;           # url => tag hash, for the blocks whose files must say something

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
	# suite has no audio. An unlisted URL returns nothing, which is how the queue
	# page renders "tags no longer readable" - and that case is asserted rather
	# than worked around.
	#
	# %FILES is empty except where a block fills it, which is step 8c's three
	# conflict kinds (§15.22): what the page SAYS about a conflict now depends on
	# what the files say, so at least one block has to have files that say
	# something. A URL absent from the map is an unreadable file, and a readable
	# file with no Discogs tag is a POPULATED hash with no configured key - which
	# is what readTags really returns (Tags::decide's POD on remote URLs). The
	# distinction decides whether an album becomes a conflict at all.
	# Called as Slim::Formats->readTags($url) (Tags::readTrack), so the class name
	# is the first argument and the URL the second.
	*Slim::Formats::readTags = sub {
		my ( undef, $url ) = @_;

		$main::READ_TAGS++;

		return exists $main::FILES{ $url // '' } ? { %{ $main::FILES{$url} } } : {};
	};
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
require Plugins::SqueezeWax::API::Async;

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
# remote => 1 makes every track a streaming one, so the album has no local file.
sub album {
	my ( $id, $title, $artist, %opt ) = @_;

	my $tracks = $opt{tracks} || 1;
	my $remote = $opt{remote} ? 1 : 0;

	for my $n ( 1 .. $tracks ) {
		$nextTrack++;
		my $url = $remote ? "spotify:track:a$id-t$n" : "file:///a$id-t$n";
		$dbh->do( 'INSERT INTO tracks VALUES (?,?,?,?,?,?,?,?,?,?)', undef,
			$nextTrack, $id, md5_hex($url), $url,
			100, 1, $n, $remote, 1, 'flc' );
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

sub allRows {
	return $dbh->selectall_arrayref(
		'SELECT * FROM squeezewax.discogs_match ORDER BY album_key', { Slice => {} } );
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

# The profile request every server sync makes after the identity since step 10,
# for the currency label (decisions §15.31 ruling 15).
sub profile_response {
	return {
		code    => 200,
		headers => healthy_headers(),
		content => encode_json( { username => 'deschman', curr_abbr => 'EUR' } ),
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

# One collection sync through the real Async state machine - the settings
# page's "Sync collection now" and the post-scan fallback both arrive here - and
# so through the real ownership pass. Returns the result hash.
sub sync {
	@REQUESTS = ();

	my $result;

	Plugins::SqueezeWax::API::Async->sync( $PREFS{discogsToken}, sub { $result = shift } );

	return $result;
}

# ---------------------------------------------------------------------------
# The fixture: one library, one collection.
# ---------------------------------------------------------------------------

my %K;

# Its title is owned twice in the collection, so the pass calls it ambiguous
# and it lands in the queue.
$K{ambiguous} = album( 1, 'Ciao Monkey', 'Someone' );

# A conflict, written by the real importer path so the row is exactly what a
# scan would leave behind rather than a hand-built approximation.
$K{conflict} = album( 2, 'Contested', 'Depeche Mode' );

# An album nobody owns and nothing is tagged on: it must never appear.
$K{quiet} = album( 3, 'Nothing Owned', 'Nobody' );

# Both 'Ciao Monkey' entries are by the album's OWN artist. Since §15.17 part 5
# the title route narrows by artist before calling a title ambiguous, so two
# entries by DIFFERENT artists would be a generic shared title and no queue item
# at all - which is not the fixture this suite needs.
my @COLLECTION = (
	[ 2001, 1001, 9001, 'Ciao Monkey', 'Someone' ],
	[ 2002, 1002, 9002, 'Ciao Monkey', 'Someone' ],
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
# 1. THE SEAM. A real sync, the real pass, and the page renders what the pass
#    concluded: why each album is there and what to do about it.
#
#    This is the assertion the whole file is for. Every module in the path is
#    real, and nothing between the collection and the rendered item is asserted
#    by proxy.
# ===========================================================================
{
	@RESPONSES = ( identity_response(), profile_response(), page_response(@COLLECTION) );

	my $result = sync();

	ok( $result && $result->{ok}, 'the sync completes' ) or diag explain $result;

	is( scalar @REQUESTS, 3,
		'  ...with the identity request, the profile request and one page request' );

	# API.pm built the request for real, so the token is where it belongs.
	# A flat name-then-value list, as buildRequest returns it.
	my %h = @{ $REQUESTS[0]{headers} };
	is( $h{Authorization}, 'Discogs token=token-abc',
		'  ...with the token in an Authorization header, from the real API.pm' );

	is( rowFor( $K{ambiguous} )->{review_reason}, 'ambiguous',
		'the pass marked the twice-owned title ambiguous' );
	is( rowFor( $K{conflict} )->{review_reason}, 'conflict',
		"  ...and did not disturb the importer's conflict mark" );
	ok( !rowFor( $K{quiet} ), '  ...and an album owning nothing has no row' );

	my $before = allRows();

	my $params = press();

	is( scalar @REQUESTS, 0, 'rendering the page issues no Discogs request' );
	is_deeply( allRows(), $before, '  ...and writes nothing' );

	my %item = map { $_->{album_key} => $_ } @{ $params->{review} };

	is( scalar @{ $params->{review} }, 2, 'the page lists the two albums the pass could not decide' );
	ok( !$item{ $K{quiet} }, '  ...and not the album owning nothing' );

	is( $item{ $K{ambiguous} }{reasonText}, 'PLUGIN_SQUEEZEWAX_REASON_AMBIGUOUS',
		'THE SEAM: the ambiguous album says why it is there' );
	is( $item{ $K{ambiguous} }{fixText}, 'PLUGIN_SQUEEZEWAX_FIX_AMBIGUOUS',
		'  ...and what to do about it (§15.46 part 7)' );

	is( $item{ $K{conflict} }{reasonText}, 'PLUGIN_SQUEEZEWAX_REASON_CONFLICT',
		'the conflict says why it is there' );
	is( $item{ $K{conflict} }{fixText}, 'PLUGIN_SQUEEZEWAX_FIX_CONFLICT',
		'  ...and what to do about it' );
	ok( $item{ $K{conflict} }{canShowTags}, '  ...and offers to show its tags' );
	ok( !$item{ $K{ambiguous} }{canShowTags}, 'a computed item has no tags to show' );

	is( $params->{openItems}, 2, 'the open-item count is the list length' );

	ok( !exists $params->{orphans}, 'there is no orphan list any more (§15.46 part 8)' );
	ok( !exists $params->{choices}, '  ...and no re-match list' );
}

# ===========================================================================
# 2. Old action names write nothing and ask Discogs nothing
#
#    rematch, link, reject and relink were removed with manual matching
#    (§15.46). A page left open across the update can still send one, with
#    every field the old buttons sent. Each must render the page and do nothing
#    else: no row written or deleted, no request, no message pretending it
#    worked.
# ===========================================================================
{
	@RESPONSES = ();

	my $before = allRows();

	for my $case (
		[ 'rematch', { rematch => 1, album_key => $K{ambiguous} } ],
		[ 'link',    { link => 1, album_key => $K{ambiguous}, release_id => 1001,
		               master_id => 9001 } ],
		[ 'reject',  { reject => 1, album_key => $K{conflict}, confirm => 1 } ],
		[ 'relink',  { relink => 1, album_key => $K{conflict}, target_key => $K{quiet} } ],
		[ 'reject beside saveSettings',
		             { saveSettings => 1, reject => 1, album_key => $K{conflict}, confirm => 1 } ],
	) {
		my ( $name, $fields ) = @$case;

		my $out = press(%$fields);

		is( scalar @REQUESTS, 0, "an old '$name' request issues no Discogs request" );
		is_deeply( allRows(), $before, "  ...writes nothing" );
		ok( $CALLS{super_handler}, '  ...and still renders the page' );
		ok( !$out->{warning} && !$out->{actionResult}, '  ...with no message about it' );
		is( scalar @{ $out->{review} }, 2, '  ...listing the queue as before' );
	}
}

# ===========================================================================
# 3. The one action is refused while a scan is running
# ===========================================================================
{
	local $main::SCANNING = 1;

	my $before = allRows();

	my $out = press( showtags => 1, album_key => $K{conflict} );

	is( $out->{warning}, 'PLUGIN_SQUEEZEWAX_BUSY_SCANNING', 'showtags is refused while scanning' );
	is( $READ_TAGS, 0, '  ...and reads no file' );
	is_deeply( allRows(), $before, '  ...and nothing was written' );
}

# ===========================================================================
# 4. The rejection pause is visible on the queue page (§15.17 part 4)
#
# Driven through the REAL Async state, set by a real 401 through the honest
# transport - not a stubbed flag. That join is the point: §15.15 part 2 sets
# the pause inside _finish, and this page has to read the same state the
# scan-triggered sync consults. A stubbed boolean would prove the template
# works and nothing about whether the two halves agree.
# ===========================================================================
{
	# Clean state first, so the notice's absence means something.
	@RESPONSES = ( identity_response(), profile_response(), page_response(@COLLECTION) );
	sync();

	my $before = press();
	ok( !$before->{tokenPaused}, 'no pause notice after a successful sync' );

	# A real 401, through the transport that routes non-2xx to the error
	# callback, which is what sets the flag at Async's single exit.
	@RESPONSES = ( { code => 401, headers => healthy_headers(), content => '{}' } );

	my $rows = allRows();
	my $failed = sync();

	is( $failed->{error}, 'unauthorized', 'a 401 fails the sync as unauthorized' );
	is_deeply( allRows(), $rows, '  ...and changes no row' );

	ok( Plugins::SqueezeWax::API::Async->tokenRejected,
		'a real 401 sets the rejection pause in Async (§15.15 part 2)' );

	my $paused = press();
	ok( $paused->{tokenPaused},
		'  ...and the queue page shows the pause notice (§15.17 part 4)' );

	# It clears the way the settings page clears it: a sync that works.
	@RESPONSES = ( identity_response(), profile_response(), page_response(@COLLECTION) );
	sync();

	my $after = press();
	ok( !$after->{tokenPaused}, '  ...and it clears once a sync succeeds again' );
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

	# Refused while scanning.
	{
		local $main::SCANNING = 1;
		my $busy = press( showtags => 1, album_key => $K{conflict} );
		is( $busy->{warning}, 'PLUGIN_SQUEEZEWAX_BUSY_SCANNING',
			'showtags is refused while scanning' );
		is( $READ_TAGS, 0, '  ...and reads nothing' );
	}

	# The 0.0.0.3 defect: saveSettings beside the action must not swallow it.
	my $both = press( saveSettings => 1, showtags => 1, album_key => $K{conflict} );
	my ($still) = grep { $_->{album_key} eq $K{conflict} } @{ $both->{review} };
	ok( $still->{tags}, 'a saveSettings beside showtags does not swallow it' );

}

# ===========================================================================
# 9c. Three kinds of conflict, three sentences (step 8c group B, §15.22)
# ===========================================================================
#
# The stored review_reason is 'conflict' for all three, because the column
# records "these tags are contested" and the remedy is the same either way. What
# differs is the MESSAGE, and this is where the user meets it.
#
# Until step 8c there was one sentence - "Two tags name different releases" - and
# it was true only of the in-file case. Saying it of an album where one file is
# tagged and another is not tells the user something untrue about their own
# library, which §15.17 part 3 ranks below a missing feature. So that string
# became the generic one the reason COLUMN can honestly claim, and the specifics
# moved into the detail the "Show tags" button reveals.
#
# Driven through the page, not by reading Queue.pm's map: what matters is that a
# user pressing the button meets a sentence naming their own files.
{
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');

	# Two local tracks, so there are two candidates to disagree.
	my $covers = album( 50, 'Cover Versions', 'Various Artists', tracks => 2 );

	my $ONE = 'file:///a50-t1';
	my $TWO = 'file:///a50-t2';

	$dbh->do(
		"INSERT INTO squeezewax.discogs_match
		 (album_key, lms_album_id, match_tier, state, review_reason)
		 VALUES (?, 50, 'strict', 'candidate', 'conflict')", undef, $covers );

	my $readable = { TITLE => 'A Song', CONTENT_TYPE => 'flc' };

	# 'cross-ids' - album 3421's real ids, 793593 and 369197.
	{
		local %FILES = (
			$ONE => { %$readable, DISCOGS_RELEASE_ID => 793593 },
			$TWO => { %$readable, DISCOGS_RELEASE_ID => 369197 },
		);

		my ($item) = @{ press( showtags => 1, album_key => $covers )->{review} };

		is( $item->{tags}{kind}, 'cross-ids',
			'two files naming different releases render as cross-ids' );
		is( $item->{tags}{kindText}, 'PLUGIN_SQUEEZEWAX_QUEUE_TAGS_CROSS_IDS',
			'  ...with their own sentence, not the in-file one' );
		is( scalar @{ $item->{tags}{conflict} }, 2, '  ...naming both ids' );
		like( $item->{tags}{conflict}[0], qr/a50-t1/,
			'  ...each with the file it came from, so the user knows which to open' );
		like( $item->{tags}{conflict}[1], qr/369197/, '  ...and the id that file held' );
		is( scalar @{ $item->{tags}{untagged} }, 0, '  ...with nothing untagged to name' );
		ok( !$item->{tags}{resolved}, '  ...and it is not reported resolved' );
	}

	# 'cross-partial' - one file tagged, the other readable and carrying no
	# Discogs tag at all. §15.21 ruling 6's second half.
	{
		local %FILES = (
			$ONE => { %$readable, DISCOGS_RELEASE_ID => 793593 },
			$TWO => { %$readable },
		);

		my ($item) = @{ press( showtags => 1, album_key => $covers )->{review} };

		is( $item->{tags}{kind}, 'cross-partial',
			'one file tagged and another not renders as cross-partial' );
		is( $item->{tags}{kindText}, 'PLUGIN_SQUEEZEWAX_QUEUE_TAGS_CROSS_PARTIAL',
			'  ...with the sentence that says only some files carry a tag' );
		isnt( $item->{tags}{kindText}, 'PLUGIN_SQUEEZEWAX_QUEUE_TAGS_CROSS_IDS',
			'  ...and NOT the one about different releases, which would be untrue here' );

		is_deeply( $item->{tags}{untagged}, ['a50-t2'],
			'  ...and it names WHICH file has no tag - without it the line names one file '
				. 'and one id and reads as though nothing were wrong' );
	}

	# 'in-file' - two disagreeing tags in ONE file. The case that was always
	# handled, and whose sentence must not have moved.
	{
		local %FILES = (
			$ONE => { %$readable, DISCOGS_RELEASE_ID => [ 111, 222 ] },
			$TWO => { %$readable, DISCOGS_RELEASE_ID => 111 },
		);

		my ($item) = @{ press( showtags => 1, album_key => $covers )->{review} };

		is( $item->{tags}{kind}, 'in-file',
			'two disagreeing tags in one file still render as in-file' );
		is( $item->{tags}{kindText}, 'PLUGIN_SQUEEZEWAX_QUEUE_TAGS_IN_FILE',
			'  ...with the sentence that case always meant' );
	}

	# The tags agree again: still 'resolved', and the kind sentence is not shown.
	# Only the importer clears 'conflict', and only on a scan (§15.16 part 3).
	{
		local %FILES = (
			$ONE => { %$readable, DISCOGS_RELEASE_ID => 793593 },
			$TWO => { %$readable, DISCOGS_RELEASE_ID => 793593 },
		);

		my ($item) = @{ press( showtags => 1, album_key => $covers )->{review} };

		ok( $item->{tags}{resolved},
			'files that agree again report the conflict resolved, as before step 8c' );
		is( $item->{tags}{kind}, undef, '  ...with no kind, because there is no conflict' );
		is( $item->{tags}{kindText}, undef, '  ...and no sentence about one' );
	}

	# An unreadable second file does not turn a tagged album into a conflict on
	# the page any more than it does in the importer.
	{
		local %FILES = ( $ONE => { %$readable, DISCOGS_RELEASE_ID => 793593 } );

		my ($item) = @{ press( showtags => 1, album_key => $covers )->{review} };

		ok( $item->{tags}{resolved},
			'an unreadable second file reads as resolved, not as a partial conflict' );
		is( $item->{tags}{read}, 1, '  ...having read the one file it could' );
	}

	# And the pre-8c case the older assertions cover: no file readable at all.
	{
		my ($item) = @{ press( showtags => 1, album_key => $covers )->{review} };

		is( $item->{tags}{read}, 0, 'no readable file at all still reports zero read' );
		ok( !$item->{tags}{resolved}, '  ...and is not claimed resolved' );
		is( $item->{tags}{kindText}, undef, '  ...with no sentence about a kind' );
	}

	# The reason COLUMN's own sentence, which is shown for every conflict whatever
	# its kind and therefore may not claim any one of them. Read from strings.txt,
	# because string() here returns the token.
	{
		open my $fh, '<', "$Bin/../SqueezeWax/strings.txt" or die $!;
		local $/;
		my $all = <$fh>;
		close $fh;

		my ($text) = $all =~ /^PLUGIN_SQUEEZEWAX_REASON_CONFLICT\n\tEN\t([^\n]*)/m;

		ok( $text, 'PLUGIN_SQUEEZEWAX_REASON_CONFLICT has EN text' );
		unlike( $text, qr/two tags/i,
			'  ...and no longer claims "two tags", which is untrue of a cross-track conflict' );
	}

	$dbh->do('DELETE FROM squeezewax.discogs_match');
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

		( my $fix = uc $reason ) =~ s/-/_/g;
		is( $item->{fixText}, "PLUGIN_SQUEEZEWAX_FIX_$fix",
			"  ...and says what to do, in its own line (§15.46 part 7)" );
	}

	# A leftover 'orphan' mark - migration 8 clears them, so this is belt and
	# braces - on a row whose album is gone. There is no orphan list to show it
	# in, and the review list shows only albums that are in the library.
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match
		 (album_key, lms_album_id, discogs_release_id, match_tier, state,
		  snapshot_album_title, snapshot_track_count, snapshot_artist, review_reason)
		 VALUES (?, 99, 888888, 'strict', 'candidate', 'Isolar', 2, 'Amorph', 'orphan')",
		undef, 'cd' x 16 );

	my $params = press();

	is( scalar @{ $params->{review} }, 0, 'a gone album is not a review item' );
	ok( !exists $params->{orphans}, '  ...and there is no orphan list to put it in' );
	is( $params->{openItems}, 0, '  ...so nothing is counted as open' );

	# An all-remote album cannot be tagged (§15.46 part 3), so its item says that
	# instead of telling the user to edit files that do not exist.
	$dbh->do('DELETE FROM squeezewax.discogs_match');

	my $stream = album( 60, 'Streamed Only', 'Someone Else', tracks => 2, remote => 1 );

	$dbh->do(
		"INSERT INTO squeezewax.discogs_match (album_key, lms_album_id, ownership, review_reason)
		 VALUES (?, 60, 'absent', 'artist-disagree')", undef, $stream );

	my ($streamed) = @{ press()->{review} };

	ok( $streamed, 'an all-remote album in the queue is listed' );
	is( $streamed->{reasonText}, 'PLUGIN_SQUEEZEWAX_REASON_ARTIST_DISAGREE',
		'  ...with its reason' );
	is( $streamed->{fixText}, 'PLUGIN_SQUEEZEWAX_QUEUE_STREAMING_NOTE',
		'  ...and the streaming note in place of a fix it cannot follow' );

	$dbh->do('DELETE FROM squeezewax.discogs_match');
}

# ===========================================================================
# 9b. The page as a human reads it (§15.17 part 6)
#
# Four defects from the first real look at the page, on 2026-09-26.
# ===========================================================================
{
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');

	# A non-ASCII album, stored the way LMS stores one: UTF-8 bytes.
	my $bjork = album( 40, "Gling-Gl\xc3\xb3", "Bj\xc3\xb6rk" );

	$dbh->do(
		"INSERT INTO squeezewax.discogs_match (album_key, lms_album_id, ownership, review_reason)
		 VALUES (?, 40, 'absent', 'artist-disagree')", undef, $bjork );

	my $params = press();

	# 1. A template comment must not leak onto the page.
	#
	# Asserted over the template SOURCE, not a rendered page: there is no
	# Template Toolkit here, and the source check is the stronger one anyway -
	# it catches the whole class of bug rather than the one instance seen on
	# the screenshot. The first close marker inside a [%# comment ends it, and
	# everything after it is emitted as text.
	{
		my $open  = '[' . '%#';
		my $close = '%' . ']';

		for my $t ( glob("$Bin/../SqueezeWax/HTML/EN/plugins/SqueezeWax/*.html") ) {
			open my $fh, '<', $t or die "could not read $t: $!\n";
			local $/;
			my $text = <$fh>;
			close $fh;

			my $leaked = 0;
			my $at     = 0;

			while ( ( $at = index( $text, $open, $at ) ) >= 0 ) {
				my $end  = index( $text, $close, $at );

				# The body is what sits BETWEEN the opener and the first close
				# marker - the opener itself is not part of it, or every
				# comment would match.
				my $body = $end >= 0 ? substr( $text, $at + 3, $end - $at - 3 ) : '';

				# An opener inside that body means the author wrote template
				# syntax in the comment, so this close marker is not the one
				# they meant to end it with: the rest reaches the page.
				$leaked++ if $body =~ /\[%/;

				$at = $end >= 0 ? $end + 2 : length $text;
			}

			is( $leaked, 0, "no comment in " . ( $t =~ s{.*/}{}r ) . " closes early and leaks to the page" );
		}
	}

	# 2. Non-ASCII renders as characters, not as UTF-8 bytes read as Latin-1.
	my ($item) = @{ $params->{review} };
	is( $item->{title},  "Gling-Gl\x{00f3}", 'a non-ASCII title is decoded for display' );
	is( $item->{artist}, "Bj\x{00f6}rk",     '  ...and so is the artist' );
	isnt( $item->{title}, "Gling-Gl\xc3\xb3",
		'  ...not handed over as raw bytes, which render as "Gling-GlA3"' );

	# Display only: the database still holds what it held.
	my ($storedTitle) = $dbh->selectrow_array(
		'SELECT title FROM albums WHERE id = 40' );
	is( $storedTitle, "Gling-Gl\xc3\xb3",
		'  ...and nothing in the database changed (§15.12, D5)' );

	# A string that will not decode is shown as stored rather than dropped.
	is( Plugins::SqueezeWax::Queue::_display("\xff\xfe bad"), "\xff\xfe bad",
		'an undecodable string is shown as stored, not dropped' );
	is( Plugins::SqueezeWax::Queue::_display(undef), undef, '  ...and undef stays undef' );

	# 4. The review queue's description does not describe an orphan list,
	#    which is gone (§15.46 part 8). Read from strings.txt, because string()
	#    here returns the token.
	{
		open my $fh, '<', "$Bin/../SqueezeWax/strings.txt" or die $!;
		local $/;
		my $all = <$fh>;
		close $fh;

		my ($desc) = $all =~ /^PLUGIN_SQUEEZEWAX_QUEUE_DESC\n\tEN\t([^\n]*)/m;

		ok( $desc, 'PLUGIN_SQUEEZEWAX_QUEUE_DESC has EN text' );
		unlike( $desc, qr/orphan|album has gone/i,
			'  ...and it does not describe an orphan list' );
	}

	# 5. The template carries no control for an action that is gone (§15.46).
	{
		open my $fh, '<', "$Bin/../SqueezeWax/HTML/EN/plugins/SqueezeWax/queue.html" or die $!;
		local $/;
		my $html = <$fh>;
		close $fh;

		for my $gone (qw(rematch link reject relink)) {
			unlike( $html, qr/name="$gone"/, "queue.html has no '$gone' button" );
		}

		like( $html, qr/name="showtags"/, '  ...and keeps "Show tags"' );
		unlike( $html, qr/\borphans\b|\bchoices\b/, '  ...and renders no orphan or re-match list' );
	}
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
