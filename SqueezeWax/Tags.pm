package Plugins::SqueezeWax::Tags;

# Reading a Discogs release ID out of a file's tags.
#
# LMS discards custom tags: the format readers hand back every tag they find and
# only *rename* the ones LMS knows (Slim/Formats/FLAC.pm:220-265), but the
# scanner writes only known columns. MusicBrainz IDs survive because LMS
# special-cases them (FLAC.pm:51); a Discogs release ID has no column and does
# not. So we re-read the file with Slim::Formats->readTags (Slim/Formats.pm:153),
# which is what Slim::Schema itself calls during a scan (Slim/Schema.pm:1694,
# :1997).
#
# There is no standard tag name, and the key *shape* differs by format: custom
# tags reach LMS keyed by the tagger's label, uppercased - the Vorbis field name
# for FLAC, the TXXX frame description for MP3. LMS's own tables show the
# consequence: the same MusicBrainz tag is 'MUSICBRAINZ_ALBUMID' in FLAC.pm:51
# and 'MUSICBRAINZ ALBUM ID' in MP3.pm:48. Hence an ordered *list* of names in
# Settings rather than one name, and detection rather than guessed defaults.
# See decisions §3.

use strict;

use Slim::Formats;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.squeezewax');
my $prefs = preferences('plugin.squeezewax');

# Empty by default. decisions §3 chose detection over guessed defaults, and a
# guessed default that silently matches nothing is exactly the failure mode it
# was choosing against.
#
# Set at file scope rather than from initPlugin so both entry points get it
# regardless of load order. init only fills a pref that is absent or undef
# (Slim/Utils/Prefs/Base.pm:197-200), so repeating it is harmless.
$prefs->init({ discogsTagNames => [] });

=head2 tagNames()

The configured tag names, in precedence order. Never undef.

=cut

sub tagNames {
	return $prefs->get('discogsTagNames') || [];
}

# Conventional key names for the master release id. Unlike the release id these
# are not configurable: nothing reads them yet beyond discogs_master_id, and a
# second Settings list for a field with no user-visible effect is not worth the
# UI. Best-effort, matched case-insensitively.
my @MASTER_KEYS = ( 'DISCOGS_MASTER_ID', 'DISCOGS MASTER ID', 'DISCOGS_MASTER_RELEASE_ID' );

=head2 parseReleaseId( $value )

Extract a Discogs release ID from one tag value. Returns the ID, or undef if
the value does not look like one.

Accepts, per decisions §3:

  123456                                        bare
  https://www.discogs.com/release/123456-Title  URL, /releases/ and a locale
                                                prefix included
  [r123456]                                     Discogs markup

A value that is present but unparseable returns undef, and the caller treats
that as a conflict rather than as absence - "there is a tag here and I cannot
read it" is not the same as "there is no tag".

=cut

sub parseReleaseId {
	my $value = shift;

	return undef unless defined $value;

	$value =~ s/^\s+|\s+$//g;

	return undef if $value eq '';

	# Bare id.
	return $1 if $value =~ /^(\d+)$/;

	# Discogs markup. [r123456] is a release; [m...] master, [a...] artist,
	# [l...] label - deliberately not accepted, they are different things.
	return $1 if $value =~ /^\[r(\d+)\]$/i;

	# URL. The optional segment before release/releases is a locale ('de',
	# 'pt_BR'), which is why it is not a catch-all: /master/123456 must not
	# parse as a release, and a catch-all would let /master/release-ish paths
	# through.
	return $1 if $value =~ m{discogs\.com/(?:[a-z]{2}(?:[-_][A-Za-z]{2})?/)?releases?/(\d+)}i;

	return undef;
}

# Master ids appear as a bare number, a /master/123456 URL, or [m123456].
sub _parseMasterId {
	my $value = shift;

	return undef unless defined $value;

	$value =~ s/^\s+|\s+$//g;

	return $1 if $value =~ /^(\d+)$/;
	return $1 if $value =~ /^\[m(\d+)\]$/i;
	return $1 if $value =~ m{discogs\.com/(?:[a-z]{2}(?:[-_][A-Za-z]{2})?/)?master/(?:view/)?(\d+)}i;

	return undef;
}

# A tag value may be a scalar or an arrayref, and LMS does not normalise this in
# one place - it special-cases per format, and not even the same tags: see
# MUSICBRAINZ_ID in Slim/Formats/MP3.pm:343-351 and DATE in
# Slim/Formats/FLAC.pm:249-256. Anything outside those short lists arrives
# however the reader left it, so a custom tag can be either shape.
sub _values {
	my $raw = shift;

	return () unless defined $raw;
	return grep { defined } @$raw if ref $raw eq 'ARRAY';
	return ($raw);
}

