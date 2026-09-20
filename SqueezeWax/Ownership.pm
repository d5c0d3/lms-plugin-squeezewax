package Plugins::SqueezeWax::Ownership;

# The ownership pass: design §3 nodes C-K, build-order step 7.
#
# Plan: plans/build-order-step-6-7-ownership.md §2. This half is the
# comparison - pure functions over strings, no database and no LMS - so that
# the rules the §13.10 measurement established can be exercised offline,
# exactly, by scripts/ownership-check.pl.
#
# Every function here is PORTED from scripts/title-agreement.pl rather than
# re-derived. That script is what measured the auto-badge split on the
# reference library, and a rule that drifts from it silently invalidates the
# measurement that chose the threshold. Where this deliberately differs - the
# artist rung - the difference is a recorded ruling and is marked as such.

use strict;

use Encode ();

use Slim::Music::Info;
use Slim::Schema;
use Slim::Utils::Log;

use Plugins::SqueezeWax::Library;
use Plugins::SqueezeWax::Match;

my $log = logger('plugin.squeezewax');

=head1 NORMALISATION

Decisions §13.10.4 fixes the rung for every text comparison with Discogs at
B<L2>: trim, collapse internal whitespace, case-fold. No bracket-suffix rule,
no punctuation stripping, no leading-article rule. Those are rungs 3 to 5 of
C<title-agreement.pl>'s ladder and they were measured and rejected - each one
merges records that are genuinely different pressings.

=cut

# L2, as scripts/title-agreement.pl:151-164 computes it for $rung == 2:
# collapse, lc, collapse again. The second collapse is not redundant in the
# general ladder (rung 3 can reintroduce runs of spaces), and it is kept here
# so this function stays a transcription rather than a simplification of it.
sub _level2 {
	my ($s) = @_;

	return '' unless defined $s;

	$s = _collapse($s);
	$s = lc($s);

	return _collapse($s);
}

# scripts/title-agreement.pl:131-139.
sub _collapse {
	my ($s) = @_;

	return '' unless defined $s;

	$s =~ s/^\s+//;
	$s =~ s/\s+$//;
	$s =~ s/\s+/ /g;

	return $s;
}

=head2 _decode( $bytes )

The characters behind a blob column, or undef if it will not decode.

=cut

# scripts/title-agreement.pl:310-325.
#
# albums.title and contributors.name are blob columns
# (SQL/SQLite/schema_1_up.sql:116, :154), so DBD::SQLite hands back raw bytes -
# nothing under Slim/ sets sqlite_unicode. The Discogs side arrives as
# character strings from decode_json. Comparing bytes against characters would
# silently fail every non-ASCII title, so both sides are characters by the time
# any comparison happens.
#
# Undef on failure, never a repaired string. A name that will not decode is
# counted and treated as no match: guessing at an encoding here would badge an
# album on a name the user never typed.
sub _decode {
	my ($bytes) = @_;

	return undef unless defined $bytes;

	return $bytes if utf8::is_utf8($bytes);

	return eval { Encode::decode( 'UTF-8', $bytes, Encode::FB_CROAK() ) };
}

=head2 _titleKey( $string )

The comparison key for an album title. L2 and nothing else (§13.10.4).

=cut

sub _titleKey {
	my ($s) = @_;

	return _level2($s);
}

=head2 _artistKey( $string )

The comparison key for an artist name: Discogs' trailing disambiguator
stripped, then L2.

=cut

# The " (2)" strip is scripts/title-agreement.pl:169-177. It is a fact about
# how Discogs formats the field, not a normalisation knob, so it applies to
# artist strings only and never to titles. It is applied to both sides, as the
# script does, because an LMS name is not guaranteed free of it either.
#
# L2, NOT the script's rung 5. scripts/title-agreement.pl:179-185 normalises
# artists at rung 5, and decisions §15.13 part 3 records that as a divergence
# between the script and the record rather than as a rule: §13.10.4 applies to
# every text comparison with Discogs, artists included. The change can only
# move albums from badge to queue, and the split is re-measured under this rule
# before step 7 ships (TODO.md, 2026-09-19).
sub _artistKey {
	my ($s) = @_;

	return undef unless defined $s && $s =~ /\S/;

	$s =~ s/\s*\(\d+\)\s*$//;

	my $key = _level2($s);

	return ( $key eq '' ) ? undef : $key;
}

