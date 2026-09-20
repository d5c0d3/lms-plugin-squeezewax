#!/usr/bin/env perl
#
# Offline exercise of Plugins::SqueezeWax::Schema's migration runner and DDL.
#
# No LMS instance is needed. This drives the real @MIGRATIONS list against a
# scratch database through a plain DBI handle, standing in for the handle LMS
# would pass to postDBConnect. It proves the migrations apply, are idempotent,
# and that the constraints reject what they are supposed to reject.
#
# What it cannot prove: that the postDBConnect handler is wired into LMS
# correctly, or that any Slim::* call exists. Those need a real server.
#
# Usage: scripts/schema-check.pl

use strict;
use warnings;

use Config;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use Test::More;

# DBI and DBD::SQLite come from refs/slimserver, so this runs against the same
# versions LMS ships rather than whatever the host happens to have. refs stores
# XS per perl-version and architecture and the pure-perl halves in more than
# one place, so the search order matters: CPAN/DBI.pm is 1.616 while the .so
# next to CPAN/arch/<ver>/DBI.pm is 1.628, and getting them crossed is a
# DynaLoader version mismatch rather than a clean failure.
#
# Mirror Slim::bootstrap's @SlimINC exactly (refs/slimserver/Slim/bootstrap.pm
# lines 90-127) rather than approximating it.
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

require DBI;

# Schema.pm's runtime dependencies are all LMS modules we do not want to drag
# in here, so stub the two it uses at compile time. logger() is called at file
# scope; OSDetect is only reached from init()/dbFile(), which we do not call.
BEGIN {
	$INC{'Slim/Utils/Log.pm'} = 1;
	$INC{'Slim/Utils/OSDetect.pm'} = 1;

	no strict 'refs';
	*{'Slim::Utils::Log::logger'}   = sub { Test::StubLogger->new };
	*{'Slim::Utils::Log::logError'} = sub { };
	*{'Slim::Utils::Log::import'}   = sub {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::logger"}   = \&Slim::Utils::Log::logger;
		*{"${caller}::logError"} = \&Slim::Utils::Log::logError;
	};

	# Schema.pm is compiled with main::SCANNER already defined by its callers.
	*{'main::SCANNER'}   = sub () { 0 };
	*{'main::INFOLOG'}   = sub () { 0 };
	*{'main::DEBUGLOG'}  = sub () { 0 };
	# _samePath case-folds under ISWINDOWS; these tests run the POSIX branch.
	*{'main::ISWINDOWS'} = sub () { 0 };
}

{
	package Test::StubLogger;
	sub new     { bless {}, shift }
	sub error   { }
	sub warn    { }
	sub info    { }
	sub debug   { }
	sub is_info { 0 }
	sub is_debug{ 0 }
}

use lib "$Bin/..";
require SqueezeWax::Schema;

# SqueezeWax/Schema.pm declares itself as Plugins::SqueezeWax::Schema.
my $S = 'Plugins::SqueezeWax::Schema';

my $dir = tempdir( CLEANUP => 1 );

sub fresh_dbh {
	my $dbh = DBI->connect( "dbi:SQLite:dbname=$dir/main.db", '', '', {
		RaiseError => 1,
		PrintError => 0,
		AutoCommit => 1,
	} );

	# LMS sets this connection-wide; it applies to attached databases too, so
	# exercise the DDL under the same conditions (Slim/Utils/SQLiteHelper.pm:99).
	$dbh->do('PRAGMA foreign_keys = ON');
	$dbh->do("ATTACH '$dir/squeezewax.db' AS squeezewax");

	return $dbh;
}

sub version_of {
	my $dbh = shift;
	my ($v) = $dbh->selectrow_array('PRAGMA squeezewax.user_version');
	return $v;
}

my $target = $S->SCHEMA_VERSION;
cmp_ok( $target, '>', 0, "SCHEMA_VERSION is $target, not folded to 0 at BEGIN" );

