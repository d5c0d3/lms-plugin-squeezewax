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

C<various> means B<both> sides name a various-artists compilation. It is not a
weaker C<agree>: it is the compilation gate, and the caller must not badge on
it (§15.14).

C<$variousString> is C<Slim::Music::Info::variousArtistString()>, passed in
rather than called, so that this stays pure and the offline suite can vary it.

=cut

# Is this LMS name a various-artists name? The configured label (§15.7), or
# either literal (§15.14).
#
# The literals are acceptable HERE and nowhere else. §15.7 forbids a literal on
# the LMS side for AGREEMENT, because a literal could badge a band genuinely
# called "Various Artists" on an install whose label is something else. This
# only ever WITHHOLDS a badge, so a literal fails safe: at worst that band's
# album waits for the review queue. §15.7's rule is untouched - nothing below
# grants agreement on a literal.
sub _lmsIsVarious {
	my ( $lms, $variousString ) = @_;

	return 1 if $lms eq 'various' || $lms eq 'various artists';

	my $label = _artistKey($variousString);

	return ( defined $label && $lms eq $label ) ? 1 : 0;
}

# scripts/title-agreement.pl:373-390, plus decisions §15.7 and §15.14.
#
# The both-sides-Various test runs BEFORE plain equality, and that ordering is
# the whole of §15.14. Consulted after equality - which is how §15.13 part 8
# first shipped - the gate keyed on the MECHANISM by which the two sides
# matched, so the outcome turned on which of Discogs' two spellings a release
# happened to carry: 'Various Artists' against the default label reached plain
# equality and badged, while 'Various' on the same record reached the mapping
# and was gated. §15.11 part 2's exemption for albums whose LMS artist is
# literally 'Various' was the same seam from the other side.
#
# The gate exists because for a compilation, artist agreement carries almost no
# evidence (§11, §15.7) - and that is true however the two sides spell it. So
# this narrows the set of matches that badge, which is the opposite of what the
# equivalence alone did, and is why it cannot be a post-equality widening.
#
# The Discogs side is the literal, because that is Discogs' own fixed
# vocabulary. The gate lifts or changes shape with Q9 and the pages 2-3
# measurement (§15.14 Scope).
sub _artistsAgree {
	my ( $lmsArtist, $discogsArtists, $variousString ) = @_;

	my $lms = _artistKey($lmsArtist);

	return 'lms-absent' unless defined $lms;

	my @discogs = grep { defined } map { _artistKey($_) } @{ $discogsArtists || [] };

	return 'discogs-absent' unless @discogs;

	if ( _lmsIsVarious( $lms, $variousString ) ) {
		for my $d (@discogs) {
			return 'various' if $d eq 'various' || $d eq 'various artists';
		}
	}

	for my $d (@discogs) {
		return 'agree' if $d eq $lms;
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
		         match_tier, state, ownership, snapshot_track_count, review_reason
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
	# Tagged means an identification WITH a release id, on a row the tags do not
	# contradict.
	#
	# There are two kinds of conflict row and until step 8 only one of them was
	# handled here. A FRESH conflict has a NULL release id (§3a), so the release
	# id test alone already excluded it - which is what the comment that used to
	# stand here said, as though it were the whole story. An INCUMBENT conflict
	# keeps the release id it had (Match.pm's _recordConflict), and is 'strict'
	# and 'candidate' like any identification, so nothing here could tell it
	# apart: the pass treated a contested match as evidence of ownership and
	# could promote it back to 'confirmed' at :351, undoing §3a's demotion in
	# the next sync. That is TODO 2026-09-19, and review_reason is what closes
	# it (§15.16 part 4).
	#
	# So a conflict of either kind is untagged: it skips C, D and F, its state
	# is never written because there is nothing to promote, and the title route
	# at H alone decides its ownership. The identification is not discarded -
	# the pass never unmatches an album - it is simply not treated as an answer
	# while the tags disagree about what the answer is.
	my $conflict = $row && ( $row->{review_reason} || '' ) eq 'conflict';

	my $tagged = $row && !$conflict
		&& defined $row->{match_tier} && defined $row->{discogs_release_id};

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
		# The compilation gate (§15.13 part 8, widened by §15.14). Both sides
		# name a various-artists compilation, however each spells it, so the
		# artists agreeing carries almost no evidence that this is the record
		# the user owns. No badge until the pages 2-3 measurement reports.
		$count->{gated}++;

		return ( 'absent', $state, 'various' );
	}

	$count->{ $verdict eq 'disagree' ? 'artist_disagree' : 'artist_absent' }++;

	return ( 'absent', $state, $verdict );
}

