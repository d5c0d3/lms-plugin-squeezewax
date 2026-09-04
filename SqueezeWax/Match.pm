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

use Plugins::SqueezeWax::Library;
use Plugins::SqueezeWax::Schema;

my $log = logger('plugin.squeezewax');

# Refusal reasons already logged, so a per-album loop cannot repeat one.
my %warned;

# Whether this process may write to our tables right now, as a pure function of
# the three inputs. Returns the reason to refuse, or undef to allow.
#
# The rule used to be stated in this module's header and enforced in Settings.pm,
# which left every new caller to remember something the module claimed to
# guarantee. It cannot be a blanket stillScanning check either: in the scanner
# stillScanning is true by definition and the importer is exactly the thing that
# must write. The scanner owns writes during a scan; the server defers until it
# is over (finding 2b).
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

	# Once per reason per process. The importer calls this on a 5,000-album loop,
	# and an unusable schema would otherwise produce 5,000 identical warn lines -
	# turning a diagnostic into the thing that buries the diagnostics. startScan's
	# early return should stop it reaching that loop at all, but "should" is what
	# the guard is for.
	if ( !$warned{$refusal}++ ) {
		$log->warn( "refusing to write to squeezewax.db: $refusal"
			. ( $ready ? '' : ' (' . ( Plugins::SqueezeWax::Schema->lastError || 'unknown' ) . ')' ) );
	}

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

# Both skip caches in one round trip. Two rows back is the invariant-1 violation
# §2a says Match.pm enforces - an album in discogs_match and discogs_no_match for
# the same tier - caught for free on the one code path that would ever notice,
# and it returns match_tier for the manual guard at the same time.
my $STATE_SQL = q{
	SELECT 'match' AS src, match_tier AS tier, source_timestamp, discogs_release_id, state
	  FROM squeezewax.discogs_match
	 WHERE album_key = ?
	UNION ALL
	SELECT 'none' AS src, tier, source_timestamp, NULL, NULL
	  FROM squeezewax.discogs_no_match
	 WHERE album_key = ? AND tier = 'strict'
};

=head2 strictState( $albumKey )

What we already know about this album at Strict tier. Returns a hashref with
C<src> ('match' or 'none'), C<tier>, C<source_timestamp>, C<discogs_release_id>
and C<state>, or undef when nothing is recorded.

=cut

sub strictState {
	my ( $class, $albumKey ) = @_;

	my $rows = Slim::Schema->dbh->selectall_arrayref(
		$STATE_SQL, { Slice => {} }, $albumKey, $albumKey
	);

	return undef unless $rows && @$rows;

	if ( @$rows > 1 ) {
		# §2a invariant 1. No constraint can express it - foreign keys are banned
		# (§2) and SQLite has no cross-table CHECK - so this is where it is
		# enforced. Prefer the discogs_match row: it may carry a decision, and a
		# no-match row never does.
		$log->error(
			"album_key $albumKey has rows in both discogs_match and discogs_no_match "
			. 'for tier strict; preferring the match row'
		);

		my ($match) = grep { $_->{src} eq 'match' } @$rows;

		return $match if $match;
	}

	return $rows->[0];
}

=head2 recordStrict( \%album, \%decision )

Write the outcome of the Strict pass for one album. C<%decision> is what
C<Plugins::SqueezeWax::Tags-E<gt>decide> returned; an empty hashref means no
configured tag was present.

Returns one of 'confirmed', 'candidate', 'none', 'manual' or undef.

=cut

sub recordStrict {
	my ( $class, $album, $decision, $state ) = @_;

	return undef unless $class->_writeOk;

	my $dbh = Slim::Schema->dbh;
	my $key = $album->{album_key};
	my $now = time();

	# Rule one, checked before anything else. An in-place file change that has
	# nothing to do with tags - artwork embedded, ReplayGain written - moves
	# tracks.timestamp without moving album_key, so a manually re-matched album
	# WILL be re-examined. An unguarded upsert would silently restore the file's
	# original tag over the pressing the user chose: no log line, wrong badge, no
	# way for them to tell.
	#
	# Not expressible as `ON CONFLICT ... DO UPDATE ... WHERE match_tier <>
	# 'manual'`, though SQLite supports that: verified, it leaves the manual row
	# COMPLETELY untouched, including source_timestamp - so the importer would
	# re-examine it on every scan forever. We need to refresh the cheap columns
	# and leave the decision alone, which is two different things.
	if ( $state && $state->{src} eq 'match' && ( $state->{tier} || '' ) eq 'manual' ) {
		$dbh->do(
			'UPDATE squeezewax.discogs_match SET source_timestamp = ?, lms_album_id = ?
			  WHERE album_key = ?',
			undef, $album->{source_timestamp}, $album->{album_id}, $key
		);

		return 'manual';
	}

	if ( $decision->{conflict} ) {
		return $class->_recordConflict( $album, $decision, $state );
	}

	if ( $decision->{id} ) {
		return $class->_recordMatch( $album, $decision );
	}

	return $class->_recordNoMatch( $album, $state );
}

