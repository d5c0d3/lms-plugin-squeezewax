#!/usr/bin/env perl
#
# Measures how often LMS album titles and Discogs basic_information.title
# agree, for the user's own collection. decisions §13 makes title-led
# matching against the collection the foundation of v1 and §13.9 records
# this as its largest unmeasured assumption; decisions §8 measured title
# normalisation against SEARCH RESULTS, which is a different population
# with different title conventions.
#
# What this proves: the agreement rate at each rung of a FIXED
# normalisation ladder, the two collision directions, and the auto-badge
# split, for one page of one collection against one library.
#
# What it CANNOT prove: anything about the rest of the collection. The
# fixture is page 1 of 3 (100 of 203 items), sorted by label, so it is not
# a random sample. A one-page figure is not a whole-collection figure.
# It also cannot prove the artist figures exactly - see the approximation
# note below.
#
# THE LADDER IS FIXED. Do not tune it until the number looks acceptable:
# that produces a figure which reads as measured and is actually fitted.
# A rule that looks like it would help belongs in the report as a finding,
# not in this file.
#
# Divergence from house style, deliberate: this script takes arguments.
# No other scripts/*.pl does. Hardcoding either path would make the
# measurement unrepeatable on another machine, and the collection grows.
#
# The database is opened READ-ONLY and nothing is written anywhere - no
# files, no DDL, no ANALYZE, no VACUUM, no temp tables. Reading a live
# LMS's SQLite file read-only is safe; the report records whether one was
# running.
#
# Usage: scripts/title-agreement.pl <library.db> <collection.json> [<server.prefs>]

use strict;
use warnings;

# This file contains literal § characters in its report text. Without `use
# utf8` those are UTF-8 bytes, and the :encoding(UTF-8) layer on STDOUT
# encodes them a second time - the report comes out saying "Â§". The rest of
# scripts/*.pl is pure ASCII and so does not need this.
use utf8;

use Config;
use Encode qw(decode);
use FindBin qw($Bin);

# Same @INC dance as the offline suites, for the same reason: DBI and
# DBD::SQLite come from refs/slimserver so we run against the versions LMS
# ships. See scripts/schema-check.pl for why the order matters.
BEGIN {
	my $libPath = "$Bin/../refs/slimserver";
	die "refs/slimserver not found at $libPath\n" unless -d $libPath;

	my $arch = $Config::Config{archname};
	$arch =~ s/^i[3456]86-/i386-/;
	$arch =~ s/gnu-//;

	my $perlmajorversion = $Config{version};
	$perlmajorversion =~ s/\.\d+$//;

	unshift @INC, grep { -d } (
		"$libPath/CPAN/arch/$perlmajorversion/$arch",
		"$libPath/CPAN/arch/$perlmajorversion/$arch/auto",
		"$libPath/CPAN/arch/$perlmajorversion",
		"$libPath/lib",
		"$libPath/CPAN",
		$libPath,
	);
}

use DBI;
use DBD::SQLite;
use JSON::XS ();

binmode STDOUT, ':encoding(UTF-8)';

my ( $dbPath, $jsonPath, $prefsPath ) = @ARGV;

die "Usage: $0 <library.db> <collection.json> [<server.prefs>]\n"
	unless defined $dbPath && defined $jsonPath;

die "library.db not found: $dbPath\n"      unless -f $dbPath;
die "collection json not found: $jsonPath\n" unless -f $jsonPath;

# ---------------------------------------------------------------------------
# The ladder
# ---------------------------------------------------------------------------
#
# Rungs are CUMULATIVE IN WHICH RULES ARE ENABLED, not a literal left-to-right
# pipeline down the table. That distinction is a judgement call this script
# makes and reports, because the table's own order is self-defeating:
# L3 removes punctuation, which destroys the brackets L5 exists to strip, so
# applying the rules in table order would make L5 gain exactly zero BY
# CONSTRUCTION - a measurement artifact, not a fact about titles.
#
# So enabled rules are applied in the order that leaves each one able to do
# its job: bracket-strip, then trim/collapse, then case-fold, then
# punctuation, then article. The report states this, and also states what L5
# would have scored under naive table order, so the choice is auditable
# rather than hidden.

