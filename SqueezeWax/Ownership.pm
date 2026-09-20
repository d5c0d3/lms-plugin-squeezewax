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

use Slim::Utils::Log;

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

1;
