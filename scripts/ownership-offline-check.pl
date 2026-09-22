#!/usr/bin/env perl
#
# Replay the ownership pass against copies of a real library, with a
# collection you can alter.
#
# NOT PART OF scripts/check-all.sh, and deliberately so: every other suite
# runs anywhere, and this one needs a real library.db and a real
# squeezewax.db, which only exist on a machine with a populated LMS. Running
# it is a deliberate act, and it takes its paths as arguments the way
# scripts/title-agreement.pl does, for the same reason - hardcoding either
# would make it unrepeatable on another machine.
#
# WHY IT EXISTS. Build-order steps 6-7's hardware check (6) is "remove a
# record from the Discogs collection and watch the pass react". Doing that for
# real mutates data this project does not own and cannot restore if a step
# fails, and asking an owner to edit their collection to test our code is a
# bad trade. This gets the same answer by removing the record from the
# COLLECTION LIST the pass is handed, which is the only place the pass ever
# sees it.
#
# WHAT IS REAL: Plugins::SqueezeWax::Ownership (apply, _apply, _decide,
# _indexCollection, _isOwnershipOnly, _write) and Plugins::SqueezeWax::Library
# (eachAlbum, ownershipArtists), with their real SQL, against real rows.
#
# WHAT IS NOT: the sync, the transport, Discogs, and LMS itself. This cannot
# prove that a real fetch hands the pass a changed list, nor that the live
# write path works in the server process. It proves what the pass DOES with a
# changed list. The hardware check stays open for the rest.
#
# NOTHING LIVE IS WRITTEN, and the script does not trust the caller to have
# passed a copy. Both databases are copied into a temp directory first, with
# SQLite's own online backup through a READ-ONLY handle, so it is safe to
# point at a running LMS's files. The temp directory goes away on exit.
#
# METHOD. Three sequential passes on one database, which is exactly how the
# real thing behaves - decisions 13.2, every sync re-derives every conclusion
# from scratch:
#     A   the collection as given            the "before"
#     B   minus the dropped release ids      the records leave
#     C   the collection as given again      the records come back
# A vs B isolates the removal. A vs C must be empty, or the pass is not
# reversible and 13.2 does not hold.
#
# Albums whose owned release is absent from the given collection conclude
# `absent` in all three passes and cancel out of every diff, so the dropped
# ids are the only variable. That is why a one-page fixture is a legitimate
# input even though it is 100 of 203 items: the figures in pass A are not the
# live figures and are not meant to be.
#
# Usage:
#   scripts/ownership-offline-check.pl <library.db> <squeezewax.db> \
#       [<collection.json>] [--drop=9701013,443973]
#
# <collection.json> defaults to scripts/fixtures/collection-page1.json, and
# --drop defaults to the two records steps 6-7 check (6) names: release
# 9701013 (Route 66, Nat King Cole), which gives an ownership-only row, and
# 443973 (Jagged Little Pill, Alanis Morissette), which gives a tagged exact
# row. Both are in that fixture.

use strict;
use warnings;

use Config;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

my $REPO = "$Bin/..";

BEGIN {
	my $libPath = "$Bin/../refs/slimserver";
	die "refs/slimserver not found at $libPath\n" unless -d $libPath;

	my $arch = $Config::Config{archname};
	$arch =~ s/^i[3456]86-/i386-/;
	$arch =~ s/gnu-//;

	my $pv = $Config{version};
	$pv =~ s/\.\d+$//;

	unshift @INC, grep { -d } (
		"$libPath/CPAN/arch/$pv/$arch",
		"$libPath/CPAN/arch/$pv/$arch/auto",
		"$libPath/CPAN/arch/$pv",
		"$libPath/lib",
		"$libPath/CPAN",
		$libPath,
	);
}

require DBI;
use JSON::XS ();