# --- a fresh file migrates to the current version -------------------------
my $dbh = fresh_dbh();
is( version_of($dbh), 0, 'a never-migrated file reports user_version 0' );

$S->_migrate($dbh);
is( version_of($dbh), $target, "migrated to version $target" );

my ($mode) = $dbh->selectrow_array('PRAGMA squeezewax.journal_mode = WAL');
is( lc $mode, 'wal', 'journal_mode can be set to WAL outside a transaction' );

# --- attach detection -----------------------------------------------------
# postDBConnect fires once per connect and the connect count is not fixed (see
# _attachedFile's comment), so the handler must recognise its own attach rather
# than rely on a second ATTACH failing.
is( $S->_attachedFile($dbh), "$dir/squeezewax.db",
	'_attachedFile reports the file our schema name is attached to' );

my $unattached = DBI->connect( "dbi:SQLite:dbname=$dir/main3.db", '', '', {
	RaiseError => 1, PrintError => 0, AutoCommit => 1,
} );
is( $S->_attachedFile($unattached), undef,
	'_attachedFile returns undef when the name is not attached' );

# The reason the check exists: LMS connects with RaiseError => 1 and
# PrintError => 0 (Slim/Schema.pm:273-275), so a repeat ATTACH throws rather
# than being ignored, and postDBConnect's eval would mark the plugin unusable
# over a benign condition.
ok( !eval { $dbh->do("ATTACH '$dir/squeezewax.db' AS squeezewax"); 1 },
	'a second ATTACH of the same name dies under RaiseError' );
like( $@, qr/already in use/, '  ...with "already in use"' );

# The path SQLite reports is canonicalised; the path dbFile() builds is not
# (Slim/Utils/Prefs.pm:90-92 takes --prefsdir verbatim, :645 returns it as-is).
# A raw string comparison would therefore disable the plugin on any host with a
# symlinked or relative prefs directory - Synology, QNAP, most Docker images -
# on the *second* postDBConnect, which is the normal case.
SKIP: {
	skip 'symlinks unavailable', 4 unless eval { symlink( '', '' ); 1 };

	mkdir "$dir/real";
	symlink "$dir/real", "$dir/link" or skip 'could not create symlink', 4;

	my $linked = DBI->connect( "dbi:SQLite:dbname=$dir/main4.db", '', '', {
		RaiseError => 1, PrintError => 0, AutoCommit => 1,
	} );
	$linked->do("ATTACH '$dir/link/squeezewax.db' AS squeezewax");

	my $reported = $S->_attachedFile($linked);
	is( $reported, "$dir/real/squeezewax.db",
		'SQLite reports the symlink-resolved path, not the one we passed' );
	isnt( $reported, "$dir/link/squeezewax.db",
		'  ...so a raw string comparison against dbFile() would not match' );

	ok( $S->_samePath( $reported, "$dir/link/squeezewax.db" ),
		'_samePath sees through a symlinked directory' );
	ok( $S->_samePath( $reported, "$dir/real/../real/squeezewax.db" ),
		'_samePath collapses ".."' );
}

# A genuinely different file must still be caught - the die this protects is
# what stops us reading and writing someone else's database under our name.
ok( !$S->_samePath( "$dir/squeezewax.db", "$dir/somethingelse.db" ),
	'_samePath rejects two genuinely different files' );

# An unresolvable path falls back to the raw strings rather than being treated
# as a mismatch.
ok( $S->_samePath( '/no/such/dir/x.db', '/no/such/dir/x.db' ),
	'_samePath falls back to string equality when abs_path cannot resolve' );

# --- migrating again is a no-op -------------------------------------------
$S->_migrate($dbh);
is( version_of($dbh), $target, 'a second migrate leaves the version alone' );

# and the individual steps are themselves idempotent, which is what makes a
# resumed partial migration safe
$dbh->do('PRAGMA squeezewax.user_version = 0');
eval { $S->_migrate($dbh); 1 } or fail("re-running every migration died: $@");
is( version_of($dbh), $target, 'every migration re-applied cleanly over its own output' );

