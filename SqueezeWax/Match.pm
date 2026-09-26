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
#
# match_tier IS NOT NULL is what makes that invariant survive the ownership
# pass (decisions §15.13 part 6). Since migration 3 the column is nullable, and
# a NULL one means "no identification": the row exists for its ownership
# conclusion alone. Such a row and a strict no-match row may coexist for one
# album without contradiction - they answer different questions, "do you own
# this record" and "did reading the tags produce a candidate" - so invariant 1
# is reworded to cover identification rows only, and the importer's lookups
# filter to those. Without the clause, every untagged album the pass concluded
# on would log an invariant-1 error on the next scan.
my $STATE_SQL = q{
	SELECT 'match' AS src, match_tier AS tier, source_timestamp, discogs_release_id, state
	  FROM squeezewax.discogs_match
	 WHERE album_key = ?
	   AND match_tier IS NOT NULL
	UNION ALL
	SELECT 'none' AS src, tier, source_timestamp, NULL, NULL
	  FROM squeezewax.discogs_no_match
	 WHERE album_key = ? AND tier = 'strict'
};

=head2 hasAnyStrictMatch()

True if the configured tag names have ever named a release: a Strict row
carrying a C<discogs_release_id>, whatever its C<state>.

Used by the importer's anomaly warning to tell "this configuration produces
nothing" from "this one album has no tag". A run that examines a single
untagged album in a library where hundreds are matched is not an anomaly.

A hit is a clean tag hit, not an ownership decision. Since decisions §13.4,
identification writes C<candidate> and only the ownership pass promotes to
C<confirmed>, so a predicate keyed on C<state> would answer 0 for every library
until step 7 - and would fire the warning on every scan of every library, which is
the warning's own documented failure mode. The question it asks is whether the
tags have ever produced anything, and tags are what C<discogs_release_id>
records.

A conflict row holding an incumbent id counts: tags did once name a release. A
fresh conflict row, whose id is NULL, does not. A manual row does not either -
the user chose it, and it says nothing about the tag names.

=cut

sub hasAnyStrictMatch {
	my $class = shift;

	my ($found) = Slim::Schema->dbh->selectrow_array(
		q{SELECT 1 FROM squeezewax.discogs_match
		   WHERE match_tier = 'strict' AND discogs_release_id IS NOT NULL LIMIT 1}
	);

	return $found ? 1 : 0;
}

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

# --- The identification pre-pass ------------------------------------------
#
# Two things cannot be decided one album at a time, so they happen in a walk of
# their own before the main loop (decisions §15.12 part 2, plan §2.6).
#
# The relink is the reason. §15.5's fit is "exactly one" across the WHOLE
# library, in both directions. Inside the per-album loop it would be decided
# greedily - the first new album to fit an orphan would claim it before a second
# candidate was ever seen - so the answer would depend on scan order, which is
# the one thing a recovery mechanism must not do.
#
# The backfill rides along because it needs the same walk: an existing row's
# artist comes from the current album with that album_key, and there is nowhere
# else to read it from without a second pass over LMS's tables.
#
# The reads below load our two tables whole. They are small - one row per
# matched album - and loading them is what keeps the walk a single streaming
# pass with no per-album query against LMS.

=head2 snapshotRows()

Every C<discogs_match> row, with the columns the pre-pass needs: identity
(C<album_key>, C<lms_album_id>, C<match_tier>) and the snapshot.

Returns an arrayref of hashrefs, empty when there are none.

=cut

sub snapshotRows {
	my $class = shift;

	return Slim::Schema->dbh->selectall_arrayref(
		q{SELECT album_key, lms_album_id, match_tier,
		         snapshot_artist, snapshot_album_title, snapshot_track_count
		    FROM squeezewax.discogs_match},
		{ Slice => {} }
	) || [];
}

=head2 noMatchKeys()

The C<album_key>s carrying a strict C<discogs_no_match> row, as a hashref.