=head2 _artistsAgree( $lmsArtist, \@discogsArtists, $variousString )

One of C<agree>, C<various>, C<disagree>, C<lms-absent> or C<discogs-absent>.

C<$variousString> is C<Slim::Music::Info::variousArtistString()>, passed in
rather than called, so that this stays pure and the offline suite can vary it.

=cut

# scripts/title-agreement.pl:373-390, plus decisions §15.7's equivalence.
#
# The Various check is consulted ONLY when plain equality has already failed,
# so it can widen the set of matches and never narrow it.
#
# The LMS side must equal the CONFIGURED various-artists label, never a
# literal (§15.7). A user whose label is "Diverse" has albums genuinely by a
# band called "Various Artists", and treating the literal as the label would
# badge those against any Discogs compilation with the same title. The Discogs
# side is the literal, because that is Discogs' own fixed vocabulary.
#
# Returning 'various' rather than 'agree' is what lets step 7 ship with Q9
# open (§15.13 part 8): a match reached only this way does not badge, pending
# the pages 2-3 measurement.
sub _artistsAgree {
	my ( $lmsArtist, $discogsArtists, $variousString ) = @_;

	my $lms = _artistKey($lmsArtist);

	return 'lms-absent' unless defined $lms;

	my @discogs = grep { defined } map { _artistKey($_) } @{ $discogsArtists || [] };

	return 'discogs-absent' unless @discogs;

	for my $d (@discogs) {
		return 'agree' if $d eq $lms;
	}

	my $various = _artistKey($variousString);

	if ( defined $various && $lms eq $various ) {
		for my $d (@discogs) {
			return 'various' if $d eq 'various' || $d eq 'various artists';
		}
	}

	return 'disagree';
}


# ---------------------------------------------------------------------------
# The pass itself.
# ---------------------------------------------------------------------------

=head2 apply( \@entries )

Re-derive C<ownership> for B<every> album from a completed collection sync, and
write the result. Returns C<'ok'>, C<'refused'> or C<'failed'>.

C<\@entries> is the sync's own in-memory list, one hashref per collection item:
C<instance_id>, C<id> (release), C<master_id>, C<title>, C<artists>. Nothing
about it persists - §13.2's rule is that every completed sync re-derives every
conclusion from scratch, so a mirrored collection would be a second source of
truth to keep correct.

=cut

sub apply {
	my ( $class, $entries ) = @_;

	# Rule one, before anything is read: the pass is a server-side writer, so
	# it is refused while a scan holds the write lock (Match.pm:43-85). Checked
	# up front rather than at the writes, because walking the whole library to
	# then throw the answer away is the expensive way to find out.
	if ( !Plugins::SqueezeWax::Match->_writeOk ) {
		return 'refused';
	}

	my $result = eval { _apply($entries) };

	if ( !$result ) {
		$log->error( 'the ownership pass failed: ' . ( $@ || 'unknown error' ) );

		return 'failed';
	}

	return $result;
}

# Index the collection three ways, once.
#
# byTitle holds DISTINCT RELEASE IDS, not entries: the same record owned twice
# is two instances of one release, and counting it as two candidates would make
# every such album ambiguous - a queue item where no choice changes anything,
# against §13.4. Two DIFFERENT releases sharing a title still count as two;
# that is §13.10.3's ambiguous direction and it is the case the queue is for.
sub _indexCollection {
	my ($entries) = @_;

	my %index = ( releases => {}, masters => {}, byTitle => {} );

	for my $entry ( @{ $entries || [] } ) {
		my $id = $entry->{id};

		next unless defined $id;

		$index{releases}{$id} = 1;

		# Both sentinel forms are guarded, per TODO.md 2026-09-07: Discogs
		# reports a release with no master as master_id 0, and a response that
		# omits the field leaves it undef. Either one, taken at face value,
		# makes every release with no master collide on one key.
		my $master = $entry->{master_id};
		$index{masters}{$master} = 1 if defined $master && $master != 0;

		my $key = _titleKey( $entry->{title} );

		next if $key eq '';

		$index{byTitle}{$key}{$id} = $entry->{artists} || [];
	}

	return \%index;
}

