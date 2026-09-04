package Plugins::SqueezeWax::Library;

# Everything that reads LMS's own tables.
#
# Raw SQL on Slim::Schema->dbh, not DBIC. Both routes exist and both work in
# either process, but Slim/Utils/Scanner/API.pm:37-38 warns in its own POD that
# "Track objects should be avoided when possible to avoid slowing down the
# scanner", and inflating every track of every album to read one column is
# exactly that. The pattern is a plugin doing the same thing:
# Slim/Plugin/FullTextSearch/Plugin.pm:542-553 (prepare_cached over
# SELECT ... FROM tracks WHERE tracks.album = ?).
#
# Because squeezewax.db is ATTACHed to the same handle, a caller can join our
# tables to main.tracks in one query in either process - the payoff of the
# attach design (decisions §2).

use strict;

use Digest::MD5 qw(md5_hex);

use Slim::Schema;
use Slim::Utils::Log;

my $log = logger('plugin.squeezewax');

# One streaming pass over the whole library, grouped by album in Perl, rather
# than a per-album query: the per-album form is N+1 over a 5,000-album library.
#
# The predicate is LMS's own (Slim/Control/Queries.pm:4811). ORDER BY album,
# urlmd5 gives the same per-album urlmd5 ordering the per-album form would, so
# the digest is identical either way - urlmd5 is char(32) with no COLLATE
# (SQL/SQLite/schema_16_up.sql:42), so it sorts BINARY and LMS's ICU collation
# machinery (Slim/Utils/SQLiteHelper.pm:165-207) never applies.
#
# remote is selected, not filtered on. v2's Fuzzy tier is precisely for
# streaming albums with no local file (design §3, walkthrough 4); filtering here
# would have to be undone then. The Strict caller decides, not the iterator.
my $ALBUM_TRACKS_SQL = q{
	SELECT t.album, t.urlmd5, t.url, t.timestamp, t.disc, t.tracknum, t.remote,
	       t.content_type, a.title
	  FROM tracks t
	  LEFT JOIN albums a ON a.id = t.album
	 WHERE t.album IS NOT NULL
	   AND t.audio = 1
	   AND t.content_type NOT IN ('cpl','src','ssp','dir')
	 ORDER BY t.album, t.urlmd5
};

# One aggregate over the same predicate, for Progress->new's total. An
# indeterminate progress bar would undercut finding 4's reasoning: the scan-UI
# row is the healthy-run signal that justified dropping the log category to WARN,
# and a bar with no total carries less of that.
my $ALBUM_COUNT_SQL = q{
	SELECT COUNT(DISTINCT t.album)
	  FROM tracks t
	 WHERE t.album IS NOT NULL
	   AND t.audio = 1
	   AND t.content_type NOT IN ('cpl','src','ssp','dir')
};

=head2 eachAlbum( \&callback )

Call $callback once per album with a hashref:

  album_id          LMS albums.id - a cache value, never identity
  album_key         md5 over the album's qualifying tracks' urlmd5, sorted
  source_timestamp  MAX(timestamp) over the album's *local* tracks, or undef
  local_tracks      count of local qualifying tracks
  remote_tracks     count of remote qualifying tracks
  candidates        up to two local track urls, in (disc, tracknum, url) order
  content_type      the primary candidate's content type, or undef
  title             album title for display only - may be undef

Returns the number of albums seen. A callback returning false stops the walk.

An album with no qualifying tracks never appears at all, which is how the
"zero tracks yields no key" rule (step 2, finding 2) is enforced here: it is a
property of the query rather than a guard to remember. md5_hex('') is a single
constant every empty album would collide on, and discogs_match's
CHECK(length(album_key) = 32) is the backstop if a future caller reintroduces
the per-album form.

=cut

