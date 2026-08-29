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

		# Quoted rather than interpolated as SQLiteHelper.pm:353 does, so a
		# path containing an apostrophe cannot break the statement.
		$dbh->do( 'ATTACH ' . $dbh->quote($path) . ' AS ' . DB_SCHEMA );

		# Note that a missing *file* is not an error - SQLite creates it
		# silently. Only a missing or unwritable directory fails here. It is
		# the user_version check that catches an empty database, not this.

		$class->_ensureWalMode($dbh);

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

		return;
	}

	my ($mode) = $dbh->selectrow_array( 'PRAGMA ' . DB_SCHEMA . '.journal_mode = WAL' );

	if ( !$mode || lc($mode) ne 'wal' ) {
		die 'failed to set WAL journal mode (got ' . ($mode || 'no result') . ")\n";
	}

	return 1;
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