# --- the scanner check refuses an empty database --------------------------
my $emptyDbh = DBI->connect( "dbi:SQLite:dbname=$dir/main2.db", '', '', {
	RaiseError => 1, PrintError => 0, AutoCommit => 1,
} );
$emptyDbh->do("ATTACH '$dir/never-migrated.db' AS squeezewax");
is( version_of($emptyDbh), 0, 'ATTACH silently created an empty file, version 0' );
ok( !eval { $S->_checkVersion($emptyDbh); 1 }, '_checkVersion refuses an empty database' );
like( $@, qr/expected $target/, '  ...and says what it expected' );

# a matching version passes
ok( eval { $S->_checkVersion($dbh); 1 }, '_checkVersion accepts a migrated database' );

# --- a newer file is refused rather than guessed at -----------------------
my $ahead = $target + 1;
$dbh->do("PRAGMA squeezewax.user_version = $ahead");
ok( !eval { $S->_migrate($dbh); 1 }, '_migrate refuses a file newer than the plugin' );
like( $@, qr/newer than this plugin/, '  ...and says why' );
$dbh->do("PRAGMA squeezewax.user_version = $target");

# --- expected tables exist ------------------------------------------------
my %tables = map { $_->[0] => 1 } @{
	$dbh->selectall_arrayref("SELECT name FROM squeezewax.sqlite_master WHERE type = 'table'")
};

for my $t (qw(discogs_match discogs_release_cache discogs_price_snapshot
              discogs_no_match)) {
	ok( $tables{$t}, "table $t exists" );
}

# (i) discogs_collection was never a v1 table. Migration 1 created it and
# migration 3 drops it; decisions §15.10.
ok( !$tables{discogs_collection}, 'discogs_collection is gone after migrating' );

# (f) the exact column set of the rebuilt discogs_match, not just a spot check:
# migration 3 drops snapshot_total_duration and adds ownership, and asserting
# the whole set is what catches a column that survives the rebuild by accident.
my %matchColumns = map { $_->{name} => 1 } @{
	$dbh->selectall_arrayref(
		'SELECT name FROM pragma_table_info(?)', { Slice => {} }, 'discogs_match'
	)
};

is_deeply(
	[ sort keys %matchColumns ],
	[ sort qw(album_key mb_album_id lms_album_id discogs_release_id discogs_master_id
	          match_tier state ownership matched_at snapshot_artist snapshot_album_title
	          snapshot_track_count source_timestamp) ],
	'discogs_match carries exactly the v1 column set'
);
ok( $matchColumns{source_timestamp}, 'discogs_match has source_timestamp' );
ok( !$matchColumns{snapshot_total_duration}, 'snapshot_total_duration is dropped (f)' );

# (g) the orphan index follows §15.5's predicate, which keys on match_tier
# rather than state.
my %indexes = map { $_->[0] => $_->[1] } @{
	$dbh->selectall_arrayref(
		"SELECT name, sql FROM squeezewax.sqlite_master WHERE type = 'index' AND sql IS NOT NULL"
	)
};

for my $i (qw(discogs_match_release discogs_match_lms_album discogs_match_mb_album
              discogs_match_orphan)) {
	ok( $indexes{$i}, "index $i survives the rebuild" );
}
ok( !$indexes{discogs_collection_release}, 'discogs_collection_release is gone (i)' );
like( $indexes{discogs_match_orphan} || '', qr/\(\s*match_tier\s*,\s*snapshot_track_count\s*\)/,
	'the orphan index is on (match_tier, snapshot_track_count) (g)' );

# --- no foreign keys, anywhere -------------------------------------------
for my $t ( sort keys %tables ) {
	my $fks = $dbh->selectall_arrayref("PRAGMA squeezewax.foreign_key_list($t)");
	is( scalar @$fks, 0, "$t declares no foreign keys" );
}

# --- constraints reject what they should ----------------------------------
my $key = 'a' x 32;