sub eachAlbum {
	my ( $class, $cb ) = @_;

	my $sth = Slim::Schema->dbh->prepare_cached($ALBUM_TRACKS_SQL);
	$sth->execute;

	my ( $albumId, $urlmd5, $url, $timestamp, $disc, $tracknum, $remote,
		$contentType, $title );
	$sth->bind_columns(
		\( $albumId, $urlmd5, $url, $timestamp, $disc, $tracknum, $remote,
			$contentType, $title )
	);

	my $seen    = 0;
	my $current;
	my $continue = 1;

	my $flush = sub {
		return 1 unless $current;

		$seen++;
		my $album = _finish($current);
		undef $current;

		return $cb->($album) ? 1 : 0;
	};

	# The handle comes from prepare_cached, so it is reused on the next call. A
	# callback that dies part-way through would otherwise leave it Active and the
	# next eachAlbum would get DBI's "prepare_cached(...) statement handle
	# ... still Active" warning, with a half-consumed result set behind it.
	#
	# Moot in the scanner, where an abort exits the process outright
	# (Slim/Utils/SQLiteHelper.pm:443-460), but not in the server: the Settings
	# detection worker runs this shape of work through Slim::Utils::Scheduler,
	# where one unreadable file must not poison the handle for the rest of the
	# session.
	my $ok = eval {
		while ( $continue && $sth->fetch ) {
			if ( !$current || $current->{album_id} != $albumId ) {
				$continue = $flush->() or last;
				$current = {
					album_id      => $albumId,
					title         => $title,
					urlmd5        => [],
					local         => [],
					remote_tracks => 0,
				};
			}

			push @{ $current->{urlmd5} }, $urlmd5;

			if ($remote) {
				$current->{remote_tracks}++;
			}
			else {
				push @{ $current->{local} }, {
					url          => $url,
					timestamp    => $timestamp,
					disc         => $disc,
					tracknum     => $tracknum,
					content_type => $contentType,
				};
			}
		}

		$flush->() if $continue;

		1;
	};

	my $err = $@;

	$sth->finish;

	die $err if !$ok;

	return $seen;
}

sub _finish {
	my $acc = shift;

	my @local = @{ $acc->{local} };

	# Skip undef timestamps rather than feeding them to a numeric comparison.
	# SQL MAX ignores NULLs; a Perl maximum over a list containing undef warns
	# under `use warnings` and can return the wrong value. Remote rows always
	# have a NULL timestamp - Slim/Formats.pm:261 is the only producer of a
	# TIMESTAMP attribute and it sits behind `if (-e $filepath)` at :259, which
	# is false for a non-file URL because $filepath = $file at :165 - so a mixed
	# local/remote album is the normal case here, not an edge case.
	my $source;
	for my $t (@local) {
		next unless defined $t->{timestamp};
		$source = $t->{timestamp} if !defined $source || $t->{timestamp} > $source;
	}

	# Ordered by (disc, tracknum, url) so "first track" means the first track;
	# the urlmd5 order the digest needs is effectively random. Two candidates,
	# because decisions §3 reads one track per album and falls back to one more
	# rather than paying 12x the file reads for a per-track-tagged compilation.
	#
	# splice rather than a [0..1] slice: on a single-track album the slice
	# yields a read-only undef, and map aliases $_ to it, so `$_->{url}` dies
	# with "Modification of a read-only value attempted" rather than returning
	# one candidate. Single-track albums are common (singles, DJ mixes).
	my @sorted = sort {
		   ( $a->{disc}     || 0 ) <=> ( $b->{disc}     || 0 )
		|| ( $a->{tracknum} || 0 ) <=> ( $b->{tracknum} || 0 )
		|| $a->{url} cmp $b->{url}
	} @local;

	splice( @sorted, 2 ) if @sorted > 2;

	my @candidates = map { $_->{url} } @sorted;

	return {
		album_id         => $acc->{album_id},

		# For progress and log lines only, never identity. Taken from the
		# accumulator rather than per track, since it is a property of the album.
		# May be NULL in the database, so callers degrade to the id.
		title            => $acc->{title},

		album_key        => md5_hex( join '', @{ $acc->{urlmd5} } ),
		source_timestamp => $source,
		local_tracks     => scalar @local,
		remote_tracks    => $acc->{remote_tracks},
		candidates       => \@candidates,

		# The primary candidate's content_type. Carried for the detection
		# report's format mix and for stratifying the sample - the tag key
		# spelling differs by format, which is the whole reason the pref is a
		# list. undef for an album with no local tracks.
		content_type     => $sorted[0] ? $sorted[0]->{content_type} : undef,
	};
}

