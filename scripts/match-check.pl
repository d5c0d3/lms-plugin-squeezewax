#!/usr/bin/env perl
#
# Offline exercise of Plugins::SqueezeWax::Match.
#
# §3b's two statements are dead code on a real server at build-order step 3
# commit 4 - discogs_match has no rows until commit 5 - so this is the only
# coverage they get, and the match_tier = 'manual' exclusion has no other test
# at all. That clause is what stops a settings change discarding a user's own
# pressing choice, so it is worth a scratch database.
#
# Usage: scripts/match-check.pl

use strict;
use warnings;

use constant SCANNER  => 0;
use constant PERFMON  => 0;
use constant DEBUGLOG => 1;
use constant INFOLOG  => 1;

use Config;
use File::Temp qw(tempdir);
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

	$INC{'Slim/Schema.pm'}    = 1;
	$INC{'Slim/Utils/Log.pm'} = 1;

	# Slim::Music::Import reaches Slim::Utils::DateTime -> Slim::Utils::Unicode,
	# which needs an initialised OSDetect. Only stillScanning is called.
	$INC{'Slim/Music/Import.pm'} = 1;
	{
		no strict 'refs';
		*{'Slim::Music::Import::stillScanning'} = sub { $main::SCANNING };
	}

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

use DBI;

# Match.pm has a real `use Plugins::SqueezeWax::Schema`, so unlike the other
# suites it needs the Plugins/SqueezeWax layout LMS resolves against rather than
# a by-file-path require. Build it, the same way syntax-check.sh does.
my $incdir;

BEGIN {
	$incdir = tempdir( CLEANUP => 1 );
	mkdir "$incdir/Plugins";
	symlink "$Bin/../SqueezeWax", "$incdir/Plugins/SqueezeWax"
		or die "could not link the plugin into $incdir: $!\n";
	unshift @INC, $incdir;
}

require Plugins::SqueezeWax::Schema;
require Plugins::SqueezeWax::Match;

my $S = 'Plugins::SqueezeWax::Schema';
my $M = 'Plugins::SqueezeWax::Match';

my $dir = tempdir( CLEANUP => 1 );
my $dbh = DBI->connect( "dbi:SQLite:dbname=$dir/library.db", '', '', {
	RaiseError => 1, PrintError => 0, AutoCommit => 1,
} );
$dbh->do("ATTACH '$dir/squeezewax.db' AS squeezewax");

{
	no warnings 'once';
	*Slim::Schema::dbh = sub { $dbh };
}

# Build the real schema through the real migration runner.
$S->_migrate($dbh);

sub seed {
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');

	# One row per match_tier, all with a source_timestamp set so a NULL after
	# the fact is unambiguous.
	my $i = 0;
	for my $tier (qw(strict structural fuzzy manual)) {
		my $key = substr( $tier . ( 'x' x 32 ), 0, 32 );
		$dbh->do(
			'INSERT INTO squeezewax.discogs_match
			 (album_key, match_tier, state, discogs_release_id, source_timestamp)
			 VALUES (?,?,?,?,?)',
			undef, $key, $tier, 'confirmed', 1000 + $i++, 555
		);
	}

	for my $tier (qw(strict structural)) {
		$dbh->do(
			'INSERT INTO squeezewax.discogs_no_match (album_key, tier, source_timestamp, checked_at)
			 VALUES (?,?,?,?)',
			undef, substr( 'n' . $tier . ( 'y' x 32 ), 0, 32 ), $tier, 555, 1
		);
	}
}

sub tierTimestamp {
	my $tier = shift;
	my ($ts) = $dbh->selectrow_array(
		'SELECT source_timestamp FROM squeezewax.discogs_match WHERE match_tier = ?',
		undef, $tier
	);
	return $ts;
}

sub noMatchTiers {
	return join ',', sort map { $_->[0] } @{
		$dbh->selectall_arrayref('SELECT tier FROM squeezewax.discogs_no_match')
	};
}