my $insertMatch = sub {
	my %col = (
		album_key          => $key,
		discogs_release_id => 1,
		match_tier         => 'strict',
		state              => 'confirmed',
		@_,
	);
	my @names = sort keys %col;
	my $sql = 'INSERT INTO squeezewax.discogs_match (' . join(',', @names) . ') VALUES ('
		. join( ',', ('?') x @names ) . ')';
	return eval { $dbh->do( $sql, undef, map { $col{$_} } @names ); 1 };
};

ok( $insertMatch->(), 'a well-formed match row inserts' );

ok( !$insertMatch->( album_key => 'too-short' ), 'album_key CHECK rejects a short key' );
ok( !$insertMatch->( album_key => '' ),          'album_key CHECK rejects an empty key' );

ok( !$insertMatch->( album_key => 'b' x 32, state => 'Confirmed' ),
	"state CHECK rejects 'Confirmed'" );
ok( !$insertMatch->( album_key => 'b' x 32, match_tier => 'Strict' ),
	"match_tier CHECK rejects 'Strict'" );

# 'manual' is the value the review queue will write in build-order step 8;
# if the CHECK rejected it we would only find out then.
ok( $insertMatch->( album_key => 'c' x 32, match_tier => 'manual' ),
	"match_tier CHECK accepts 'manual'" );

# (b) The tiers v1 removed. Until migration 3 these were accepted; decisions
# §14.3 deleted Fuzzy from the roadmap and §13.8 replaced Structural, so a row
# arriving at either tier now is a bug and must not be storable.
for my $tier (qw(structural fuzzy)) {
	ok( !$insertMatch->( album_key => substr( $tier . ( 'x' x 32 ), 0, 32 ), match_tier => $tier ),
		"match_tier CHECK rejects '$tier' (removed in v1)" );
}

ok( $insertMatch->( album_key => 'd' x 32, match_tier => 'strict' ),
	"match_tier CHECK accepts 'strict'" );

# (b) NULL match_tier is the ownership pass's row: an ownership conclusion with
# no identification behind it (§14.1, §14.8). Standard SQL treats a CHECK that
# evaluates to NULL as not violated, so no explicit OR ... IS NULL is needed -
# expected rather than verified when the obligation was written, asserted here.
ok( $insertMatch->( album_key => 'e' x 32, match_tier => undef ),
	'match_tier CHECK accepts NULL (an ownership-only row)' );
ok( $insertMatch->( album_key => 'f' x 32, state => undef ),
	'state CHECK accepts NULL' );

# (c) and N1: what an insert that names neither column actually writes. state
# must come out NULL - a DEFAULT 'candidate' here would drop an auto-badged
# album into the review queue, silently wrong rather than loud (§14.8).
# ownership must come out 'absent', because the importer's two INSERTs do not
# name it and a bare NOT NULL column would fail both.
$dbh->do( 'INSERT INTO squeezewax.discogs_match (album_key, lms_album_id) VALUES (?, ?)',
	undef, 'g' x 32, 42 );

my ( $bareState, $bareOwnership, $bareTier ) = $dbh->selectrow_array(
	'SELECT state, ownership, match_tier FROM squeezewax.discogs_match WHERE album_key = ?',
	undef, 'g' x 32
);

is( $bareState,     undef,    'an insert omitting state yields NULL (c)' );
is( $bareTier,      undef,    'an insert omitting match_tier yields NULL' );
is( $bareOwnership, 'absent', "an insert omitting ownership yields 'absent' (N1)" );

# N1's enum. 'owned' is the word design §4 uses for the badge and is the likely
# typo; 'Exact' is the casing one.
for my $bad (qw(Exact owned)) {
	ok( !$insertMatch->( album_key => substr( $bad . ( 'z' x 32 ), 0, 32 ), ownership => $bad ),
		"ownership CHECK rejects '$bad'" );
}

for my $good (qw(exact version absent)) {
	ok( $insertMatch->( album_key => substr( $good . ( 'y' x 32 ), 0, 32 ), ownership => $good ),
		"ownership CHECK accepts '$good'" );
}