=head2 sample_albums( $perFormat )

Up to C<$perFormat> albums for B<each> distinct local content type, as a plain
arrayref of the same records C<eachAlbum> yields. Albums with no local tracks
are excluded - there is nothing to read tags from.

B<All database work happens here, synchronously, and the result is
materialised> - in two passes, so peak memory is bounded by the sample size
rather than the library size. The caller spreads the *file reads* over
scheduler ticks, never the query. Holding a
C<prepare_cached> handle open across many event-loop turns - potentially
minutes, since scheduler tasks only run when the server is otherwise idle - and
in that window C<Slim::Schema-E<gt>disconnect; Slim::Schema-E<gt>init> can fire:
a completing scan does exactly that at C<Slim/Utils/SQLiteHelper.pm:626-628>,
and so does any plugin registering a post-connect handler. The next tick would
then fetch from a handle on a dead C<$dbh>.

B<Stratified by content type, not uniform.> A uniform sample of a library that
is 90% FLAC returns about five MP3 albums out of fifty - and the MP3s are
exactly where the tag key differs, since the same tag is
C<MUSICBRAINZ_ALBUMID> from FLAC (C<Slim/Formats/FLAC.pm:51>) and
C<'MUSICBRAINZ ALBUM ID'> from MP3 (C<Slim/Formats/MP3.pm:48>). Sampling per
format is what makes the report able to say "your FLACs use this key and your
MP3s use that one", which is the finding the whole list-of-names design exists
to surface.

B<Deterministic stride, not C<ORDER BY RANDOM()> or reservoir sampling.> A user
who re-runs detection and gets different counts will not trust either result.
An even stride over each format's albums also beats taking the first N, which
on a library sorted by insertion order means sampling one corner of it.

=cut

sub sample_albums {
	my ( $class, $perFormat ) = @_;

	$perFormat ||= 25;

	# Two passes, deliberately. The obvious single pass accumulates every album
	# record and then strides - which makes peak memory scale linearly with
	# library size, in a module whose header rejects the per-album query form on
	# scaling grounds. The first pass here keeps only an id per format, the
	# stride picks ids, and the second pass keeps just the chosen records.
	#
	# The cost is a second table scan. Detection is user-initiated and rare, so
	# trading I/O for bounded memory is the right way round; and both passes see
	# the same ORDER BY, so the choice is as deterministic as the one-pass form.
	my %idsByFormat;

	$class->eachAlbum( sub {
		my $album = shift;

		# Nothing to read tags from, and its content_type is undef.
		return 1 unless $album->{local_tracks};

		push @{ $idsByFormat{ $album->{content_type} || 'unknown' } }, $album->{album_id};

		return 1;
	} );

	my %wanted;

	for my $format ( sort keys %idsByFormat ) {
		my $ids   = $idsByFormat{$format};
		my $total = scalar @$ids;

		if ( $total <= $perFormat ) {
			$wanted{$_} = 1 for @$ids;
			next;
		}

		# Even stride, so the sample spans the library rather than clustering at
		# whichever end insertion order put first. int() rather than rounding,
		# with a distinct-index guard so a repeated index cannot double-count.
		my $stride = $total / $perFormat;

		for my $i ( 0 .. $perFormat - 1 ) {
			$wanted{ $ids->[ int( $i * $stride ) ] } = 1;
		}
	}

	my @sample;

	$class->eachAlbum( sub {
		my $album = shift;

		push @sample, $album if $wanted{ $album->{album_id} };

		return 1;
	} );

	return \@sample;
}

=head2 albumCount()

How many albums C<eachAlbum> will emit. One aggregate over the same predicate,
for C<Slim::Utils::Progress-E<gt>new>'s C<total>.

=cut

sub albumCount {
	my $class = shift;

	my ($count) = Slim::Schema->dbh->selectrow_array($ALBUM_COUNT_SQL);

	return $count || 0;
}

=head2 albumLabel( $album )

Display label for a progress or log line: the title, or the album id when the
title is NULL. Never used to identify an album.

=cut

sub albumLabel {
	my ( $class, $album ) = @_;

	my $title = $album->{title};

	return ( defined $title && $title ne '' ) ? $title : "album $album->{album_id}";
}

1;