# Counted and reported, never handled. L4 is English-only and that is a
# stated limitation, not an oversight.
my @ARTICLES_NON_EN = qw(
	le la les der die das el los las il lo gli de het een
);

sub _strip_bracket_suffix {
	my ($s) = @_;

	# One trailing (...) or [...] group, e.g. "(Remastered)", "[Deluxe Edition]".
	$s =~ s/\s*[\(\[][^\(\)\[\]]*[\)\]]\s*$//;

	return $s;
}

sub _collapse {
	my ($s) = @_;

	$s =~ s/^\s+//;
	$s =~ s/\s+$//;
	$s =~ s/\s+/ /g;

	return $s;
}

sub _strip_punctuation {
	my ($s) = @_;

	# "punctuation removed, keeping alphanumerics and spaces" - removed, not
	# replaced by a space. "Rock&Roll" becomes "RockRoll".
	$s =~ s/[^\p{Alnum} ]+//g;

	return _collapse($s);
}

sub _normalise {
	my ( $s, $rung ) = @_;

	return '' unless defined $s;

	$s = _strip_bracket_suffix($s) if $rung >= 5;
	$s = _collapse($s)             if $rung >= 2;
	$s = lc($s)                    if $rung >= 1;
	$s = _strip_punctuation($s)    if $rung >= 3;

	$s =~ s/^(?:the|a|an)\s+// if $rung >= 4;

	return $rung >= 2 ? _collapse($s) : $s;
}

# Discogs disambiguates same-named artists with a trailing " (2)". That is a
# fact about how Discogs formats the field, not a normalisation knob, and it
# is applied ONLY to artist strings, never to titles.
sub _strip_discogs_disambiguator {
	my ($s) = @_;

	return $s unless defined $s;

	$s =~ s/\s*\(\d+\)\s*$//;

	return $s;
}

sub _normalise_artist {
	my ($s) = @_;

	return undef unless defined $s && $s =~ /\S/;

	return _normalise( _strip_discogs_disambiguator($s), 5 );
}

