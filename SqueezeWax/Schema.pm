package Plugins::SqueezeWax::Schema;

# Plugin-owned SQLite database, ATTACHed to LMS's own connection as schema
# 'squeezewax'. See docs/squeezewax-v1-decisions.md §2 for the full rationale.
#
# The file lives in the preferences directory, not in library.db (which dies
# with the cache), not in persist.db (which LMS owns), and never inside the
# plugin directory (replaced wholesale on every plugin update).
#
# An ATTACH is per-connection, so it is re-asserted from a postDBConnect
# handler rather than done once at startup - the same reason LMS attaches
# persistentdb from postConnect (Slim/Utils/SQLiteHelper.pm:345-355). That
# also re-establishes it after the post-scan reconnect at
# Slim/Utils/SQLiteHelper.pm:626-628.

use strict;

use Cwd ();

use Slim::Utils::Log;
use Slim::Utils::OSDetect;

use constant DB_NAME   => 'squeezewax.db';
use constant DB_SCHEMA => 'squeezewax';

# Ordered list of migrations. Index n produces user_version n+1, so the target
# version is simply the count. Never reorder or remove an entry: append.
#
# Each must be idempotent - CREATE TABLE IF NOT EXISTS and friends - because a
# run that dies partway leaves user_version at the last step that completed,
# and the next connect retries from there.
my @MIGRATIONS = (
	\&_migration_1,
	\&_migration_2,
);

# A sub, not a `use constant`: constants are folded at BEGIN, before the
# runtime assignment to @MIGRATIONS above has happened.
#
# The empty prototype is load-bearing. Without it a bareword call slurps
# whatever follows as arguments, so `SCHEMA_VERSION - 1` parses as
# `SCHEMA_VERSION(-1)` and quietly yields the unreduced version.
sub SCHEMA_VERSION () { scalar @MIGRATIONS }

my $log = logger('plugin.squeezewax');

my $registered = 0;
my $ready      = 0;
my $error;

=head2 init()

Register our postDBConnect handler. Called from both Plugin.pm (server) and
Importer.pm (scanner); only one of the two is ever loaded in a given process,
since Slim::Utils::PluginManager::load picks 'module' or 'importmodule' by
pass (Slim/Utils/PluginManager.pm:204).

Registering is safe to repeat regardless: %postConnectHandlers is keyed by the
handler, so postDBConnect is still called once per connect, and the forced
disconnect/reconnect is guarded on the count being 1
(Slim/Utils/SQLiteHelper.pm:390-402). That reconnect is what gets our handler
called for the connection that is already open by the time plugins load.

=cut

sub init {
	my $class = shift;

	return if $registered;

	my $sqlHelperClass = Slim::Utils::OSDetect->getOS()->sqlHelperClass();

	# MySQLHelper stubs addPostConnectHandler out and has no dbFile at all
	# (Slim/Utils/MySQLHelper.pm:225-226), so there is nothing for us to hook.
	if ( !$sqlHelperClass->can('dbFile') ) {
		$error = 'SQLite is required; this database backend is not supported';
		$log->error($error);
		return;
	}

	# Pass the class name, not an object: %postConnectHandlers is keyed by the
	# stringified handler.
	$sqlHelperClass->addPostConnectHandler(__PACKAGE__);

	$registered = 1;

	return 1;
}

=head2 dbFile()

Absolute path to our database file, resolved the way LMS resolves persist.db.

=cut

sub dbFile {
	# Slim/Utils/SQLiteHelper.pm:556-566. The second argument is a plain
	# boolean - any true value selects the preferences directory.
	return Slim::Utils::OSDetect->getOS()->sqlHelperClass()->dbFile(DB_NAME, 1);
}

=head2 postDBConnect( $dbh )

Called from Slim::Utils::SQLiteHelper::postConnect for every connect.

