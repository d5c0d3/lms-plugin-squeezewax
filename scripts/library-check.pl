#!/usr/bin/env perl
#
# Offline exercise of Plugins::SqueezeWax::Library's album iterator.
#
# No LMS instance is needed. A scratch SQLite database stands in for library.db
# with just the tracks columns the iterator reads, and Slim::Schema->dbh is
# stubbed to hand it over. That is enough to prove the grouping, the digest, the
# timestamp handling and the candidate pick, none of which depend on LMS.
#
# What it cannot prove: that Slim::Schema->dbh exists or returns what we think.
# Per CLAUDE.md every Slim::* call still has to be found in refs/ and cited.
#
# Usage: scripts/library-check.pl

use strict;
use warnings;

# Slim::Utils::Log reads these as compile-time constants in package main.
use constant SCANNER  => 0;
use constant PERFMON  => 0;
use constant DEBUGLOG => 1;
use constant INFOLOG  => 1;

use Config;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

# Loaded before the BEGIN below puts refs/slimserver on @INC, so this is the
# host's Test::More rather than the 2008-era copy refs ships, which has no
# done_testing. schema-check.pl relies on the same ordering.
use Test::More;

# Same @INC dance as schema-check.pl, for the same reason: DBI and DBD::SQLite
# come from refs/slimserver so we run against the versions LMS ships. See that
# script's comment for why the order matters.
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

	# Library.pm legitimately `use Slim::Schema` - Slim/Plugin/OnlineLibraryBase.pm:11
	# does the same - but loading it offline fails on a JSON::XS XS mismatch deep in
	# the dependency chain. Mark it loaded and supply only ->dbh, which is the one
	# thing the iterator calls.
	$INC{'Slim/Schema.pm'} = 1;
}

use DBI;
use Digest::MD5 qw(md5_hex);