# --- discogs_no_match -----------------------------------------------------
my $insertNoMatch = sub {
	my %col = ( album_key => 'n' x 32, tier => 'strict', checked_at => 1, @_ );
	my @names = sort keys %col;
	return eval {
		$dbh->do(
			'INSERT INTO squeezewax.discogs_no_match (' . join( ',', @names ) . ') VALUES ('
				. join( ',', ('?') x @names ) . ')',
			undef, map { $col{$_} } @names
		);
		1;
	};
};

ok( $insertNoMatch->(), 'a well-formed no-match row inserts' );

# (h) The composite PK still exists, but v1 has only one valid tier, so the
# "same album_key under a second tier" case can no longer be written as a
# second valid tier. What it asserts now is that the PK is composite and the
# CHECK is what stops the second row, not the key.
ok( !$insertNoMatch->( tier => 'structural' ),
	"tier CHECK rejects 'structural' (removed in v1)" );
ok( !$insertNoMatch->(), 'and a duplicate (album_key, tier) is still rejected' );

my @noMatchPk = map { $_->{name} } grep { $_->{pk} } @{
	$dbh->selectall_arrayref(
		'SELECT name, pk FROM pragma_table_info(?)', { Slice => {} }, 'discogs_no_match'
	)
};
is_deeply( [ sort @noMatchPk ], [ 'album_key', 'tier' ],
	'discogs_no_match keeps its composite (album_key, tier) primary key' );

# 'fuzzy' is v2 and deliberately outside the CHECK; a typo'd tier would
# otherwise degrade to "not examined", which looks identical to correct
# behaviour.
ok( !$insertNoMatch->( album_key => 'o' x 32, tier => 'fuzzy' ),
	"tier CHECK rejects 'fuzzy' (v2, deliberately absent)" );
ok( !$insertNoMatch->( album_key => 'o' x 32, tier => 'Strict' ),
	"tier CHECK rejects 'Strict'" );
ok( !$insertNoMatch->( album_key => 'short', tier => 'strict' ),
	'album_key CHECK rejects a short key here too' );

# NULL source_timestamp must be allowed and must never compare equal, which is
# what makes an album whose timestamp cannot be established re-examine rather
# than skip.
ok( $insertNoMatch->( album_key => 'p' x 32, source_timestamp => undef ),
	'source_timestamp may be NULL' );
my ($skips) = $dbh->selectrow_array(
	'SELECT COUNT(*) FROM squeezewax.discogs_no_match WHERE album_key = ? AND source_timestamp = ?',
	undef, 'p' x 32, 12345
);
is( $skips, 0, 'a NULL source_timestamp never matches a timestamp, so it never skips' );

# --- migration 3: the upgrade path from a populated version-2 database -----
#
# Everything above runs against a database migrated straight to the current
# version, where the rebuild had nothing to copy. The obligations that matter
# most - (e), (a) and re-run safety - are about a file that already holds rows,
# so build one the way a real upgrade meets it: migrations 1 and 2 only,
# user_version pinned at 2, rows inserted under the OLD constraints.
my $v2 = 0;

