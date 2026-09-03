#!/usr/bin/env perl
#
# Offline exercise of Plugins::SqueezeWax::Tags - the parser and the decision.
#
# No LMS instance and no music files are needed: everything here operates on tag
# hashrefs of the shape Slim::Formats->readTags returns, so the whole of
# decisions §3's parsing contract is testable without a server.
#
# What it cannot prove: that Slim::Formats->readTags exists or returns what we
# think. Per CLAUDE.md that call still has to be found in refs/ and cited.
#
# Usage: scripts/tags-check.pl

use strict;
use warnings;

use constant SCANNER  => 0;
use constant PERFMON  => 0;
use constant DEBUGLOG => 1;
use constant INFOLOG  => 1;

use FindBin qw($Bin);

# Host Test::More, before refs goes on @INC - see library-check.pl.
use Test::More;

# Tags.pm's LMS dependencies are the ones the offline JSON::XS problem lives in
# (Slim::Utils::Prefs) or drag in most of the server (Slim::Formats). Stub both,
# plus the logger, exactly as schema-check.pl does for Schema.pm.
BEGIN {
	$INC{'Slim/Utils/Log.pm'}   = 1;
	$INC{'Slim/Utils/Prefs.pm'} = 1;
	$INC{'Slim/Formats.pm'}     = 1;

	no strict 'refs';

	*{'Slim::Utils::Log::logger'}   = sub { Test::StubLogger->new };
	*{'Slim::Utils::Log::logError'} = sub { };
	*{'Slim::Utils::Log::import'}   = sub {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::logger"}   = \&Slim::Utils::Log::logger;
		*{"${caller}::logError"} = \&Slim::Utils::Log::logError;
	};

	*{'Slim::Utils::Prefs::preferences'} = sub { Test::StubPrefs->new };
	*{'Slim::Utils::Prefs::import'}      = sub {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::preferences"} = \&Slim::Utils::Prefs::preferences;
	};

	*{'main::SCANNER'}  = sub () { 0 };
	*{'main::INFOLOG'}  = sub () { 0 };
	*{'main::DEBUGLOG'} = sub () { 0 };
}

{
	package Test::StubLogger;
	sub new      { bless {}, shift }
	sub error    { }
	sub warn     { }
	sub info     { }
	sub debug    { }
	sub is_info  { 0 }
	sub is_debug { 0 }
}