# Case-insensitive key lookup. Separator differences are deliberately NOT
# normalised: 'DISCOGS_RELEASE_ID' and 'DISCOGS RELEASE ID' are genuinely
# different keys that different taggers write, which is the whole reason the
# pref is a list. Folding them together here would let one configured name
# silently match a tag the user did not tick.
sub _lookup {
	my ( $tags, $name ) = @_;

	return $tags->{$name} if exists $tags->{$name};

	my $wanted = uc $name;

	for my $key ( keys %$tags ) {
		return $tags->{$key} if uc($key) eq $wanted;
	}

	return undef;
}

=head2 decide( $tags )

Given a tag hashref from readTags, decide what the configured tags say.

Returns a hashref:

  id        the release ID, when exactly one was established
  master_id the master release ID, if a conventional tag carried one
  tag       the tag name the ID came from
  conflict  arrayref of "NAME=value" strings, when the tags disagree or a
            configured tag's value will not parse

Exactly one of C<id> and C<conflict> is set. Neither is set when no configured
tag is present at all, which is the "no tag found" case.

**Do not test this by asking whether the tag hash is empty.** readTags returns a
*populated* hashref for a remote URL - it skips the tag-reading block but still
runs the "Last resort" plainTitle at Slim/Formats.pm:246-251 and
CONTENT_TYPE ||= $type at :274, returning at :280 with at least TITLE and
CONTENT_TYPE. The contract here is absence of the *configured keys*.

=cut

sub decide {
	my ( $class, $tags ) = @_;

	my %found;     # id => { tag => name, raw => value as it appeared }
	my @unparsed;  # "NAME=value" for values that are present but unreadable
	my $present = 0;

	for my $name ( @{ $class->tagNames } ) {
		my $raw = _lookup( $tags, $name );

		next unless defined $raw;

		for my $value ( _values($raw) ) {
			next if !defined $value || $value =~ /^\s*$/;

			$present++;

			if ( my $id = parseReleaseId($value) ) {
				$found{$id} ||= { tag => $name, raw => $value };
			}
			else {
				push @unparsed, "$name=$value";
			}
		}
	}

	return {} unless $present;

	# Several tags agreeing on one ID is agreement, not conflict.
	my @ids = sort keys %found;

	if ( @unparsed || @ids > 1 ) {
		# Report the values as they appeared, not the parsed ids: the user has
		# to find these strings in their files, and a bare id would not help
		# them locate a URL-shaped tag.
		return {
			conflict => [
				( map { "$found{$_}->{tag}=$found{$_}->{raw}" } @ids ),
				@unparsed,
			],
		};
	}

	return {
		id        => $ids[0],
		tag       => $found{ $ids[0] }->{tag},
		master_id => _masterId($tags),
	};
}

sub _masterId {
	my $tags = shift;

	for my $name (@MASTER_KEYS) {
		my $raw = _lookup( $tags, $name );

		next unless defined $raw;

		for my $value ( _values($raw) ) {
			if ( my $id = _parseMasterId($value) ) {
				return $id;
			}
		}
	}

	return undef;
}

=head2 readTrack( $url )

readTags for one track, never fatal. Returns a hashref, empty on failure.

=cut

sub readTrack {
	my ( $class, $url ) = @_;

	my $tags = eval { Slim::Formats->readTags($url) };

	if ($@) {
		$log->warn("could not read tags from $url: $@");
		return {};
	}

	return $tags || {};
}

=head2 candidateKeys( $tags )

Every tag key whose value looks like a Discogs release ID or URL, regardless of
what is configured. This is what the Settings detection action reports, and it
uses the same parser as matching so the report cannot promise something
matching would then reject.

Returns a list of [ key, id ] pairs.

Two tiers of evidence, because a bare integer is not evidence of anything on its
own:

=over 4

=item * A B<URL or [r...] markup> value is unambiguous, so the key is reported
whatever it is called. This is what catches a tagger using a name nobody would
have guessed.

=item * A B<bare integer> is only reported when the key name mentions Discogs.
Otherwise TRACKNUM, YEAR, BPM, DISCNUMBER and every other numeric tag would be
reported as a candidate release ID, and a report full of false positives is
worse than a short one - the user is being asked to tick the right box.

=back

A bare integer under an unguessable key is therefore missed. That is what the
Settings page's free-text "add a tag name" field is for; detection is a
convenience, not the only route in.

=cut

sub candidateKeys {
	my ( $class, $tags ) = @_;

	my @hits;

	for my $key ( sort keys %$tags ) {
		# DISCOG, not DISCOGS: decisions §3 records both DISCOGS_RELEASE_ID and
		# DISCOG_RELEASE_ID (no S) in Discogs' own forum threads.
		my $named = $key =~ /DISCOG/i;

		for my $value ( _values( $tags->{$key} ) ) {
			next unless defined $value;

			my $id = parseReleaseId($value) or next;

			# A bare integer needs the key name to corroborate it.
			next if $value =~ /^\s*\d+\s*$/ && !$named;

			push @hits, [ $key, $id ];
			last;
		}
	}

	return @hits;
}

1;