This must never die. The dispatch loop at Slim/Utils/SQLiteHelper.pm:379-381
has no eval, postConnect is called unguarded from Slim/Schema.pm:283, and
Slim::Schema->init is called unguarded from slimserver.pl:437 - so an
exception here would take LMS's entire database connection down over a
plugin's problem. Failures are recorded and reported by isReady() instead.

=cut

sub postDBConnect {
	my ( $class, $dbh ) = @_;

	$ready = 0;
	$error = undef;

	# Use the handle we are passed. Slim::Schema::disconnect does not clear the
	# $_dbh cache (Slim/Schema.pm:325-331) and $_dbh is only reassigned at
	# Slim/Schema.pm:139-141, after _connect returns - so Slim::Schema->dbh
	# still hands back the old, disconnected handle at this point.
	eval {
		my $path = $class->dbFile();

		# Detect an existing attach rather than relying on the ATTACH failing.
		# Slim/Schema.pm:273-275 sets RaiseError => 1, PrintError => 0, so a
		# second ATTACH of the same name would die ("database squeezewax is
		# already in use"), be caught below, and mark us unusable over a
		# condition that is entirely benign.
		my $attached = $class->_attachedFile($dbh);

		if ( !defined $attached ) {
			# Quoted rather than interpolated as SQLiteHelper.pm:353 does, so a
			# path containing an apostrophe cannot break the statement.
			$dbh->do( 'ATTACH ' . $dbh->quote($path) . ' AS ' . DB_SCHEMA );

			# Note that a missing *file* is not an error - SQLite creates it
			# silently. Only a missing or unwritable directory fails here. It is
			# the user_version check that catches an empty database, not this.
		}
		elsif ( !$class->_samePath( $attached, $path ) ) {
			# Never observed, and no way to see it before this check existed.
			# Continuing would read and write someone else's file under our
			# schema name.
			die DB_SCHEMA . " is already attached to a different file:\n"
				. "  attached: $attached\n"
				. "  expected: $path\n";
		}
		else {
			main::DEBUGLOG && $log->is_debug
				&& $log->debug( DB_SCHEMA . " already attached to $path; skipping ATTACH" );
		}

		my $journalMode = $class->_ensureWalMode($dbh);

		# Deliberately no synchronous pragma. Pragmas are not inherited by an
		# attached database: main is at OFF (SQLiteHelper.pm:99) but ours
		# defaults to FULL, and FULL is what we want for data we cannot
		# regenerate.

		$dbh->do( 'PRAGMA ' . DB_SCHEMA . '.cache_size = 2000' );

		# DDL is the server's job alone. The scanner takes what it finds.
		if (main::SCANNER) {
			$class->_checkVersion($dbh);
		}
		else {
			$class->_migrate($dbh);
		}

		$ready = 1;

		# The only proof postDBConnect ran to completion rather than merely
		# reaching a die - see the module header. journal_mode especially,
		# since _ensureWalMode's pragma fails silently by design and this
		# read-back is the only signal we have of it.
		main::INFOLOG && $log->is_info && $log->info(
			DB_NAME . ' ready (' . ( main::SCANNER ? 'scanner' : 'server' ) . ' process): path='
			. $path . ' user_version=' . $class->_version($dbh)
			. ' journal_mode=' . ( $journalMode || 'unknown' )
		);
	};

	if ($@) {
		$error = $@;
		$error =~ s/\s+$//;
		$ready = 0;

		$log->error( DB_NAME . " is unusable: $error" );

		# logError goes to the root logger, so this is visible at default log
		# levels in both server.log and scanner.log (Slim/Utils/Log.pm:318-330).
		logError( 'SqueezeWax is inactive: ' . DB_NAME . " is unusable: $error" );
	}

	return $ready;
}