# Same stubbing as schema-check.pl: logger() is called at file scope, and we do
# not want the real Slim::Utils::Log dragged in.
BEGIN {
	$INC{'Slim/Utils/Log.pm'} = 1;

	no strict 'refs';
	*{'Slim::Utils::Log::logger'}   = sub { Test::StubLogger->new };
	*{'Slim::Utils::Log::logError'} = sub { };
	*{'Slim::Utils::Log::import'}   = sub {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::logger"}   = \&Slim::Utils::Log::logger;
		*{"${caller}::logError"} = \&Slim::Utils::Log::logError;
	};

	*{'main::SCANNER'}  = sub () { 0 };
	*{'main::INFOLOG'}  = sub () { 0 };
	*{'main::DEBUGLOG'} = sub () { 0 };
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

use lib "$Bin/..";

# Loaded by file path; the package inside declares Plugins::SqueezeWax::Library.
require SqueezeWax::Library;

my $L = 'Plugins::SqueezeWax::Library';

my $dir = tempdir( CLEANUP => 1 );
my $dbh = DBI->connect( "dbi:SQLite:dbname=$dir/library.db", '', '', {
	RaiseError => 1, PrintError => 0, AutoCommit => 1,
} );

{
	no warnings 'once';
	*Slim::Schema::dbh = sub { $dbh };
}

# Only the columns the iterator reads. Types match SQL/SQLite/schema_16_up.sql.
$dbh->do(q{
	CREATE TABLE tracks (
		id INTEGER PRIMARY KEY, album INT, urlmd5 TEXT, url TEXT,
		timestamp INT, disc INT, tracknum INT, remote INT, audio INT,
		content_type TEXT
	)
});
$dbh->do('CREATE TABLE albums (id INTEGER PRIMARY KEY, title TEXT)');

my $insert = $dbh->prepare('INSERT INTO tracks VALUES (?,?,?,?,?,?,?,?,?,?)');

# album 1: three local tracks, inserted deliberately out of urlmd5 order so the
#          ORDER BY is doing the work rather than the insertion order
$insert->execute( 1, 1, md5_hex('c'), 'file:///c', 300, 1, 3, 0, 1, 'flc' );
$insert->execute( 2, 1, md5_hex('a'), 'file:///a', 100, 1, 1, 0, 1, 'flc' );
$insert->execute( 3, 1, md5_hex('b'), 'file:///b', 900, 1, 2, 0, 1, 'flc' );

# album 2: one local, one remote. The remote row's NULL timestamp is the normal
#          case, not an edge case - see Library::_finish.
$insert->execute( 4, 2, md5_hex('d'), 'file:///d', 50, 1, 1, 0, 1, 'flc' );
$insert->execute( 5, 2, md5_hex('e'), 'spotify://x', undef, 1, 2, 1, 1, 'flc' );

# album 3: entirely remote
$insert->execute( 6, 3, md5_hex('f'), 'spotify://y', undef, 1, 1, 1, 1, 'flc' );

# album 4: only a non-qualifying content_type, so it must never be emitted
$insert->execute( 7, 4, md5_hex('g'), 'file:///g', 10, 1, 1, 0, 1, 'cpl' );

# album 5: a track with audio = 0
$insert->execute( 8, 5, md5_hex('h'), 'file:///h', 10, 1, 1, 0, 0, 'flc' );

$dbh->do("INSERT INTO albums VALUES (1, 'One'), (2, 'Two'), (3, 'Three'), (4, 'Four'), (5, 'Five')");

my @albums;
my $seen = $L->eachAlbum( sub { push @albums, $_[0]; 1 } );

is( $seen, 3, 'three albums emitted' );
is( scalar @albums, 3, '  ...and three passed to the callback' );

my %by = map { $_->{album_id} => $_ } @albums;

# --- zero qualifying tracks yields no key, by construction ----------------
ok( !$by{4}, 'an album whose only track is a non-audio content_type is never emitted' );
ok( !$by{5}, 'an album whose only track has audio = 0 is never emitted' );

# md5_hex('') is a single constant every empty album would collide on, so the
# guard being structural rather than conditional is the point.
my $emptyDigest = md5_hex('');
ok( !grep( { $_->{album_key} eq $emptyDigest } @albums ), 'no album carries md5_hex("")' );

# --- the digest matches the per-album form exactly -------------------------
# The streaming query orders by (album, urlmd5); the per-album form step 2
# specified orders by urlmd5 within one album. These must agree or a future
# change of shape would silently orphan every existing match row.
is( $by{1}->{album_key},
	md5_hex( join '', sort ( md5_hex('a'), md5_hex('b'), md5_hex('c') ) ),
	'album_key equals the sorted-urlmd5 digest of the per-album form' );

is( length $by{1}->{album_key}, 32, 'album_key satisfies the CHECK(length = 32)' );

# --- timestamps ------------------------------------------------------------
is( $by{1}->{source_timestamp}, 900, 'source_timestamp is the max over local tracks' );
is( $by{2}->{source_timestamp}, 50,
	'a NULL remote timestamp is skipped rather than compared' );
is( $by{3}->{source_timestamp}, undef,
	'an all-remote album has no source_timestamp, so it can never skip' );

# --- local/remote counts ---------------------------------------------------
is( $by{1}->{local_tracks},  3, 'local_tracks counts local only' );
is( $by{1}->{remote_tracks}, 0, 'remote_tracks is zero for a local album' );
is( $by{2}->{local_tracks},  1, 'a mixed album counts one local' );
is( $by{2}->{remote_tracks}, 1, '  ...and one remote' );
is( $by{3}->{local_tracks},  0,
	'an all-remote album has no local tracks, which is what Strict skips on' );

# --- candidate pick --------------------------------------------------------
is_deeply( $by{1}->{candidates}, [ 'file:///a', 'file:///b' ],
	'candidates are the two lowest by (disc, tracknum, url), not by urlmd5' );

# Regression: a [0..1] slice on a one-element list yields a read-only undef,
# and map aliases $_ to it, so $_->{url} dies rather than returning one
# candidate. Single-track albums are common (singles, DJ mixes).
is_deeply( $by{2}->{candidates}, ['file:///d'],
	'a single-track album yields one candidate rather than dying' );
is_deeply( $by{3}->{candidates}, [],
	'an all-remote album yields no candidates' );

# --- the callback can stop the walk ---------------------------------------
my $stopped = 0;
my $count = $L->eachAlbum( sub { $stopped++; return 0 } );
is( $stopped, 1, 'returning false from the callback stops the walk' );

# --- albumTitle is a display lookup, never identity ------------------------
is( $L->albumTitle(1), 'One', 'albumTitle reads the title' );
is( $L->albumTitle(999), undef, 'albumTitle on a missing album is undef, not fatal' );

done_testing();