The pre-pass needs both tables to identify a key miss: an album with a
no-match row has been examined and produced nothing, so it is not a candidate
for a relink. Testing C<discogs_match> alone would offer it one, and the
relink would then put a match row on an C<album_key> that already has a
no-match row - breaking §2a invariant 1 (plan §0.4).

=cut

sub noMatchKeys {
	my $class = shift;

	my $keys = Slim::Schema->dbh->selectcol_arrayref(
		q{SELECT album_key FROM squeezewax.discogs_no_match WHERE tier = 'strict'}
	) || [];

	return { map { $_ => 1 } @$keys };
}

# The fit key: the three snapshot columns rendered as one string, so that
# "fits" becomes "has the same key" and the one-to-one test is two hash counts
# rather than a quadratic comparison.
#
# Exact equality, no normalisation (§15.5). Both sides are LMS's own strings -
# the snapshot was taken from an LMS album and the candidate is an LMS album -
# so L2 normalisation, which exists for comparing Discogs' text with LMS's, has
# no work to do here.
#
# BYTES on both sides. DBD::SQLite returns bytes (no sqlite_unicode anywhere in
# slimserver's Slim/) and the iterator passes contributors.name through
# untouched, so both sides are the same bytes for the same name. Decoding one
# side would make every non-ASCII artist silently fail to fit (§2.3).
#
# undef anywhere means no key at all, so the row fits nothing - which is what
# makes a pre-step-4 row with a NULL snapshot_artist unrelinkable until the
# backfill fills it, and what the backfill exists for (§15.12 part 1).
#
# Length-prefixed rather than joined on a separator: a separator that can occur
# inside a title would let ("A", "B|C") and ("A|B", "C") collide, and an album
# title is exactly the kind of field that contains punctuation. The track count
# is numified so that 5 and "5" agree, which is the == the predicate asks for.
sub _fitKey {
	my ( $artist, $title, $trackCount ) = @_;

	return undef unless defined $artist && defined $title && defined $trackCount;

	return join( "\x00",
		length($artist), $artist, length($title), $title, $trackCount + 0 );
}

# Pair orphaned rows with key-miss albums, where the pairing is unambiguous.
#
# A plain function, and pure: no database handle, no logging, no Slim::* call.
# That is what lets the offline suite exercise it directly, and it is why the
# resolver lives here rather than in Importer.pm, whose startScan body is inside
# `if (main::SCANNER)` and is constant-folded away in any test process.
#
# Unique in BOTH directions (§15.12 part 2): the orphan must fit exactly one
# miss AND that miss must fit exactly one orphan. Requiring it on the orphan
# side only would let two new albums contend for one orphan, with scan order
# deciding; requiring it on the miss side only would let one album claim two
# orphans. Everything else is left exactly as it was and counted unresolved -
# the ambiguous branch needs the review queue, which is step 8 (§15.5 part 4).
#
# Because the fit is exact equality, "fits exactly one" is "exactly one row has
# this key", so both tests are counts on the same hash key.
sub _resolveRelinks {
	my ( $orphans, $misses ) = @_;

	my ( %missByFit, %missCount );

	for my $miss ( @{ $misses || [] } ) {
		my $fit = _fitKey( $miss->{artist}, $miss->{title}, $miss->{local_tracks} );
		next unless defined $fit;

		$missCount{$fit}++;
		$missByFit{$fit} = $miss;
	}

	my ( %orphanByFit, %orphanCount );

	for my $orphan ( @{ $orphans || [] } ) {
		my $fit = _fitKey( $orphan->{snapshot_artist}, $orphan->{snapshot_album_title},
			$orphan->{snapshot_track_count} );
		next unless defined $fit;

		$orphanCount{$fit}++;
		$orphanByFit{$fit} = $orphan;
	}

	my @pairs;

	# Sorted so the order of the writes is a property of the data rather than of
	# hash ordering: an abort part-way through then leaves a reproducible state.
	for my $fit ( sort keys %orphanCount ) {
		next unless $orphanCount{$fit} == 1;
		next unless ( $missCount{$fit} || 0 ) == 1;

		push @pairs, {
			old_key  => $orphanByFit{$fit}->{album_key},
			new_key  => $missByFit{$fit}->{album_key},
			album_id => $missByFit{$fit}->{album_id},
		};
	}

	return \@pairs;
}