# --- the guard: a broken schema refuses rather than half-applying ----------
{
	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Schema::isReady = sub { 0 };
	local *Plugins::SqueezeWax::Schema::lastError = sub { 'pretend failure' };

	seed();
	is( $M->invalidateStrict, undef,
		'invalidateStrict refuses when the schema is not ready' );
	is( tierTimestamp('strict'), 555,
		'  ...and changes nothing, rather than half-applying' );
}

# --- _writeOk: the server defers to a running scan, the scanner does not ---
# The rule used to be stated in Match.pm's header and enforced in Settings.pm,
# which left every new caller to remember it. These pin the branch.
{
	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Schema::isReady = sub { 1 };

	local $main::SCANNING = 0;
	ok( $M->_writeOk, 'the server may write when no scan is running' );

	local $main::SCANNING = 1;
	ok( !$M->_writeOk, 'the server refuses to write while a scan is running' );

	seed();
	is( $M->invalidateStrict, undef, '  ...so invalidateStrict is a no-op then' );
	is( tierTimestamp('strict'), 555, '  ...and changes nothing' );
}

# The policy itself, exhaustively. main::SCANNER is a compile-time constant that
# Perl inlines, so `return 1 if main::SCANNER` cannot be flipped in one process -
# and the scanner branch is the one whose removal would silently stop the
# importer writing anything at all. Hence _writeRefusal being a pure function of
# its three inputs.
my $refusal = \&Plugins::SqueezeWax::Match::_writeRefusal;

#                     ready  scanner  scanning
is( $refusal->( 1, 0, 0 ), undef, 'server, no scan: allowed' );
is( $refusal->( 1, 1, 0 ), undef, 'scanner, no scan: allowed' );
is( $refusal->( 1, 1, 1 ), undef,
	'scanner during a scan: allowed - it holds the lock and is entitled to it' );
like( $refusal->( 1, 0, 1 ), qr/scan is running/,
	'server during a scan: refused, because BEGIN IMMEDIATE locks our file too' );
like( $refusal->( 0, 0, 0 ), qr/not ready/, 'unusable schema: refused' );
like( $refusal->( 0, 1, 1 ), qr/not ready/,
	'unusable schema outranks everything, including the scanner exemption' );

{
	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Schema::isReady = sub { 1 };
	local $main::SCANNING = 0;

	seed();

	is( noMatchTiers(), 'strict,structural', 'both no-match tiers seeded' );

	my $rows = $M->invalidateStrict;

	ok( defined $rows, 'invalidateStrict reports rows affected' );

	# --- discogs_no_match: strict gone, structural kept -------------------
	is( noMatchTiers(), 'structural',
		'strict no-match rows are deleted, structural rows kept' );

	# --- discogs_match: strict NULLed, everything else untouched ----------
	is( tierTimestamp('strict'), undef,
		'a strict match row has its source_timestamp NULLed, so it is re-examined' );

	# THE clause that protects a user decision. It has no other test.
	is( tierTimestamp('manual'), 555,
		"a match_tier = 'manual' row is untouched - the user's pressing choice survives" );

	is( tierTimestamp('structural'), 555, 'a structural row is untouched' );
	is( tierTimestamp('fuzzy'),      555, 'a fuzzy row is untouched' );

	# --- the strict row survives, it is not deleted -----------------------
	# §2a's rule is never delete a row that carries a decision, and every row
	# this predicate touches may carry one. Invalidation must never be the thing
	# that removes a row.
	my ($count) = $dbh->selectrow_array(
		'SELECT COUNT(*) FROM squeezewax.discogs_match WHERE match_tier = ?', undef, 'strict'
	);
	is( $count, 1, 'the strict row is NULLed, never deleted' );

	my ($release) = $dbh->selectrow_array(
		'SELECT discogs_release_id FROM squeezewax.discogs_match WHERE match_tier = ?',
		undef, 'strict'
	);
	is( $release, 1000, '  ...and keeps its release id' );

	# --- NULL never compares equal, which is what forces re-examination ---
	my ($skippable) = $dbh->selectrow_array(
		'SELECT COUNT(*) FROM squeezewax.discogs_match
		  WHERE match_tier = ? AND source_timestamp = ?', undef, 'strict', 555
	);
	is( $skippable, 0, 'the NULLed row cannot match a timestamp, so it cannot skip' );

	# --- idempotent -------------------------------------------------------
	ok( defined $M->invalidateStrict, 'a second invalidation is harmless' );
	is( tierTimestamp('manual'), 555, '  ...and still leaves manual alone' );
}

