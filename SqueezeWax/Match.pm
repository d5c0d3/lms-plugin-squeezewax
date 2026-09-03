package Plugins::SqueezeWax::Match;

# Writes into squeezewax.db.
#
# Created in build-order step 3 commit 4 rather than commit 5, because §3b's
# invalidation is DML on our schema and Settings.pm should not carry SQL. The
# Strict write path arrives in commit 5.
#
# Every entry point here must check Schema->isReady first. And note finding 2b:
# during a scan the scanner holds a write lock on every attached database,
# because Slim/Utils/SQLiteHelper.pm:358 sets sqlite_use_immediate_transaction
# and BEGIN IMMEDIATE locks all of them. Server-side writes must therefore be
# refused while Slim::Music::Import->stillScanning, not attempted and retried.

use strict;

use Slim::Schema;
use Slim::Utils::Log;

use Plugins::SqueezeWax::Schema;

my $log = logger('plugin.squeezewax');

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

	if ( !Plugins::SqueezeWax::Schema->isReady ) {
		$log->warn( 'cannot invalidate the strict cache: '
			. ( Plugins::SqueezeWax::Schema->lastError || 'database not ready' ) );
		return undef;
	}

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

	# do() returns '0E0' for zero rows, which is true but numerically zero.
	my $total = ( $deleted || 0 ) + ( $nulled || 0 );

	main::INFOLOG && $log->is_info && $log->info(
		"strict cache invalidated: $deleted no-match rows deleted, "
		. "$nulled match rows will be re-examined"
	);

	return $total;
}

1;