# Every discogs_match row the pass needs, loaded whole before the library walk
# starts. Library::eachAlbum holds one prepare_cached handle for the length of
# the walk, so a query issued inside the callback would take that handle out
# from under it (Importer.pm:302-304).
#
# Not Match::snapshotRows: that selects the columns orphan recovery needs, and
# the pass needs the identification and the current ownership instead.
sub _loadRows {
	return Slim::Schema->dbh->selectall_arrayref(
		q{SELECT album_key, lms_album_id, discogs_release_id, discogs_master_id,
		         match_tier, state, ownership, snapshot_track_count
		    FROM squeezewax.discogs_match},
		{ Slice => {} }
	) || [];
}

# Decisions §15.13 part 5's predicate, written out once.
#
# It is the second place a discogs_match row may be deleted, and it passes §2a's
# governing rule - never delete a row carrying a decision or a recovery snapshot
# - because a row with no tier, no release id and no snapshot carries neither.
# It is an ownership conclusion and nothing else, so when the conclusion lapses
# there is nothing left to keep. Without it §14.8's invariant cannot hold: the
# table would accumulate rows asserting nothing.
#
# Note what it excludes, clause by clause: a manual or strict row has a tier, a
# conflict row has a tier, anything a tag or a user ever named has a release id,
# and orphan recovery's index material has a snapshot.
sub _isOwnershipOnly {
	my ($row) = @_;

	return !defined $row->{match_tier}
		&& !defined $row->{discogs_release_id}
		&& !defined $row->{snapshot_track_count};
}

# Design §3 nodes C-K for one album. Returns ( $ownership, $state, $bucket ),
# where $state is undef when this album's state must not be touched and $bucket
# names the queue category step 8 will want, or undef.
sub _decide {
	my ( $album, $row, $index, $artistBytes, $variousString, $count ) = @_;

	my $ownership;
	my $state;

	# --- C: is this album tagged? -----------------------------------------
	#
	# Tagged means an identification WITH a release id. A conflict row has a
	# tier but a NULL release id (§3a), so it is not tagged: it falls to H and
	# its state is never written, because there is nothing to promote.
	my $tagged = $row && defined $row->{match_tier} && defined $row->{discogs_release_id};

	# Only a strict row's state is the pass's to move. A manual link "is not
	# subject to the collection cross-check that governs Strict" (design §3),
	# so the user's choice survives a record leaving the collection.
	my $strict = $row && defined $row->{match_tier} && $row->{match_tier} eq 'strict';

	if ($tagged) {
		my $master = $row->{discogs_master_id};

		if ( $index->{releases}{ $row->{discogs_release_id} } ) {
			# D: this exact pressing is in the collection.
			$ownership = 'exact';
			$state     = 'confirmed' if $strict;
		}
		elsif ( defined $master && $master != 0 && $index->{masters}{$master} ) {
			# F: a different pressing of the same release is.
			$ownership = 'version';
			$state     = 'candidate' if $strict;
		}
		else {
			# Neither. The identification stands - the pass never unmatches an
			# album - but it is no longer evidence of ownership, so the state
			# drops back and the title route gets a turn.
			$state = 'candidate' if $strict;
		}
	}

	return ( $ownership, $state, undef ) if defined $ownership;

	# --- H: the title route ------------------------------------------------
	my $title = _decode( $album->{title} );

	if ( !defined $title ) {
		$count->{undecodable}++;

		return ( 'absent', $state, 'undecodable' );
	}

	my $candidates = $index->{byTitle}{ _titleKey($title) };

	return ( 'absent', $state, undef ) unless $candidates;

	my @ids = keys %$candidates;

	if ( @ids > 1 ) {
		# §13.10.3's ambiguous direction: two different owned releases share
		# this title and nothing here can choose between them. Step 7 stores no
		# marker for it (§15.13 part 4); the count is what tells step 8 how big
		# its queue will be before it is built.
		$count->{ambiguous}++;

		return ( 'absent', $state, 'ambiguous' );
	}

	my $artists = $candidates->{ $ids[0] };
	my $artist  = defined $artistBytes ? _decode($artistBytes) : undef;

	if ( defined $artistBytes && !defined $artist ) {
		$count->{undecodable}++;

		return ( 'absent', $state, 'undecodable' );
	}

	my $verdict = _artistsAgree( $artist, $artists, $variousString );

	if ( $verdict eq 'agree' ) {
		return ( 'version', $state, undef );
	}

	if ( $verdict eq 'various' ) {
		# The Q9 gate (§15.13 part 8). A match reached only through §15.7's
		# equivalence does not badge until the pages 2-3 measurement reports.
		$count->{gated}++;

		return ( 'absent', $state, 'various' );
	}

	$count->{ $verdict eq 'disagree' ? 'artist_disagree' : 'artist_absent' }++;

	return ( 'absent', $state, $verdict );
}

