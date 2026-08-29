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

		$ready = 1;
	};

	if ($@) {
		$error = $@;
		$ready = 0;

		$log->error("Couldn't attach " . DB_NAME . ": $error");
		logError("SqueezeWax is disabled: couldn't attach " . DB_NAME . ": $error");
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