# Do two paths name the same database file?
#
# A raw string comparison is wrong, and wrong in the direction that disables the
# plugin on a perfectly healthy system. SQLite canonicalises the path it reports
# in pragma_database_list - verified on 3.50.6, it resolves symlinks, collapses
# '..' and absolutises a relative path - while dbFile() is not canonicalised
# anywhere: Slim/Utils/Prefs.pm:90-92 takes --prefsdir straight off the command
# line and `sub dir` at :645 returns it verbatim, and dbFile just catfiles onto
# that. So a symlinked prefs directory (the default on Synology and QNAP, and
# common in Docker images) or a relative --prefsdir (a checkout, a hand-written
# systemd unit) would make the strings differ on the *second* postDBConnect -
# which is the normal case, not a rare one, since FullTextSearch is bundled,
# enabled by default and registers in both processes. The plugin would go dead
# with an error naming two paths that are the same file.
#
# NOT stat dev+inode, though that is what "same file" actually means: Windows
# inode numbers are frequently 0, so two genuinely different files would compare
# equal, the ATTACH would be skipped, and we would silently read and write
# someone else's database under our schema name - the exact failure the die
# exists to prevent. abs_path fails in the safe direction: a false negative
# disables the plugin loudly, a false positive corrupts data quietly. Do not
# "simplify" this to an inode check.
sub _samePath {
	my ( $class, $left, $right ) = @_;

	return 0 unless defined $left && defined $right;

	# abs_path resolves a missing leaf inside an existing directory, so a
	# first-ever run is fine; it returns undef only when a directory component
	# is missing. Fall back to the raw strings in that case rather than treating
	# an unresolvable path as a mismatch.
	my $canonLeft  = Cwd::abs_path($left);
	my $canonRight = Cwd::abs_path($right);

	if ( defined $canonLeft && defined $canonRight ) {
		( $left, $right ) = ( $canonLeft, $canonRight );
	}

	# NTFS case-folds, so the same file can be reported with different case.
	return lc($left) eq lc($right) if main::ISWINDOWS;

	return $left eq $right;
}

# The file our schema name is currently attached to, or undef if it is not
# attached on this handle.
#
# postDBConnect fires once per connect (Slim/Schema.pm:283, inside _connect),
# and the number of connects is not fixed: addPostConnectHandler forces a
# disconnect/reconnect on the *first* registration of each handler, guarded on
# $postConnectHandlers{$handler} == 1 per handler
# (Slim/Utils/SQLiteHelper.pm:390-402). So it is one connect for the initial
# init plus one for every distinct handler that registers after us - today
# Slim::Plugin::FullTextSearch::Plugin, which registers in both processes
# (its install.xml declares <module> and <importmodule>, and the registration
# at Plugin.pm:199 precedes the `return if main::SCANNER` at :202), tomorrow
# whatever the user installs. Detecting the attach makes the count irrelevant,
# which is the point of doing it rather than reasoning about the count.
sub _attachedFile {
	my ( $class, $dbh ) = @_;

	# No row when the name is not attached, so this is undef. Verified on
	# SQLite 3.50.6: attaching a path that does not exist yet still reports the
	# absolute path here (SQLite creates the file), so a first-ever run is
	# indistinguishable from a later one - which is what we want. Only
	# ':memory:' reports the empty string, and we never attach that; it would
	# fall through to the mismatch branch, which is the right answer anyway.
	my ($file) = $dbh->selectrow_array(
		'SELECT file FROM pragma_database_list WHERE name = ?', undef, DB_SCHEMA
	);

	return $file;
}