# Same stubbing as scripts/ownership-check.pl.
BEGIN {
	$INC{'Slim/Utils/Log.pm'}    = 1;
	$INC{'Slim/Schema.pm'}       = 1;
	$INC{'Slim/Music/Info.pm'}   = 1;
	$INC{'Slim/Music/Import.pm'} = 1;
	$INC{'Slim/Utils/Prefs.pm'}  = 1;
	$INC{'Slim/Formats.pm'}      = 1;

	no strict 'refs';
	*{'Slim::Music::Import::stillScanning'} = sub { 0 };
	*{'Slim::Utils::Prefs::preferences'}    = sub { Stub::Prefs->new };
	*{'Slim::Utils::Prefs::import'}         = sub {
		my $c = caller; no strict 'refs';
		*{$c . '::preferences'} = \&Slim::Utils::Prefs::preferences;
	};
	*{'Slim::Utils::Log::logger'}   = sub { Stub::Logger->new };
	*{'Slim::Utils::Log::logError'} = sub { };
	*{'Slim::Utils::Log::import'}   = sub {
		my $c = caller; no strict 'refs';
		*{"${c}::logger"}   = \&Slim::Utils::Log::logger;
		*{"${c}::logError"} = \&Slim::Utils::Log::logError;
	};
	*{'main::SCANNER'}   = sub () { 0 };
	*{'main::INFOLOG'}   = sub () { 1 };
	*{'main::DEBUGLOG'}  = sub () { 0 };
	*{'main::ISWINDOWS'} = sub () { 0 };
}

{ package Stub::Prefs;  sub new { bless {}, shift } sub get { [] } sub set { 1 } }
{ package Stub::Logger; sub new { bless {}, shift }
  sub error { shift; print "    LOG error: @_\n" }
  sub warn  { shift; print "    LOG warn: @_\n" }
  sub info  { shift; push @main::LOG, "@_"; return }
  sub debug {} sub is_info {1} sub is_debug {0} }

our @LOG;

my $incdir = tempdir( CLEANUP => 1 );
mkdir "$incdir/Plugins";
symlink "$REPO/SqueezeWax", "$incdir/Plugins/SqueezeWax" or die "symlink: $!\n";
unshift @INC, $incdir;

require Plugins::SqueezeWax::Ownership;
require Plugins::SqueezeWax::Library;
require Plugins::SqueezeWax::Match;
require Plugins::SqueezeWax::Schema;

my @drop;
my @paths;

for my $arg (@ARGV) {
	if ( $arg =~ /^--drop=(.*)$/ ) {
		@drop = grep { /^\d+$/ } split /\s*,\s*/, $1;
		next;
	}

	push @paths, $arg;
}

my ( $lib, $swx, $fixture ) = @paths;

$fixture ||= "$Bin/fixtures/collection-page1.json";
@drop = ( 9701013, 443973 ) unless @drop;

die <<"USAGE" unless defined $lib && defined $swx;
Usage: $0 <library.db> <squeezewax.db> [<collection.json>] [--drop=id,id]

Both databases are COPIED before anything runs; the originals are opened
read-only and never written. It is safe to point this at a running LMS.
USAGE

for my $f ( $lib, $swx, $fixture ) {
	die "not found: $f\n" unless -f $f;
}

# Copies, taken through SQLite's own online backup from a read-only handle.
# A plain file copy of a live database can tear against a concurrent write;
# this cannot, which is what makes pointing at a running LMS safe.
my $work = tempdir( CLEANUP => 1 );

sub _copy_db {
	my ( $from, $to ) = @_;

	my $src = DBI->connect( "dbi:SQLite:dbname=$from", '', '', {
		RaiseError        => 1,
		PrintError        => 0,
		AutoCommit        => 1,
		sqlite_open_flags => DBD::SQLite::OPEN_READONLY(),
	} );

	$src->sqlite_backup_to_file($to);
	$src->disconnect;

	return $to;
}

require DBD::SQLite;

print "working on copies in $work\n";
print "  library   : $lib\n";
print "  squeezewax: $swx\n";
print "  collection: $fixture\n";
printf "  dropping  : %s\n\n", join( ', ', @drop );

_copy_db( $lib, "$work/library.db" );
_copy_db( $swx, "$work/squeezewax.db" );

my $dbh = DBI->connect( "dbi:SQLite:dbname=$work/library.db", '', '',
	{ RaiseError => 1, PrintError => 0, AutoCommit => 1 } );
$dbh->do("ATTACH '$work/squeezewax.db' AS squeezewax");