=head2 backfillArtist( $albumKey, $artist )

Fill a NULL C<snapshot_artist> on an existing snapshot, from the current
album's artist. Returns 1 if a row was written, 0 otherwise.

Nothing wrote C<snapshot_artist> before step 4, so every snapshot taken before
it has NULL there - and §15.5's fit is exact equality, which NULL never
satisfies. The skip contract means an unchanged album is never re-examined, so
the normal write path would never fill them in either: without this, recovery
would cover nothing that exists on the reference server today (§15.12 part 1).

That column only. No state, no timestamp, no other snapshot column, and no file
read - this is LMS's own data for the same C<album_key>. Manual rows are
included, and they are the rows recovery exists for. Conflict rows are excluded
for free, because they carry no C<snapshot_track_count> (§15.4).

Idempotent: the C<IS NULL> guard is in the statement as well as in the caller's
selection, so a second run writes nothing even if the caller's list is stale.

=cut

sub backfillArtist {
	my ( $class, $albumKey, $artist ) = @_;

	return 0 unless $class->_writeOk;
	return 0 unless defined $artist;

	# prepare_cached: the first scan after this ships backfills EVERY row
	# identified before step 4, which on a real library is hundreds or
	# thousands. One prepare for the lot.
	my $sth = Slim::Schema->dbh->prepare_cached(
		q{UPDATE squeezewax.discogs_match
		     SET snapshot_artist = ?
		   WHERE album_key = ?
		     AND snapshot_artist IS NULL
		     AND snapshot_track_count IS NOT NULL}
	);

	my $rows = $sth->execute( $artist, $albumKey );
	$sth->finish;

	return ( $rows && $rows > 0 ) ? 1 : 0;
}

=head2 relinkOrphan( $oldKey, $newKey, $albumId )

Move an orphaned match onto the album it now describes. Returns 1 on success,
0 otherwise.

An UPDATE of C<album_key> and C<lms_album_id>, clearing C<review_reason> where
it was C<'orphan'>, and nothing else. A relink re-identifies which local album a
match belongs to; it does not re-decide which release it is - so
C<discogs_release_id>, C<discogs_master_id>, C<match_tier>, C<state>,
C<matched_at>, C<source_timestamp> and the whole snapshot are carried forward
untouched.

Never an INSERT, and never a DELETE of the row being relinked. An
INSERT-plus-DELETE would be the same result by a route that can lose the row if
it fails between the two, on the one table that is not regenerable (§2a).

It does delete two OTHER rows first, both on the TARGET key and both
regenerable: a C<discogs_match> row carrying no decision, and a strict
C<discogs_no_match> row (§15.17 part 2). The first is a primary-key collision,
the second an §2a invariant 1 violation; both would otherwise land on the
scanner with nobody to tell.

On the first of those: Since step 7 the ownership pass writes a row for an album it has
a conclusion or a review reason about and nothing else - NULL tier, NULL release
id, NULL snapshot - and C<album_key> is the primary key, so such a row on the
target makes the UPDATE below fail with a constraint violation, in the scanner,
where there is nobody to tell. Decisions §15.16 part 9 (R13) is what permits
the delete: such a row carries no decision and no snapshot, the pass rebuilds it
at the next sync, and it is deleted whatever review reason it carries, since a
pass-written reason is re-derived too. The predicate is §15.13 part 5's, written
out here rather than borrowed, because this is a different caller with a
different justification.

