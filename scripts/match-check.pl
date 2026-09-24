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

	# Importer.pm is loaded below for its pre-pass, which is at file scope and
	# so is reachable here - unlike startScan, whose body is inside
	# `if (main::SCANNER)` and is constant-folded away in this process.
	$INC{'Slim/Utils/Prefs.pm'}    = 1;
	$INC{'Slim/Formats.pm'}        = 1;
	$INC{'Slim/Utils/Progress.pm'} = 1;

	{
		no strict 'refs';
		*{'Slim::Utils::Prefs::preferences'} = sub { Test::StubPrefs->new };
		*{'Slim::Utils::Prefs::import'}      = sub {
			my $caller = caller;
			no strict 'refs';
			*{"${caller}::preferences"} = \&Slim::Utils::Prefs::preferences;
		};
	}

	no strict 'refs';
	*{'Slim::Utils::Log::logger'}   = sub { Test::StubLogger->new };
	*{'Slim::Utils::Log::addLogCategory'} = sub { Test::StubLogger->new };
	*{'Slim::Utils::Log::logError'} = sub { };
	*{'Slim::Utils::Log::import'}   = sub {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::logger"}   = \&Slim::Utils::Log::logger;
		*{"${caller}::logError"} = \&Slim::Utils::Log::logError;
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

{
	package Test::StubPrefs;
	sub new     { bless {}, shift }
	sub init    { 1 }
	sub get     { [] }
	sub set     { 1 }
	sub migrate { 1 }
}

our @LOG;

{
	package Test::StubLogger;
	sub new      { bless {}, shift }
	sub error    { }
	sub warn     { }
	sub info     { shift; push @main::LOG, "@_"; return }
	sub debug    { }
	sub is_info  { 1 }
	sub is_debug { 0 }
}

use DBI;
use Digest::MD5 qw(md5_hex);

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
require Plugins::SqueezeWax::Importer;

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

	# The pre-pass commits once, after its writes. AutoCommit is on here.
	*Slim::Schema::forceCommit = sub { 1 };
}

# Build the real schema through the real migration runner.
$S->_migrate($dbh);