# A clean hit. Auto-confirm is what design §3 specifies for Strict: the tag names
# the release, so there is nothing to resolve.
sub _recordMatch {
	my ( $class, $album, $decision ) = @_;

	my $dbh = Slim::Schema->dbh;
	my $key = $album->{album_key};

	$dbh->do(
		q{
			INSERT INTO squeezewax.discogs_match
				(album_key, lms_album_id, discogs_release_id, discogs_master_id,
				 match_tier, state, matched_at, source_timestamp,
				 snapshot_album_title, snapshot_track_count)
			VALUES (?,?,?,?,'strict','confirmed',?,?,?,?)
			ON CONFLICT(album_key) DO UPDATE SET
				lms_album_id         = excluded.lms_album_id,
				discogs_release_id   = excluded.discogs_release_id,
				discogs_master_id    = excluded.discogs_master_id,
				match_tier           = excluded.match_tier,
				state                = excluded.state,
				matched_at           = excluded.matched_at,
				source_timestamp     = excluded.source_timestamp,
				snapshot_album_title = excluded.snapshot_album_title,
				snapshot_track_count = excluded.snapshot_track_count
		},
		undef,
		$key, $album->{album_id}, $decision->{id}, $decision->{master_id},
		time(), $album->{source_timestamp}, $album->{title}, $album->{local_tracks}
	);

	_clearNoMatch( $dbh, $key );

	return 'confirmed';
}

# Tags disagree, or a configured tag's value will not parse. §3a.
sub _recordConflict {
	my ( $class, $album, $decision, $state ) = @_;

	my $dbh = Slim::Schema->dbh;
	my $key = $album->{album_key};

	# What a conflict does to an EXISTING row, per §3a: an incumbent
	# discogs_release_id is preserved rather than NULLed. §3a's argument for
	# writing NULL on a fresh conflict is that taking the top-precedence tag's id
	# would be first-wins under another name - but preserving an incumbent is not
	# choosing between the competing tags. That choice was already made and §2a
	# says a decision survives. The demotion to 'candidate' is what stops the
	# badge, since the badge join is state = 'confirmed'.
	my $incumbent = ( $state && $state->{src} eq 'match' )
		? $state->{discogs_release_id}
		: undef;

	$log->warn(
		'conflicting Discogs tags on ' . Plugins::SqueezeWax::Library->albumLabel($album)
		. ': ' . join( ', ', @{ $decision->{conflict} } )
		. ( defined $incumbent ? " (keeping the existing match $incumbent)" : '' )
	);

	$dbh->do(
		q{
			INSERT INTO squeezewax.discogs_match
				(album_key, lms_album_id, discogs_release_id,
				 match_tier, state, matched_at, source_timestamp)
			VALUES (?,?,?,'strict','candidate',?,?)
			ON CONFLICT(album_key) DO UPDATE SET
				lms_album_id     = excluded.lms_album_id,
				match_tier       = excluded.match_tier,
				state            = excluded.state,
				source_timestamp = excluded.source_timestamp
		},
		undef,
		$key, $album->{album_id}, $incumbent, time(), $album->{source_timestamp}
	);

	_clearNoMatch( $dbh, $key );

	return 'candidate';
}

# No configured tag on either candidate track.
sub _recordNoMatch {
	my ( $class, $album, $state ) = @_;

	my $dbh = Slim::Schema->dbh;
	my $key = $album->{album_key};

	# §2a invariant 2, and the one place a discogs_match row may be deleted. A
	# conflict row whose tags have since been removed would otherwise sit in the
	# review queue forever advertising a conflict that no longer exists, and step
	# 5 cannot even render it - §3a stores no conflict_note and re-reads tags that
	# are now gone.
	#
	# The predicate IS the rule "never delete a row that carries a decision or a
	# recovery snapshot", written out: 'strict' excludes manual, 'candidate'
	# excludes confirmed, a NULL release id excludes anything adjudicated, and a
	# NULL snapshot excludes orphan recovery's index material. Anyone widening
	# this must show their case passes that test, not that it resembles this
	# shape.
	$dbh->do(
		q{
			DELETE FROM squeezewax.discogs_match
			 WHERE album_key = ?
			   AND match_tier = 'strict'
			   AND state = 'candidate'
			   AND discogs_release_id IS NULL
			   AND snapshot_track_count IS NULL
		},
		undef, $key
	);

	# Only when nothing survives in discogs_match, or invariant 1 breaks.
	my ($still) = $dbh->selectrow_array(
		'SELECT COUNT(*) FROM squeezewax.discogs_match WHERE album_key = ?', undef, $key
	);

	if ($still) {
		# A confirmed or manual row we may not touch. Refresh the cheap column so
		# the album stops being re-examined, and write no no-match row.
		$dbh->do(
			'UPDATE squeezewax.discogs_match SET source_timestamp = ? WHERE album_key = ?',
			undef, $album->{source_timestamp}, $key
		);

		return 'kept';
	}

	$dbh->do(
		q{
			INSERT INTO squeezewax.discogs_no_match (album_key, tier, source_timestamp, checked_at)
			VALUES (?, 'strict', ?, ?)
			ON CONFLICT(album_key, tier) DO UPDATE SET
				source_timestamp = excluded.source_timestamp,
				checked_at       = excluded.checked_at
		},
		undef, $key, $album->{source_timestamp}, time()
	);

	return 'none';
}

# An album cannot be both matched and not-matched at the same tier (§2a
# invariant 1).
sub _clearNoMatch {
	my ( $dbh, $key ) = @_;

	$dbh->do(
		q{DELETE FROM squeezewax.discogs_no_match WHERE album_key = ? AND tier = 'strict'},
		undef, $key
	);
}

1;
