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
	SELECT t.album, t.urlmd5, t.url, t.timestamp, t.disc, t.tracknum, t.remote
	  FROM tracks t
	 WHERE t.album IS NOT NULL
	   AND t.audio = 1
	   AND t.content_type NOT IN ('cpl','src','ssp','dir')
	 ORDER BY t.album, t.urlmd5
};

=head2 eachAlbum( \&callback )

Call $callback once per album with a hashref:

  album_id          LMS albums.id - a cache value, never identity
  album_key         md5 over the album's qualifying tracks' urlmd5, sorted
  source_timestamp  MAX(timestamp) over the album's *local* tracks, or undef
  local_tracks      count of local qualifying tracks
  remote_tracks     count of remote qualifying tracks
  candidates        up to two local track urls, in (disc, tracknum, url) order

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

	my ( $albumId, $urlmd5, $url, $timestamp, $disc, $tracknum, $remote );
	$sth->bind_columns( \( $albumId, $urlmd5, $url, $timestamp, $disc, $tracknum, $remote ) );

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

	while ( $continue && $sth->fetch ) {
		if ( !$current || $current->{album_id} != $albumId ) {
			$continue = $flush->() or last;
			$current = { album_id => $albumId, urlmd5 => [], local => [], remote_tracks => 0 };
		}

		push @{ $current->{urlmd5} }, $urlmd5;

		if ($remote) {
			$current->{remote_tracks}++;
		}
		else {
			push @{ $current->{local} }, {
				url       => $url,
				timestamp => $timestamp,
				disc      => $disc,
				tracknum  => $tracknum,
			};
		}
	}

	$flush->() if $continue;

	$sth->finish;

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
		album_key        => md5_hex( join '', @{ $acc->{urlmd5} } ),
		source_timestamp => $source,
		local_tracks     => scalar @local,
		remote_tracks    => $acc->{remote_tracks},
		candidates       => \@candidates,
	};
}

=head2 albumTitle( $albumId )

Title for progress and log lines only. Never used to identify an album.

=cut

sub albumTitle {
	my ( $class, $albumId ) = @_;

	my ($title) = Slim::Schema->dbh->selectrow_array(
		'SELECT title FROM albums WHERE id = ?', undef, $albumId
	);

	return $title;
}

1;
