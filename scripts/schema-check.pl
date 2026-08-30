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
	*{'main::SCANNER'}  = sub () { 0 };
	*{'main::INFOLOG'}  = sub () { 0 };
	*{'main::DEBUGLOG'} = sub () { 0 };
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

for my $t (qw(discogs_match discogs_release_cache discogs_collection discogs_price_snapshot)) {
	ok( $tables{$t}, "table $t exists" );
}

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

# 'manual' is the value the review queue will write in build-order step 5;
# if the CHECK rejected it we would only find out then.
ok( $insertMatch->( album_key => 'c' x 32, match_tier => 'manual' ),
	"match_tier CHECK accepts 'manual'" );

for my $tier (qw(strict structural fuzzy)) {
	ok( $insertMatch->( album_key => substr( $tier . ( 'x' x 32 ), 0, 32 ), match_tier => $tier ),
		"match_tier CHECK accepts '$tier'" );
}

ok( !eval {
	$dbh->do( 'INSERT INTO squeezewax.discogs_collection (instance_id, discogs_release_id, list_state)'
		. " VALUES (1, 1, 'Owned')" ); 1
}, "list_state CHECK rejects 'Owned'" );

ok( eval {
	$dbh->do( 'INSERT INTO squeezewax.discogs_collection (instance_id, discogs_release_id, list_state)'
		. " VALUES (2, 1, 'wantlist')" ); 1
}, "list_state CHECK accepts 'wantlist'" );

done_testing();