sub _apply {
	my ($entries) = @_;

	my $index = _indexCollection($entries);
	my $rows  = _loadRows();
	my %row   = map { $_->{album_key} => $_ } @$rows;

	my $artists = Plugins::SqueezeWax::Library->ownershipArtists;

	# Read once, outside the walk, and passed down: _artistsAgree stays pure,
	# and the label cannot change under us mid-pass.
	# Slim/Music/Info.pm:1540 - the variousArtistsString pref, falling back to
	# the localized VARIOUSARTISTS string. Never a hardcoded literal (§15.7).
	my $variousString = Slim::Music::Info::variousArtistString();

	my %count = map { $_ => 0 } qw(
		albums exact version absent_with_row inserted updated deleted
		promoted demoted gated ambiguous artist_disagree artist_absent undecodable
	);

	my ( @insert, @update, @delete );
	my %seen;

	# EVERY album, all-remote included. This is where §13.10.1 lands: the
	# importer keeps its local_tracks gate because there is nothing to read tags
	# from in an all-remote album, but ownership is derived from the collection
	# and a streamed copy of an owned record is still an owned record (§15.11).
	Plugins::SqueezeWax::Library->eachAlbum( sub {
		my $album = shift;
		my $key   = $album->{album_key};

		$seen{$key} = 1;
		$count{albums}++;

		my $row = $row{$key};

		my ( $ownership, $state ) = _decide(
			$album, $row, $index, $artists->{ $album->{album_id} },
			$variousString, \%count
		);

		$ownership = 'absent' unless defined $ownership;

		$count{$ownership}++ if $ownership ne 'absent';

		if ( !$row ) {
			# §14.8's invariant: absence of a row already means "nothing
			# known", so a row with NULL state, NULL match_tier and
			# ownership = 'absent' asserts nothing and must never be written.
			# Without this the pass would write a row per album.
			return 1 if $ownership eq 'absent';

			push @insert, [ $key, $album->{album_id}, $ownership ];

			return 1;
		}

		$count{absent_with_row}++ if $ownership eq 'absent';

		# The ownership conclusion has lapsed and the row carries nothing else.
		# DELETE takes precedence over the update below.
		if ( $ownership eq 'absent' && _isOwnershipOnly($row) ) {
			push @delete, $key;

			return 1;
		}

		my $ownershipChanged = ( $row->{ownership} || '' ) ne $ownership;
		my $stateChanged     = defined $state && ( $row->{state} || '' ) ne $state;

		return 1 unless $ownershipChanged || $stateChanged;

		if ($stateChanged) {
			$count{ $state eq 'confirmed' ? 'promoted' : 'demoted' }++;
		}

		push @update, {
			album_key => $key,
			ownership => $ownership,
			state     => $stateChanged ? $state : undef,
		};

		return 1;
	} );

	# Rows whose album is gone. An orphan carrying an identification is orphan
	# recovery's to deal with at the next scan and keeps its last ownership -
	# it has no tile, so no badge can show either way. An ownership-only row
	# has nothing to recover.
	for my $r (@$rows) {
		next if $seen{ $r->{album_key} };
		next unless _isOwnershipOnly($r);

		push @delete, $r->{album_key};
	}

	_write( \@insert, \@update, \@delete, \%count );

	main::INFOLOG && $log->is_info && $log->info(
		"ownership pass: $count{albums} albums, exact=$count{exact} "
		. "version=$count{version} absent-with-row=$count{absent_with_row}; "
		. "wrote inserted=$count{inserted} updated=$count{updated} "
		. "deleted=$count{deleted} promoted=$count{promoted} demoted=$count{demoted}; "
		. "queue-to-be gated=$count{gated} ambiguous=$count{ambiguous} "
		. "artist-disagree=$count{artist_disagree} artist-absent=$count{artist_absent} "
		. "undecodable=$count{undecodable}"
	);

	return 'ok';
}