sub seed {
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');

	# One row per match_tier, all with a source_timestamp set so a NULL after
	# the fact is unambiguous. Two tiers, not four: migration 3 narrowed
	# match_tier to ('strict','manual') per decisions §14.1/§14.3.
	my $i = 0;
	for my $tier (qw(strict manual)) {
		my $key = substr( $tier . ( 'x' x 32 ), 0, 32 );
		$dbh->do(
			'INSERT INTO squeezewax.discogs_match
			 (album_key, match_tier, state, discogs_release_id, source_timestamp)
			 VALUES (?,?,?,?,?)',
			undef, $key, $tier, 'confirmed', 1000 + $i++, 555
		);
	}

	# One tier, not two: migration 3 narrowed discogs_no_match to
	# CHECK (tier IN ('strict')) per decisions §15.6.
	for my $tier (qw(strict)) {
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

	is( noMatchTiers(), 'strict', 'the one v1 no-match tier is seeded' );

	@LOG = ();

	my $rows = $M->invalidateStrict;

	# Reachable only since INFOLOG was turned on (stub audit entry 5.3): the
	# line interpolates two live counters, so a rename or a typo in either
	# would have gone unseen while the expression was short-circuited away.
	my ($line) = grep { /strict cache invalidated/ } @LOG;

	ok( $line, 'the invalidation logs a summary at info' );
	like( $line, qr/\d+ no-match rows deleted/, '  ...naming the rows deleted' );
	like( $line, qr/\d+ match rows will be re-examined/,
		'  ...and the rows left to re-examine' );

	ok( defined $rows, 'invalidateStrict reports rows affected' );

	# --- discogs_no_match: emptied ----------------------------------------
	#
	# In v1 this is the whole of invalidateStrict's behaviour here, because
	# 'strict' is the only tier the CHECK admits (§15.6). The DELETE's
	# WHERE tier = 'strict' therefore has nothing left to be scoped against,
	# and its scoping is untested until v2 widens the CHECK - recorded in
	# TODO.md, 2026-09-20, under "Deferred by decision".
	is( noMatchTiers(), '', 'every no-match row is deleted' );

	# --- discogs_match: strict NULLed, everything else untouched ----------
	is( tierTimestamp('strict'), undef,
		'a strict match row has its source_timestamp NULLed, so it is re-examined' );

	# THE clause that protects a user decision. It has no other test - and
	# since migration 3 narrowed match_tier to ('strict','manual'), 'manual' is
	# also the only row left that proves the UPDATE is scoped by tier at all.
	# The structural and fuzzy rows that used to carry that second job cannot
	# be written any more (§14.1, §14.3).
	is( tierTimestamp('manual'), 555,
		"a match_tier = 'manual' row is untouched - the user's pressing choice survives" );

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

	# Step 8: the row is findable. Before this, a fresh conflict was identifiable
	# only by its NULL release id and an incumbent one not at all (§15.16 part 2).
	is( row($key)->{review_reason}, 'conflict', "  ...and review_reason is 'conflict'" );

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

	# THE ROW TODO 2026-09-19 COULD NOT FIND. strict, candidate, a non-NULL
	# release id and a full snapshot - identical in every column to a clean
	# identification. review_reason is the only thing that separates them, and
	# B1's pass reads it to decline promoting this row (§15.16 part 4).
	is( row($key)->{review_reason}, 'conflict',
		"  ...and an INCUMBENT conflict is marked 'conflict' too" );

	# A clean identification over it clears the mark: the tags now agree, so
	# there is nothing left to review (§15.16 part 3).
	$M->recordStrict( $album, { id => 456 }, $M->strictState($key) );
	is( row($key)->{review_reason}, undef,
		'a clean identification clears review_reason' );
	is( row($key)->{discogs_release_id}, 456, '  ...and records the new id' );

	# Tags removed from an INCUMBENT conflict: the narrow delete does not reach
	# it (it has a release id and a snapshot), so it takes the 'kept' path and
	# keeps its mark until the user rejects it - TODO 2026-09-07 ground (a),
	# §15.16 part 7. A FRESH conflict in the same situation is deleted outright,
	# asserted above.
	$dbh->do( "UPDATE squeezewax.discogs_match SET review_reason = 'conflict'" );
	is( $M->recordStrict( $album, {}, $M->strictState($key) ), 'kept',
		'an incumbent conflict whose tags are gone is kept, not deleted' );
	is( row($key)->{review_reason}, 'conflict',
		"  ...and keeps 'conflict' - the kept path names no reason column" );

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

# --- _resolveRelinks: unambiguous in BOTH directions, or nothing -----------
# A pure function, called as a plain function (CLAUDE.md's calling convention):
# no class name, no database, no logging. Every case here is decided on the two
# arrayrefs alone.
{
	no warnings 'once';
	*resolve = \&Plugins::SqueezeWax::Match::_resolveRelinks;

	my $orphan = sub {
		my ( $key, $artist, $title, $n ) = @_;
		return {
			album_key            => $key,
			match_tier           => 'strict',
			snapshot_artist      => $artist,
			snapshot_album_title => $title,
			snapshot_track_count => $n,
		};
	};

	my $miss = sub {
		my ( $key, $id, $artist, $title, $n ) = @_;
		return {
			album_key    => $key,
			album_id     => $id,
			artist       => $artist,
			title        => $title,
			local_tracks => $n,
		};
	};

	is_deeply( resolve( [], [] ), [], 'nothing in, nothing out' );
	is_deeply( resolve( undef, undef ), [], 'undef inputs are not fatal' );

	# --- the one-to-one case ---------------------------------------------
	my $pairs = resolve(
		[ $orphan->( 'o1', 'Miles Davis', 'Kind of Blue', 5 ) ],
		[ $miss->( 'n1', 77, 'Miles Davis', 'Kind of Blue', 5 ) ],
	);
	is( scalar @$pairs, 1, 'a one-to-one fit resolves' );
	is( $pairs->[0]{old_key},  'o1', '  ...naming the orphan to move' );
	is( $pairs->[0]{new_key},  'n1', '  ...the album_key to move it to' );
	is( $pairs->[0]{album_id}, 77,   '  ...and the new lms_album_id' );

	# --- one orphan, two identical misses ---------------------------------
	# Two copies of the same album appeared. Resolving this either way would
	# make the answer depend on scan order, so it resolves neither.
	is_deeply(
		resolve(
			[ $orphan->( 'o1', 'Miles Davis', 'Kind of Blue', 5 ) ],
			[
				$miss->( 'n1', 77, 'Miles Davis', 'Kind of Blue', 5 ),
				$miss->( 'n2', 78, 'Miles Davis', 'Kind of Blue', 5 ),
			],
		),
		[], 'an orphan fitting two misses resolves nothing'
	);

	# --- two identical orphans, one miss ----------------------------------
	is_deeply(
		resolve(
			[
				$orphan->( 'o1', 'Miles Davis', 'Kind of Blue', 5 ),
				$orphan->( 'o2', 'Miles Davis', 'Kind of Blue', 5 ),
			],
			[ $miss->( 'n1', 77, 'Miles Davis', 'Kind of Blue', 5 ) ],
		),
		[], 'a miss fitting two orphans resolves nothing'
	);

	# An ambiguous pair must not poison an unambiguous one beside it.
	$pairs = resolve(
		[
			$orphan->( 'o1', 'Miles Davis', 'Kind of Blue', 5 ),
			$orphan->( 'o2', 'Miles Davis', 'Kind of Blue', 5 ),
			$orphan->( 'o3', 'Bill Evans', 'Waltz for Debby', 7 ),
		],
		[
			$miss->( 'n1', 77, 'Miles Davis', 'Kind of Blue', 5 ),
			$miss->( 'n2', 78, 'Bill Evans', 'Waltz for Debby', 7 ),
		],
	);
	is( scalar @$pairs, 1, 'an ambiguous fit does not block an unambiguous one' );
	is( $pairs->[0]{old_key}, 'o3', '  ...and the unambiguous one is the pair' );

	# --- NULLs fit nothing -------------------------------------------------
	# This is why the backfill exists: every snapshot written before step 4 has
	# a NULL artist, and NULL equals nothing, so none of them could be relinked.
	is_deeply(
		resolve(
			[ $orphan->( 'o1', undef, 'Kind of Blue', 5 ) ],
			[ $miss->( 'n1', 77, 'Miles Davis', 'Kind of Blue', 5 ) ],
		),
		[], 'a NULL snapshot_artist fits nothing'
	);

	is_deeply(
		resolve(
			[ $orphan->( 'o1', 'Miles Davis', 'Kind of Blue', 5 ) ],
			[ $miss->( 'n1', 77, undef, 'Kind of Blue', 5 ) ],
		),
		[], 'an undef album artist on the new side fits nothing either'
	);

	# --- exact equality, no normalisation ---------------------------------
	is_deeply(
		resolve(
			[ $orphan->( 'o1', 'Miles Davis', 'Kind of Blue', 5 ) ],
			[ $miss->( 'n1', 77, 'Miles Davis', 'Kind of Blue', 6 ) ],
		),
		[], 'a differing track count is not a fit'
	);

	# --- bytes, not characters --------------------------------------------
	# The decoded form of the same name must NOT fit. If it did, the predicate
	# would be silently comparing one side decoded and the other not - which is
	# how every non-ASCII artist stops fitting in production while the tests
	# stay green.
	my $bytes   = "Bj\xc3\xb6rk";
	my $decoded = $bytes;
	utf8::decode($decoded);

	$pairs = resolve(
		[ $orphan->( 'o1', $bytes, 'Vespertine', 12 ) ],
		[ $miss->( 'n1', 77, $bytes, 'Vespertine', 12 ) ],
	);
	is( scalar @$pairs, 1, 'a non-ASCII artist fits its own bytes' );

	is_deeply(
		resolve(
			[ $orphan->( 'o1', $bytes, 'Vespertine', 12 ) ],
			[ $miss->( 'n1', 77, $decoded, 'Vespertine', 12 ) ],
		),
		[], '  ...and does NOT fit the same name decoded to characters'
	);
}

# --- the relink write: an UPDATE that carries everything but identity ------
{
	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Schema::isReady = sub { 1 };
	local $main::SCANNING = 0;

	my $old = 'o' x 32;
	my $new = 'n' x 32;

	my $seedOrphan = sub {
		my $tier = shift || 'strict';
		$dbh->do('DELETE FROM squeezewax.discogs_match');
		$dbh->do('DELETE FROM squeezewax.discogs_no_match');
		$dbh->do(
			"INSERT INTO squeezewax.discogs_match
			 (album_key, lms_album_id, discogs_release_id, discogs_master_id,
			  match_tier, state, matched_at, source_timestamp,
			  snapshot_album_title, snapshot_track_count, snapshot_artist)
			 VALUES (?,?,?,?,?,'confirmed',?,?,?,?,?)",
			undef, $old, 1, 4242, 99, $tier, 500, 900, 'Kind of Blue', 5, 'Miles Davis'
		);
	};

	$seedOrphan->();
	is( $M->relinkOrphan( $old, $new, 42 ), 1, 'a relink reports one row written' );

	my ($rows) = $dbh->selectrow_array('SELECT COUNT(*) FROM squeezewax.discogs_match');
	is( $rows, 1, '  ...and the table still holds exactly one row - UPDATE, not INSERT' );

	is( row($old), undef, '  ...nothing is left under the old album_key' );

	my $r = row($new);
	is( $r->{album_key},    $new, '  ...the row moved to the new album_key' );
	is( $r->{lms_album_id}, 42,   '  ...with the new lms_album_id' );

	# Everything that constitutes the decision is carried, not re-decided.
	is( $r->{discogs_release_id},   4242,           '  ...release id carried' );
	is( $r->{discogs_master_id},    99,             '  ...master id carried' );
	is( $r->{match_tier},           'strict',       '  ...match_tier carried' );
	is( $r->{state},                'confirmed',    '  ...state carried, not re-derived' );
	is( $r->{matched_at},           500,            '  ...matched_at carried' );
	is( $r->{source_timestamp},     900,            '  ...source_timestamp carried, so the album skips' );
	is( $r->{snapshot_album_title}, 'Kind of Blue', '  ...snapshot_album_title carried' );
	is( $r->{snapshot_track_count}, 5,              '  ...snapshot_track_count carried' );
	is( $r->{snapshot_artist},      'Miles Davis',  '  ...snapshot_artist carried' );

	# Invariant 1: the relink target had no row in either table, so it cannot
	# now hold one in both.
	is( noMatchRow($new), undef, 'the relinked album_key has no no-match row (invariant 1)' );
	my $state = $M->strictState($new);
	is( $state->{src}, 'match', '  ...and strictState sees exactly the match row' );

	# A manual row is the case recovery exists for: the user chose that release
	# because the tags could not, so re-identification would not reproduce it.
	$seedOrphan->('manual');
	is( $M->relinkOrphan( $old, $new, 42 ), 1, 'a manual row relinks' );
	is( row($new)->{match_tier}, 'manual', '  ...and is still manual afterwards' );
	is( row($new)->{discogs_release_id}, 4242, "  ...with the user's pressing intact" );

	# An orphan that is no longer there changes nothing and is not counted.
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	is( $M->relinkOrphan( $old, $new, 42 ), 0,
		'a relink that matches no row reports failure rather than counting it' );

	# --- review_reason across the relink (step 8, §15.16 parts 3 and 9) ----
	#
	# The relink is what resolves 'orphan', so it clears it. It must clear
	# nothing else: 'conflict' belongs to the importer's identification path and
	# a moved folder is not an answer to contradictory tags.
	$seedOrphan->();
	$dbh->do( "UPDATE squeezewax.discogs_match SET review_reason = 'orphan'" );
	is( $M->relinkOrphan( $old, $new, 42 ), 1, 'an orphan-marked row relinks' );
	is( row($new)->{review_reason}, undef, "  ...and the relink clears 'orphan'" );

	$seedOrphan->();
	$dbh->do( "UPDATE squeezewax.discogs_match SET review_reason = 'conflict'" );
	is( $M->relinkOrphan( $old, $new, 42 ), 1, 'a conflict-marked row relinks too' );
	is( row($new)->{review_reason}, 'conflict',
		"  ...and keeps 'conflict' - the importer owns it, and a move settles nothing" );

	# --- the pre-delete on the target key (R13) ----------------------------
	#
	# TODO 2026-09-19's PK collision. The ownership pass writes a row for an
	# album it has a conclusion or a reason about; album_key is the primary key;
	# so without the delete this UPDATE fails, inside the scanner, silently.
	my $seedBlocker = sub {
		my (%col) = @_;
		$dbh->do(
			'INSERT INTO squeezewax.discogs_match (album_key, lms_album_id, ownership, review_reason)
			 VALUES (?,?,?,?)',
			undef, $new, 42, $col{ownership} // 'absent', $col{review_reason}
		);
	};

	$seedOrphan->();
	$seedBlocker->( ownership => 'exact' );
	is( $M->relinkOrphan( $old, $new, 42 ), 1,
		'a relink onto an album carrying an ownership-only row succeeds' );
	is( row($new)->{discogs_release_id}, 4242,
		"  ...and it is the ORPHAN's row that survives, not the blocker" );
	my ($afterBlock) = $dbh->selectrow_array('SELECT COUNT(*) FROM squeezewax.discogs_match');
	is( $afterBlock, 1, '  ...leaving exactly one row on the key' );

	# The same, with the blocker carrying a pass-written reason. R13: a reason
	# the pass wrote is re-derived at the next sync, so it is not a decision and
	# does not protect the row.
	$seedOrphan->();
	$seedBlocker->( review_reason => 'ambiguous' );
	is( $M->relinkOrphan( $old, $new, 42 ), 1,
		'a blocker carrying a pass reason does not stop the relink either (R13)' );
	is( row($new)->{snapshot_artist}, 'Miles Davis', "  ...the orphan's snapshot is what remains" );

	# And what the pre-delete must NOT reach: a real identification standing on
	# the target key fails all three clauses, so the relink fails loudly rather
	# than overwriting someone else's decision.
	$seedOrphan->();
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match
		 (album_key, lms_album_id, discogs_release_id, match_tier, state,
		  snapshot_album_title, snapshot_track_count, snapshot_artist)
		 VALUES (?,?,?,'strict','candidate',?,?,?)",
		undef, $new, 42, 7777, 'Other', 9, 'Someone Else'
	);
	is( $M->relinkOrphan( $old, $new, 42 ), 0,
		'a relink onto a key holding a real identification fails rather than clobbering it' );
	is( row($new)->{discogs_release_id}, 7777, '  ...and that identification is untouched' );
	ok( row($old), '  ...and the orphan is still where it was' );
}

# --- the backfill: one column, only where it is NULL -----------------------
{
	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Schema::isReady = sub { 1 };
	local $main::SCANNING = 0;

	my $key = 'k' x 32;

	my $seed = sub {
		my ( $artist, $count ) = @_;
		$dbh->do('DELETE FROM squeezewax.discogs_match');
		$dbh->do(
			"INSERT INTO squeezewax.discogs_match
			 (album_key, lms_album_id, discogs_release_id, match_tier, state,
			  matched_at, source_timestamp, snapshot_album_title,
			  snapshot_track_count, snapshot_artist)
			 VALUES (?,?,?,'strict','candidate',?,?,?,?,?)",
			undef, $key, 7, 123, 500, 900, 'Kind of Blue', $count, $artist
		);
	};

	$seed->( undef, 5 );
	is( $M->backfillArtist( $key, 'Miles Davis' ), 1, 'a NULL snapshot_artist is filled' );

	my $r = row($key);
	is( $r->{snapshot_artist}, 'Miles Davis', '  ...with the current album artist' );

	# That column ONLY. A backfill that moved source_timestamp would make the
	# album re-examine on the next scan; one that moved state would pre-empt the
	# ownership pass.
	is( $r->{discogs_release_id},   123,            '  ...release id untouched' );
	is( $r->{match_tier},           'strict',       '  ...match_tier untouched' );
	is( $r->{state},                'candidate',    '  ...state untouched' );
	is( $r->{matched_at},           500,            '  ...matched_at untouched' );
	is( $r->{source_timestamp},     900,            '  ...source_timestamp untouched' );
	is( $r->{lms_album_id},         7,              '  ...lms_album_id untouched' );
	is( $r->{snapshot_album_title}, 'Kind of Blue', '  ...snapshot_album_title untouched' );
	is( $r->{snapshot_track_count}, 5,              '  ...snapshot_track_count untouched' );

	is( $M->backfillArtist( $key, 'Someone Else' ), 0,
		'a second call writes nothing - it fills only NULLs' );
	is( row($key)->{snapshot_artist}, 'Miles Davis',
		'  ...so an artist already recorded is never overwritten' );

	# A conflict row has no snapshot at all (§15.4), and must not acquire half
	# of one here - that would make _recordNoMatch's narrow delete unreachable.
	$seed->( undef, undef );
	is( $M->backfillArtist( $key, 'Miles Davis' ), 0,
		'a row with no snapshot_track_count is not backfilled' );
	is( row($key)->{snapshot_artist}, undef, '  ...and keeps a NULL snapshot_artist' );

	# --- refused writes write nothing -------------------------------------
	# Server-side during a scan: BEGIN IMMEDIATE would fail on the lock, so
	# _writeOk refuses. Both new writes go through it (plan §0.1).
	$seed->( undef, 5 );
	{
		local $main::SCANNING = 1;
		is( $M->backfillArtist( $key, 'Miles Davis' ), 0,
			'a backfill refused by _writeOk reports nothing written' );
		is( $M->relinkOrphan( $key, 'q' x 32, 42 ), 0,
			'a relink refused by _writeOk reports nothing written' );
	}
	is( row($key)->{snapshot_artist}, undef, '  ...and the refused backfill wrote nothing' );
	ok( row($key), '  ...and the refused relink left the row where it was' );
}

# --- the pre-pass, end to end over a real iterator walk --------------------
# The glue: which rows the walk calls orphans, which albums it calls key misses,
# and that the two new writes are driven from one pass. Everything below runs
# against Library::eachAlbum over real tracks/albums/contributors rows.
{
	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Schema::isReady = sub { 1 };
	local $main::SCANNING = 0;

	$dbh->do(q{
		CREATE TABLE tracks (
			id INTEGER PRIMARY KEY, album INT, urlmd5 TEXT, url TEXT,
			timestamp INT, disc INT, tracknum INT, remote INT, audio INT,
			content_type TEXT
		)
	});
	$dbh->do('CREATE TABLE albums (id INTEGER PRIMARY KEY, title TEXT, contributor INT)');
	$dbh->do('CREATE TABLE contributors (id INTEGER PRIMARY KEY, name BLOB)');

	my $ins = $dbh->prepare('INSERT INTO tracks VALUES (?,?,?,?,?,?,?,?,?,?)');

	# album 1 - the album that moved: two local tracks, tagged nothing.
	$ins->execute( 1, 1, md5_hex('a1'), 'file:///a1', 700, 1, 1, 0, 1, 'flc' );
	$ins->execute( 2, 1, md5_hex('a2'), 'file:///a2', 800, 1, 2, 0, 1, 'flc' );

	# album 2 - unmoved, and its row predates step 4, so it needs a backfill.
	$ins->execute( 3, 2, md5_hex('b1'), 'file:///b1', 100, 1, 1, 0, 1, 'flc' );

	# album 3 - a key miss that already has a no-match row, so it is NOT a
	# relink candidate however well it fits (plan §0.4).
	$ins->execute( 4, 3, md5_hex('c1'), 'file:///c1', 200, 1, 1, 0, 1, 'flc' );

	$dbh->do("INSERT INTO albums (id, title) VALUES
		(1, 'Kind of Blue'), (2, 'Vespertine'), (3, 'Kind of Blue')");
	$dbh->do( 'INSERT INTO contributors (id, name) VALUES (1, ?), (2, ?)',
		undef, 'Miles Davis', "Bj\xc3\xb6rk" );
	$dbh->do('UPDATE albums SET contributor = 1 WHERE id IN (1, 3)');
	$dbh->do('UPDATE albums SET contributor = 2 WHERE id = 2');

	# The iterator derives album_key; read it back rather than recomputing it
	# here, so the test cannot drift from Library::_finish.
	my %byId;
	Plugins::SqueezeWax::Library->eachAlbum( sub { $byId{ $_[0]{album_id} } = $_[0]; 1 } );

	my $orphanKey = 'z' x 32;

	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');

	# The orphan: a manual row whose album_key is gone, whose snapshot matches
	# album 1, and whose source_timestamp is album 1's current one.
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match
		 (album_key, lms_album_id, discogs_release_id, match_tier, state,
		  matched_at, source_timestamp, snapshot_album_title,
		  snapshot_track_count, snapshot_artist)
		 VALUES (?,?,?,'manual','confirmed',?,?,?,?,?)",
		undef, $orphanKey, 999, 4242, 500, $byId{1}{source_timestamp},
		'Kind of Blue', 2, 'Miles Davis'
	);

	# Album 2's row: current key, has a snapshot, NULL artist - a pre-step-4 row.
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match
		 (album_key, lms_album_id, discogs_release_id, match_tier, state,
		  matched_at, source_timestamp, snapshot_album_title, snapshot_track_count)
		 VALUES (?,?,?,'strict','candidate',?,?,?,?)",
		undef, $byId{2}{album_key}, 2, 555, 500, $byId{2}{source_timestamp},
		'Vespertine', 1
	);

	# Album 3 is a decoy: it fits the orphan's snapshot as well as album 1 does,
	# but it carries a no-match row, so it is not a key miss and cannot contend.
	# Without the both-tables test the relink would be ambiguous and resolve
	# nothing at all - which is what this album is here to catch.
	$dbh->do(
		"INSERT INTO squeezewax.discogs_no_match (album_key, tier, source_timestamp, checked_at)
		 VALUES (?, 'strict', ?, ?)",
		undef, $byId{3}{album_key}, $byId{3}{source_timestamp}, 1
	);

	my $pre = Plugins::SqueezeWax::Importer::_prePass();

	is( $pre->{relinked},   1, 'the pre-pass relinks the moved album' );
	is( $pre->{orphaned},   0, '  ...leaving no unresolved orphan' );
	is( $pre->{backfilled}, 1, '  ...and backfills the pre-step-4 row' );

	my $moved = row( $byId{1}{album_key} );
	ok( $moved, 'the orphan row now sits on the current album_key' );
	is( $moved->{discogs_release_id}, 4242, "  ...still naming the user's release" );
	is( $moved->{match_tier}, 'manual', '  ...still manual' );
	is( $moved->{lms_album_id}, 1, '  ...with the current lms_album_id' );
	is( row($orphanKey), undef, '  ...and nothing is left behind under the old key' );

	is( row( $byId{2}{album_key} )->{snapshot_artist}, "Bj\xc3\xb6rk",
		'the backfill wrote the album artist as bytes' );

	# The decoy kept its no-match row and gained nothing.
	is( row( $byId{3}{album_key} ), undef,
		'an album with a no-match row is not a relink target' );

	# What the main loop does next. A relinked row carries its source_timestamp,
	# so _canSkip is true and the album is never examined - no tag read, and no
	# no-match row written over the row we just recovered.
	my $state = $M->strictState( $byId{1}{album_key} );
	is( $state->{src}, 'match', 'the main loop finds a match row, not a no-match row' );
	ok( Plugins::SqueezeWax::Importer::_canSkip( $byId{1}, $state ),
		'  ...and skips the album, because its files moved but did not change' );
	is( noMatchRow( $byId{1}{album_key} ), undef,
		'  ...so no no-match row is ever written for it (invariant 1)' );

	# Idempotent: nothing is an orphan or a backfill target the second time.
	my $again = Plugins::SqueezeWax::Importer::_prePass();
	is( $again->{relinked},   0, 'a second pre-pass relinks nothing' );
	is( $again->{orphaned},   0, '  ...has no orphans left' );
	is( $again->{backfilled}, 0, '  ...and backfills nothing' );

	# --- TODO 2026-09-19, end to end: an ownership-only row on the target ---
	#
	# Both halves of the fix in one run, through the real _prePass rather than
	# through relinkOrphan directly. The album that the orphan fits already
	# carries a row the ownership pass wrote - which before step 8 made it "not
	# a key miss" (so it was never offered) and, had it been offered, would have
	# collided on the primary key.
	#
	# The reason on the blocker is deliberate: a pass reason does not protect a
	# row (R13), and the queue is where this album would otherwise sit forever.
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');

	$dbh->do(
		"INSERT INTO squeezewax.discogs_match
		 (album_key, lms_album_id, discogs_release_id, match_tier, state,
		  matched_at, source_timestamp, snapshot_album_title,
		  snapshot_track_count, snapshot_artist)
		 VALUES (?,?,?,'manual','confirmed',?,?,?,?,?)",
		undef, $orphanKey, 999, 4242, 500, $byId{1}{source_timestamp},
		'Kind of Blue', 2, 'Miles Davis'
	);

	$dbh->do(
		"INSERT INTO squeezewax.discogs_match (album_key, lms_album_id, ownership, review_reason)
		 VALUES (?,?,'absent','ambiguous')",
		undef, $byId{1}{album_key}, 1
	);

	# Album 3 is still a decoy, and still disqualified by its no-match row.
	$dbh->do(
		"INSERT INTO squeezewax.discogs_no_match (album_key, tier, source_timestamp, checked_at)
		 VALUES (?, 'strict', ?, ?)",
		undef, $byId{3}{album_key}, $byId{3}{source_timestamp}, 1
	);

	my $blocked = Plugins::SqueezeWax::Importer::_prePass();
	is( $blocked->{relinked}, 1,
		'an album carrying only a pass row is still a relink target (TODO 2026-09-19)' );
	is( $blocked->{orphaned}, 0, '  ...so the orphan is resolved, not left counted' );

	my $landed = row( $byId{1}{album_key} );
	is( $landed->{discogs_release_id}, 4242, '  ...the manual row landed on it' );
	is( $landed->{match_tier}, 'manual',     '  ...still manual' );
	is( $landed->{review_reason}, undef,
		"  ...and the blocker's 'ambiguous' went with the blocker" );
	is( row($orphanKey), undef, '  ...with nothing left under the old key' );

	my ($onKey) = $dbh->selectrow_array(
		'SELECT COUNT(*) FROM squeezewax.discogs_match WHERE album_key = ?',
		undef, $byId{1}{album_key}
	);
	is( $onKey, 1, '  ...and exactly one row on the key, not a collision' );
}

