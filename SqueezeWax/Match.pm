package Plugins::SqueezeWax::Match;

# Writes into squeezewax.db.
#
# Created in build-order step 3 commit 4 rather than commit 5, because §3b's
# invalidation is DML on our schema and Settings.pm should not carry SQL. The
# Strict write path arrives in commit 5.
#
# Every entry point here calls _writeOk first, which enforces both rules rather
# than leaving them to each caller: the schema has to be usable, and a
# server-side write has to be refused while a scan is running, because
# BEGIN IMMEDIATE locks every attached database (finding 2b). The scanner is
# exempt from the second - it holds that lock and is entitled to it.

use strict;

use Slim::Music::Import;
use Slim::Schema;
use Slim::Utils::Log;

use Plugins::SqueezeWax::Schema;

my $log = logger('plugin.squeezewax');

# Whether this process may write to our tables right now.
#
# The rule was previously stated in the header and enforced in Settings.pm, which
# meant every new caller had to remember something the module claimed to
# guarantee. Commit 5 adds one caller and step 5 will add more, so it lives here.
#
# It cannot be a blanket stillScanning check: in the scanner stillScanning is
# true by definition and the importer is exactly the thing that must write. But
# the distinction is expressible - the scanner owns writes during a scan, the
# server defers until it is over (finding 2b).
# The policy, as a pure function of the three inputs. Returns the reason to
# refuse, or undef to allow.
#
# Separate from _writeOk because main::SCANNER is a compile-time constant that
# Perl inlines, so a test in one process cannot exercise both branches of
# `return 1 if main::SCANNER` - and the scanner branch is the one whose removal
# would silently stop the importer writing anything at all.
sub _writeRefusal {
	my ( $ready, $isScanner, $isScanning ) = @_;

	return 'database not ready' unless $ready;

	# The scanner holds the write lock during a scan and is entitled to it.
	return undef if $isScanner;

	# BEGIN IMMEDIATE locks every attached database, forced by
	# sqlite_use_immediate_transaction at Slim/Utils/SQLiteHelper.pm:358, so a
	# server-side write during a scan fails with "database is locked" rather than
	# waiting. Refuse deliberately instead of surfacing a lock error.
	return 'a scan is running' if $isScanning;

	return undef;
}

sub _writeOk {
	my $class = shift;

	my $ready = Plugins::SqueezeWax::Schema->isReady ? 1 : 0;

	# Not called when the scanner is running: in that process the answer is
	# already known and stillScanning is not a pure read (Import.pm:730-754 does
	# crash cleanup and can fire a ['rescan','done'] notification).
	my $scanning = main::SCANNER ? 0 : ( Slim::Music::Import->stillScanning ? 1 : 0 );

	my $refusal = _writeRefusal( $ready, main::SCANNER ? 1 : 0, $scanning );

	return 1 unless defined $refusal;

	$log->warn( "refusing to write to squeezewax.db: $refusal"
		. ( $ready ? '' : ' (' . ( Plugins::SqueezeWax::Schema->lastError || 'unknown' ) . ')' ) );

	return 0;
}

=head2 invalidateStrict()

Discard the cached Strict answer for the whole library, per decisions §3b.

Called when the configured tag-name set changes. Both skip caches key on file
state alone, and the tag list is not part of that key, so without this a
corrected tag list changes nothing on the next scan - and finding 4's
C<matched == 0 && examined E<gt> 0> warning cannot fire either, because
C<examined> would be zero.

Returns the number of rows affected across both tables, or undef if the schema
is not usable.

=cut

sub invalidateStrict {
	my $class = shift;

	return undef unless $class->_writeOk;

	my $dbh = Slim::Schema->dbh;

	# DELETE on discogs_no_match because it is regenerable in full (§2a); the
	# rows cost re-reads, never a match.
	my $deleted = $dbh->do(
		q{DELETE FROM squeezewax.discogs_no_match WHERE tier = 'strict'}
	);

	# UPDATE rather than DELETE on discogs_match because every row this
	# predicate touches may carry a decision - state = 'confirmed' is one, and
	# any non-NULL discogs_release_id is a proposal something adjudicated - and
	# §2a's rule is never delete a row that carries a decision or a recovery
	# snapshot. NULLing source_timestamp forces re-examination without
	# discarding anything: NULL never compares equal to a timestamp.
	#
	# Where re-examination then finds no tag at all, §2a's narrow delete
	# predicate applies at that point, in the importer, not here. The two
	# mechanisms compose, and invalidation is never the thing that removes a row.
	#
	# match_tier = 'manual' falls outside the predicate entirely, so a user's
	# own pressing choice is untouched - consistent with the write path's first
	# rule in commit 5.
	my $nulled = $dbh->do(
		q{UPDATE squeezewax.discogs_match SET source_timestamp = NULL
		   WHERE match_tier = 'strict'}
	);

	# do() returns the string '0E0' for zero rows - true, but numerically zero.
	# It has to be forced through numeric context for display too, or a no-op
	# invalidation logs "0E0 no-match rows deleted".
	$deleted = 0 + ( $deleted || 0 );
	$nulled  = 0 + ( $nulled  || 0 );

	main::INFOLOG && $log->is_info && $log->info(
		"strict cache invalidated: $deleted no-match rows deleted, "
		. "$nulled match rows will be re-examined"
	);

	return $deleted + $nulled;
}

1;