# One transaction for the whole pass. Every album is decided before anything is
# written, so what lands is a complete conclusion rather than a prefix of one -
# a half-applied pass would show some badges from this sync and some from the
# last, which is §13.7's named failure.
sub _write {
	my ( $insert, $update, $delete, $count ) = @_;

	return 1 unless @$insert || @$update || @$delete;

	my $dbh = Slim::Schema->dbh;

	$dbh->begin_work;

	eval {
		# Only the three columns. Everything else stays NULL, which is what
		# makes this row readable as "an ownership conclusion, no
		# identification" - and what keeps the importer's lookups, which filter
		# on match_tier IS NOT NULL, from ever seeing it (§15.13 part 6).
		my $ins = $dbh->prepare_cached(
			'INSERT INTO squeezewax.discogs_match (album_key, lms_album_id, ownership)
			 VALUES (?,?,?)'
		);

		for my $row (@$insert) {
			$ins->execute(@$row);
			$count->{inserted}++;
		}

		$ins->finish;

		# Two statements rather than one with a conditional SET: the pass must
		# never write state on a row whose state is not its to move, and "do not
		# name the column" is a stronger guarantee than "pass the old value".
		#
		# Neither names source_timestamp, any snapshot_* column,
		# discogs_release_id, discogs_master_id or match_tier. The pass derives
		# ownership; it never identifies, never snapshots (§15.4), and never
		# touches the skip contract (Importer.pm:397-408).
		my $updOwnership = $dbh->prepare_cached(
			'UPDATE squeezewax.discogs_match SET ownership = ? WHERE album_key = ?'
		);
		my $updBoth = $dbh->prepare_cached(
			'UPDATE squeezewax.discogs_match SET ownership = ?, state = ? WHERE album_key = ?'
		);

		for my $row (@$update) {
			if ( defined $row->{state} ) {
				$updBoth->execute( $row->{ownership}, $row->{state}, $row->{album_key} );
			}
			else {
				$updOwnership->execute( $row->{ownership}, $row->{album_key} );
			}

			$count->{updated}++;
		}

		$updOwnership->finish;
		$updBoth->finish;

		# The predicate is repeated in SQL rather than trusted from the read.
		# Between the load and the write the importer cannot have run - a scan
		# would have made _writeOk refuse - but the row is the one thing in this
		# database that is not disposable, and the cost of the extra clauses is
		# nothing.
		my $del = $dbh->prepare_cached(
			q{DELETE FROM squeezewax.discogs_match
			   WHERE album_key = ?
			     AND match_tier IS NULL
			     AND discogs_release_id IS NULL
			     AND snapshot_track_count IS NULL}
		);

		for my $key (@$delete) {
			$count->{deleted} += ( $del->execute($key) || 0 );
		}

		$del->finish;

		$dbh->commit;

		1;
	} or do {
		my $err = $@ || 'unknown error';

		eval { $dbh->rollback; 1 } or $log->error("rollback after a failed pass also failed: $@");

		die $err;
	};

	return 1;
}

1;
