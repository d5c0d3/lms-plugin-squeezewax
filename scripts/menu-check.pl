#!/usr/bin/env perl
#
# The step 9 seam suite: an LMS album id -> our row -> what the user sees.
#
# Why it is a seam suite and not three module suites. The one failure this step
# can produce is silent: THE WRONG ALBUM SHOWN AS OWNED. Nothing logs it,
# nothing counts it, and the user has no way to tell a wrong badge from a right
# one except by knowing their own collection. The join that produces it runs
# across four modules - LMS's albums.id, Library::albumKey, discogs_match's
# ownership column and Ownership::_effectiveMaster - and each of those is
# already green in a suite of its own. So this one drives the join.
#
# Real here: Library.pm's key over a real SQLite database, Schema.pm's
# migrations, Ownership::_effectiveMaster, Menu.pm's providers, and - for the
# album and track menus - Slim::Menu::AlbumInfo and Slim::Menu::TrackInfo
# THEMSELVES, initialised as slimserver.pl:466-474 initialises them and driven
# through ->menu, so the callback signature and the provider ordering are LMS's
# own rather than our reading of them.
#
# Stubbed only at LMS's boundary:
#   Slim::Schema->dbh                  the scratch database
#   Slim::Music::Info                  getCurrentTitle, which menu() calls
#   Slim::Utils::Misc                  a %INC marker; its chain reaches
#                                      Slim::Utils::Unicode, which does not load
#                                      offline (the same cut syntax-check makes)
#   Slim::Networking::SimpleAsyncHTTP  a transport that DIES on any call
#
# The transport is the point of part 5: a menu open must never reach Discogs.
#
# What it cannot prove: that a real skin renders the item, that the Discogs URL
# forms are right (plan §7 settles both on hardware), or anything about a real
# library.db's album ids.
#
# Usage: scripts/menu-check.pl

use strict;
use warnings;

# Compile-time constants the LMS modules below read from package main. RESIZER
# is Slim::Utils::DbCache's, reached through BrowseLibrary's cache.
use constant PERFMON  => 0;
use constant DEBUGLOG => 1;
use constant INFOLOG  => 1;
use constant RESIZER  => 0;
use constant SCANNER  => 0;
use constant ISWINDOWS => 0;
use constant ISMAC    => 0;

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

# Every token strings.txt defines, so a string the menu asks for and nobody
# wrote is a failure here rather than a bare PLUGIN_SQUEEZEWAX_... on a player.
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

our @LOG;
our @WARNINGS;
our $SCANNING = 0;
our @DISPATCH;

BEGIN {
	$INC{'Slim/Schema.pm'}                     = 1;
	$INC{'Slim/Music/Import.pm'}               = 1;
	$INC{'Slim/Music/Info.pm'}                 = 1;
	$INC{'Slim/Utils/Misc.pm'}                 = 1;
	$INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = 1;

	# Slim::Utils::Strings loads Slim::Utils::Prefs, whose Namespace reaches
	# Slim::Utils::Unicode - which dies offline in its own file scope, on a
	# locale the suite has no way to supply. Cut at Prefs, with the one symbol
	# Strings imports from it supplied, exactly as syntax-check.sh cuts it.
	$INC{'Slim/Utils/Prefs.pm'} = 1;

	no strict 'refs';
	no warnings 'redefine';

	*{'Slim::Music::Import::stillScanning'} = sub { $main::SCANNING };

	# menu() ends by naming the feed after the album, falling back to this.
	*{'Slim::Music::Info::getCurrentTitle'} = sub { 'a title' };

	*{'main::SCANNER'}   = sub () { 0 };
	*{'main::INFOLOG'}   = sub () { 1 };
	*{'main::DEBUGLOG'}  = sub () { 0 };
	*{'main::ISWINDOWS'} = sub () { 0 };
	*{'main::WEBUI'}     = sub () { 1 };
	*{'main::idleStreams'} = sub { };

	# Both menus register a CLI dispatch in init(). Recorded rather than
	# executed: what is dispatched is core's business, and this suite is about
	# what the provider returns.
	$INC{'Slim/Control/Request.pm'} = 1;
	*{'Slim::Control::Request::addDispatch'} = sub { push @main::DISPATCH, $_[0]; 1 };

	*{'Slim::Utils::Prefs::preferences'} = sub { Test::StubPrefs->new };
	*{'Slim::Utils::Prefs::import'}      = sub {
		my $caller = caller;
		no strict 'refs';
		*{ $caller . '::preferences' } = \&Slim::Utils::Prefs::preferences;
	};
}