# _decide's bucket vocabulary, mapped onto the six values discogs_match's CHECK
# accepts (§15.16 part 2). The buckets are what the pass thinks in; the reasons
# are what the queue page reads, and the two are deliberately not the same
# words: 'various' says what the pass saw, 'various-gated' says what it did
# about it, and 'lms-absent' and 'discogs-absent' are one thing to the user -
# nobody could say which side the name was missing from, and nothing different
# follows from it.
#
# Exhaustive over _decide's returns, verified against every return site: the
# only bucket with no reason is 'undecodable', by D2. A name we cannot decode is
# a bug in our reading or in the tags, not a decision the user can make on a
# web page, so it stays a logged count and §13.10.5 does not list it.
my %REASON = (
	ambiguous      => 'ambiguous',
	various        => 'various-gated',
	disagree       => 'artist-disagree',
	'lms-absent'   => 'artist-absent',
	'discogs-absent' => 'artist-absent',
	undecodable    => undef,
);

# What review_reason should read on this album's row once the pass is done, or
# the string 'keep' when the pass may not touch it at all.
#
# Three rules, in this order, and the order is what makes them rules rather than
# preferences:
#
# 1. 'conflict' is the importer's, and sticky (§15.16 part 3). The pass never
#    writes it and never clears it. It is cleared by a clean identification, by
#    a relink that resolves an 'orphan', or by the user rejecting the row - all
#    things that happen because something CHANGED, which is exactly what a
#    re-derivation from the same collection is not.
#
# 2. A manual row on a live album carries no pass reason (D1). The user has
#    already answered; re-asking every sync is not review, it is nagging. A
#    manual link to a record whose title is shared would otherwise come back as
#    'ambiguous' at every sync forever. NULL rather than 'keep', so that a stale
#    'orphan' on an album that has come back is cleared rather than left to
#    advertise a row nothing can relink.
#
# 3. Otherwise the bucket decides, and NULL means "not in the queue".
sub _reasonFor {
	my ( $row, $bucket ) = @_;

	return 'keep' if $row && ( $row->{review_reason} || '' ) eq 'conflict';

	return undef if $row && ( $row->{match_tier} || '' ) eq 'manual';

	return defined $bucket ? $REASON{$bucket} : undef;
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
		orphans
	);

	# What was actually WRITTEN, as opposed to what was decided. The bucket
	# counts above are decisions - they include albums whose row already said
	# the same thing - and step 8's queue is sized by rows, not by verdicts.
	# Keyed by the review_reason value, so the summary reads in the queue's
	# vocabulary rather than the pass's.
	my %reasonWritten;

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

		my ( $ownership, $state, $bucket ) = _decide(
			$album, $row, $index, $artists->{ $album->{album_id} },
			$variousString, \%count
		);

		$ownership = 'absent' unless defined $ownership;

		$count{$ownership}++ if $ownership ne 'absent';

		# The third return value, which until step 8 was discarded here. It is
		# the only thing that survives the sync: §13.2 requires the collection
		# be thrown away, so an ambiguity or an artist disagreement that is not
		# written down now cannot be recomputed later.
		my $reason = _reasonFor( $row, $bucket );
		my $keepReason = defined $reason && $reason eq 'keep';

		if ( !$row ) {
			# §14.8 as §15.16 part 9 amends it: a row is worth its existence
			# where there is an identification, an ownership conclusion other
			# than 'absent', OR a review reason. Absence of a row still means
			# "nothing known", so an album that owns nothing and has nothing to
			# review still gets none - which is what keeps this from writing a
			# row per album, and what the h_none case in the suite pins.
			return 1 if $ownership eq 'absent' && !defined $reason;

			push @insert, [ $key, $album->{album_id}, $ownership, $reason ];

			$reasonWritten{$reason}++ if defined $reason;

			return 1;
		}

		$count{absent_with_row}++ if $ownership eq 'absent';

		my $reasonChanged = !$keepReason
			&& ( $row->{review_reason} || '' ) ne ( $reason || '' );

		# The ownership conclusion has lapsed and the row carries nothing else.
		# DELETE takes precedence over the update below - but only if there is
		# no reason to keep the row for, which is the second half of §15.16 part
		# 9. A row whose ownership is 'absent' and whose reason is 'ambiguous'
		# is not "nothing known": it is the queue item.
		#
		# The SQL guard in _write is deliberately NOT widened to match. It
		# protects rows carrying a decision or a snapshot, which is a different
		# question from this one, and a pass-written reason is neither - it is
		# re-derived at the next sync. The decision of WHETHER to delete is
		# made here; the guard is there to stop this sub deleting something it
		# has no business deleting.
		if ( $ownership eq 'absent' && !defined $reason && _isOwnershipOnly($row) ) {
			push @delete, $key;

			return 1;
		}

		my $ownershipChanged = ( $row->{ownership} || '' ) ne $ownership;
		my $stateChanged     = defined $state && ( $row->{state} || '' ) ne $state;

		return 1 unless $ownershipChanged || $stateChanged || $reasonChanged;

		if ($stateChanged) {
			$count{ $state eq 'confirmed' ? 'promoted' : 'demoted' }++;
		}

		$reasonWritten{$reason}++ if $reasonChanged && defined $reason;

		# Only the keys that were decided. What is not here is not named in the
		# SQL, which is the discipline _write's comment describes.
		my %row = ( album_key => $key, ownership => $ownership );

		$row{state}  = $state  if $stateChanged;
		$row{reason} = $reason if $reasonChanged;

		push @update, \%row;

		return 1;
	} );

	# Rows whose album is gone. An orphan carrying an identification is orphan
	# recovery's to deal with at the next scan and keeps its last ownership -
	# it has no tile, so no badge can show either way. An ownership-only row
	# has nothing to recover.
	#
	# Step 8 adds the marking. The pass is the only thing that sees the whole
	# library and the whole table at once, so it is the only thing that can say
	# "this row's album is gone" - the importer's pre-pass sees it too, but only
	# when tag names are configured (§15.8, R11), and only from inside a scan.
	# Nothing sweeps orphans automatically (§2a invariant 4), which is precisely
	# why they have to be shown: TODO 2026-09-19 found three sitting on the
	# reference server that nothing would ever have mentioned.
	for my $r (@$rows) {
		next if $seen{ $r->{album_key} };

		if ( _isOwnershipOnly($r) ) {
			push @delete, $r->{album_key};

			next;
		}

		# §15.5 part 3's predicate: an identification AND a snapshot. Without a
		# snapshot the row cannot be relinked to anything, so the orphan list
		# could offer nothing but reject - and it is not the pass's place to
		# invite a deletion it cannot justify. Such a row simply sits, as it did
		# before.
		next unless defined $r->{match_tier} && defined $r->{snapshot_track_count};

		$count{orphans}++;

		# Manual orphans included, deliberately. D1 keeps a pass reason off a
		# manual row whose album is CURRENT, because the user has already
		# answered the question the reason would re-ask. An orphan is not a
		# verdict on a live album - it is the report that the album is gone -
		# and a manual row is the one recovery exists for, so leaving it unmarked
		# would hide exactly the row the user most wants back.
		#
		# 'conflict' still wins, because it is sticky and the importer's (R3).
		next if ( $r->{review_reason} || '' ) eq 'conflict';
		next if ( $r->{review_reason} || '' ) eq 'orphan';

		push @update, { album_key => $r->{album_key}, reason => 'orphan' };

		$reasonWritten{orphan}++;
	}

	_write( \@insert, \@update, \@delete, \%count );

	# Two different figures, and the summary says which is which because they
	# disagree and a reader would otherwise assume one of them was wrong.
	#
	# "decided" is the verdict count, over every album the pass looked at. It
	# includes albums whose row already said the same thing, so it is stable
	# from sync to sync and is what the measurement scripts compare against.
	#
	# "wrote" is the rows that CHANGED, which is what the queue grew or shrank
	# by. On a second sync over the same inputs it is empty, which is §13.2's
	# determinism showing up in the log.
	my $written = join ', ',
		map { "$_=$reasonWritten{$_}" } sort keys %reasonWritten;

	main::INFOLOG && $log->is_info && $log->info(
		"ownership pass: $count{albums} albums, exact=$count{exact} "
		. "version=$count{version} absent-with-row=$count{absent_with_row}; "
		. "wrote inserted=$count{inserted} updated=$count{updated} "
		. "deleted=$count{deleted} promoted=$count{promoted} demoted=$count{demoted}; "
		. "queue decided gated=$count{gated} ambiguous=$count{ambiguous} "
		. "artist-disagree=$count{artist_disagree} artist-absent=$count{artist_absent} "
		. "undecodable=$count{undecodable} orphans=$count{orphans}; "
		. 'reasons wrote ' . ( $written eq '' ? 'nothing' : $written )
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
		# Only the four columns. Everything else stays NULL, which is what makes
		# this row readable as "an ownership conclusion and/or a review reason,
		# no identification" - and what keeps the importer's lookups, which
		# filter on match_tier IS NOT NULL, from ever seeing it (§15.13 part 6).
		#
		# review_reason joined the list at step 8 and is why such a row may now
		# exist with ownership = 'absent', which §14.8 previously forbade:
		# §15.16 part 9 amends the invariant to "an identification, an ownership
		# conclusion other than absent, OR a review reason". The row still
		# asserts something; it just asserts a different thing.
		my $ins = $dbh->prepare_cached(
			'INSERT INTO squeezewax.discogs_match (album_key, lms_album_id, ownership, review_reason)
			 VALUES (?,?,?,?)'
		);

		for my $row (@$insert) {
			$ins->execute(@$row);
			$count->{inserted}++;
		}

		$ins->finish;

		# A statement per column set, rather than one with a conditional SET: the
		# pass must never write state on a row whose state is not its to move,
		# nor a review reason on a row whose reason is not its to write, and "do
		# not name the column" is a stronger guarantee than "pass the old value".
		#
		# Until step 8 that was two hand-written statements, ownership and
		# ownership+state. There are now three columns the pass may write and an
		# orphan mark that writes only one of them, which is five combinations -
		# five named statements and a five-way branch to pick between them, each
		# a place to name one column too many. So the SET list is built from the
		# keys _apply actually put on the row, which makes the guarantee
		# structural: a column that was not decided is not in the hash, so it
		# cannot be in the SQL. The three names come from a fixed table below,
		# never from the data.
		#
		# prepare_cached keys on the SQL text, so this is at most five cached
		# handles for the whole pass, the same as five named ones.
		#
		# None of them names source_timestamp, any snapshot_* column,
		# discogs_release_id, discogs_master_id or match_tier. The pass derives
		# ownership and, since step 8, a review reason; it never identifies,
		# never snapshots (§15.4), and never touches the skip contract
		# (Importer.pm:397-408).
		my @COLUMNS = (
			[ ownership => 'ownership' ],
			[ state     => 'state' ],
			[ reason    => 'review_reason' ],
		);

		for my $row (@$update) {
			my @set = grep { exists $row->{ $_->[0] } } @COLUMNS;

			next unless @set;

			my $sql = 'UPDATE squeezewax.discogs_match SET '
				. join( ', ', map { "$_->[1] = ?" } @set )
				. ' WHERE album_key = ?';

			my $sth = $dbh->prepare_cached($sql);

			$sth->execute( ( map { $row->{ $_->[0] } } @set ), $row->{album_key} );
			$sth->finish;

			$count->{updated}++;
		}

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