# journal_mode must be WAL: both the server and the scanner attach this file,
# and in rollback-journal mode a writer locks the whole file, so a server-side
# write during a scan can block or fail.
#
# The setting persists in the file, so this is a one-time change that later
# connects merely confirm. It cannot be set inside a transaction, and when it
# fails that way it returns the unchanged mode without raising - so the
# returned value has to be read back. There is no exception to catch.
sub _ensureWalMode {
	my ( $class, $dbh ) = @_;

	if (main::SCANNER) {
		# The scanner never mutates the file - see decisions §2. Read only.
		my ($mode) = $dbh->selectrow_array( 'PRAGMA ' . DB_SCHEMA . '.journal_mode' );

		if ( !$mode || lc($mode) ne 'wal' ) {
			$log->error(
				DB_NAME . " is in '" . ($mode || 'unknown') . "' journal mode, not WAL; "
				. 'concurrent access with the server may block'
			);
		}

		return $mode;
	}

	my ($mode) = $dbh->selectrow_array( 'PRAGMA ' . DB_SCHEMA . '.journal_mode = WAL' );

	if ( !$mode || lc($mode) ne 'wal' ) {
		die 'failed to set WAL journal mode (got ' . ($mode || 'no result') . ")\n";
	}

	return $mode;
}

# Version lives in the database file itself, not in prefs: prefs and the file
# are destroyed independently, so a prefs-held version could claim v5 against a
# database that does not exist. See decisions §2.
sub _version {
	my ( $class, $dbh ) = @_;

	my ($version) = $dbh->selectrow_array( 'PRAGMA ' . DB_SCHEMA . '.user_version' );

	return $version || 0;
}

# Server only. Runs whatever migrations are outstanding, bumping user_version
# after each so an interrupted run resumes rather than restarting.
sub _migrate {
	my ( $class, $dbh ) = @_;

	my $from = $class->_version($dbh);

	if ( $from > SCHEMA_VERSION ) {
		# Downgraded plugin against a newer file. Refuse rather than guess:
		# the newer schema may hold columns this version would silently drop.
		die DB_NAME . " is at version $from, newer than this plugin understands ("
			. SCHEMA_VERSION . "). Refusing to touch it.\n";
	}

	return 1 if $from == SCHEMA_VERSION;

	main::INFOLOG && $log->is_info
		&& $log->info( 'Migrating ' . DB_NAME . " from version $from to " . SCHEMA_VERSION );

	for my $i ( $from .. SCHEMA_VERSION - 1 ) {
		my $to = $i + 1;

		eval {
			$MIGRATIONS[$i]->($dbh);

			# user_version takes no bind parameters, hence the interpolation.
			# $to is a loop index over our own list, not external input.
			$dbh->do( 'PRAGMA ' . DB_SCHEMA . ".user_version = $to" );
		};

		if ($@) {
			die "migration to version $to failed: $@";
		}

		main::INFOLOG && $log->is_info && $log->info("Migrated " . DB_NAME . " to version $to");
	}

	return 1;
}

# Scanner only. The tables must already exist; we never create them here.
#
# Note that the ATTACH above cannot tell us anything: SQLite creates a missing
# file silently, so a first-ever run that starts with a scan would attach a
# perfectly valid empty database. This check is what catches that - a fresh
# file reports version 0.
sub _checkVersion {
	my ( $class, $dbh ) = @_;

	my $version = $class->_version($dbh);

	if ( $version != SCHEMA_VERSION ) {
		die DB_NAME . " is at version $version, expected " . SCHEMA_VERSION
			. ' - start the server once to create or migrate it'
			. "\n";
	}

	return 1;
}