# --- the Strict write path -----------------------------------------------
{
	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Schema::isReady = sub { 1 };
	local $main::SCANNING = 0;

	my $key = 'w' x 32;

	my $album = {
		album_key        => $key,
		album_id         => 42,
		title            => 'Kind of Blue',
		artist           => 'Miles Davis',
		source_timestamp => 900,
		local_tracks     => 5,
	};

	sub row {
		return Slim::Schema->dbh->selectrow_hashref(
			'SELECT * FROM squeezewax.discogs_match WHERE album_key = ?', undef, $_[0]
		);
	}

	sub noMatchRow {
		return Slim::Schema->dbh->selectrow_hashref(
			'SELECT * FROM squeezewax.discogs_no_match WHERE album_key = ? AND tier = ?',
			undef, $_[0], 'strict'
		);
	}

	my $M = 'Plugins::SqueezeWax::Match';

	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');

	# A clean hit IDENTIFIES. It does not confirm: confirmation means the release
	# is in the collection, which the scanner cannot check (decisions §13.4,
	# §15.3, design §3 node E). Whatever this case says, it must not say that a
	# tag hit settles ownership.
	is( $M->recordStrict( $album, { id => 123, master_id => 9 }, undef ), 'identified',
		'a clean hit returns identified, not confirmed' );
	my $r = row($key);
	is( $r->{discogs_release_id}, 123,         '  ...with the release id' );
	is( $r->{discogs_master_id},  9,           '  ...and the master id' );
	is( $r->{state},              'candidate', '  ...state candidate - only the ownership pass promotes' );
	is( $r->{match_tier},         'strict',    '  ...tier strict' );
	is( $r->{source_timestamp},   900,         '  ...and the source timestamp' );

	# All THREE snapshot columns, captured at identification rather than at
	# promotion (§15.4). snapshot_artist was written by nothing before step 4,
	# which left orphan recovery unable to match anything (§15.5).
	is( $r->{snapshot_album_title}, 'Kind of Blue', '  ...snapshot_album_title is captured' );
	is( $r->{snapshot_track_count}, 5,              '  ...snapshot_track_count is captured' );
	is( $r->{snapshot_artist},      'Miles Davis',  '  ...snapshot_artist is captured too' );

	# no tag at all, over an IDENTIFIED row: the row is kept, not deleted. The
	# narrow delete does not reach it - it has a release id and a snapshot, and
	# those are the clauses that protect it now that its state is 'candidate'.
	is( $M->recordStrict( { %$album, source_timestamp => 950 }, {}, $M->strictState($key) ),
		'kept', 'no tag over an identified row keeps it' );
	is( row($key)->{discogs_release_id}, 123, '  ...release id survives' );
	is( row($key)->{state}, 'candidate', '  ...and so does its state' );
	is( row($key)->{source_timestamp}, 950, '  ...timestamp refreshed so it stops re-examining' );
	is( noMatchRow($key), undef, '  ...and no no-match row is written (invariant 1)' );

	# LMS reassigns albums.id on a full rescan, and this is the one path that
	# would otherwise leave a row carrying a stale id indefinitely.
	is( row($key)->{lms_album_id}, 42, '  ...and lms_album_id is refreshed too' );

	# The snapshot stores contributors.name as the iterator read it: bytes, never
	# decoded. Decoding one side and not the other would break every non-ASCII
	# artist silently - the recovery fit would simply never match (§2.3).
	{
		my $utf8Key  = 'b' x 32;
		my $utf8Name = "Bj\xc3\xb6rk";    # "Björk" as UTF-8 bytes
		$dbh->do('DELETE FROM squeezewax.discogs_match');
		$M->recordStrict(
			{ %$album, album_key => $utf8Key, artist => $utf8Name, title => 'Vespertine' },
			{ id => 321 }, undef
		);
		is( row($utf8Key)->{snapshot_artist}, $utf8Name,
			'a non-ASCII artist is snapshotted byte-identical' );
		ok( !utf8::is_utf8( row($utf8Key)->{snapshot_artist} ),
			'  ...and comes back as bytes, not a decoded character string' );
	}

	# A no-match row followed by a clean hit must not leave both (invariant 1).
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');
	$M->recordStrict( $album, {}, undef );
	ok( noMatchRow($key), 'a no-tag album gets a no-match row' );
	$M->recordStrict( $album, { id => 555 }, $M->strictState($key) );
	is( noMatchRow($key), undef,
		'a later clean hit clears the no-match row rather than leaving both' );
	is( row($key)->{discogs_release_id}, 555, '  ...and records the match' );

	# a fresh conflict writes NULL
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	is( $M->recordStrict( $album, { conflict => ['A=1','B=2'] }, undef ), 'candidate',
		'a fresh conflict lands in the review queue' );
	is( row($key)->{discogs_release_id}, undef,
		'  ...with a NULL release id, per §3a - no first-wins by another name' );
	is( row($key)->{state}, 'candidate', '  ...state candidate' );

	# §15.4: a conflict row NEVER carries a snapshot. A snapshot on one would
	# make the narrow delete below unreachable, and the row would advertise a
	# conflict forever in a queue that cannot render it.
	is( row($key)->{snapshot_album_title}, undef, '  ...and snapshot_album_title is NULL' );
	is( row($key)->{snapshot_track_count}, undef, '  ...snapshot_track_count is NULL' );
	is( row($key)->{snapshot_artist},      undef, '  ...snapshot_artist is NULL' );

	# a conflict whose tags then disappear: the row is DELETED and a no-match
	# written. This is §2a's one permitted deletion.
	is( $M->recordStrict( $album, {}, $M->strictState($key) ), 'none',
		'a conflict row whose tags are gone becomes a no-match' );
	is( row($key), undef, '  ...the phantom conflict row is deleted' );
	ok( noMatchRow($key), '  ...and a no-match row replaces it' );
	is( noMatchRow($key)->{source_timestamp}, 900, '  ...carrying the source timestamp' );

	# THE TRANSITION §3a DID NOT COVER: a conflict over an existing IDENTIFIED
	# row keeps the incumbent id rather than NULLing it. The demotion to
	# 'candidate' marks it unresolved for the review queue - it is not what
	# stops the badge, which reads the ownership column (design §4), and over an
	# identified row it changes no value, since identification already writes
	# 'candidate'.
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');
	$M->recordStrict( $album, { id => 123 }, undef );

	is( $M->recordStrict( $album, { conflict => ['A=123','B=456'] }, $M->strictState($key) ),
		'candidate', 'a conflict over an identified row records the conflict' );
	is( row($key)->{state}, 'candidate', '  ...state candidate' );
	is( row($key)->{discogs_release_id}, 123,
		'  ...but the adjudicated id is KEPT, not NULLed - §2a protects a decision' );

	# The snapshots of the row it landed on survive, because _recordConflict's
	# ON CONFLICT list does not name them. §15.4 bars a conflict from CAPTURING
	# a snapshot; it does not ask an existing one to be thrown away, and
	# throwing it away would cost the album its orphan recovery over a tagging
	# mistake. Described here, not changed.
	is( row($key)->{snapshot_album_title}, 'Kind of Blue',
		'  ...and the identification\'s snapshot_album_title is carried through' );
	is( row($key)->{snapshot_track_count}, 5,  '  ...along with snapshot_track_count' );
	is( row($key)->{snapshot_artist}, 'Miles Davis', '  ...and snapshot_artist' );

	# manual is outside all of it
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do(
		'INSERT INTO squeezewax.discogs_match
		 (album_key, match_tier, state, discogs_release_id, source_timestamp, lms_album_id)
		 VALUES (?,?,?,?,?,?)',
		undef, $key, 'manual', 'confirmed', 777, 100, 1
	);

	is( $M->recordStrict( $album, { id => 123 }, $M->strictState($key) ), 'manual',
		'a manual row is never overwritten, even by a clean hit' );
	is( row($key)->{discogs_release_id}, 777, "  ...the user's pressing choice survives" );
	is( row($key)->{match_tier}, 'manual', '  ...and stays manual' );

	# but the cheap columns ARE refreshed, or the importer would re-examine it
	# on every scan forever - which is why the ON CONFLICT ... WHERE form does
	# not work here, verified: it leaves the row completely untouched.
	is( row($key)->{source_timestamp}, 900, '  ...while source_timestamp is refreshed' );
	is( row($key)->{lms_album_id}, 42, '  ...along with lms_album_id' );
}