sub version_2_dbh {
	my (%opt) = @_;

	$v2++;

	my $h = DBI->connect( "dbi:SQLite:dbname=$dir/v2main$v2.db", '', '', {
		RaiseError => 1, PrintError => 0, AutoCommit => 1,
	} );
	$h->do('PRAGMA foreign_keys = ON');
	$h->do("ATTACH '$dir/v2-$v2.db' AS squeezewax");

	# The plain-function halves of the migration list, called as plain
	# functions (CLAUDE.md). Running _migrate would take the file to 3.
	Plugins::SqueezeWax::Schema::_migration_1($h);
	Plugins::SqueezeWax::Schema::_migration_2($h);
	$h->do('PRAGMA squeezewax.user_version = 2');

	# A confirmed strict row with a full snapshot, a conflict row (strict,
	# candidate, NULL release id, no snapshot - §3a), and a manual row. These
	# are the three shapes (e) has to carry forward untouched.
	$h->do( q{INSERT INTO squeezewax.discogs_match
		(album_key, mb_album_id, lms_album_id, discogs_release_id, discogs_master_id,
		 match_tier, state, matched_at, snapshot_artist, snapshot_album_title,
		 snapshot_track_count, snapshot_total_duration, source_timestamp)
		VALUES (?,?,?,?,?,'strict','confirmed',?,?,?,?,?,?)},
		undef, 'a' x 32, 'mb-1', 11, 111, 999, 1000, 'Artist', 'Title', 12, 3600, 77 );

	$h->do( q{INSERT INTO squeezewax.discogs_match
		(album_key, lms_album_id, match_tier, state, matched_at, source_timestamp)
		VALUES (?,?,'strict','candidate',?,?)},
		undef, 'b' x 32, 22, 1001, 88 );

	$h->do( q{INSERT INTO squeezewax.discogs_match
		(album_key, lms_album_id, discogs_release_id, match_tier, state, matched_at)
		VALUES (?,?,?,'manual','confirmed',?)},
		undef, 'c' x 32, 33, 222, 1002 );

	if ( $opt{legacy_tier} ) {
		$h->do( q{INSERT INTO squeezewax.discogs_match
			(album_key, lms_album_id, discogs_release_id, match_tier, state)
			VALUES (?,?,?,?,'candidate')},
			undef, 'l' x 32, 44, 444, $opt{legacy_tier} );
	}

	# A structural no-match row and a collection row, both of which migration 3
	# discards rather than carries.
	$h->do( q{INSERT INTO squeezewax.discogs_no_match (album_key, tier, checked_at)
		VALUES (?,'structural',?)}, undef, 'n' x 32, 5 );
	$h->do( q{INSERT INTO squeezewax.discogs_collection (instance_id, discogs_release_id)
		VALUES (1, 111)} );

	return $h;
}

sub match_fingerprint {
	my $h = shift;

	return $h->selectall_arrayref(
		q{SELECT album_key, mb_album_id, lms_album_id, discogs_release_id,
		         discogs_master_id, match_tier, state, matched_at, snapshot_artist,
		         snapshot_album_title, snapshot_track_count, source_timestamp
		    FROM squeezewax.discogs_match ORDER BY album_key},
		{ Slice => {} }
	);
}

