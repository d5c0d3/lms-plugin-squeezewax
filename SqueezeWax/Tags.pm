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

# Path segments that mark a Discogs *entity* rather than a title slug. A release
# URL's intervening segments are the title slug and/or a locale, never one of
# these, so rejecting them keeps the release/master separation intact while still
# allowing an arbitrary slug.
#
# The guard exists because I could not verify the one case that would make the
# permissive form unsafe: whether a path of the form .../releases/<digits> exists
# on Discogs where the digits are NOT a release id - a label's releases tab
# paginated as /label/23528-Warp-Records/releases/2, say. discogs.com returns 403
# to an automated fetch, so this was not settled against the live site. What is
# established: web and API pagination both use a ?page= query parameter rather
# than a path segment, and the canonical release forms are /release/<id>-<slug>
# and /<artist-title-slug>/release/<id>. Guarding costs nothing and removes the
# need to have been right about that.
my $ENTITY_SEGMENT = qr{^(?:label|artist|master|user|seller|lists?|forum|group)$}i;

# Bare digits, Discogs markup, or a URL. Kept as one string so both the release
# and master parsers stay in step.
#
# Markup variants: Discogs' own forum shows [r123456], [r 123456] and [r= 1234]
# all working, and someone pasting from a release note could have any of them.
# No variant can create a false positive - they all denote the same release.
sub _parseEntityId {
	my ( $value, $type, $markup ) = @_;

	return undef unless defined $value;

	$value =~ s/^\s+|\s+$//g;

	return undef if $value eq '';

	# Bare id. `0 +` normalises, so a zero-padded '0123456' and a plain
	# '123456' are the same answer rather than two hash keys that look like two
	# tags disagreeing. discogs_release_id is INTEGER, so they would have stored
	# identically anyway.
	return 0 + $1 if $value =~ /^(\d+)$/;

	return 0 + $1 if $value =~ /^\[$markup\s*=?\s*(\d+)\]$/i;

	if ( $value =~ m{discogs\.com/((?:[^/\s]+/)*)$type/(?:view/)?(\d+)}i ) {
		my ( $prefix, $id ) = ( $1, $2 );

		for my $segment ( grep { length } split m{/}, ( $prefix // '' ) ) {
			return undef if $segment =~ $ENTITY_SEGMENT;
		}

		return 0 + $id;
	}

	return undef;
}

=head2 _parseReleaseId( $value )

Extract a Discogs release ID from one tag value. Returns the ID as an integer,
or undef if the value does not look like one.

Accepts, per decisions §3:

  123456                                                bare
  0123456                                               zero-padded, same answer
  [r123456] / [r 123456] / [r= 123456]                  Discogs markup
  https://www.discogs.com/release/123456-Title          canonical URL
  https://www.discogs.com/releases/123456               plural
  https://www.discogs.com/de/release/123456             locale prefix
  https://www.discogs.com/Some-Artist-Title/release/123456   slug prefix

The slug form is the one Discogs itself emits, so a value pasted from a browser
or copied out of an API C<uri> field has to parse. It particularly must not fail:
decide() treats present-but-unparseable as a *conflict*, so a URL this could not
read would put the album in the review queue as a false conflict rather than
letting it fall through to Structural - worse than simply missing it.

Never returns a valid falsy id: 0 is not a Discogs release, so callers may use
C<if ( my $id = ... )>.

A private function, per CLAUDE.md's calling convention: reached through decide()
and candidateKeys(), and directly from the offline suite.

=cut

sub _parseReleaseId {
	my $value = shift;

	# releases? so the plural form parses; view/ is a master-only path but
	# harmless here.
	return _parseEntityId( $value, 'releases?', 'r' );
}

# Master ids appear as a bare number, [m123456], or a /master/123456 URL - the
# example in Discogs' own API documentation is the slug form,
# ".../Electric-Universe-Stardiver/master/1000", so the same widening applies.
sub _parseMasterId {
	my $value = shift;

	return _parseEntityId( $value, 'master', 'm' );
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

			if ( my $id = _parseReleaseId($value) ) {
				$found{$id} ||= { tag => $name, raw => $value };
			}
			else {
				push @unparsed, "$name=$value";
			}
		}
	}

	return {} unless $present;

	# Several tags agreeing on one ID is agreement, not conflict.
	#
	# The sort is for a stable conflict report only, and is a string sort over
	# integer ids - deliberately not load-bearing: one key means there is no
	# order, and more than one means conflict, where the list is prose for a log
	# line rather than anything a caller indexes into.
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

Returns a list of C<[ $key, $id, $corroborated ]> triples.

Two tiers of evidence, because a bare integer is not evidence of anything on its
own:

=over 4

=item * A B<URL or [r...] markup> value is unambiguous, so the key is reported
whatever it is called, with C<$corroborated> true. This is what catches a tagger
using a name nobody would have guessed.

=item * A B<bare integer> is corroborated only when the key name mentions
Discogs. Otherwise TRACKNUM, YEAR, BPM, BARCODE and every other numeric tag
would look like a candidate release ID - and a magnitude test buys nothing
clean, since BARCODE and UPC are 12-13 digits and LENGTH in milliseconds is 6.
The key name is the honest discriminator.

=back

Uncorroborated hits are still B<returned>, with C<$corroborated> false, so the
caller can render them as a demoted "other numeric tags found" list. decisions
§3 makes detection the coverage report - "so silent failure is impossible" - and
a user whose tagger writes C<RELEASE_ID> would otherwise be told nothing at all.
Whether to show the second list is the caller's decision; suppressing it here
would take that choice away.

=cut

sub candidateKeys {
	my ( $class, $tags ) = @_;

	my @hits;

	for my $key ( sort keys %$tags ) {
		# DISCOG, not DISCOGS: decisions §3 records both DISCOGS_RELEASE_ID and
		# DISCOG_RELEASE_ID (no S) in Discogs' own forum threads.
		my $named = $key =~ /DISCOG/i ? 1 : 0;

		for my $value ( _values( $tags->{$key} ) ) {
			next unless defined $value;

			my $id = _parseReleaseId($value) or next;

			# A bare integer is only corroborated by the key name; any other
			# accepted form is unambiguous on its own.
			my $bare = $value =~ /^\s*\d+\s*$/ ? 1 : 0;

			push @hits, [ $key, $id, ( $bare ? $named : 1 ) ];
			last;
		}
	}

	return @hits;
}

1;