Closes TODO 2026-09-19 "an ownership-only row blocks a later relink", for both
callers: the scanner's pre-pass and the queue page's relink.

C<source_timestamp> riding along unchanged is what makes the main loop skip the
album afterwards: its files moved but did not change, so there is nothing to
re-read (plan §0.5). One that was moved AND retagged does not skip, and
identification overwrites the relink in the same scan.

=cut

sub relinkOrphan {
	my ( $class, $oldKey, $newKey, $albumId ) = @_;

	return 0 unless $class->_writeOk;

	my $dbh = Slim::Schema->dbh;

	# The two statements must land together or not at all, and the two callers
	# arrive with different transaction states. In the scanner the handle is
	# AutoCommit = 0 with one long-lived transaction open for the whole scan
	# (scanner.pl:295, quoted in Importer.pm's COMMIT_EVERY comment), so both
	# statements already ride it and begin_work would die with "already in a
	# transaction". In the server the handle is AutoCommit = 1
	# (Slim/Schema.pm:274) and there is nothing to ride, so one is opened here -
	# the same shape Ownership::_write uses, which only ever runs server-side.
	#
	# Hence the conditional rather than an unconditional begin_work: the
	# guarantee is "one transaction", not "a transaction this sub opened".
	my $ownTxn = $dbh->{AutoCommit} ? 1 : 0;

	$dbh->begin_work if $ownTxn;

	my $rows = eval {
		# First: the regenerable row standing on the target key, if any. Not
		# prepare_cached with the orphan UPDATE below sharing a handle - they are
		# two statements and each gets its own.
		$dbh->do(
			q{DELETE FROM squeezewax.discogs_match
			   WHERE album_key = ?
			     AND match_tier IS NULL
			     AND discogs_release_id IS NULL
			     AND snapshot_track_count IS NULL},
			undef, $newKey
		);

		# And the target's strict no-match row, for the same reason one clause
		# further out (§15.17 part 2). §2a invariant 1 forbids an album holding
		# a match row and a no-match row at once, so this has to go before the
		# UPDATE lands the match row - not after, and not instead.
		#
		# Deleting it costs nothing that cannot be rebuilt: discogs_no_match is
		# regenerable in full (its own migration comment says so), and the worst
		# case is one album re-read at the next scan. That is what puts it
		# inside §2a invariant 3 rather than against it.
		#
		# The SCANNER never reaches this: _prePass excludes no-match albums from
		# its key misses, so it offers no such target and its behaviour is
		# unchanged. This clause exists for the queue page, which decides after
		# the scan, when every current album already has a row of some kind.
		$dbh->do(
			q{DELETE FROM squeezewax.discogs_no_match
			   WHERE album_key = ? AND tier = 'strict'},
			undef, $newKey
		);

		# Then the move. review_reason is cleared only where it was 'orphan':
		# the relink is exactly what resolves that reason, and naming the column
		# unconditionally would blank a 'conflict' the importer owns (R3).
		my $sth = $dbh->prepare_cached(
			q{UPDATE squeezewax.discogs_match
			     SET album_key = ?, lms_album_id = ?,
			         review_reason = CASE WHEN review_reason = 'orphan'
			                              THEN NULL ELSE review_reason END
			   WHERE album_key = ?}
		);

		my $n = $sth->execute( $newKey, $albumId, $oldKey );
		$sth->finish;

		# Exactly one row, or we did not do what we think we did. album_key is
		# the PRIMARY KEY, so more than one is impossible and zero means the
		# orphan went away between the read and the write. Inside the eval, so
		# that the delete above is rolled back with it: on the scanner's shared
		# transaction there is nothing to roll back to, but the row deleted
		# there is regenerable by definition (R13), so nothing is lost either
		# way. The caller must not count this as a relink - the summary is the
		# only place a user sees that recovery ran at all.
		die "changed " . ( defined $n ? $n : 'no' ) . " rows, expected exactly 1\n"
			unless defined $n && $n == 1;

		$n;
	};

	if ( !defined $rows ) {
		my $err = $@ || 'unknown error';
		chomp $err;

		eval { $dbh->rollback; 1 } if $ownTxn;

		$log->error("relinking $oldKey to $newKey $err");

		return 0;
	}

	$dbh->commit if $ownTxn;

	return 1;
}