# --- R6: the importer ignores ownership-only rows (§15.13 part 6) ----------
#
# Since migration 3, match_tier is nullable and a NULL one means "no
# identification": the row exists for the ownership pass's conclusion alone.
# The importer's lookups must not see it. Without the filter, every untagged
# album a sync concluded on would log an invariant-1 error on the next scan and
# then never be examined for tags again.
{
	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Schema::isReady = sub { 1 };
	local $main::SCANNING = 0;

	my $key = 'w' x 32;

	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');

	# What the ownership pass writes: a key, an album id and an ownership.
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match (album_key, lms_album_id, ownership)
		 VALUES (?, 7, 'exact')", undef, $key
	);

	my $state = $M->strictState($key);
	is( $state, undef,
		'strictState does not see an ownership-only row - it is not an identification' );

	# The pair §15.13 part 6 explicitly permits. They answer different
	# questions: "do you own this record" and "did reading the tags produce a
	# candidate", and one album may truthfully have both answers.
	$dbh->do(
		"INSERT INTO squeezewax.discogs_no_match (album_key, tier, source_timestamp, checked_at)
		 VALUES (?, 'strict', 1, 1)", undef, $key
	);

	$state = $M->strictState($key);
	is( $state->{src}, 'none',
		'an ownership-only row and a strict no-match row coexist, and the no-match wins' );

	# ...and no invariant-1 error is logged, because only one row comes back.
	# Two rows is what triggers it, and the filter is what stops there being two.
	my ($rows) = $dbh->selectrow_array(
		'SELECT COUNT(*) FROM squeezewax.discogs_match WHERE album_key = ?', undef, $key );
	is( $rows, 1, '  ...while the ownership-only row is still there, untouched' );

	# _recordNoMatch's surviving-row count carries the same filter. An
	# ownership-only row must not suppress the no-match row, or one sync would
	# stop the album ever being re-read for tags.
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');

	my $album = {
		album_key => $key, album_id => 7, source_timestamp => 42,
		title => 'Untagged', artist => 'Someone', local_tracks => 1,
	};

	is( $M->recordStrict( $album, {}, $M->strictState($key) ), 'none',
		'an album with only an ownership row still records a no-match, not "kept"' );
	ok( noMatchRow($key), '  ...and the no-match row is actually written' );
	is( row($key)->{ownership}, 'exact',
		'  ...and the ownership conclusion is left alone' );

	# A tag hit upserting over an ownership-only row keeps ownership, because
	# neither _recordMatch nor _recordConflict names the column in its update
	# list. The badge survives identification arriving later.
	$dbh->do('DELETE FROM squeezewax.discogs_no_match');

	is( $M->recordStrict( $album, { id => 4242 }, $M->strictState($key) ), 'identified',
		'a tag hit over an ownership-only row identifies it' );

	my $upserted = row($key);
	is( $upserted->{ownership},          'exact', '  ...and keeps the ownership conclusion' );
	is( $upserted->{discogs_release_id}, 4242,    '  ...while gaining the identification' );
	is( $upserted->{match_tier},         'strict', '  ...and the tier' );

	# The same for the conflict path, which has the shorter update list.
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match (album_key, lms_album_id, ownership)
		 VALUES (?, 7, 'version')", undef, $key
	);

	is( $M->recordStrict( $album, { conflict => [ 'A=1', 'B=2' ] }, $M->strictState($key) ),
		'candidate', 'a tag conflict over an ownership-only row records the conflict' );
	is( row($key)->{ownership}, 'version',
		'  ...and keeps the ownership conclusion too' );

	# snapshotRows is deliberately NOT filtered: the orphan filter lives in
	# _prePass and already requires match_tier (Importer.pm:355-359). Step 8 put
	# the SAME test on the miss side - _prePass now treats a NULL-tier row as a
	# key miss - which is why this stays unfiltered rather than being narrowed
	# here. Narrowing it would put the rule in two places and leave the orphan
	# side reading a list that had already had its own inputs removed.
	$dbh->do('DELETE FROM squeezewax.discogs_match');
	$dbh->do(
		"INSERT INTO squeezewax.discogs_match (album_key, lms_album_id, ownership)
		 VALUES (?, 7, 'exact')", undef, $key
	);

	my ($seen) = grep { $_->{album_key} eq $key } @{ $M->snapshotRows };
	ok( $seen, 'snapshotRows still returns an ownership-only row, by design' );
	is( $seen->{match_tier}, undef, '  ...with a NULL match_tier, so it is never an orphan' );
}

done_testing();