{
	# One shared store, so setting the pref in a test is visible to Tags.pm.
	package Test::StubPrefs;
	my %store;
	sub new  { bless {}, shift }
	sub init { my ( $s, $h ) = @_; $store{$_} //= $h->{$_} for keys %$h; 1 }
	sub get  { $store{ $_[1] } }
	sub set  { $store{ $_[1] } = $_[2]; 1 }
}

use lib "$Bin/..";
require SqueezeWax::Tags;

my $T = 'Plugins::SqueezeWax::Tags';

# --- the pref defaults to empty, deliberately -----------------------------
is_deeply( $T->tagNames, [],
	'discogsTagNames defaults to empty - detection, not guessed defaults' );

# --- parseReleaseId: the three accepted forms -----------------------------
my @accept = (
	[ '123456',                                            123456, 'bare id' ],
	[ '  123456  ',                                        123456, 'bare id with whitespace' ],
	[ '[r123456]',                                         123456, 'Discogs markup' ],
	[ '[R123456]',                                         123456, 'markup, uppercase' ],
	[ 'https://www.discogs.com/release/123456-Kind-Of-Blue', 123456, 'release URL' ],
	[ 'https://www.discogs.com/releases/123456',           123456, 'plural /releases/' ],
	[ 'http://discogs.com/release/123456',                 123456, 'no www, http' ],
	[ 'https://www.discogs.com/de/release/123456-Titel',   123456, 'locale prefix' ],
	[ 'https://www.discogs.com/pt_BR/release/123456',      123456, 'locale with region' ],

	# Zero-padded. Normalised to an integer so a padded and an unpadded tag do
	# not look like two tags disagreeing - discogs_release_id is INTEGER, so
	# they would have stored identically anyway.
	[ '0123456',                                           123456, 'zero-padded bare id' ],

	# Markup variants. Discogs' own forum shows all three working.
	[ '[r 123456]',                                        123456, 'markup with a space' ],
	[ '[r= 123456]',                                       123456, 'markup with equals and space' ],
	[ '[r=123456]',                                        123456, 'markup with equals' ],

	# The slug-prefixed form is what Discogs itself emits, so a value pasted
	# from a browser or copied out of an API uri field must parse. Failing it
	# would be worse than a miss: decide() treats unparseable as a conflict, so
	# the album would land in the review queue as a false conflict instead of
	# falling through to Structural.
	[ 'https://www.discogs.com/Various-Aldre-Svenska-Spelman-Volym-I/release/4198228',
	  4198228, 'slug before /release/' ],
	[ 'https://www.discogs.com/Miles-Davis-Kind-Of-Blue/releases/123456',
	  123456, 'slug before plural /releases/' ],
	[ 'https://www.discogs.com/de/Some-Slug/release/123456',
	  123456, 'locale and slug together' ],
);

for my $case (@accept) {
	is( Plugins::SqueezeWax::Tags::_parseReleaseId( $case->[0] ), $case->[1],
		"accepts: $case->[2]" );
}

# --- parseReleaseId: what must NOT parse ----------------------------------
# A master is not a release. Confusing them would badge the wrong pressing,
# which is precisely what Strict tier exists to avoid.
my @reject = (
	[ '[m123456]',                                  'master markup' ],
	[ 'https://www.discogs.com/master/123456',      'master URL' ],
	[ 'https://www.discogs.com/master/view/123456', 'master view URL' ],
	[ '[a123456]',                                  'artist markup' ],
	[ '[l123456]',                                  'label markup' ],
	[ 'r123456',                                    'markup without brackets' ],
	[ '',                                           'empty string' ],
	[ '   ',                                        'whitespace only' ],
	[ 'not a release',                              'free text' ],
	[ '123456abc',                                  'trailing junk on a bare id' ],
	[ 'abc123456',                                  'leading junk on a bare id' ],
	[ undef,                                        'undef' ],

	# The slug widening allows an arbitrary segment before release/, so these
	# guard against it swallowing an entity path whose trailing number is not a
	# release id. I could not settle against the live site whether
	# .../releases/<n> exists as a paginated label tab - discogs.com 403s an
	# automated fetch - so the guard is there to make that not matter.
	[ 'https://www.discogs.com/label/23528-Warp-Records/releases/2',
	  'a label path whose trailing number is not a release id' ],
	[ 'https://www.discogs.com/artist/41-Autechre/releases/3',
	  'an artist path, likewise' ],
	[ 'https://www.discogs.com/user/someone/releases/1',
	  'a user path, likewise' ],
	[ 'https://www.discogs.com/master/1000/releases/2',
	  'a master path, likewise' ],
);

for my $case (@reject) {
	is( Plugins::SqueezeWax::Tags::_parseReleaseId( $case->[0] ), undef,
		"rejects: $case->[1]" );
}

# --- decide: no configured tag means no opinion ---------------------------
Test::StubPrefs->new->set( 'discogsTagNames', [] );
is_deeply( $T->decide( { DISCOGS_RELEASE_ID => '123456' } ), {},
	'nothing configured, so nothing found - the tag is ignored' );

Test::StubPrefs->new->set( 'discogsTagNames', ['DISCOGS_RELEASE_ID'] );

# --- decide: the clean hit ------------------------------------------------
my $d = $T->decide( { DISCOGS_RELEASE_ID => '123456' } );
is( $d->{id},  123456,               'a configured tag yields its id' );
is( $d->{tag}, 'DISCOGS_RELEASE_ID', '  ...and names the tag it came from' );
ok( !$d->{conflict},                 '  ...with no conflict' );

# --- decide: absence -----------------------------------------------------
is_deeply( $T->decide( { TITLE => 'x', CONTENT_TYPE => 'flc' } ), {},
	'a populated hash with no configured key is "nothing found"' );

# This is the contract that matters for remote URLs: readTags returns a
# POPULATED hashref for them (Slim/Formats.pm:246-251, :274, :280), so testing
# for an empty hash would never fire. decide() must key off the configured
# names, which the case above proves.

# --- decide: case-insensitive key lookup ---------------------------------
is( $T->decide( { 'discogs_release_id' => '123456' } )->{id}, 123456,
	'key lookup is case-insensitive' );

# ...but separator differences are NOT folded, because they are genuinely
# different tags that different taggers write - the reason the pref is a list.
# FLAC gives MUSICBRAINZ_ALBUMID (FLAC.pm:51), MP3 gives
# MUSICBRAINZ ALBUM ID (MP3.pm:48).
is_deeply( $T->decide( { 'DISCOGS RELEASE ID' => '123456' } ), {},
	'a space-separated key does not match an underscore-configured name' );

# --- decide: scalar or arrayref -----------------------------------------
# LMS does not normalise this in one place - MP3.pm:343-351 unwraps
# MUSICBRAINZ_ID, FLAC.pm:249-256 unwraps DATE, and anything else arrives as the
# reader left it.
is( $T->decide( { DISCOGS_RELEASE_ID => ['123456'] } )->{id}, 123456,
	'an arrayref value with one element is accepted' );

is( $T->decide( { DISCOGS_RELEASE_ID => [ '123456', '123456' ] } )->{id}, 123456,
	'an arrayref repeating the same id is agreement, not conflict' );

my $arrayConflict = $T->decide( { DISCOGS_RELEASE_ID => [ '123456', '999' ] } );
ok( $arrayConflict->{conflict},
	'an arrayref with two different ids is a conflict' );
ok( !defined $arrayConflict->{id},
	'  ...and yields no id, so nothing can be written as confirmed' );

# --- decide: agreement across two tags ----------------------------------
Test::StubPrefs->new->set( 'discogsTagNames', [ 'DISCOGS_RELEASE_ID', 'DISCOG_RELEASE_ID' ] );

is( $T->decide( {
	DISCOGS_RELEASE_ID => '123456',
	DISCOG_RELEASE_ID  => '123456',
} )->{id}, 123456, 'two configured tags agreeing is agreement, not conflict' );

# Zero padding must not manufacture a conflict: the two strings are different
# hash keys but the same release, and discogs_release_id is INTEGER.
my $padded = $T->decide( {
	DISCOGS_RELEASE_ID => '0123456',
	DISCOG_RELEASE_ID  => '123456',
} );
is( $padded->{id}, 123456, 'a zero-padded and a plain id are agreement' );
ok( !$padded->{conflict}, '  ...not a conflict' );

# --- decide: disagreement is not Strict ---------------------------------
my $conflict = $T->decide( {
	DISCOGS_RELEASE_ID => '123456',
	DISCOG_RELEASE_ID  => '654321',
} );

ok( $conflict->{conflict}, 'two configured tags disagreeing is a conflict' );
ok( !defined $conflict->{id},
	'  ...and no id, so §3a can write discogs_release_id NULL' );
is( scalar @{ $conflict->{conflict} }, 2, '  ...listing both values' );
like( join( ' ', @{ $conflict->{conflict} } ), qr/123456/, '  ...including the first' );
like( join( ' ', @{ $conflict->{conflict} } ), qr/654321/, '  ...and the second' );

# --- decide: unparseable is a conflict, not absence ---------------------
my $bad = $T->decide( { DISCOGS_RELEASE_ID => 'https://example.com/nope' } );
ok( $bad->{conflict},      'a present but unparseable value is a conflict' );
ok( !defined $bad->{id},   '  ...not a match' );
ok( !!@{ $bad->{conflict} }, '  ...and is reported' );

# The distinction that matters: "there is a tag here and I cannot read it" is
# not "there is no tag". The first goes to the review queue, the second writes a
# discogs_no_match row.
isnt( scalar keys %$bad, 0, 'an unparseable value does not look like absence' );

# --- decide: conflict reports the raw value, not the parsed id ----------
Test::StubPrefs->new->set( 'discogsTagNames', [ 'DISCOGS_RELEASE_ID', 'DISCOG_RELEASE_ID' ] );
my $urlConflict = $T->decide( {
	DISCOGS_RELEASE_ID => 'https://www.discogs.com/release/123456-Title',
	DISCOG_RELEASE_ID  => '654321',
} );
like( join( ' ', @{ $urlConflict->{conflict} } ), qr{discogs\.com/release/123456},
	'the conflict report shows the value as it appears in the file' );

# --- master id ---------------------------------------------------------
Test::StubPrefs->new->set( 'discogsTagNames', ['DISCOGS_RELEASE_ID'] );

is( $T->decide( {
	DISCOGS_RELEASE_ID => '123456',
	DISCOGS_MASTER_ID  => '999',
} )->{master_id}, 999, 'a conventional master tag is captured alongside' );

is( $T->decide( {
	DISCOGS_RELEASE_ID => '123456',
	DISCOGS_MASTER_ID  => '[m999]',
} )->{master_id}, 999, 'master markup is accepted' );

is( $T->decide( {
	DISCOGS_RELEASE_ID => '123456',
	DISCOGS_MASTER_ID  => 'https://www.discogs.com/master/999',
} )->{master_id}, 999, 'a master URL is accepted' );

is( $T->decide( { DISCOGS_RELEASE_ID => '123456' } )->{master_id}, undef,
	'no master tag means no master id, not a failure' );

# --- candidateKeys: two tiers of evidence ------------------------------
my @hits = $T->candidateKeys( {
	DISCOGS_RELEASE_ID => '123456',
	TRACKNUM           => '7',
	YEAR               => '1959',
	BPM                => '120',
	BARCODE            => '0724358213423',
	TITLE              => 'So What',
} );

# Corroborated hits come back flagged; the numeric noise comes back demoted
# rather than suppressed, so the caller can render decisions §3's coverage
# report and a user whose tagger writes RELEASE_ID is not told nothing at all.
my @corroborated = grep { $_->[2] } @hits;
is_deeply( \@corroborated, [ [ 'DISCOGS_RELEASE_ID', 123456, 1 ] ],
	'only the Discogs-named key is corroborated' );

my %demoted = map { $_->[0] => $_->[1] } grep { !$_->[2] } @hits;
is_deeply( [ sort keys %demoted ], [qw(BARCODE BPM TRACKNUM YEAR)],
	'the other numeric tags are returned but demoted, not dropped' );

# A magnitude gate would not have helped: BARCODE here is 13 digits.
is( $demoted{BARCODE}, 724358213423,
	'a 13-digit barcode is demoted by key name, not by length' );

# An unambiguous value is reported whatever the key is called - this is what
# catches a tagger using a name nobody would have guessed.
@hits = $T->candidateKeys( { WEIRD_CUSTOM_FIELD => 'https://www.discogs.com/release/42' } );
is_deeply( \@hits, [ [ 'WEIRD_CUSTOM_FIELD', 42, 1 ] ],
	'a URL value is corroborated under any key name' );

@hits = $T->candidateKeys( { WEIRD_CUSTOM_FIELD => '42' } );
is_deeply( \@hits, [ [ 'WEIRD_CUSTOM_FIELD', 42, 0 ] ],
	'a bare integer under an unguessable key is returned uncorroborated' );

# DISCOG without the S - decisions §3 records both spellings in the wild.
@hits = $T->candidateKeys( { DISCOG_RELEASE_ID => '123456' } );
is_deeply( \@hits, [ [ 'DISCOG_RELEASE_ID', 123456, 1 ] ],
	'DISCOG without the S corroborates a bare id' );

# A master URL is not a release, so detection must not offer it at all - not
# even demoted.
@hits = $T->candidateKeys( { DISCOGS_MASTER_ID => 'https://www.discogs.com/master/999' } );
is_deeply( \@hits, [], 'a master URL is not offered as a release candidate' );

done_testing();