=head2 recordStrict( \%album, \%decision )

Write the outcome of the Strict pass for one album. C<%decision> is what
C<Plugins::SqueezeWax::Tags-E<gt>decide> returned; an empty hashref means no
configured tag was present.

Returns one of 'identified', 'candidate' (a conflict), 'none', 'kept',
'manual' or undef.

=cut

sub recordStrict {
	my ( $class, $album, $decision, $state ) = @_;

	return undef unless $class->_writeOk;

	my $dbh = Slim::Schema->dbh;
	my $key = $album->{album_key};

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

# A clean hit: the tag names the release, so there is nothing to resolve at this
# tier. It is an IDENTIFICATION, not a confirmation. Confirmation means the
# release is in the user's collection, which this process has not checked and
# cannot check - design §3 node E puts that test in the ownership pass, and
# decisions §13.4 and §15.3 make that pass the only writer of 'confirmed'. So
# this writes 'candidate' and returns 'identified'.
#
# The recovery snapshot rides identification rather than promotion (§15.4): the
# scanner has the album's LMS-side data open here, nothing about a snapshot
# depends on ownership, and capturing on promotion would leave every unowned
# album without recovery material. snapshot_artist is $album->{artist} exactly
# as the iterator supplied it - bytes from contributors.name, never decoded,
# because recovery compares it against the same bytes (§11.4).
#
# review_reason is written NULL, explicitly, in both halves. This is the one
# place 'conflict' is cleared (§15.16 part 3): the tags now name one release, so
# whatever they disagreed about before is settled and the row must leave the
# queue. It also clears any pass-written reason, which costs nothing - the next
# sync re-derives all five of those from the collection.
sub _recordMatch {
	my ( $class, $album, $decision ) = @_;

	my $dbh = Slim::Schema->dbh;
	my $key = $album->{album_key};

	$dbh->do(
		q{
			INSERT INTO squeezewax.discogs_match
				(album_key, lms_album_id, discogs_release_id, discogs_master_id,
				 match_tier, state, matched_at, source_timestamp,
				 snapshot_album_title, snapshot_track_count, snapshot_artist,
				 review_reason)
			VALUES (?,?,?,?,'strict','candidate',?,?,?,?,?,NULL)
			ON CONFLICT(album_key) DO UPDATE SET
				lms_album_id         = excluded.lms_album_id,
				discogs_release_id   = excluded.discogs_release_id,
				discogs_master_id    = excluded.discogs_master_id,
				match_tier           = excluded.match_tier,
				state                = excluded.state,
				matched_at           = excluded.matched_at,
				source_timestamp     = excluded.source_timestamp,
				snapshot_album_title = excluded.snapshot_album_title,
				snapshot_track_count = excluded.snapshot_track_count,
				snapshot_artist      = excluded.snapshot_artist,
				review_reason        = excluded.review_reason
		},
		undef,
		$key, $album->{album_id}, $decision->{id}, $decision->{master_id},
		time(), $album->{source_timestamp}, $album->{title}, $album->{local_tracks},
		$album->{artist}
	);

	_clearNoMatch( $dbh, $key );

	return 'identified';
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
	# says a decision survives. The demotion to 'candidate' marks the row
	# unresolved for the review queue (step 8). It is NOT what stops the badge:
	# the badge reads the ownership column directly, with no join and no
	# render-time test on state (design §4). Since §13.4 an identified row is
	# 'candidate' already, over one of those the demotion changes no value at
	# all - what the conflict actually records is the tier and timestamp
	# refresh, and the warning below.
	#
	# review_reason = 'conflict' is what makes the row findable. Before step 8
	# nothing recorded that a row was contested: since §13.4 an identified row is
	# 'candidate' too, so a fresh conflict is only distinguishable by its NULL
	# release id, and an INCUMBENT conflict - the branch below, which keeps the
	# id - is indistinguishable from a plain identification by any column. That
	# is TODO 2026-09-19's "a conflict row with an incumbent id looks like a
	# tagged candidate"; this line closes it, and B1's pass reads the column to
	# decline promoting such a row (§15.16 part 4).
	#
	# Written in both halves, so a conflict over a previously clean row marks it
	# as well as a fresh one. It is cleared only by _recordMatch, by relinkOrphan
	# where it was 'orphan', or by the user rejecting the row: 'conflict' is
	# sticky and the ownership pass never touches it (§15.16 part 3).
	#
	# No snapshot columns here, by rule (§15.4): a snapshot on a conflict row
	# would make _recordNoMatch's narrow delete unreachable and the row would
	# advertise a conflict forever. An EXISTING row's snapshots survive because
	# the ON CONFLICT list below does not name them - they are carried, not
	# rewritten.
	my $incumbent = ( $state && $state->{src} eq 'match' )
		? $state->{discogs_release_id}
		: undef;

	# The album label is quoted because titles contain colons - a real one from
	# hardware was "Isolar: Unidentified Explorers", which rendered as
	# "on Isolar: Unidentified Explorers: TAG=..." with no way to see where the
	# title ended. This line exists to tell a user which album to go and fix.
	$log->warn(
		'conflicting Discogs tags on "'
		. Plugins::SqueezeWax::Library->albumLabel($album) . '": '
		. join( ', ', @{ $decision->{conflict} } )
		. ( defined $incumbent ? " (keeping the existing match $incumbent)" : '' )
	);

	$dbh->do(
		q{
			INSERT INTO squeezewax.discogs_match
				(album_key, lms_album_id, discogs_release_id,
				 match_tier, state, matched_at, source_timestamp, review_reason)
			VALUES (?,?,?,'strict','candidate',?,?,'conflict')
			ON CONFLICT(album_key) DO UPDATE SET
				lms_album_id     = excluded.lms_album_id,
				match_tier       = excluded.match_tier,
				state            = excluded.state,
				source_timestamp = excluded.source_timestamp,
				review_reason    = excluded.review_reason
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

	# §2a invariant 2, and the FIRST of the three places a discogs_match row may
	# be deleted (§15.16 part 7 adds user reject as the third). Unchanged by step
	# 8. A fresh conflict row whose tags have since been removed would otherwise
	# sit in the review queue forever advertising a conflict that no longer
	# exists, and the queue cannot even render it - §3a stores no conflict_note
	# and re-reads tags that are now gone.
	#
	# Note which conflict this reaches, because step 8's reject exists for the
	# other one. A FRESH conflict has a NULL release id and no snapshot, so it
	# matches every clause below and is deleted here, review_reason and all. An
	# INCUMBENT conflict kept its release id (:659-661 below), so it fails the
	# third clause, falls through to the 'kept' path, and keeps
	# review_reason = 'conflict' until the user rejects it - TODO 2026-09-07's
	# ground (a). review_reason is deliberately NOT named in the kept path's
	# UPDATE: that path refreshes the cheap columns and decides nothing.
	#
	# The predicate IS the rule "never delete a row that carries a decision or a
	# recovery snapshot", written out. Read it clause by clause, because since
	# §13.4 the state clause no longer carries the weight it reads as: an
	# identified row is 'candidate' too, so 'candidate' no longer separates
	# identifications from conflicts. What protects an identification is the
	# other two clauses - it has a release id AND a snapshot, and a fresh
	# conflict row is the only thing with neither. 'strict' still excludes
	# manual; 'candidate' still excludes a row the ownership pass promoted; a
	# NULL release id still excludes anything a tag or a user ever named; a NULL
	# snapshot still excludes orphan recovery's index material. Anyone widening
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
	#
	# The same match_tier IS NOT NULL filter $STATE_SQL carries, for the same
	# reason (§15.13 part 6): an ownership-only row is not something that
	# survived identification, so it must not suppress the no-match row. Without
	# the clause, one sync concluding on an untagged album would stop that album
	# ever being re-examined for tags.
	my ($still) = $dbh->selectrow_array(
		'SELECT COUNT(*) FROM squeezewax.discogs_match
		  WHERE album_key = ? AND match_tier IS NOT NULL', undef, $key
	);

	if ($still) {
		# A confirmed row, or a demoted candidate carrying an adjudicated id, that
		# we may not delete. Refresh the cheap columns so the album stops being
		# re-examined, and write no no-match row.
		#
		# lms_album_id as well as source_timestamp: LMS reassigns albums.id on a
		# full rescan, and this is the one path that would otherwise leave a row
		# carrying a stale id indefinitely. The other three paths all refresh it.
		$dbh->do(
			'UPDATE squeezewax.discogs_match SET source_timestamp = ?, lms_album_id = ?
			  WHERE album_key = ?',
			undef, $album->{source_timestamp}, $album->{album_id}, $key
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

=head2 recordManual( \%album, $releaseId, $masterId )

Record the user's own choice of release for one album. Returns 1 if a row was
written, 0 otherwise.

The queue page's confirm action, and the only writer of C<match_tier = 'manual'>
(§15.16 part 6). It writes C<state = 'confirmed'> directly, which C<_recordMatch>
may not: design §3 exempts a manual link from the collection cross-check that
governs Strict, so there is nothing for the ownership pass to confirm and
nothing for it to demote. C<Ownership::_decide> honours that by moving C<state>
only on a C<'strict'> row.

It captures the recovery snapshot, because a manual link IS an identification
(§15.4) and manual rows are exactly what orphan recovery exists for: the user
chose this pressing because the tags could not name it, so re-identification
after a folder move would not reproduce the choice (§15.5). C<snapshot_artist> is
C<< $album->{artist} >> as the iterator supplied it - bytes, never decoded, since
recovery compares it against the same bytes (§11.4).

It never names C<ownership>. The badge is the pass's to write and changes at the
next sync, which is what the page tells the user (§15.16 part 6).

C<review_reason> is written NULL: confirming is the answer to whatever put the
album in the queue.

=cut

sub recordManual {
	my ( $class, $album, $releaseId, $masterId ) = @_;

	return 0 unless $class->_writeOk;

	# Both ids come off a form, so both are validated here rather than trusted.
	# A non-integer release id would be stored as text in an INTEGER column -
	# SQLite's type affinity keeps a non-numeric string as-is - and would then
	# never match the collection index, so the album would silently stop
	# badging with nothing to show why.
	return 0 unless defined $releaseId && $releaseId =~ /^[0-9]+$/ && $releaseId > 0;

	# Both of Discogs' "no master" forms collapse to NULL, the same guard
	# Ownership::_indexCollection applies to the same field (:271-275): a
	# master_id of 0 taken at face value makes every masterless release collide
	# on one key at node F.
	$masterId = undef
		unless defined $masterId && $masterId =~ /^[0-9]+$/ && $masterId > 0;

	my $dbh = Slim::Schema->dbh;
	my $key = $album->{album_key};

	$dbh->do(
		q{
			INSERT INTO squeezewax.discogs_match
				(album_key, lms_album_id, discogs_release_id, discogs_master_id,
				 match_tier, state, matched_at, source_timestamp,
				 snapshot_album_title, snapshot_track_count, snapshot_artist,
				 review_reason)
			VALUES (?,?,?,?,'manual','confirmed',?,?,?,?,?,NULL)
			ON CONFLICT(album_key) DO UPDATE SET
				lms_album_id         = excluded.lms_album_id,
				discogs_release_id   = excluded.discogs_release_id,
				discogs_master_id    = excluded.discogs_master_id,
				match_tier           = excluded.match_tier,
				state                = excluded.state,
				matched_at           = excluded.matched_at,
				source_timestamp     = excluded.source_timestamp,
				snapshot_album_title = excluded.snapshot_album_title,
				snapshot_track_count = excluded.snapshot_track_count,
				snapshot_artist      = excluded.snapshot_artist,
				review_reason        = excluded.review_reason
		},
		undef,
		$key, $album->{album_id}, $releaseId, $masterId,
		time(), $album->{source_timestamp}, $album->{title}, $album->{local_tracks},
		$album->{artist}
	);

	_clearNoMatch( $dbh, $key );

	return 1;
}

=head2 rejectRow( $albumKey )

Delete one C<discogs_match> row at the user's explicit request. Returns the
number of rows deleted: 1, or 0 if the row was not one this may delete.

The THIRD permitted deletion in C<discogs_match> (§15.16 part 7), after
C<_recordNoMatch>'s narrow predicate and the ownership pass's regenerable-row
sweep. §2a's invariant 2 governs AUTOMATIC deletion - the table is the one thing
here that is not regenerable, so nothing may quietly decide a decision has
lapsed. This one is none of those things: it is user-invoked, confirmed on the
page, and one row named by its key.

The predicate is the whole of the rule, and it is narrower than "whatever the
page asked for". Four shapes are rejectable, and each because there is something
for the user to undo or be rid of:

=over

=item * a B<manual> row - their own earlier choice;

=item * a row marked C<'conflict'> - the incumbent kind, which
C<_recordNoMatch> cannot reach and which otherwise advertises a conflict
forever (TODO 2026-09-07 ground (a));

=item * a row marked C<'orphan'> - a match for an album that is gone, which
nothing sweeps automatically (§2a invariant 4) and which may be a manual row
the user no longer wants recovered (ground (b));

=item * a fresh conflict by §3a's own predicate, C<'strict'> with a NULL
release id, which is how a conflict written before migration 4 is found (D3).

=back

Everything else is refused, and the refusal is the point. A computed queue item
- ambiguous, artist-disagree, artist-absent, various-gated - carries no user
decision to undo: it is a conclusion the next sync will re-derive from the same
inputs, so deleting the row would change nothing and the item would return. That
is why there is no stored dismiss (§15.16 part 7), and why the queue cannot
become the recovery path for a wrong badge that §14.4 rules out.

=cut

sub rejectRow {
	my ( $class, $albumKey ) = @_;

	return 0 unless $class->_writeOk;

	return 0 unless defined $albumKey && length $albumKey == 32;

	my $dbh = Slim::Schema->dbh;

	my $sth = $dbh->prepare_cached(
		q{DELETE FROM squeezewax.discogs_match
		   WHERE album_key = ?
		     AND ( match_tier = 'manual'
		           OR review_reason IN ('conflict','orphan')
		           OR ( match_tier = 'strict' AND discogs_release_id IS NULL ) )}
	);

	my $rows = $sth->execute($albumKey);
	$sth->finish;

	$rows = 0 unless $rows && $rows =~ /^[0-9]+$/;

	# No discogs_no_match row is written to take its place. A no-match row means
	# "this tier was attempted and produced nothing", which is a statement about
	# the files; rejecting is a statement about our record of them. Writing one
	# would also stop the album being re-examined, and a rejected album should
	# be re-examined - that is how the user gets a different answer.
	main::INFOLOG && $log->is_info && $log->info(
		$rows ? "rejected the match row for $albumKey"
		      : "refused to reject $albumKey: no row, or not a rejectable one"
	);

	return $rows;
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