# Enough of a prefs object for the classes that read one at file scope. No
# SqueezeWax pref is involved in a menu open, which is itself the point: the
# menu asks the database, not the settings.
{
	package Test::StubPrefs;
	sub new  { bless {}, shift }
	sub get  { return undef }
	sub set  { return 1 }
	sub init { return 1 }
	sub client { return $_[0] }
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

# AlbumInfo.pm ties a file-scope variable to Tie::Cache::LRU without using the
# class, relying on Slim::Schema to have loaded it. Slim::Schema is stubbed.
require Tie::Cache::LRU;

# TrackInfo::menu asks the protocol handler for a remote track's metadata. No
# handler here: every fixture track is a file, and $remoteMeta is then the empty
# set that AlbumInfo's own comment describes.
{
	$INC{'Slim/Player/ProtocolHandlers.pm'} = 1;

	no strict 'refs';
	*{'Slim::Player::ProtocolHandlers::handlerForURL'} = sub { undef };
}

# The logger is replaced BEFORE the menu classes are loaded: they capture one at
# file scope, and a core provider failing against the stand-in album below is
# logged rather than fatal - so without this the failure goes to a real Log4perl
# that was never initialised, instead of into @WARNINGS where part 5 reads it.
require Slim::Utils::Log;

{
	no strict 'refs';
	no warnings 'redefine';
	*{'Slim::Utils::Log::logger'} = sub { Test::StubLogger->new };
}

require Slim::Menu::AlbumInfo;
require Slim::Menu::TrackInfo;

# Returns the token so an assertion can name the string a branch chose, and
# records a token nobody defined. Slim::Utils::Strings is loaded for real by the
# Slim::Menu classes, so only the function is replaced.
{
	no strict 'refs';
	no warnings 'redefine';

	*{'Slim::Utils::Strings::string'} = sub {
		my ($token) = @_;

		# Ours only. The core providers alongside us ask for core's tokens,
		# which live in the server's own strings file, not in this plugin's.
		push @main::MISSING_STRINGS, $token
			if ( $token // '' ) =~ /^PLUGIN_SQUEEZEWAX_/
			&& !exists $main::STRINGS{$token};

		return $token;
	};
}

# The transport that must never be called. Part 5's whole assertion: a menu
# open spends no Discogs request and no rate budget. Anything reaching API.pm
# from here dies with this message rather than quietly returning undef.
{
	package Slim::Networking::SimpleAsyncHTTP;

	sub new { die "menu-check: the menu must not issue a Discogs request\n" }
	sub get { die "menu-check: the menu must not issue a Discogs request\n" }
}

# ---------------------------------------------------------------------------
# A real database and the real migrations.
# ---------------------------------------------------------------------------

my $dir = tempdir( CLEANUP => 1 );

my $dbh = DBI->connect( "dbi:SQLite:dbname=$dir/library.db", '', '', {
	RaiseError => 1, PrintError => 0, AutoCommit => 1,
} );

$dbh->do('PRAGMA foreign_keys = ON');
$dbh->do("ATTACH '$dir/squeezewax.db' AS squeezewax");

{
	no warnings 'once', 'redefine';
	*Slim::Schema::dbh = sub { $dbh };
}

# Only the columns Library reads, plus library_track and library_album, which
# VirtualLibraries::rebuild fills and the owned view writes into.
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
$dbh->do('CREATE TABLE library_track (library TEXT, track INT, UNIQUE (library, track))');
$dbh->do('CREATE TABLE library_album (library TEXT, album INT, UNIQUE (library, album))');

my $incdir;

BEGIN {
	$incdir = tempdir( CLEANUP => 1 );
	mkdir "$incdir/Plugins";
	symlink "$Bin/../SqueezeWax", "$incdir/Plugins/SqueezeWax"
		or die "could not link the plugin into $incdir: $!\n";
	unshift @INC, $incdir;
}

require Plugins::SqueezeWax::Schema;
require Plugins::SqueezeWax::Library;
require Plugins::SqueezeWax::Ownership;
require Plugins::SqueezeWax::Menu;
require Plugins::SqueezeWax::View;

Plugins::SqueezeWax::Schema->_migrate($dbh);

{
	no warnings 'once', 'redefine';
	*Plugins::SqueezeWax::Schema::isReady = sub { 1 };
}

my $L = 'Plugins::SqueezeWax::Library';

# ---------------------------------------------------------------------------
# Fixtures.
# ---------------------------------------------------------------------------

my $nextTrack = 0;

# One album, its key taken from the real iterator rather than recomputed, so a
# fixture cannot drift from Library::_finish.
sub album {
	my ( $id, $title, %opt ) = @_;

	my $tracks = $opt{tracks} || 2;
	my $remote = $opt{remote} ? 1 : 0;

	for my $n ( 1 .. $tracks ) {
		$nextTrack++;
		# The url carries $nextTrack, not just the album id: the D1 block below
		# re-creates an album AT AN ID THAT WAS USED BEFORE, and urls derived
		# from the id alone would hand it the old album's key - which is the
		# one thing that block must not accidentally arrange.
		my $url = $remote ? "spotify://a$id-t$nextTrack" : "file:///a$id-t$nextTrack";

		$dbh->do( 'INSERT INTO tracks VALUES (?,?,?,?,?,?,?,?,?,?)', undef,
			$nextTrack, $id, md5_hex($url), $url, 100, 1, $n, $remote, 1, 'flc' );
	}

	$dbh->do( 'INSERT INTO albums (id, title) VALUES (?,?)', undef, $id, $title );

	return $L->albumKey($id);
}

# A discogs_match row, written as SQL: this suite reads rows, and driving a
# whole sync to produce each of the nine shapes below would test the sync.
# ownership-check.pl and queue-check.pl own the writing side.
sub match {
	my ( $key, %col ) = @_;

	$col{match_tier} ||= 'strict';

	my @cols = ( 'album_key', keys %col );
	my @vals = ( $key, values %col );
	my $marks = join ',', ('?') x @cols;

	$dbh->do( 'INSERT INTO squeezewax.discogs_match (' . join( ',', @cols )
		. ") VALUES ($marks)", undef, @vals );

	return $key;
}

# A blessed stand-in for Slim::Schema::Album. Blessed is what matters:
# AlbumInfo::menu inflates an UNblessed album from the url and bails out when it
# cannot, so a plain hashref would never reach a provider at all.
{
	package Test::Album;
	sub new  { my ( $class, $id ) = @_; bless { id => $id }, $class }
	sub id   { $_[0]->{id} }
	sub title { 'An Album' }
	sub artwork { 0 }
	sub coverArtExists { 0 }
}

{
	package Test::Track;
	sub new   { my ( $class, $album ) = @_; bless { album => $album }, $class }
	sub album  { $_[0]->{album} }
	sub url    { 'file:///a-track' }
	sub id     { 1 }
	sub remote  { 0 }
	sub title   { 'A Track' }
	sub coverid { 0 }
	sub coverArtExists { 0 }
}

# Our item as the user would get it, by driving the REAL menu. Returns the list
# of items our provider contributed - core's own items are dropped, since every
# one of them either fails against the stand-in album (inside menu()'s own eval,
# which is why they are harmless) or is not ours to assert.
sub albumMenu {
	my ($albumId) = @_;

	@WARNINGS = ();


	my $menu = Slim::Menu::AlbumInfo->menu( undef, 'file:///a-track',
		Test::Album->new($albumId), {} );

	return _ours( $menu->{items} );
}

sub trackMenu {
	my ($album) = @_;

	@WARNINGS = ();

	my $menu = Slim::Menu::TrackInfo->menu( undef, 'file:///a-track',
		Test::Track->new($album), {} );

	return _ours( $menu->{items} );
}

# Ours are the items whose name is one of our own tokens. The string stub below
# returns the token, so the name IS the token.
sub _ours {
	my ($items) = @_;

	return [ grep { ( $_->{name} || '' ) =~ /^PLUGIN_SQUEEZEWAX_/ } @{ $items || [] } ];
}

# As slimserver.pl:466-474 does, and BEFORE the plugin registers: init() resets
# the provider list, so a plugin registering first would be wiped. That ordering
# is real - PluginManager->load() runs at slimserver.pl:482, after the menu
# init block - and this suite reproduces it rather than assuming it.
Slim::Menu::AlbumInfo->init();
Slim::Menu::TrackInfo->init();

Plugins::SqueezeWax::Menu->init();

# ===========================================================================
# 1. Key agreement: the id LMS hands the menu reaches the row the pass wrote
# ===========================================================================

my %K;

$K{exact}       = album( 1, 'An Exact Match' );
$K{exact_conf}  = album( 2, 'A Contested Exact' );
$K{exact_norel} = album( 3, 'An Exact With No Release' );
$K{master}      = album( 4, 'A Version With A Tagged Master' );
$K{derived}     = album( 5, 'A Version With A Derived Master' );
$K{stale}       = album( 6, 'A Version With A Stale Derivation' );
$K{ver_conf}    = album( 7, 'A Contested Version' );
$K{ver_none}    = album( 8, 'A Version With No Master' );
$K{absent}      = album( 9, 'Not Owned' );
$K{unknown}     = album( 10, 'Never Looked At' );
$K{stream}      = album( 11, 'An Owned Stream', remote => 1 );

{
	my @walk;
	$L->eachAlbum( sub { push @walk, $_[0]; 1 } );

	is( scalar @walk, 11, 'the fixture library holds eleven albums' );

	my $mismatch = 0;
	for my $a (@walk) {
		my $key = $L->albumKey( $a->{album_id} );
		$mismatch++ if !defined $key || $key ne $a->{album_key};
	}

	is( $mismatch, 0,
		'albumKey agrees with the walk for every album - the menu reaches the row the pass wrote' );
}

# The rows. Each is one line of the plan §2 table.
match( $K{exact},       ownership => 'exact',   discogs_release_id => 1001 );
match( $K{exact_conf},  ownership => 'exact',   discogs_release_id => 1002,
       review_reason => 'conflict' );
match( $K{exact_norel}, ownership => 'exact' );
match( $K{master},      ownership => 'version', discogs_release_id => 1004,
       discogs_master_id => 9004 );
match( $K{derived},     ownership => 'version', discogs_release_id => 1005,
       derived_master_id => 9005, derived_from_release_id => 1005 );

# The stale one: the derivation was made for a release these tags no longer
# name. _effectiveMaster refuses it, and so must the link.
match( $K{stale},       ownership => 'version', discogs_release_id => 1006,
       derived_master_id => 9006, derived_from_release_id => 999 );

match( $K{ver_conf},    ownership => 'version', discogs_release_id => 1007,
       discogs_master_id => 9007, review_reason => 'conflict' );
match( $K{ver_none},    ownership => 'version', discogs_release_id => 1008 );
match( $K{absent},      ownership => 'absent',  discogs_release_id => 1009 );
match( $K{stream},      ownership => 'exact',   discogs_release_id => 1011 );

# ===========================================================================
# 2. The table in plan §2, row by row
# ===========================================================================

sub line   { my $i = shift; return $i->[0] && $i->[0]{name} }
sub link_  { my $i = shift; return $i->[1] && $i->[1]{weblink} }

{
	my $items = albumMenu(1);

	is( scalar @$items, 2, 'an exact match gets a line and a link' );
	is( line($items), 'PLUGIN_SQUEEZEWAX_MENU_OWN_PRESSING', '  ...saying you own this pressing' );
	is( $items->[1]{name}, 'PLUGIN_SQUEEZEWAX_MENU_LINK',
		'  ...and the link describes the album, not the copy' );
	is( link_($items), 'https://www.discogs.com/release/1001', '  ...pointing at the release page' );
	is( $items->[0]{type}, 'text', '  ...as a plain text item, core\'s own shape' );
	ok( !exists $items->[1]{rel}, '  ...and nothing carries a rel, so no nofollow' );
}

{
	my $items = albumMenu(2);

	is( scalar @$items, 1, 'a contested exact match gets a line and NO link' );
	is( line($items), 'PLUGIN_SQUEEZEWAX_MENU_OWN_PRESSING',
		'  ...the ownership line is still shown' );
}

{
	my $items = albumMenu(3);

	is( scalar @$items, 1, 'an exact match with no release id gets a line and no link' );
}

{
	my $items = albumMenu(4);

	is( link_($items), 'https://www.discogs.com/master/9004',
		'a version with a tagged master links to the master page' );
	is( line($items), 'PLUGIN_SQUEEZEWAX_MENU_OWN_VERSION',
		'  ...saying you own a version of this record' );
}

{
	my $items = albumMenu(5);

	is( link_($items), 'https://www.discogs.com/master/9005',
		'a version whose derived master still describes its release links to it' );
}

{
	my $items = albumMenu(6);

	is( scalar @$items, 1,
		'a version whose derivation is stale gets no link - _effectiveMaster refuses it' );
	is( line($items), 'PLUGIN_SQUEEZEWAX_MENU_OWN_VERSION', '  ...but keeps its line' );
}

{
	my $items = albumMenu(7);

	is( scalar @$items, 1, 'a contested version gets no link even with a master id' );
}

{
	my $items = albumMenu(8);

	is( scalar @$items, 1, 'a version with no master at all gets a line and no link' );
}

{
	my $items = albumMenu(9);

	is( scalar @$items, 0, 'an album the pass decided is absent gets no entry at all' );
}

{
	my $items = albumMenu(10);

	is( scalar @$items, 0, 'an album with no row gets no entry - the same as absent, to a user' );
}

# A release link is never built from a conflict row's release id, whatever the
# ownership: the row's two candidates disagree and neither is an answer.
{
	my @links = map { link_( albumMenu($_) ) } ( 2, 7 );

	ok( !grep( { defined $_ } @links ), 'no conflict row produces a link of any kind' );
}

# --- the track provider ----------------------------------------------------

{
	my $items = trackMenu( Test::Album->new(1) );

	is( scalar @$items, 2, 'the playing track of an owned album gets the same entry' );
	is( line($items), 'PLUGIN_SQUEEZEWAX_MENU_OWN_PRESSING', '  ...the same line' );
	is( link_($items), 'https://www.discogs.com/release/1001', '  ...and the same link' );
}

{
	my $items = trackMenu( Test::Album->new(9) );

	is( scalar @$items, 0, 'the playing track of an unowned album gets no entry' );
}

{
	my $items = trackMenu(undef);

	is( scalar @$items, 0,
		'a track with no library album - a stream that is not in the library - gets no entry' );
}

# ===========================================================================
# 3. D1: identity is album_key, and an album id that moved does not mislead
# ===========================================================================
#
# THE ASSERTION THIS SUITE EXISTS FOR. LMS reassigns albums.id on a full wipe,
# and on a retitle that re-creates the album. Nothing refreshes
# discogs_match.lms_album_id for an album the importer skips, so after such a
# move the column points at whatever album now holds that id - which is how a
# record you do not own gets shown as owned, silently.
#
# So: move an owned album's id WITHOUT touching discogs_match, and give the old
# id to a different album.
{
	# Album 1 is the owned exact match. Move it to 101 and put an unowned album
	# in its place at 1, tracks and all - exactly what a wipe-and-rescan does.
	$dbh->do('UPDATE tracks SET album = 101 WHERE album = 1');
	$dbh->do('UPDATE albums SET id = 101 WHERE id = 1');

	my $usurper = album( 1, 'Someone Else\'s Record' );

	isnt( $usurper, $K{exact}, 'the album now holding id 1 is a different record' );

	# The stale column is still there, still pointing at 1. Nothing in this step
	# reads it, and this is the fixture that proves so.
	$dbh->do( 'UPDATE squeezewax.discogs_match SET lms_album_id = 1 WHERE album_key = ?',
		undef, $K{exact} );

	my $moved = albumMenu(101);

	is( scalar @$moved, 2, 'the owned album is still found after its id changed' );
	is( link_($moved), 'https://www.discogs.com/release/1001',
		'  ...with its own release, not another album\'s' );

	my $wrong = albumMenu(1);

	is( scalar @$wrong, 0,
		'the album that inherited the old id is NOT shown as owned - D1' );
}

# ===========================================================================
# 4. The view is exactly the owned set
# ===========================================================================

# VirtualLibraries is not loaded here: it reaches the Prefs/Unicode chain this
# suite cuts, and what has to be right is WHAT THE CALLBACK INSERTS. So the
# callback is called the way rebuild() calls it - with the library id, after the
# library's rows have been deleted - and the insert is read back.
sub buildView {
	my $id = 'swowned';

	$dbh->do( 'DELETE FROM library_track WHERE library = ?', undef, $id );

	Plugins::SqueezeWax::View::_build($id);

	return $dbh->selectcol_arrayref(q{
		SELECT DISTINCT t.album
		  FROM library_track lt
		  JOIN tracks t ON t.id = lt.track
		 WHERE lt.library = ?
		 ORDER BY t.album
	}, undef, $id );
}

{
	my $albums = buildView();

	# Owned: the exact match (now at 101), the contested exact (2), the exact
	# with no release (3), the four version rows (4-7), the version with no
	# master (8) and the owned stream (11). Not: the absent album (9), the one
	# with no row (10), or the usurper that inherited id 1.
	is_deeply( $albums, [ 2, 3, 4, 5, 6, 7, 8, 11, 101 ],
		'the view holds exactly the albums the ownership column names' );

	# A contested album is in the view although the menu gives it no link. The
	# two are different questions: which record this is, and whether the album
	# is owned at all.
	ok( ( grep { $_ == 2 || $_ == 7 } @$albums ),
		'  ...including the conflict rows, which are owned but unlinkable' );

	ok( !grep( { $_ == 9 || $_ == 10 || $_ == 1 } @$albums ),
		'  ...and neither the absent album, the unknown one, nor the id-1 usurper' );

	# §13.10.3: a rip and a stream of one record are two owned albums. Album 11
	# is entirely remote, and every one of its tracks is in the view.
	my ($streamTracks) = $dbh->selectrow_array(q{
		SELECT COUNT(*) FROM library_track lt JOIN tracks t ON t.id = lt.track
		 WHERE lt.library = 'swowned' AND t.album = 11
	});

	is( $streamTracks, 2, 'every track of an owned all-remote album is in the view' );
}

# A rebuild follows the data: a record that leaves the collection leaves the
# view, and one that arrives joins it - with no rescan in between. This is the
# "press Sync collection now" path (plan §7.5).
{
	$dbh->do( "UPDATE squeezewax.discogs_match SET ownership = 'absent' WHERE album_key = ?",
		undef, $K{master} );

	my $albums = buildView();

	ok( !grep( { $_ == 4 } @$albums ), 'a version album that became absent drops out of the view' );

	$dbh->do( "UPDATE squeezewax.discogs_match SET ownership = 'version' WHERE album_key = ?",
		undef, $K{master} );

	$albums = buildView();

	ok( ( grep { $_ == 4 } @$albums ), '  ...and comes back when it is owned again' );
}

# The empty case is a library with nothing in it, not an error: a user who has
# never synced owns nothing as far as we know.
{
	$dbh->do("UPDATE squeezewax.discogs_match SET ownership = 'absent'");

	my $albums = buildView();

	is_deeply( $albums, [], 'an unsynced library builds an empty view rather than failing' );

	$dbh->do('DELETE FROM squeezewax.discogs_match');

	$albums = buildView();

	is_deeply( $albums, [], '  ...and so does one with no rows at all' );
}

# ===========================================================================
# 5. Zero requests, and every string defined
# ===========================================================================

# The transport above dies on new() or get(). Every menu built so far ran
# through it being loaded and none of them touched it, which is the assertion:
# a menu open spends no Discogs request and no rate budget (CLAUDE.md, one
# process one budget).
{
	my $died = 0;

	for my $id ( 1 .. 11 ) {
		eval { albumMenu($id); 1 } or $died++;
	}

	is( $died, 0, 'no menu open reaches the transport - zero Discogs requests' );

	ok( !grep( { /must not issue a Discogs request/ } @WARNINGS ),
		'  ...and none was attempted and swallowed' );
}

# ===========================================================================
# 6. The derive line: counts against pending, settled and stale rows
# ===========================================================================
#
# What the settings page says about the master-derive job. It exists because
# ownership goes on changing for up to 25 minutes after a scan, and a badge that
# moves on its own with nothing on screen to explain it is what §15.23 ran into.
#
# The rows are the four states §15.22 describes, and the count must read them
# the same way _pending does - which is why the predicate is interpolated from
# one definition rather than written twice.
{
	require Plugins::SqueezeWax::Derive;

	$dbh->do('DELETE FROM squeezewax.discogs_match');

	my $D = 'Plugins::SqueezeWax::Derive';

	is( $D->progress, undef,
		'an empty table has nothing pending, so the page shows no line' );

	# Identified, never looked at: pending.
	match( 'a' x 32, ownership => 'exact', discogs_release_id => 2001 );

	# Looked at, and the answer still describes this release: settled.
	match( 'b' x 32, ownership => 'exact', discogs_release_id => 2002,
	       derived_master_id => 9002, derived_from_release_id => 2002 );

	# Looked at, and Discogs said there is no master: ALSO settled. This is the
	# state that keeps the masterless releases from being re-fetched forever.
	match( 'c' x 32, ownership => 'exact', discogs_release_id => 2003,
	       derived_from_release_id => 2003 );

	# Looked at, but the tags have named a different release since: stale, and
	# therefore pending again.
	match( 'd' x 32, ownership => 'exact', discogs_release_id => 2004,
	       derived_master_id => 9004, derived_from_release_id => 1 );

	# No release id at all: not identified, so not the job's business.
	match( 'e' x 32, ownership => 'absent' );

	my $p = $D->progress;

	is( $p->{total},   4, 'the total counts identified releases, not rows or albums' );
	is( $p->{pending}, 2, '  ...and the pending count is the unsettled ones' );
	is( $p->{done},    2, '  ...with "no master" counted as settled, not as work left' );

	# Several albums can name one release, and one fetch settles all of them:
	# the job works in releases, so the line has to as well.
	match( 'f' x 32, ownership => 'exact', discogs_release_id => 2001 );

	$p = $D->progress;

	is( $p->{total},   4, 'a second album naming a release already counted does not inflate the total' );
	is( $p->{pending}, 2, '  ...nor the pending count' );

	# Nothing left to do: no line at all, rather than "4 of 4".
	$dbh->do('UPDATE squeezewax.discogs_match SET derived_from_release_id = discogs_release_id');

	is( $D->progress, undef,
		'a settled library shows no derive line rather than a complete one' );
}

# The username is a pref, never a row: §9.5 stores conclusions, not Content, and
# a Discogs account name is neither.
{
	my $found = 0;

	for my $table (qw(discogs_match discogs_no_match discogs_sync_state discogs_meta)) {
		my $cols = $dbh->selectall_arrayref("PRAGMA squeezewax.table_info($table)");

		$found++ if grep { $_->[1] =~ /user/i } @$cols;
	}

	is( $found, 0, 'no table of ours has anywhere to put a Discogs username' );
}

is_deeply( \@MISSING_STRINGS, [],
	'every string the menu asks for is defined in strings.txt' );

done_testing();