sub _levenshtein {
	my ( $a, $b ) = @_;

	my @prev = ( 0 .. length($b) );
	my @cur;

	for my $i ( 1 .. length($a) ) {
		$cur[0] = $i;

		for my $j ( 1 .. length($b) ) {
			my $cost = substr( $a, $i - 1, 1 ) eq substr( $b, $j - 1, 1 ) ? 0 : 1;
			my $min = $prev[$j] + 1;
			$min = $cur[ $j - 1 ] + 1     if $cur[ $j - 1 ] + 1 < $min;
			$min = $prev[ $j - 1 ] + $cost if $prev[ $j - 1 ] + $cost < $min;
			$cur[$j] = $min;
		}

		@prev = @cur;
	}

	return $prev[ length($b) ];
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

sub _load_albums {
	my ($path) = @_;

	my $dbh = DBI->connect( "dbi:SQLite:dbname=$path", '', '', {
		RaiseError        => 1,
		PrintError        => 0,
		AutoCommit        => 1,
		sqlite_open_flags => DBD::SQLite::OPEN_READONLY(),
	} );

	# Gate copied from Library.pm's $ALBUM_TRACKS_SQL, with local_tracks kept
	# as a REPORTED COLUMN rather than a filter. Importer.pm's
	# "local_tracks == 0" skip is deliberately not reproduced: it came from
	# Structural's duration fingerprint, which needed local files to read
	# durations from, and a title comparison needs no local file.
	my $sql = q{
		SELECT a.id,
		       a.title,
		       a.compilation,
		       t.qualifying,
		       t.local_tracks,
		       (SELECT c.name FROM contributor_album ca
		          JOIN contributors c ON c.id = ca.contributor
		         WHERE ca.album = a.id AND ca.role = 5
		         ORDER BY c.id LIMIT 1) AS albumartist,
		       (SELECT c.name FROM contributor_album ca
		          JOIN contributors c ON c.id = ca.contributor
		         WHERE ca.album = a.id AND ca.role = 1
		         ORDER BY c.id LIMIT 1) AS artist,
		       (SELECT c.name FROM contributors c WHERE c.id = a.contributor)
		         AS singular
		  FROM albums a
		  JOIN (
		        SELECT t.album,
		               COUNT(*) AS qualifying,
		               SUM(CASE WHEN t.remote = 1 THEN 0 ELSE 1 END) AS local_tracks
		          FROM tracks t
		         WHERE t.album IS NOT NULL
		           AND t.audio = 1
		           AND t.content_type NOT IN ('cpl','src','ssp','dir')
		         GROUP BY t.album
		       ) t ON t.album = a.id
		 ORDER BY a.id
	};

	my $rows = $dbh->selectall_arrayref( $sql, { Slice => {} } );

	my ( @albums, @undecodable );

	for my $r (@$rows) {
		my $title = _decode_bytes( $r->{title} );

		if ( !defined $title ) {
			# Reported, never repaired. A silently "fixed" title would make
			# the agreement rate a fiction.
			push @undecodable, $r->{id};
			next;
		}

		# Three-tier approximation of Slim::Schema::Album::artists, which is a
		# runtime accessor a standalone script cannot call (decisions §11.4).
		# Slim::Schema->variousArtistsObject is NEVER called - it is not
		# side-effect-free.
		my $artistRaw;
		my $artistTier;

		for my $tier ( [ albumartist => 'ALBUMARTIST (role 5)' ],
		               [ artist      => 'ARTIST (role 1)' ],
		               [ singular    => 'albums.contributor' ] ) {
			my $v = _decode_bytes( $r->{ $tier->[0] } );

			if ( defined $v && $v =~ /\S/ ) {
				$artistRaw  = $v;
				$artistTier = $tier->[1];
				last;
			}
		}

		push @albums, {
			id           => $r->{id},
			title        => $title,
			artist       => $artistRaw,
			artist_tier  => $artistTier,
			compilation  => $r->{compilation} ? 1 : 0,
			qualifying   => $r->{qualifying},
			local_tracks => $r->{local_tracks},
			has_albumartist => ( defined $r->{albumartist} ? 1 : 0 ),
		};
	}

	$dbh->disconnect;

	return ( \@albums, \@undecodable );
}

sub _decode_bytes {
	my ($bytes) = @_;

	return undef unless defined $bytes;

	# albums.title and contributors.name are BLOB columns, so DBD::SQLite
	# hands back raw bytes. The Discogs side arrives as character strings from
	# decode_json. Comparing bytes against characters would silently fail
	# every non-ASCII title, so both sides are characters by the time any
	# comparison happens.
	return $bytes if utf8::is_utf8($bytes);

	my $decoded = eval { decode( 'UTF-8', $bytes, Encode::FB_CROAK ) };

	return $decoded;
}

sub _load_collection {
	my ($path) = @_;

	open my $fh, '<:raw', $path or die "could not read $path: $!\n";
	local $/;
	my $bytes = <$fh>;
	close $fh;

	my $data = JSON::XS::decode_json($bytes);

	my @entries;

	for my $r ( @{ $data->{releases} || [] } ) {
		my $b = $r->{basic_information} or next;

		push @entries, {
			id        => $b->{id},
			master_id => $b->{master_id},
			title     => $b->{title},
			artists   => [ map { $_->{name} } @{ $b->{artists} || [] } ],
		};
	}

	return ( \@entries, $data->{pagination} );
}

# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------

sub _index_by_key {
	my ( $items, $rung ) = @_;

	my %by;

	for my $i (@$items) {
		my $k = _normalise( $i->{title}, $rung );

		next if $k eq '';

		push @{ $by{$k} }, $i;
	}

	return \%by;
}

sub _artists_agree {
	my ( $lmsArtist, $discogsArtists ) = @_;

	my $l = _normalise_artist($lmsArtist);

	return ( 0, 'lms-absent' ) unless defined $l && $l ne '';

	my @d = grep { defined && $_ ne '' }
	        map  { _normalise_artist($_) } @$discogsArtists;

	return ( 0, 'discogs-absent' ) unless @d;

	for my $d (@d) {
		return ( 1, 'agree' ) if $d eq $l;
	}

	return ( 0, 'disagree' );
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

my ( $albums, $undecodable ) = _load_albums($dbPath);
my ( $entries, $pagination ) = _load_collection($jsonPath);

my @withLocal = grep { $_->{local_tracks} > 0 } @$albums;
my @allRemote = grep { $_->{local_tracks} == 0 } @$albums;

print "=" x 74, "\n";
print "TITLE AGREEMENT - LMS library vs Discogs collection\n";
print "=" x 74, "\n\n";

print "library.db  : $dbPath\n";
print "collection  : $jsonPath\n";
print "prefs       : ", ( defined $prefsPath ? $prefsPath : '(not supplied)' ), "\n\n";

printf "LMS albums (measurement population)  : %d\n", scalar @$albums;
printf "  ...with local tracks               : %d\n", scalar @withLocal;
printf "  ...all-remote                      : %d\n", scalar @allRemote;
print  "  The local_tracks == 0 gate is NOT applied (decided 2026-09-12).\n";
print  "  579 is the figure decisions §13.5's cost estimates were written\n";
print  "  against, so both are reported rather than one replacing the other.\n\n";

if (@$undecodable) {
	print "!! TITLES THAT WOULD NOT DECODE AS UTF-8 - excluded, NOT repaired:\n";
	print "     album id $_\n" for @$undecodable;
	print "\n";
}
else {
	print "Undecodable titles: none.\n\n";
}

printf "Collection entries in this fixture   : %d\n", scalar @$entries;

if ($pagination) {
	printf "  pagination: items=%s page=%s pages=%s per_page=%s\n",
		map { defined $pagination->{$_} ? $pagination->{$_} : '?' }
		qw(items page pages per_page);

	if ( $pagination->{items} ) {
		printf "  THIS FIXTURE IS %.1f%% OF THE COLLECTION. It is page %s of %s,\n",
			100 * scalar(@$entries) / $pagination->{items},
			$pagination->{page}, $pagination->{pages};
		print  "  sorted by label, so it is NOT a random sample. Every figure\n";
		print  "  below is a one-page figure and is not a whole-collection figure.\n";
	}
}

print "\n";

_report_prefs($prefsPath);
_report_artist_divergence($albums);
_report_non_english_articles( $albums, $entries );
_report_ladder( $albums, $entries );
_report_l5( $albums, $entries, \@withLocal, \@allRemote );

sub _report_prefs {
	my ($path) = @_;

	print "-" x 74, "\n";
	print "ARTIST APPROXIMATION - how exact it is\n";
	print "-" x 74, "\n\n";

	print "Slim::Schema::Album::artists is a runtime accessor, unavailable\n";
	print "here (decisions §11.4), so artist comes from SQL: ALBUMARTIST\n";
	print "(role 5), else ARTIST (role 1), else albums.contributor.\n\n";

	if ( !defined $path ) {
		print "server.prefs not supplied, so the two prefs that gate the real\n";
		print "accessor's branches are UNVERIFIED in this run. Pass the prefs\n";
		print "path as a third argument to check them.\n\n";
		return;
	}

	open my $fh, '<', $path or do {
		print "server.prefs could not be read ($path): $!\n";
		print "The two prefs are therefore UNVERIFIED in this run.\n\n";
		return;
	};

	my %want = ( bandInArtists => undef, variousArtistAutoIdentification => undef );

	while ( my $line = <$fh> ) {
		for my $k ( keys %want ) {
			$want{$k} = $1 if $line =~ /^\Q$k\E:\s*(\S+)/;
		}
	}

	close $fh;

	for my $k ( sort keys %want ) {
		printf "  %-34s = %s\n", $k, ( defined $want{$k} ? $want{$k} : '(absent)' );
	}

	print "\n";
	print "  bandInArtists off  -> the BAND branch never fires; omitting it is\n";
	print "                        exact, not approximate.\n";
	print "  variousArtistAutoIdentification on -> the ARTIST branch is gated on\n";
	print "                        !compilation, so compilations with no\n";
	print "                        ALBUMARTIST diverge. That set is sized below.\n\n";
}

sub _report_artist_divergence {
	my ($albums) = @_;

	my @set = grep { $_->{compilation} && !$_->{has_albumartist} } @$albums;
	my @real = grep { !defined $_->{artist} || $_->{artist} !~ /^various artists$/i } @set;

	printf "Divergence set (compilation = 1, no ALBUMARTIST): %d of %d\n",
		scalar @set, scalar @$albums;
	printf "  ...of those, already yielding 'Various Artists' anyway: %d\n",
		scalar(@set) - scalar(@real);
	printf "  ...ACTUALLY DIVERGING: %d\n", scalar @real;

	for my $a (@real) {
		printf "      album %-6s %-44s -> %s\n",
			$a->{id}, _trunc( $a->{title}, 44 ),
			( defined $a->{artist} ? $a->{artist} : '(none)' );
	}

	my $noArtist = grep { !defined $_->{artist} } @$albums;
	printf "  Albums with no LMS-side artist string at all: %d\n", $noArtist;

	print "\n  Where this diverges, the approximation returns the specific\n";
	print "  artist and the real accessor would return Various Artists.\n\n";
}

sub _trunc {
	my ( $s, $n ) = @_;

	return '' unless defined $s;

	return length($s) > $n ? substr( $s, 0, $n - 1 ) . '~' : $s;
}

sub _report_non_english_articles {
	my ( $albums, $entries ) = @_;

	my $re = join '|', @ARTICLES_NON_EN;
	$re = qr/^(?:$re)\s+/i;

	my $lms = grep { $_->{title} =~ $re } @$albums;
	my $col = grep { defined $_->{title} && $_->{title} =~ $re } @$entries;

	print "-" x 74, "\n";
	print "L4 IS ENGLISH-ONLY - a stated limitation, not an oversight\n";
	print "-" x 74, "\n\n";
	printf "Titles beginning with an identifiable non-English article:\n";
	printf "  LMS        : %d\n", $lms;
	printf "  collection : %d\n", $col;
	print  "  Counted, NOT handled. No rule was added for them.\n\n";
}

sub _report_ladder {
	my ( $albums, $entries ) = @_;

	print "-" x 74, "\n";
	print "THE NORMALISATION LADDER - fixed in advance, not tuned\n";
	print "-" x 74, "\n\n";

	print "Rungs are cumulative in WHICH RULES ARE ENABLED. Enabled rules are\n";
	print "applied bracket-strip -> trim/collapse -> case-fold -> punctuation\n";
	print "-> article, NOT in table order. Table order is self-defeating: L3\n";
	print "removes punctuation, destroying the brackets L5 exists to strip, so\n";
	print "L5 would gain exactly zero BY CONSTRUCTION. That would be an\n";
	print "artifact of the ordering, not a fact about titles. The naive-order\n";
	print "L5 figure is printed below so the choice is auditable.\n\n";

	printf "%-4s %-12s %-12s %-10s %-10s\n",
		'Rung', 'LMS matched', 'Col matched', 'LMS gain', 'Col gain';

	my ( $prevL, $prevC ) = ( 0, 0 );

	for my $rung ( 0 .. 5 ) {
		my ( $l, $c ) = _match_counts( $albums, $entries, $rung );

		printf "L%-3d %-12d %-12d %-+10d %-+10d\n",
			$rung, $l, $c, $l - $prevL, $c - $prevC;

		( $prevL, $prevC ) = ( $l, $c );
	}

	print "\n";

	my ( $naiveL, $naiveC ) = _match_counts_naive( $albums, $entries );
	printf "Under naive table-order application, L5 would score: LMS %d, col %d\n",
		$naiveL, $naiveC;
	printf "  (identical to L4 by construction - this is why the order was changed)\n\n";
}

sub _match_counts {
	my ( $albums, $entries, $rung ) = @_;

	my $colBy = _index_by_key( $entries, $rung );
	my $lmsBy = _index_by_key( $albums,  $rung );

	my $l = grep { my $k = _normalise( $_->{title}, $rung ); $k ne '' && $colBy->{$k} } @$albums;
	my $c = grep { my $k = _normalise( $_->{title}, $rung ); $k ne '' && $lmsBy->{$k} } @$entries;

	return ( $l, $c );
}

sub _match_counts_naive {
	my ( $albums, $entries ) = @_;

	# L5's bracket-strip applied AFTER L3's punctuation removal, i.e. in table
	# order. Printed for audit only; nothing downstream uses it.
	my $n = sub {
		my ($s) = @_;
		return _strip_bracket_suffix( _normalise( $s, 4 ) );
	};

	my %colBy;
	for my $e (@$entries) {
		my $k = $n->( $e->{title} );
		push @{ $colBy{$k} }, $e if $k ne '';
	}

	my %lmsBy;
	for my $a (@$albums) {
		my $k = $n->( $a->{title} );
		push @{ $lmsBy{$k} }, $a if $k ne '';
	}

	my $l = grep { my $k = $n->( $_->{title} ); $k ne '' && $colBy{$k} } @$albums;
	my $c = grep { my $k = $n->( $_->{title} ); $k ne '' && $lmsBy{$k} } @$entries;

	return ( $l, $c );
}

sub _report_l5 {
	my ( $albums, $entries, $withLocal, $allRemote ) = @_;

	my $rung  = 5;
	my $colBy = _index_by_key( $entries, $rung );
	my $lmsBy = _index_by_key( $albums,  $rung );

	print "-" x 74, "\n";
	print "COLLISIONS AT L5 - two directions, reported separately, NEVER summed\n";
	print "-" x 74, "\n\n";

	# --- direction (a): one LMS album -> several collection entries ---
	my @dirA;

	for my $a (@$albums) {
		my $k = _normalise( $a->{title}, $rung );
		next if $k eq '';
		my $c = $colBy->{$k} or next;
		push @dirA, [ $a, $c ] if @$c >= 2;
	}

	printf "(a) One LMS album -> 2+ collection entries : %d   <-- THE PROBLEM\n",
		scalar @dirA;
	print  "    Ambiguous: the album cannot be identified without a tiebreak.\n\n";

	for my $pair (@dirA) {
		my ( $a, $cands ) = @$pair;

		printf "    album %-6s %s\n", $a->{id}, _trunc( $a->{title}, 56 );
		printf "      LMS artist: %s\n",
			( defined $a->{artist} ? $a->{artist} : '(none)' );

		my @agreeing;

		for my $c (@$cands) {
			my ( $ok, $why ) = _artists_agree( $a->{artist}, $c->{artists} );
			push @agreeing, $c if $ok;

			printf "      release %-10s %-40s [%s] %s\n",
				$c->{id}, _trunc( $c->{title}, 40 ),
				join( ', ', @{ $c->{artists} } ), $why;
		}

		my $verdict = @agreeing == 1 ? 'RESOLVED by artist to one candidate'
		            : @agreeing == 0 ? 'ELIMINATED ALL candidates'
		            :                  'STILL AMBIGUOUS after artist';

		print "      -> $verdict\n\n";
	}

	print "\n" unless @dirA;

	# --- direction (b): one collection entry -> several LMS albums ---
	my @dirB;

	for my $e (@$entries) {
		my $k = _normalise( $e->{title}, $rung );
		next if $k eq '';
		my $a = $lmsBy->{$k} or next;
		push @dirB, [ $e, $a ] if @$a >= 2;
	}

	printf "(b) One collection entry -> 2+ LMS albums  : %d\n", scalar @dirB;
	print  "    The expected shape here is a rip and a stream of the SAME\n";
	print  "    record: two LMS albums for one owned item, and both should\n";
	print  "    badge. Removing the local_tracks gate increases that shape by\n";
	print  "    construction, since the all-remote albums are where the stream\n";
	print  "    half lives - a rise in it is not a regression.\n\n";
	print  "    But this direction is NOT uniformly benign, and the run below\n";
	print  "    shows why. Two other shapes hide in it, so each group is\n";
	print  "    classified rather than waved through:\n";
	print  "      SAME-RECORD  identical raw titles, one artist - the benign one\n";
	print  "      DIFF-TITLE   raw titles differ, so normalisation merged two\n";
	print  "                   genuinely different albums\n";
	print  "      CROSS-ARTIST the LMS albums are by different artists, so at\n";
	print  "                   most one can be the owned record\n\n";

	my %shape = ( same => 0, difftitle => 0, cross => 0, wrongbadge => 0 );

	for my $pair (@dirB) {
		my ( $e, $albumsFor ) = @$pair;

		my %artists = map {
			( defined $_->{artist} ? lc $_->{artist} : '(none)' ) => 1
		} @$albumsFor;

		my %titles = map { $_->{title} => 1 } @$albumsFor;

		my $cross    = keys(%artists) > 1;
		my $diffName = keys(%titles) > 1;

		my $label = $cross    ? 'CROSS-ARTIST'
		          : $diffName ? 'DIFF-TITLE'
		          :             'SAME-RECORD';

		$shape{ $cross ? 'cross' : $diffName ? 'difftitle' : 'same' }++;

		# The failure that matters: normalisation merged two different albums
		# AND the artist check cannot separate them, so every one of them
		# badges. A wrong badge, not a missing one.
		my $agreeing = grep {
			my ($ok) = _artists_agree( $_->{artist}, $e->{artists} );
			$ok;
		} @$albumsFor;

		my $wrongBadge = ( $diffName && !$cross && $agreeing > 1 );
		$shape{wrongbadge}++ if $wrongBadge;

		printf "    [%-12s] release %-10s %s\n",
			$label, $e->{id}, _trunc( $e->{title}, 40 );
		printf "                   Discogs artist: %s\n",
			join( ', ', @{ $e->{artists} } );

		for my $a (@$albumsFor) {
			printf "      album %-6s %-32s %-24s local=%d\n",
				$a->{id}, _trunc( $a->{title}, 32 ),
				_trunc( ( defined $a->{artist} ? $a->{artist} : '(none)' ), 24 ),
				$a->{local_tracks};
		}

		printf "      -> %d of %d agree with the Discogs artist%s\n",
			$agreeing, scalar @$albumsFor,
			( $wrongBadge
				? "  *** WRONG BADGE: different albums, artist cannot separate them"
				: '' );

		print "\n";
	}

	printf "    Shape of direction (b): SAME-RECORD %d, DIFF-TITLE %d, CROSS-ARTIST %d\n",
		@shape{qw(same difftitle cross)};
	printf "    Groups that would produce a WRONG BADGE: %d\n\n", $shape{wrongbadge};

	# --- overlap ---
	print "-" x 74, "\n";
	print "OVERLAP AT L5\n";
	print "-" x 74, "\n\n";

	my $matched = sub {
		my ($set) = @_;
		return scalar grep {
			my $k = _normalise( $_->{title}, $rung );
			$k ne '' && $colBy->{$k};
		} @$set;
	};

	printf "LMS albums matching any collection entry:\n";
	printf "  all albums        : %d of %d\n", $matched->($albums),    scalar @$albums;
	printf "  with local tracks : %d of %d\n", $matched->($withLocal), scalar @$withLocal;
	printf "  all-remote        : %d of %d   <-- THE GATE DECISION TURNS ON THIS\n",
		$matched->($allRemote), scalar @$allRemote;
	print  "  A high all-remote count means the removed gate was dropping owned\n";
	print  "  records. A count near zero means it cost nothing in practice.\n\n";

	# --- auto-badge split ---
	print "-" x 74, "\n";
	print "AUTO-BADGE SPLIT AT L5 (badging rule decided 2026-09-12)\n";
	print "-" x 74, "\n\n";

	my %bucket = (
		badge          => 0,
		disagree       => 0,
		disagree_vpair => 0,
		lms_absent     => 0,
		discogs_absent => 0,
		several        => 0,
	);

	for my $a (@$albums) {
		my $k = _normalise( $a->{title}, $rung );
		next if $k eq '';
		my $cands = $colBy->{$k} or next;

		if ( @$cands >= 2 ) {
			$bucket{several}++;
			next;
		}

		my ( $ok, $why ) = _artists_agree( $a->{artist}, $cands->[0]{artists} );

		if ($ok) {
			$bucket{badge}++;
		}
		elsif ( $why eq 'lms-absent' ) {
			$bucket{lms_absent}++;
		}
		elsif ( $why eq 'discogs-absent' ) {
			$bucket{discogs_absent}++;
		}
		else {
			$bucket{disagree}++;
			$bucket{disagree_vpair}++
				if _is_various_pair( $a->{artist}, $cands->[0]{artists} );
		}
	}

	my $total = 0;
	$total += $bucket{$_} for qw(badge disagree lms_absent discogs_absent several);

	printf "  one candidate, artist agrees        : %4d   AUTO-BADGE\n", $bucket{badge};
	printf "  one candidate, artist disagrees     : %4d   queue\n", $bucket{disagree};
	printf "      ...of which Various/Various Artists: %4d\n", $bucket{disagree_vpair};
	printf "  one candidate, LMS artist absent    : %4d   queue\n", $bucket{lms_absent};
	printf "  one candidate, Discogs artist absent: %4d   queue\n", $bucket{discogs_absent};
	printf "  several candidates (direction (a))  : %4d   queue\n", $bucket{several};
	printf "  %s\n", '-' x 52;
	printf "  total L5 title matches              : %4d\n\n", $total;

	print "  The Various/Various Artists line is a FINDING, not a fix. LMS says\n";
	print "  'Various Artists'; Discogs says 'Various'. An equivalence rule is\n";
	print "  exactly what this measurement's trap warning forbids adding\n";
	print "  mid-run, so none was added. The number is shown split so the\n";
	print "  decision can be made on evidence in a later session.\n\n";

	# --- unmatched collection entries ---
	my @unmatched = grep {
		my $k = _normalise( $_->{title}, $rung );
		$k eq '' || !$lmsBy->{$k};
	} @$entries;

	printf "Unmatched collection entries (owned, no LMS album): %d of %d\n",
		scalar @unmatched, scalar @$entries;
	print  "  Expected, not a defect - records owned but not ripped or streamed.\n\n";

	# --- example failures ---
	print "-" x 74, "\n";
	print "TEN EXAMPLE FAILURES AT L5 - for reading, NOT for tuning\n";
	print "-" x 74, "\n\n";

	print "Selection rule: L5-unmatched LMS albums sorted by albums.id\n";
	print "ascending, first ten. 'Nearest' = minimum Levenshtein distance on\n";
	print "the L5-normalised strings, ties broken by lowest Discogs release id.\n\n";

	my @failures = grep {
		my $k = _normalise( $_->{title}, $rung );
		$k eq '' || !$colBy->{$k};
	} @$albums;

	my @sample = @failures > 10 ? @failures[ 0 .. 9 ] : @failures;

	# Sorted once, outside the loop: the tie-break is "lowest Discogs release
	# id", and a sort block inside a sub whose loop variable is named $a would
	# have its $a shadowed by that lexical.
	my @entriesById = sort { $a->{id} <=> $b->{id} } @$entries;

	for my $album (@sample) {
		my $ak = _normalise( $album->{title}, $rung );
		my ( $best, $bestD );

		for my $e (@entriesById) {
			my $d = _levenshtein( $ak, _normalise( $e->{title}, $rung ) );

			if ( !defined $bestD || $d < $bestD ) {
				( $best, $bestD ) = ( $e, $d );
			}
		}

		printf "  album %-6s %s\n", $album->{id}, $album->{title};
		printf "               nearest: %s\n", ( $best ? $best->{title} : '(none)' );
		printf "               distance %d on the normalised forms\n\n",
			( defined $bestD ? $bestD : -1 );
	}

	printf "Total L5 failures: %d of %d LMS albums\n\n",
		scalar @failures, scalar @$albums;
}

sub _is_various_pair {
	my ( $lmsArtist, $discogsArtists ) = @_;

	return 0 unless defined $lmsArtist;
	return 0 unless $lmsArtist =~ /^\s*various artists\s*$/i;

	for my $d (@$discogsArtists) {
		return 1 if defined $d && $d =~ /^\s*various\s*$/i;
	}

	return 0;
}