{
	my $up = version_2_dbh();

	my $beforeRows = $up->selectall_arrayref(
		q{SELECT album_key, match_tier, state FROM squeezewax.discogs_match
		  ORDER BY album_key}, { Slice => {} }
	);
	is( scalar @$beforeRows, 3, 'the version-2 fixture holds three rows' );

	ok( eval { $S->_migrate($up); 1 }, '_migrate takes a populated version-2 file to 3' )
		or diag($@);
	is( version_of($up), $target, "  ...and it reports version $target" );

	my $afterRows = $up->selectall_arrayref(
		q{SELECT album_key, match_tier, state, ownership FROM squeezewax.discogs_match
		  ORDER BY album_key}, { Slice => {} }
	);

	# (e) row for row, same count, same state, same tier. The ownership pass -
	# not the migration - is what re-derives state.
	is( scalar @$afterRows, scalar @$beforeRows, 'the rebuild copied every row (e)' );

	for my $i ( 0 .. $#$beforeRows ) {
		is( $afterRows->[$i]{album_key}, $beforeRows->[$i]{album_key},
			"row $i keeps its album_key" );
		is( $afterRows->[$i]{state}, $beforeRows->[$i]{state},
			"row $i keeps state '" . ( $beforeRows->[$i]{state} // 'NULL' ) . "' (e)" );
		is( $afterRows->[$i]{match_tier}, $beforeRows->[$i]{match_tier},
			"row $i keeps match_tier '" . ( $beforeRows->[$i]{match_tier} // 'NULL' ) . "' (e)" );
		is( $afterRows->[$i]{ownership}, 'absent', "row $i takes ownership 'absent' (e)" );
	}

	# The conflict row is the one whose NULL release id must survive a rebuild
	# that also narrowed two enums.
	my ($conflictRelease) = $up->selectrow_array(
		'SELECT discogs_release_id FROM squeezewax.discogs_match WHERE album_key = ?',
		undef, 'b' x 32
	);
	is( $conflictRelease, undef, 'the conflict row keeps its NULL discogs_release_id' );

	# The columns nothing above names, carried through by the explicit copy.
	my ($mb, $master, $dur) = $up->selectrow_array(
		'SELECT mb_album_id, discogs_master_id, snapshot_artist FROM squeezewax.discogs_match
		  WHERE album_key = ?', undef, 'a' x 32
	);
	is( $mb,     'mb-1',   'mb_album_id survives the rebuild' );
	is( $master, 999,      'discogs_master_id survives the rebuild' );
	is( $dur,    'Artist', 'snapshot_artist survives the rebuild' );

	# (h) and (i): both regenerable tables were discarded, not copied.
	my ($noMatchLeft) = $up->selectrow_array('SELECT COUNT(*) FROM squeezewax.discogs_no_match');
	is( $noMatchLeft, 0, "the 'structural' no-match row is discarded, not migrated (h)" );

	my %upTables = map { $_->[0] => 1 } @{
		$up->selectall_arrayref("SELECT name FROM squeezewax.sqlite_master WHERE type = 'table'")
	};
	ok( !$upTables{discogs_collection}, 'discogs_collection is dropped on upgrade (i)' );
	ok( !$upTables{discogs_match_new},  'the scratch table is renamed away, not left behind' );

	# --- re-run safety ----------------------------------------------------
	#
	# _migrate bumps user_version only after the migration sub returns, so a
	# rebuild that commits and then dies leaves a version-3 table behind a
	# version-2 marker. Both forms of re-run must be no-ops.
	my $fingerprint = match_fingerprint($up);

	ok( eval { Plugins::SqueezeWax::Schema::_migration_3($up); 1 },
		'migration 3 runs a second time without dying' ) or diag($@);
	is_deeply( match_fingerprint($up), $fingerprint, '  ...and changes nothing' );

	$up->do('PRAGMA squeezewax.user_version = 2');
	ok( eval { $S->_migrate($up); 1 },
		'_migrate re-runs over a completed rebuild with user_version forced back to 2' )
		or diag($@);
	is( version_of($up), $target, '  ...and reaches the current version' );
	is_deeply( match_fingerprint($up), $fingerprint, '  ...and still changes nothing' );
}

# --- (a) a legacy tier refuses loudly and changes nothing ------------------
for my $tier (qw(structural fuzzy)) {
	my $bad = version_2_dbh( legacy_tier => $tier );

	my $before = $bad->selectall_arrayref(
		'SELECT album_key, match_tier FROM squeezewax.discogs_match ORDER BY album_key',
		{ Slice => {} }
	);

	ok( !eval { $S->_migrate($bad); 1 }, "_migrate refuses a file holding a '$tier' row (a)" );
	like( $@, qr/refusing to rebuild/, '  ...and says it is refusing' );
	like( $@, qr/\b1 row/, '  ...and says how many rows it found' );

	is( version_of($bad), 2, '  ...and leaves user_version at 2' );
	is_deeply(
		$bad->selectall_arrayref(
			'SELECT album_key, match_tier FROM squeezewax.discogs_match ORDER BY album_key',
			{ Slice => {} }
		),
		$before,
		'  ...and leaves discogs_match untouched'
	);

	my %badTables = map { $_->[0] => 1 } @{
		$bad->selectall_arrayref("SELECT name FROM squeezewax.sqlite_master WHERE type = 'table'")
	};
	ok( $badTables{discogs_collection},
		'  ...and has not begun the drops either (the refusal is first)' );
	ok( !$badTables{discogs_match_new}, '  ...and left no scratch table behind' );
}

done_testing();