# --- hasAnyStrictMatch: "have the tags ever worked", not "did this run work" -
# The importer's anomaly warning uses this to tell a broken configuration from
# a run that examined one untagged album in a library that is otherwise fine.
#
# A hit is a clean TAG hit - a strict row with a release id, in any state - and
# not an ownership decision. Keying on state = 'confirmed' was correct only
# while _recordMatch confirmed; since §13.4 nothing is confirmed until step 7,
# so that predicate would answer 0 for every library and fire the warning on
# every scan, telling users to check tag names that are fine. That exact
# regression has been observed on hardware twice.
#
# The 0-cases all run before either 1-case: the question is "any row", so once
# one qualifies nothing after it can show a 0.
{
	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Schema::isReady = sub { 1 };

	$dbh->do('DELETE FROM squeezewax.discogs_match');
	is( $M->hasAnyStrictMatch, 0, 'no rows at all: nothing has ever matched' );

	$dbh->do(
		"INSERT INTO squeezewax.discogs_match (album_key, match_tier, state)
		 VALUES (?, 'strict', 'candidate')", undef, 'c' x 32
	);
	is( $M->hasAnyStrictMatch, 0,
		'a strict row with a NULL release id does not count - a fresh conflict named nothing' );

	# CHANGED AT STEP 4, AND NOT BY ADDING A RELEASE ID. This row is a strict
	# 'confirmed' with no release id; under the old state predicate it counted,
	# and under the tag predicate it must not. A row that names no release is
	# not evidence that the tag names work, whatever its state says. Giving it
	# an id to keep the old answer would delete the case.
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match (album_key, match_tier, state)
		 VALUES (?, 'strict', 'confirmed')", undef, 'e' x 32
	);
	is( $M->hasAnyStrictMatch, 0,
		'a strict confirmed row with a NULL release id does not count either' );

	$dbh->do(
		"INSERT INTO squeezewax.discogs_match (album_key, match_tier, state, discogs_release_id)
		 VALUES (?, 'manual', 'confirmed', 901)", undef, 'd' x 32
	);
	is( $M->hasAnyStrictMatch, 0,
		'a manual match does not count even with a release id - the user chose it, not the tags' );

	# Both states count, which is the whole point: identification writes
	# 'candidate', so if this one failed the warning would fire on every scan.
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match (album_key, match_tier, state, discogs_release_id)
		 VALUES (?, 'strict', 'candidate', 902)", undef, 'f' x 32
	);
	is( $M->hasAnyStrictMatch, 1,
		'a strict candidate WITH a release id is enough - that is what identification writes' );

	$dbh->do(
		"INSERT INTO squeezewax.discogs_match (album_key, match_tier, state, discogs_release_id)
		 VALUES (?, 'strict', 'confirmed', 903)", undef, 'g' x 32
	);
	is( $M->hasAnyStrictMatch, 1,
		'and a strict confirmed row with a release id still counts, as it always did' );
}

# --- invariant 1 is detected, for free, by the skip query -----------------
{
	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Schema::isReady = sub { 1 };

	my $key = 'v' x 32;

	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match (album_key, match_tier, state, source_timestamp)
		 VALUES (?, 'strict', 'confirmed', 1)", undef, $key
	);
	$dbh->do(
		"INSERT INTO squeezewax.discogs_no_match (album_key, tier, source_timestamp, checked_at)
		 VALUES (?, 'strict', 1, 1)", undef, $key
	);

	my $state = Plugins::SqueezeWax::Match->strictState($key);

	is( $state->{src}, 'match',
		'with rows in both tables the match row wins - it may carry a decision' );
}

done_testing();