{
	no warnings 'once', 'redefine';
	*Slim::Schema::dbh = sub { $dbh };
	# The real install's label: variousArtistsString is unset, so
	# Slim::Music::Info::variousArtistString() falls back to the English
	# VARIOUSARTISTS string (Slim/Music/Info.pm:1540-1543).
	*Slim::Music::Info::variousArtistString = sub { 'Various Artists' };
	# The suite attaches the database directly rather than through
	# postDBConnect, so the readiness flag was never set.
	*Plugins::SqueezeWax::Schema::isReady = sub { 1 };
}

# The collection, in the shape API/Async.pm:444-457 builds.
sub entries {
	my (%drop) = @_;

	open my $fh, '<:raw', $fixture or die "fixture: $!\n";
	local $/;
	my $data = JSON::XS::decode_json(<$fh>);
	close $fh;

	my @e;
	for my $r ( @{ $data->{releases} || [] } ) {
		next unless defined $r->{instance_id};
		next if $drop{ $r->{id} };
		my $b = $r->{basic_information} || {};
		push @e, {
			instance_id => $r->{instance_id},
			id          => $r->{id},
			master_id   => $b->{master_id},
			title       => $b->{title},
			artists     => [ map { $_->{name} } @{ $b->{artists} || [] } ],
		};
	}
	return \@e;
}

sub dump_rows {
	my %r;
	my $rows = $dbh->selectall_arrayref(
		q{SELECT album_key, lms_album_id, coalesce(match_tier,'-') t,
		        coalesce(state,'-') s, ownership,
		        coalesce(discogs_release_id,'-') rel,
		        coalesce(snapshot_track_count,'-') snap
		   FROM squeezewax.discogs_match}, { Slice => {} } );
	$r{ $_->{album_key} } = $_ for @$rows;
	return \%r;
}

sub run {
	my ( $label, $drop ) = @_;
	@LOG = ();
	my $e = entries(%$drop);
	my $rc = Plugins::SqueezeWax::Ownership->apply($e);
	my ($sum) = grep { /^ownership pass:/ } reverse @LOG;
	printf "  %s: %d entries -> %s\n", $label, scalar @$e, $rc;
	print  "    $sum\n";
	return dump_rows();
}

sub diff {
	my ( $from, $to, $label ) = @_;
	print "\n=== $label ===\n";
	my $n = 0;
	for my $k ( sort keys %$from ) {
		if ( !exists $to->{$k} ) {
			printf "  DELETED album %-6s tier=%s state=%s ownership=%s rel=%s\n",
				$from->{$k}{lms_album_id}, $from->{$k}{t}, $from->{$k}{s},
				$from->{$k}{ownership}, $from->{$k}{rel};
			$n++;
			next;
		}
		my @ch = grep { $from->{$k}{$_} ne $to->{$k}{$_} } qw(t s ownership rel snap);
		next unless @ch;
		printf "  CHANGED album %-6s rel=%s\n", $from->{$k}{lms_album_id}, $from->{$k}{rel};
		printf "      %-10s %s -> %s\n", $_, $from->{$k}{$_}, $to->{$k}{$_} for @ch;
		$n++;
	}
	for my $k ( sort keys %$to ) {
		next if exists $from->{$k};
		printf "  INSERTED album %-6s tier=%s state=%s ownership=%s rel=%s\n",
			$to->{$k}{lms_album_id}, $to->{$k}{t}, $to->{$k}{s},
			$to->{$k}{ownership}, $to->{$k}{rel};
		$n++;
	}
	print "  (no differences)\n" unless $n;
	print "  total rows differing: $n\n";
	return $n;
}

my %DROP = map { $_ => 1 } @drop;

print "LIVE state as copied: ", scalar( keys %{ dump_rows() } ), " rows\n\n";

print "PASS A - the collection as given (the 'before')\n";
my $A = run( 'A', {} );

print "\nPASS B - the dropped records have left the collection\n";
my $B = run( 'B', \%DROP );

print "\nPASS C - the dropped records are added back\n";
my $C = run( 'C', {} );

diff( $A, $B, 'A -> B : what removing ' . join( ', ', @drop ) . ' did' );
diff( $B, $C, 'B -> C : what adding them back did' );
my $n = diff( $A, $C, 'A -> C : restoration check (MUST be empty)' );

if ($n) {
	print "\n!! NOT RESTORED - the pass is not reversible on this data\n";
	exit 1;
}

print "\nRESTORED EXACTLY\n";
exit 0;