# Migration 1: the v1 data model, per design §10.
#
# No foreign keys anywhere. Not into LMS's tables - schema_clear.sql's
# unqualified DELETE FROM albums would silently empty anything referencing
# them, and a separate attached file makes such a reference impossible to
# declare in the first place, since SQLite resolves FK targets within one
# database. And none between our own tables either: LMS sets
# PRAGMA foreign_keys = ON connection-wide (Slim/Utils/SQLiteHelper.pm:99), so
# an ON DELETE CASCADE here would be live, and nothing is worth a cascade that
# could remove a confirmed match.
sub _migration_1 {
	my $dbh = shift;

	# discogs_match. Identity is album_key - a hash over the album's tracks'
	# urlmd5, sorted - because albums.id is INTEGER PRIMARY KEY AUTOINCREMENT
	# and does not survive a library.db wipe, while urlmd5 is LMS's own
	# cross-wipe key. lms_album_id is a cache column, never identity.
	#
	# The length CHECK matters: an album with no qualifying tracks must produce
	# no key at all rather than a hash of the empty string, which is a single
	# constant every empty album would collide on.
	#
	# match_tier records provenance, not just which cascade tier ran, so it
	# carries 'manual' alongside design §3's three tiers - the review queue and
	# manual re-match both write it. Typos in either enum would otherwise
	# surface as a silently missing badge, indistinguishable from "not matched".
	$dbh->do(q{
		CREATE TABLE IF NOT EXISTS squeezewax.discogs_match (
			album_key               TEXT    NOT NULL PRIMARY KEY
			                                CHECK (length(album_key) = 32),
			mb_album_id             TEXT,
			lms_album_id            INTEGER,
			discogs_release_id      INTEGER,
			discogs_master_id       INTEGER,
			match_tier              TEXT    NOT NULL
			                                CHECK (match_tier IN ('strict','structural','fuzzy','manual')),
			state                   TEXT    NOT NULL DEFAULT 'candidate'
			                                CHECK (state IN ('candidate','confirmed')),
			matched_at              INTEGER,

			-- Orphan-recovery snapshot, captured at confirm time. Lives here
			-- rather than in discogs_collection so that recovery survives a
			-- collection wipe.
			snapshot_artist         TEXT,
			snapshot_album_title    TEXT,
			snapshot_track_count    INTEGER,
			snapshot_total_duration INTEGER
		)
	});

	$dbh->do('CREATE INDEX IF NOT EXISTS squeezewax.discogs_match_release
		ON discogs_match (discogs_release_id)');
	$dbh->do('CREATE INDEX IF NOT EXISTS squeezewax.discogs_match_lms_album
		ON discogs_match (lms_album_id)');
	$dbh->do('CREATE INDEX IF NOT EXISTS squeezewax.discogs_match_mb_album
		ON discogs_match (mb_album_id)');

	# The orphan lookup: confirmed rows whose snapshot might fit a new album.
	$dbh->do('CREATE INDEX IF NOT EXISTS squeezewax.discogs_match_orphan
		ON discogs_match (state, snapshot_track_count)');

	# discogs_release_cache. Untouched by anything LMS does to its own
	# database, so relinks and the v2 completeness check cost no API calls once
	# a release has been fetched once. GET /releases/{id} is the only endpoint
	# that returns a tracklist, which makes this worth keeping indefinitely.
	$dbh->do(q{
		CREATE TABLE IF NOT EXISTS squeezewax.discogs_release_cache (
			discogs_release_id INTEGER NOT NULL PRIMARY KEY,
			discogs_master_id  INTEGER,
			payload            TEXT,
			fetched_at         INTEGER NOT NULL
		)
	});

	# discogs_collection. Entirely regenerable - it caches Discogs' own data
	# and holds nothing the user entered here, since we deliberately do not
	# keep a local owned flag (design §5). A rekey costs DROP, recreate and a
	# ~20-request re-sync, so schema changes here are cheap.
	#
	# Note that instance_id cannot hold wantlist rows: a Discogs want has no
	# instance. v1 writes owned rows only; see TODO.md for the v2 rekey.
	$dbh->do(q{
		CREATE TABLE IF NOT EXISTS squeezewax.discogs_collection (
			instance_id        INTEGER NOT NULL PRIMARY KEY,
			discogs_release_id INTEGER NOT NULL,
			list_state         TEXT    NOT NULL DEFAULT 'owned'
			                           CHECK (list_state IN ('owned','wantlist')),
			format             TEXT,
			catalog_no         TEXT,
			label              TEXT,
			country            TEXT,
			year               INTEGER,
			condition          TEXT,
			added_at           INTEGER,
			notes              TEXT,
			synced_at          INTEGER
		)
	});

	# The badge-derivation join in design §4: confirmed match, then is the
	# release in the collection, then what list_state.
	$dbh->do('CREATE INDEX IF NOT EXISTS squeezewax.discogs_collection_release
		ON discogs_collection (discogs_release_id, list_state)');

	# discogs_price_snapshot. One row per lookup, so history is retained.
	$dbh->do(q{
		CREATE TABLE IF NOT EXISTS squeezewax.discogs_price_snapshot (
			discogs_release_id INTEGER NOT NULL,
			snapshot_at        INTEGER NOT NULL,
			price_low          REAL,
			price_median       REAL,
			price_high         REAL,
			currency           TEXT,
			PRIMARY KEY (discogs_release_id, snapshot_at)
		)
	});

	return 1;
}

# Migration 2: the skip caches that make a rescan cheap. See decisions §2a.
#
# Must be idempotent like every migration, and ALTER TABLE ADD COLUMN is not -
# it throws "duplicate column name" on a re-run - so the column list is checked
# first. The whole point of the idempotence rule is that a migration dying
# partway leaves user_version at the last completed step and the next connect
# retries from there.
sub _migration_2 {
	my $dbh = shift;

	# source_timestamp: MAX(tracks.timestamp) over the album's qualifying local
	# tracks at match time. urlmd5 is md5_hex($url) (Slim/Schema.pm:1758,
	# :1947), so editing tags in place does not move album_key - and editing
	# tags is exactly what Strict matching cares about. tracks.timestamp is the
	# file mtime, which is what LMS's own changed-file detection compares
	# (Slim/Utils/Scanner/Local.pm:270-284).
	#
	# Preferred over tracks.updated_time (Slim/Schema.pm:2007): a wipe-and-rescan
	# resets updated_time for every track, which would re-match the whole
	# library, while album_key and timestamp both survive a wipe intact.
	my %columns = map { $_->{name} => 1 } @{
		$dbh->selectall_arrayref(
			'SELECT name FROM pragma_table_info(?)', { Slice => {} }, 'discogs_match'
		) || []
	};

	if ( !$columns{source_timestamp} ) {
		$dbh->do('ALTER TABLE squeezewax.discogs_match ADD COLUMN source_timestamp INTEGER');
	}

	# discogs_no_match: "this tier was attempted for this album at this source
	# state and produced no candidate". Without it, an album with no Discogs tag
	# is re-read on every rescan forever - and LMS reads no audio files at all on
	# a no-change rescan, so that would be a cost where there is currently none.
	#
	# Deliberately NOT a 'none' tier in discogs_match: that would put regenerable
	# cache in the one table that is not disposable, and would pollute the
	# (state, snapshot_track_count) orphan-recovery index. This table is
	# regenerable in full - dropping it costs re-reads, never a match.
	#
	# PK is (album_key, tier), not album_key: strict-negative ("don't re-read the
	# file") and structural-negative ("don't re-run the search") are different
	# facts with different costs, and step 4 needs both true of one album at once.
	#
	# 'fuzzy' is deliberately absent - Fuzzy is v2, and widening the CHECK later
	# is DROP + recreate on a regenerable table, the cheapest migration there is.
	#
	# No conflict_note column; conflict rows carry a NULL discogs_release_id,
	# see §3a.
	$dbh->do(q{
		CREATE TABLE IF NOT EXISTS squeezewax.discogs_no_match (
			album_key        TEXT    NOT NULL
			                         CHECK (length(album_key) = 32),
			tier             TEXT    NOT NULL
			                         CHECK (tier IN ('strict','structural')),
			source_timestamp INTEGER,
			checked_at       INTEGER NOT NULL,
			PRIMARY KEY (album_key, tier)
		)
	});

	return 1;
}

=head2 isReady()

True once the database is attached and usable. Every entry point must check
this before touching our tables.

=cut

sub isReady { return $ready }

=head2 lastError()

The failure that made isReady() false, if any.

=cut

sub lastError { return $error }

1;
