#!/usr/bin/env perl
#
# Offline exercise of Plugins::SqueezeWax::Ownership.
#
# No LMS instance and no database: this half of the module is the comparison,
# and the comparison is pure functions over strings. That is the point of the
# split. The rules here decide which albums badge, they were measured on a real
# library by scripts/title-agreement.pl, and a silent drift from that script
# would invalidate the measurement rather than fail anything.
#
# What it cannot prove: that the rules are the RIGHT rules. That was the
# measurement's job (decisions §13.10), and re-measuring under §15.13 part 3's
# L2 artist rule is an open TODO item.
#
# Usage: scripts/ownership-check.pl

use strict;
use warnings;

use Config;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

# DBI and DBD::SQLite come from refs/slimserver, so the pass runs against the
# same SQLite LMS ships. Search order matters and is not approximated: see
# scripts/schema-check.pl's header for why crossing the pure-perl and XS halves
# is a DynaLoader mismatch rather than a clean failure.
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
		"$libPath/CPAN/arch/$Config{version}/$Config::Config{archname}",
		"$libPath/CPAN/arch/$Config{version}/$Config::Config{archname}/auto",
		"$libPath/CPAN/arch/$perlmajorversion/$Config::Config{archname}",
		"$libPath/CPAN/arch/$perlmajorversion/$Config::Config{archname}/auto",
		"$libPath/CPAN/arch/$Config::Config{archname}",
		"$libPath/CPAN/arch/$perlmajorversion",
		"$libPath/lib",
		"$libPath/CPAN",
		$libPath,
	);
}

require DBI;

use Digest::MD5 qw(md5_hex);

# Same stubbing as the other suites: logger() is called at file scope.
BEGIN {
	$INC{'Slim/Utils/Log.pm'}    = 1;
	$INC{'Slim/Schema.pm'}       = 1;
	$INC{'Slim/Music/Info.pm'}   = 1;
	$INC{'Slim/Music/Import.pm'} = 1;
	$INC{'Slim/Utils/Prefs.pm'}  = 1;
	$INC{'Slim/Formats.pm'}      = 1;

	# Match.pm reads this at runtime to decide whether a scan holds the write
	# lock; the pass's own tests drive _writeOk directly.
	no strict 'refs';
	*{'Slim::Music::Import::stillScanning'} = sub { 0 };
	*{'Slim::Utils::Prefs::preferences'}    = sub { Test::StubPrefs->new };
	*{'Slim::Utils::Prefs::import'}         = sub {
		my $caller = caller;
		no strict 'refs';
		*{$caller . '::preferences'} = \&Slim::Utils::Prefs::preferences;
	};

	no strict 'refs';
	*{'Slim::Utils::Log::logger'}   = sub { Test::StubLogger->new };
	*{'Slim::Utils::Log::logError'} = sub { };
	*{'Slim::Utils::Log::import'}   = sub {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::logger"}   = \&Slim::Utils::Log::logger;
		*{"${caller}::logError"} = \&Slim::Utils::Log::logError;
	};

	*{'main::SCANNER'}   = sub () { 0 };
	# On, so the pass's summary line is actually built and can be asserted.
	# The counts it carries are what tells step 8 how big its queue will be.
	*{'main::INFOLOG'}   = sub () { 1 };
	*{'main::DEBUGLOG'}  = sub () { 0 };
	# Schema::_samePath case-folds under ISWINDOWS; this runs the POSIX branch.
	*{'main::ISWINDOWS'} = sub () { 0 };
}

{
	package Test::StubPrefs;
	sub new  { bless {}, shift }
	sub get  { [] }
	sub set  { 1 }
}

{
	package Test::StubLogger;
	sub new      { bless {}, shift }
	sub error    { }
	sub warn     { }
	sub info     { shift; push @main::LOG, "@_"; return }
	sub debug    { }
	sub is_info  { 1 }
	sub is_debug { 0 }
}

our @LOG;

# The pass's one summary line, from the most recent run.
sub summary {
	my ($line) = grep { /^ownership pass:/ } reverse @LOG;

	return $line;
}

# Ownership.pm has real `use Plugins::SqueezeWax::*` lines, so like
# match-check.pl it needs the Plugins/SqueezeWax layout LMS resolves against
# rather than a by-file-path require. Build it, the same way syntax-check.sh
# does.
my $incdir;

BEGIN {
	$incdir = tempdir( CLEANUP => 1 );
	mkdir "$incdir/Plugins";
	symlink "$Bin/../SqueezeWax", "$incdir/Plugins/SqueezeWax"
		or die "could not link the plugin into $incdir: $!\n";
	unshift @INC, $incdir;
}

require Plugins::SqueezeWax::Ownership;

# Plain functions, called as plain functions - CLAUDE.md's calling convention.
# Calling one of these method-style would silently eat the class name as its
# first argument, which is the slip the convention exists to make greppable.
my $O = 'Plugins::SqueezeWax::Ownership';

sub titleKey    { return Plugins::SqueezeWax::Ownership::_titleKey(@_) }
sub artistKey   { return Plugins::SqueezeWax::Ownership::_artistKey(@_) }
sub decode      { return Plugins::SqueezeWax::Ownership::_decode(@_) }
sub artistsAgree{ return Plugins::SqueezeWax::Ownership::_artistsAgree(@_) }

# --- L2 and nothing more (§13.10.4) ---------------------------------------
is( titleKey('  Violator  '), 'violator', 'L2 trims' );
is( titleKey("Music\tFor  The\nMasses"), 'music for the masses',
	'L2 collapses every run of whitespace, including tabs and newlines' );
is( titleKey('VIOLATOR'), 'violator', 'L2 case-folds' );
is( titleKey(undef), '', 'an undef title gives the empty key, not a warning' );
is( titleKey(''),    '', 'an empty title gives the empty key' );

# The rungs §13.10.4 rejected. Each of these WOULD collapse under rungs 3-5 of
# title-agreement.pl's ladder, and each pair is a genuinely different record.
isnt( titleKey('Violator (Remastered)'), titleKey('Violator'),
	'L2 does NOT strip a bracket suffix - that is rung 5, and it merges pressings' );
isnt( titleKey('Rock & Roll'), titleKey('Rock Roll'),
	'L2 does NOT strip punctuation - that is rung 3' );
isnt( titleKey('The Downward Spiral'), titleKey('Downward Spiral'),
	'L2 does NOT strip a leading article - that is rung 4' );

# The pair the plan names: a superscript is not whitespace, punctuation or
# case, so L2 must keep these apart. They are different Biosphere records.
isnt( titleKey('Substrata'), titleKey("Substrata\x{00B2}"),
	'Substrata and Substrata² do not collide at L2' );

# --- the Discogs disambiguator (artists only) ------------------------------
is( artistKey('Nirvana (2)'), 'nirvana', 'a trailing " (2)" is stripped from an artist' );
is( artistKey('Nirvana (12)'), 'nirvana', '  ...with more than one digit' );
is( artistKey('Nirvana(2)'),  'nirvana',  '  ...with no space before it' );

# Applied to artists only, never to titles. A title that ends in a parenthesised
# number is a real title.
is( titleKey('Symphony No. 9 (1)'), 'symphony no. 9 (1)',
	'the disambiguator strip is NOT applied to titles' );

# Only a TRAILING group, and only digits.
is( artistKey('Sunn O))) (2)'), 'sunn o)))', 'only the trailing group is stripped' );
is( artistKey('Front 242'),     'front 242', 'a bare trailing number is not a disambiguator' );
is( artistKey('Apoptygma Berzerk (Remix)'), 'apoptygma berzerk (remix)',
	'a trailing non-numeric group is left alone' );

# --- absence is distinct from emptiness ------------------------------------
is( artistKey(undef), undef, 'an undef artist has no key' );
is( artistKey(''),    undef, 'an empty artist has no key' );
is( artistKey('   '), undef, 'a whitespace-only artist has no key' );
is( artistKey('(3)'), undef, 'an artist that is nothing but a disambiguator has no key' );

# --- _decode ---------------------------------------------------------------
my $utf8Bytes = "Bj\xc3\xb6rk";

my $decoded = decode($utf8Bytes);
is( $decoded, "Bj\x{00F6}rk", 'UTF-8 bytes decode to characters' );
ok( utf8::is_utf8($decoded),  '  ...as a character string' );

is( decode(undef), undef, 'undef decodes to undef' );
is( decode('plain ascii'), 'plain ascii', 'ASCII passes through' );

# Already-decoded input is returned untouched rather than double-decoded.
is( decode($decoded), $decoded, 'an already-decoded string is returned as-is' );

# The known limit of that test, inherited from title-agreement.pl:310-325 and
# asserted so it is not mistaken for a bug later. utf8::is_utf8 reports the
# internal representation, not "these are characters": Perl stores a character
# string whose codepoints all fit in a byte WITHOUT the flag, so a Latin-1-range
# character string is indistinguishable here from invalid UTF-8 bytes, and gets
# the same undef. This is safe in the direction that matters - a name we cannot
# be sure of is counted, never guessed at - and it does not arise in practice,
# because the only caller feeds it blob columns straight from DBD::SQLite.
my $unflagged = "Bj\x{00F6}rk";
ok( !utf8::is_utf8($unflagged), 'a Latin-1-range character string carries no UTF8 flag' );
is( decode($unflagged), undef, '  ...so it is treated as undecodable bytes, not repaired' );

# Invalid UTF-8 gives undef, never a repaired string. Latin-1 "Björk" is the
# realistic case: a tagger that wrote the wrong encoding.
is( decode("Bj\xf6rk"), undef,
	'bytes that are not valid UTF-8 give undef, not a guess' );

# --- _artistsAgree ---------------------------------------------------------
my $VA = 'Various Artists';

is( artistsAgree( 'Depeche Mode', ['Depeche Mode'], $VA ), 'agree', 'an exact match agrees' );
is( artistsAgree( 'depeche mode', ['DEPECHE MODE'], $VA ), 'agree', '  ...case-insensitively' );
is( artistsAgree( 'Nirvana', ['Nirvana (2)'], $VA ), 'agree',
	'  ...through the disambiguator strip' );
is( artistsAgree( 'Orbital', [ 'Kraftwerk', 'Orbital' ], $VA ), 'agree',
	'any one of several Discogs artists is enough' );

is( artistsAgree( 'Depeche Mode', ['Erasure'], $VA ), 'disagree', 'different artists disagree' );

is( artistsAgree( undef, ['Erasure'], $VA ), 'lms-absent', 'a missing LMS artist is lms-absent' );
is( artistsAgree( '  ', ['Erasure'], $VA ), 'lms-absent', '  ...and so is a blank one' );
is( artistsAgree( 'Erasure', [], $VA ), 'discogs-absent', 'no Discogs artists is discogs-absent' );
is( artistsAgree( 'Erasure', undef, $VA ), 'discogs-absent', '  ...and so is undef' );
is( artistsAgree( 'Erasure', [ undef, '' ], $VA ), 'discogs-absent',
	'  ...and so is a list with nothing usable in it' );

# lms-absent is checked before discogs-absent, so the two cannot both be true
# and the caller never has to guess which it got.
is( artistsAgree( undef, [], $VA ), 'lms-absent',
	'with both sides absent, lms-absent is reported' );

# --- §15.7 and §15.14: the compilation gate -------------------------------
#
# The rule is Various-to-Various, HOWEVER SPELLED. Until 2026-09-20 the gate
# was consulted only after plain equality failed, which keyed it on the
# MECHANISM of the match: 'Various Artists' against the default label reached
# equality and badged, while 'Various' on the same record reached the mapping
# and was gated. §15.14 closed that seam by running the test first. Every pair
# below is a compilation on both sides, and none of them may badge.
my $custom = 'Diverse Interpreten';

is( artistsAgree( $VA, ['Various'], $VA ), 'various',
	"the default label against Discogs' 'Various' is gated" );
is( artistsAgree( $VA, ['Various Artists'], $VA ), 'various',
	"  ...and against 'Various Artists' too - the seam §15.14 closed" );
is( artistsAgree( 'Various', ['Various'], $VA ), 'various',
	"an LMS literal 'Various' is gated even though the label is 'Various Artists'" );
is( artistsAgree( 'Various Artists', ['Various'], $VA ), 'various',
	"  ...and an LMS literal 'Various Artists' likewise" );
is( artistsAgree( $VA, ['Various (2)'], $VA ), 'various',
	'the disambiguator strip happens before the gate, so "Various (2)" is gated' );
is( artistsAgree( $VA, [ 'Various Artists', 'Various' ], $VA ), 'various',
	'a Discogs list naming both spellings is gated, not agreed' );

# It is 'various', NOT 'agree'. That distinction is the whole of the gate: the
# caller writes no badge on it.
isnt( artistsAgree( $VA, ['Various Artists'], $VA ), 'agree',
	'the gate never reports agree, whichever spelling reached it' );

# A customised label is gated against either Discogs spelling...
is( artistsAgree( $custom, ['Various'], $custom ), 'various',
	'a customised variousArtistsString is a various-artists name on the LMS side' );
is( artistsAgree( $custom, ['Various Artists'], $custom ), 'various',
	'  ...against either Discogs spelling' );

# ...and the literals still count on the LMS side even when the label differs.
# §15.7's no-literal rule is about AGREEMENT and is untouched: this only
# withholds a badge, so treating a literal as a compilation fails safe.
is( artistsAgree( 'Various Artists', ['Various'], $custom ), 'various',
	"an LMS literal is a compilation even when the label is '$custom' - the gate fails safe" );

# The Discogs side stays Discogs' own fixed vocabulary. A credit that merely
# equals the user's label is a real artist name, not a compilation marker.
is( artistsAgree( $custom, [$custom], $custom ), 'agree',
	'the label on both sides is a plain agreement - Discogs never says "Diverse Interpreten"' );
is( artistsAgree( $custom, ['Sundry'], $custom ), 'disagree',
	'the LMS label against some other Discogs artist still disagrees' );

# Real artists are entirely unaffected: the gate narrows, and only here.
is( artistsAgree( 'Depeche Mode', ['Depeche Mode'], $VA ), 'agree',
	'a real artist on both sides still agrees' );
is( artistsAgree( 'Depeche Mode', ['Various'], $VA ), 'disagree',
	'a real LMS artist against a Discogs compilation still disagrees' );
is( artistsAgree( $VA, ['Depeche Mode'], $VA ), 'disagree',
	'an LMS compilation against a real Discogs artist still disagrees' );

# A missing or blank label must not turn every artist into a compilation.
is( artistsAgree( 'Erasure', ['Various'], undef ), 'disagree',
	'an undef variousArtistsString leaves the literals as the only LMS trigger' );
is( artistsAgree( 'Various', ['Various'], undef ), 'various',
	'  ...which still fire, so the gate survives a label that cannot be read' );
is( artistsAgree( '', ['Various'], '' ), 'lms-absent',
	'a blank label cannot make a blank LMS artist match' );

# ===========================================================================
# The pass itself.
# ===========================================================================
#
# A real SQLite database behind the real Schema.pm migrations, and a stub
# library for Library::eachAlbum to walk - the same shape match-check.pl uses.
# The rules above are pure; everything below is about what actually lands in
# discogs_match, which is the one table in this plugin that is not disposable.

my $dir = tempdir( CLEANUP => 1 );
my $dbh = DBI->connect( "dbi:SQLite:dbname=$dir/library.db", '', '', {
	RaiseError => 1, PrintError => 0, AutoCommit => 1,
} );

$dbh->do('PRAGMA foreign_keys = ON');
$dbh->do("ATTACH '$dir/squeezewax.db' AS squeezewax");

{
	no warnings 'once', 'redefine';

	*Slim::Schema::dbh = sub { $dbh };

	# §15.7's label, which _artistsAgree takes as an argument so it stays pure.
	# The pass reads it once per run (Slim/Music/Info.pm:1540).
	*Slim::Music::Info::variousArtistString = sub { $VA };

	# The suite migrates the database directly rather than through
	# postDBConnect, so Schema's readiness flag was never set and _writeOk would
	# refuse everything. The refusal itself is exercised below by overriding
	# _writeOk, which is the condition that actually matters here.
	*Plugins::SqueezeWax::Schema::isReady = sub { 1 };
}

# Only the columns Library reads. Types from SQL/SQLite/schema_16_up.sql.
$dbh->do(q{
	CREATE TABLE tracks (
		id INTEGER PRIMARY KEY, album INT, urlmd5 TEXT, url TEXT,
		timestamp INT, disc INT, tracknum INT, remote INT, audio INT,
		content_type TEXT
	)
});
$dbh->do('CREATE TABLE albums (id INTEGER PRIMARY KEY, title BLOB, contributor INT)');
$dbh->do('CREATE TABLE contributors (id INTEGER PRIMARY KEY, name BLOB)');
$dbh->do('CREATE TABLE contributor_album (role INT, contributor INT, album INT)');

require Plugins::SqueezeWax::Schema;
Plugins::SqueezeWax::Schema->_migrate($dbh);

my $nextTrack = 0;

# One album, with its album_key computed the way Library::_finish computes it.
sub album {
	my ( $id, $title, $artist, %opt ) = @_;

	my $tracks = $opt{tracks} || 1;
	my $remote = $opt{remote} ? 1 : 0;

	my @urlmd5;

	for my $n ( 1 .. $tracks ) {
		$nextTrack++;
		my $url = ( $remote ? 'spotify://' : 'file:///' ) . "a$id-t$n";
		my $md5 = md5_hex($url);
		push @urlmd5, $md5;
		$dbh->do( 'INSERT INTO tracks VALUES (?,?,?,?,?,?,?,?,?,?)', undef,
			$nextTrack, $id, $md5, $url, 100, 1, $n, $remote, 1, 'flc' );
	}

	$dbh->do( 'INSERT INTO albums (id, title) VALUES (?,?)', undef, $id, $title );

	if ( defined $artist ) {
		$dbh->do( 'INSERT INTO contributors (id, name) VALUES (?,?)', undef, $id, $artist );
		$dbh->do( 'INSERT INTO contributor_album (role, contributor, album) VALUES (5,?,?)',
			undef, $id, $id );
	}

	return md5_hex( join '', sort @urlmd5 );
}

sub entry {
	my ( $instance, $release, $master, $title, @artists ) = @_;

	return {
		instance_id => $instance,
		id          => $release,
		master_id   => $master,
		title       => $title,
		artists     => \@artists,
	};
}

sub matchRow {
	my (%col) = @_;

	my @names = sort keys %col;

	$dbh->do(
		'INSERT INTO squeezewax.discogs_match (' . join( ',', @names ) . ') VALUES ('
			. join( ',', ('?') x @names ) . ')',
		undef, map { $col{$_} } @names
	);

	return;
}

sub rowFor {
	my $key = shift;

	return $dbh->selectrow_hashref(
		'SELECT * FROM squeezewax.discogs_match WHERE album_key = ?', undef, $key
	);
}

sub matchCount {
	my ($n) = $dbh->selectrow_array('SELECT COUNT(*) FROM squeezewax.discogs_match');
	return $n;
}

# --- the fixture -----------------------------------------------------------
#
# One album per path through design §3, so a failure names the path.
my %K;
$K{d_strict}   = album( 1,  'Violator',          'Depeche Mode' );
$K{d_manual}   = album( 2,  'Music For Masses',  'Depeche Mode' );
$K{f_version}  = album( 3,  'Black Celebration', 'Depeche Mode' );
$K{f_zero}     = album( 4,  'Some Great Reward', 'Depeche Mode' );
$K{f_undef}    = album( 5,  'Construction Time', 'Depeche Mode' );
$K{h_agree}    = album( 6,  'Isolar',            'Amorph' );
$K{h_none}     = album( 7,  'Nothing Owned',     'Nobody' );
$K{h_ambig}    = album( 8,  'Ciao Monkey',       'Someone' );
$K{h_various}  = album( 9,  'A Compilation',     $VA );
$K{h_disagree} = album( 10, 'Isolar',            'Wrong Artist' );
$K{conflict}   = album( 11, 'Conflicted',        'Someone' );
$K{remote}     = album( 12, 'Isolar',            'Amorph', remote => 1 );
$K{lapsing}    = album( 13, 'Was Owned',         'Someone' );

# §15.14's two cases, at the apply level. Album 14's artist IS the configured
# label and the Discogs credit is the same string, so before §15.14 this pair
# reached plain equality and BADGED - it is the seam itself. Album 15's artist
# is the literal 'Various', which differs from the label, and must gate too.
$K{va_equal}   = album( 14, 'Another Compilation', $VA );
$K{va_literal} = album( 15, 'Third Compilation',   'Various' );

# §15.17 part 5's cases: the title route narrows by ARTIST before calling a
# title ambiguous. h_ambig above is the genuine ambiguity - two pressings of
# one record by one artist - and the collection below gives both entries that
# artist. These four are the cases that distinguish the new rule from the old.
#
# one_agrees: two entries share the title, only one is by this artist. The old
# rule called this ambiguous on the title alone; it is a badge.
$K{one_agrees} = album( 30, 'Split Decision', 'Right Artist' );

# generic: three entries share the title, none by this artist. "Greatest Hits"
# on the reference server, four times over by four different artists. Not owned
# and NOT a queue item - there is nothing for a user to decide.
$K{generic}    = album( 31, 'Greatest Hits', 'Nobody Special' );

# no_artist: the same shape, but the LMS album has no artist at all, so nothing
# can narrow it. Still a queue item.
$K{no_artist}  = album( 32, 'Greatest Hits', undef );

# Step 8's cases.
#
# incumbent: the row TODO 2026-09-19 described and no fixture covered. Strict,
# candidate, a release id that IS in the collection, and a full snapshot - so
# before §15.16 part 4 it was indistinguishable from a clean identification and
# the pass would promote it to 'confirmed', silently undoing §3a's demotion.
# Its title deliberately matches nothing in the collection, so the title route
# cannot rescue it either and 'absent' is the whole answer.
$K{incumbent}  = album( 16, 'Contested Pressing', 'Depeche Mode' );

# manual_ambig: a manual link on an album whose title is owned twice. Without
# D1 this would re-enter the queue as 'ambiguous' at every sync forever, asking
# the user to decide something they have already decided.
$K{manual_ambig} = album( 17, 'Ciao Monkey', 'Someone' );

# lapsed: a row the previous pass wrote for a reason that has since gone away.
# It owns nothing and reviews nothing, so §14.8 says it must not exist.
$K{lapsed}     = album( 18, 'No Longer Ambiguous', 'Depeche Mode' );

# h_disagree and h_agree share a title deliberately; the byTitle route keys on
# the title alone and the artist check is what separates them.

my @collection = (
	entry( 1001, 111, 9001, 'Violator',          'Depeche Mode' ),
	entry( 1002, 222, undef, 'Music For Masses', 'Depeche Mode' ),
	entry( 1003, 333, 9003, 'Black Celebration', 'Depeche Mode' ),
	# The two master-id sentinels. Their TITLES deliberately do not match the
	# albums that point at them, so node H cannot rescue the album and the only
	# route left to 'version' is the master. If either sentinel were indexed at
	# face value, masters{0} would exist and both albums would badge on it.
	entry( 1004, 444, 0,     'Masterless Zero',   'Depeche Mode' ),
	entry( 1005, 555, undef, 'Masterless Undef',  'Depeche Mode' ),
	entry( 1006, 666, 9006, 'Isolar',            'Amorph' ),
	# §13.10.3's measured ambiguity: two PRESSINGS of one record, one artist.
	# Both entries are by the album's own artist, which is what makes it a real
	# ambiguity rather than a shared title (§15.17 part 5).
	entry( 1007, 777, 9007, 'Ciao Monkey',       'Someone' ),
	entry( 1008, 888, 9008, 'Ciao Monkey',       'Someone' ),

	# Two share 'Split Decision'; exactly one is by 'Right Artist'.
	entry( 1012, 1212, 9212, 'Split Decision',   'Right Artist' ),
	entry( 1013, 1313, 9313, 'Split Decision',   'Someone Else' ),

	# Three share 'Greatest Hits', none by 'Nobody Special'.
	entry( 1014, 1414, 9414, 'Greatest Hits',    'The Cure' ),
	entry( 1015, 1515, 9515, 'Greatest Hits',    'Falco' ),
	entry( 1016, 1616, 9616, 'Greatest Hits',    'Leonard Cohen' ),
	entry( 1009, 999, 9009, 'A Compilation',      'Various' ),
	entry( 1010, 1110, 9110, 'Another Compilation', 'Various Artists' ),
	entry( 1011, 1111, 9111, 'Third Compilation',   'Various' ),
);

# Tagged rows. f_zero and f_undef carry the two master-id sentinel forms
# (TODO.md 2026-09-07): 0 for "no master", and the field absent entirely.
matchRow( album_key => $K{d_strict}, lms_album_id => 1, discogs_release_id => 111,
	discogs_master_id => 9001, match_tier => 'strict', state => 'candidate',
	snapshot_track_count => 1 );
matchRow( album_key => $K{d_manual}, lms_album_id => 2, discogs_release_id => 222,
	match_tier => 'manual', state => 'candidate', snapshot_track_count => 1 );
matchRow( album_key => $K{f_version}, lms_album_id => 3, discogs_release_id => 3330,
	discogs_master_id => 9003, match_tier => 'strict', state => 'confirmed',
	snapshot_track_count => 1 );
matchRow( album_key => $K{f_zero}, lms_album_id => 4, discogs_release_id => 4440,
	discogs_master_id => 0, match_tier => 'strict', state => 'confirmed',
	snapshot_track_count => 1 );
matchRow( album_key => $K{f_undef}, lms_album_id => 5, discogs_release_id => 5550,
	match_tier => 'strict', state => 'confirmed', snapshot_track_count => 1 );

# A FRESH conflict row: strict, candidate, NULL release id, no snapshot (§3a),
# and marked, as _recordConflict now marks every conflict it writes.
matchRow( album_key => $K{conflict}, lms_album_id => 11, match_tier => 'strict',
	state => 'candidate', review_reason => 'conflict' );

# An ownership-only row whose record has since left the collection.
matchRow( album_key => $K{lapsing}, lms_album_id => 13, ownership => 'exact' );

# An ownership-only row for an album that is no longer in the library at all.
matchRow( album_key => 'z' x 32, lms_album_id => 99, ownership => 'version' );

# --- step 8's rows ---------------------------------------------------------

# The incumbent conflict. Release 111 is Violator's, and it IS in the
# collection - so node D would make this 'exact' and promote it, which is the
# defect. review_reason is the only column that separates it from d_strict.
matchRow( album_key => $K{incumbent}, lms_album_id => 16, discogs_release_id => 111,
	discogs_master_id => 9001, match_tier => 'strict', state => 'candidate',
	snapshot_track_count => 1, snapshot_artist => 'Depeche Mode',
	snapshot_album_title => 'Contested Pressing', review_reason => 'conflict' );

# The manual row on an ambiguous title. Its release id is in no collection
# entry, so node D and node F both miss and it reaches the title route, where
# 'Ciao Monkey' is owned twice.
matchRow( album_key => $K{manual_ambig}, lms_album_id => 17, discogs_release_id => 6660,
	match_tier => 'manual', state => 'confirmed', snapshot_track_count => 1 );

# The row whose reason has lapsed: nothing in the collection is called
# 'No Longer Ambiguous', so this pass concludes absent with no reason at all.
matchRow( album_key => $K{lapsed}, lms_album_id => 18, ownership => 'absent',
	review_reason => 'ambiguous' );

# --- orphans: rows whose album is not in the library -----------------------
#
# Three shapes, because the rule treats them differently. All three carry an
# identification and a snapshot, which is §15.5 part 3's predicate.
my $ORPHAN_MANUAL   = 'y' x 32;
my $ORPHAN_STRICT   = 'x' x 32;
my $ORPHAN_CONFLICT = 'w' x 32;

# A manual orphan - the shape TODO 2026-09-19 found on the reference server
# (release 888888). D1 keeps a pass reason off a manual row whose album is
# CURRENT; this one's album is gone, and it is the row recovery exists for.
matchRow( album_key => $ORPHAN_MANUAL, lms_album_id => 888, discogs_release_id => 888888,
	match_tier => 'manual', state => 'confirmed', snapshot_track_count => 18,
	snapshot_artist => 'Amorph', snapshot_album_title => 'Isolar' );

matchRow( album_key => $ORPHAN_STRICT, lms_album_id => 999, discogs_release_id => 999999,
	match_tier => 'strict', state => 'candidate', snapshot_track_count => 12,
	snapshot_artist => 'Amorph', snapshot_album_title => 'Unidentified Explorers' );

# An orphan already marked 'conflict'. 'conflict' is sticky and the importer's
# (R3), so it wins - the album being gone does not settle what the tags said.
matchRow( album_key => $ORPHAN_CONFLICT, lms_album_id => 777, discogs_release_id => 777777,
	match_tier => 'strict', state => 'candidate', snapshot_track_count => 7,
	snapshot_artist => 'Someone', snapshot_album_title => 'Gone And Contested',
	review_reason => 'conflict' );

# An orphan with an identification but NO snapshot. It cannot be relinked to
# anything, so the orphan list could offer it nothing but reject, and the pass
# has no business inviting a deletion it cannot justify. It simply sits.
my $ORPHAN_NOSNAP = 'v' x 32;
matchRow( album_key => $ORPHAN_NOSNAP, lms_album_id => 666, discogs_release_id => 666666,
	match_tier => 'strict', state => 'candidate' );

my $before = matchCount();

is( $O->apply( \@collection ), 'ok', 'the pass runs and reports ok' );

# --- C/D/F: the tagged paths ----------------------------------------------
is( rowFor( $K{d_strict} )->{ownership}, 'exact',
	'D: a tagged album whose release is in the collection is exact' );
is( rowFor( $K{d_strict} )->{state}, 'confirmed',
	'  ...and a strict row is promoted to confirmed' );

is( rowFor( $K{d_manual} )->{ownership}, 'exact',
	'D: a manual row gets ownership written too' );
is( rowFor( $K{d_manual} )->{state}, 'candidate',
	"  ...but its state is NEVER touched - the user's choice is not cross-checked" );

is( rowFor( $K{f_version} )->{ownership}, 'version',
	'F: a tagged album whose MASTER is owned, at a different release, is version' );
is( rowFor( $K{f_version} )->{state}, 'candidate',
	'  ...and a strict row drops back to candidate' );

# The two sentinels. Collection entry 444 has master_id 0 and 555 has none; if
# either were indexed at face value, every masterless release would collide on
# one key and these two albums would badge on nothing at all.
is( rowFor( $K{f_zero} )->{ownership}, 'absent',
	'F: master_id 0 is a sentinel, not a master - no version match' );
is( rowFor( $K{f_undef} )->{ownership}, 'absent',
	'F: an undefined master_id likewise' );
is( rowFor( $K{f_zero} )->{state}, 'candidate',
	'  ...and the strict row is demoted rather than left confirmed' );

# The identification itself is untouched by any of this.
is( rowFor( $K{f_zero} )->{discogs_release_id}, 4440,
	'the pass never unmatches an album: the release id stands' );

# --- H: the title route ----------------------------------------------------
my $agreed = rowFor( $K{h_agree} );
is( $agreed->{ownership}, 'version',
	'H: an untagged album whose title and artist match one owned release is version' );
is( $agreed->{match_tier}, undef, '  ...on a row with no identification' );
is( $agreed->{state},      undef, '  ...and no state' );
is( $agreed->{discogs_release_id}, undef,
	'  ...and no release id - an ownership conclusion is not an identification' );

ok( !rowFor( $K{h_none} ), 'H: an untagged album owning nothing gets NO ROW (§14.8)' );

# --- the five rows step 8 changed ------------------------------------------
#
# Each of these used to assert "no row". That was §14.8's invariant 3 as it
# stood: a row identifying nothing and owning nothing asserts nothing. §15.16
# part 9 amends the invariant to allow a third thing worth asserting - a review
# reason - because these conclusions are about a collection §13.2 requires be
# discarded, so a queue item not written down now cannot be recomputed later.
# The row is still worth its existence; it is just worth it for a new reason.
#
# What did NOT change is the boundary below at h_none: an album that owns
# nothing and has nothing to review still gets no row.
my $ambig = rowFor( $K{h_ambig} );
ok( $ambig, 'H: two owned releases sharing a title now gets a row, for its reason' );
is( $ambig->{review_reason}, 'ambiguous', "  ...marked 'ambiguous'" );
is( $ambig->{ownership},  'absent', '  ...owning nothing, because nothing here chose' );
is( $ambig->{match_tier}, undef,    '  ...and identifying nothing' );
is( $ambig->{state},      undef,    '  ...with no state' );

is( rowFor( $K{h_various} )->{review_reason}, 'various-gated',
	"H: the label against Discogs' \"Various\" is gated, and says so" );
is( rowFor( $K{h_various} )->{ownership}, 'absent', '  ...still not badged' );

# §15.14, the seam: both sides say 'Various Artists' and it matches by plain
# equality. Before the ruling this badged. It must not - and now it says why.
is( rowFor( $K{va_equal} )->{review_reason}, 'various-gated',
	'H: "Various Artists" on both sides is gated too, though it agrees exactly' );
is( rowFor( $K{va_literal} )->{review_reason}, 'various-gated',
	'H: an LMS literal "Various" against Discogs\' "Various" is gated' );

# 'various-gated' rather than 'artist-disagree', in the written column as well
# as in the counts: "we declined to decide" and "these are different artists"
# call for different things from the user, and the queue page says so.
isnt( rowFor( $K{h_various} )->{review_reason}, 'artist-disagree',
	'a gated compilation is not filed as an artist disagreement' );

# All three land in the gated bucket, not in artist-disagree - step 8 needs to
# tell "we declined to decide" apart from "these are different artists".
like( summary(), qr/\bgated=3\b/,
	'all three compilations are counted as gated in the summary' );
like( summary(), qr/\bartist-disagree=1\b/,
	'  ...and the genuine artist disagreement is still counted separately' );

# Step 8: the summary carries two different figures and says which is which.
# "decided" is the verdict count over every album, including albums whose row
# already said the same thing. "wrote" is the rows that changed, which is what
# the queue grew by - and on a second pass over the same inputs it is empty.
like( summary(), qr/queue decided .*\borphans=3\b/,
	'the summary counts orphans by §15.5 part 3: an identification AND a snapshot' );
like( summary(), qr/reasons wrote .*\bambiguous=1\b/,
	'  ...and reports the reasons it actually wrote' );

# The two figures disagree here, and the disagreement is D1 working: two albums
# DECIDED ambiguous - h_ambig and the manual link on the same title - and only
# one row was written, because the user has already answered for the other.
like( summary(), qr/queue decided .*\bambiguous=2\b/,
	'two albums decided ambiguous, but only one reason was written (D1)' );
like( summary(), qr/reasons wrote .*\bvarious-gated=3\b/,
	'  ...in the queue\'s vocabulary, not the pass\'s buckets' );
like( summary(), qr/reasons wrote .*\borphan=2\b/,
	'  ...counting the two orphans it marked, not the one already marked conflict' );

is( rowFor( $K{h_disagree} )->{review_reason}, 'artist-disagree',
	'H: a title match whose artist disagrees is filed as artist-disagree' );
is( rowFor( $K{h_disagree} )->{ownership}, 'absent', '  ...and is not badged' );

# §13.10.3 and §15.11: one collection entry, two albums - the rip and the
# stream - and BOTH badge. This is the case that lands on the ownership pass
# rather than the importer, because an all-remote album has no tags to read.
is( rowFor( $K{remote} )->{ownership}, 'version',
	'an all-remote album badges from the collection (§13.10.1, §15.11)' );

# --- the conflict row, both kinds (§15.16 part 4) ---------------------------
#
# A FRESH conflict has a NULL release id, so the release-id test at node C
# already excluded it before step 8. Nothing about it changes.
my $conflict = rowFor( $K{conflict} );
ok( $conflict, 'a conflict row is not deleted by the pass' );
is( $conflict->{state}, 'candidate',
	'a conflict row skips C and its state is never written - there is nothing to promote' );
is( $conflict->{ownership}, 'absent', '  ...and its ownership is absent' );
is( $conflict->{review_reason}, 'conflict',
	"  ...and the pass leaves 'conflict' exactly where the importer put it (R3)" );

# An INCUMBENT conflict is the one nothing could see. It is strict, candidate,
# carries release 111 - which is in the collection - and has a full snapshot,
# so every column says "clean identification" and node D would make it 'exact'
# and promote it to 'confirmed', undoing §3a's demotion at the next sync. This
# is TODO 2026-09-19, and these four assertions are the whole of the fix.
my $incumbent = rowFor( $K{incumbent} );
ok( $incumbent, 'an incumbent conflict row survives the pass' );
is( $incumbent->{state}, 'candidate',
	'an incumbent conflict is NOT promoted, though its release is owned (§15.16 part 4)' );
is( $incumbent->{ownership}, 'absent',
	'  ...and does not badge from the id the tags disagree about' );
is( $incumbent->{discogs_release_id}, 111,
	'  ...while keeping the identification - the pass never unmatches an album' );
is( $incumbent->{review_reason}, 'conflict', "  ...and keeps its mark" );

# The control: the same release id, the same tier, the same state, no mark.
# This one badges and promotes, which is what makes the row above a decision
# about review_reason rather than about anything else.
is( rowFor( $K{d_strict} )->{ownership}, 'exact',
	'  ...while the identical row WITHOUT the mark still badges exact' );
is( rowFor( $K{d_strict} )->{state}, 'confirmed', '  ...and is still promoted' );

# --- D1: a manual row on a live album carries no pass reason ---------------
#
# 'Ciao Monkey' is owned twice, so the title route calls this ambiguous. The
# user has already decided; re-asking every sync is not review.
my $manualAmbig = rowFor( $K{manual_ambig} );
is( $manualAmbig->{review_reason}, undef,
	'D1: a manual row on a current album gets no pass reason, however ambiguous' );
is( $manualAmbig->{match_tier}, 'manual', '  ...and is still manual' );
is( $manualAmbig->{state}, 'confirmed',
	"  ...and its state is untouched - a manual link is not cross-checked" );

# --- orphans (§15.16 part 5) -----------------------------------------------
#
# The pass is the only thing that sees the whole library and the whole table at
# once. Nothing sweeps orphans (§2a invariant 4), which is exactly why they
# must be shown: TODO 2026-09-19 found three sitting on the reference server
# that nothing would ever have mentioned.
is( rowFor($ORPHAN_STRICT)->{review_reason}, 'orphan',
	'a strict orphan carrying an identification and a snapshot is marked' );
is( rowFor($ORPHAN_STRICT)->{discogs_release_id}, 999999,
	'  ...and keeps everything else' );

# Manual orphans included. D1 is about a live album; an orphan is not a verdict
# on one, and a manual row is the row recovery exists for.
is( rowFor($ORPHAN_MANUAL)->{review_reason}, 'orphan',
	'a MANUAL orphan is marked too - D1 is about live albums (§15.16 part 5)' );
is( rowFor($ORPHAN_MANUAL)->{state}, 'confirmed', '  ...with its state untouched' );

is( rowFor($ORPHAN_CONFLICT)->{review_reason}, 'conflict',
	"an orphan already marked 'conflict' keeps it - sticky beats orphan (R3)" );

is( rowFor($ORPHAN_NOSNAP)->{review_reason}, undef,
	'an orphan with no snapshot is not marked: nothing could relink it' );
ok( rowFor($ORPHAN_NOSNAP), '  ...and it is not deleted either' );

# --- a reason that lapses is a row that goes --------------------------------
#
# The second half of §15.16 part 9. A row owning nothing and reviewing nothing
# asserts nothing, and the row must not outlive the reason it was written for.
ok( !rowFor( $K{lapsed} ),
	'a row whose only content was a reason is deleted once the reason lapses' );

# --- R5: the second permitted delete ---------------------------------------
ok( !rowFor( $K{lapsing} ),
	'R5: an ownership-only row whose record left the collection is deleted' );
ok( !rowFor( 'z' x 32 ),
	'R5: an ownership-only row whose album left the library is deleted' );

# and never anything else
ok( rowFor( $K{d_manual} ),  'R5 never deletes a manual row' );
ok( rowFor( $K{f_undef} ),   'R5 never deletes a strict row' );
ok( rowFor( $K{conflict} ),  'R5 never deletes a conflict row' );

# An exact count rather than a margin. The margin was there to say "not a row
# per album", and step 8 made the pass write rows it did not write before, so
# the margin is now loose enough to hide a regression. Every row is accounted
# for below, which is a stronger statement than any inequality.
my @finalKeys = sort map { $_->[0] } @{
	$dbh->selectall_arrayref('SELECT album_key FROM squeezewax.discogs_match')
};

is_deeply(
	\@finalKeys,
	[ sort
		# identifications, all carried forward
		$K{d_strict}, $K{d_manual}, $K{f_version}, $K{f_zero}, $K{f_undef},
		$K{conflict}, $K{incumbent}, $K{manual_ambig},
		# ownership conclusions
		$K{h_agree}, $K{remote},
		# review reasons - step 8's new rows
		$K{h_ambig}, $K{h_various}, $K{va_equal}, $K{va_literal}, $K{h_disagree},
		# §15.17 part 5: one badges, one has no artist to narrow by. The
		# generic-title album gets NO row at all and is asserted below.
		$K{one_agrees}, $K{no_artist},
		# orphans, which are never swept
		$ORPHAN_MANUAL, $ORPHAN_STRICT, $ORPHAN_CONFLICT, $ORPHAN_NOSNAP,
	],
	'the table holds exactly the rows that are worth their existence, and no others'
);

# The two that must be absent, named separately so a failure says which rule
# broke: §14.8's boundary, and the lapsed reason.
ok( !rowFor( $K{h_none} ), '  ...h_none is not among them (§14.8 still bites)' );
ok( !rowFor( $K{lapsed} ), '  ...nor the row whose reason lapsed' );
ok( !rowFor( $K{generic} ),
	'  ...nor a generic title owned by other artists (§15.17 part 5)' );

# --- §15.17 part 5: the title route narrows by artist --------------------
#
# The old rule counted TITLE matches and called any tie ambiguous before the
# artist was consulted. On the reference server that put four "Greatest Hits",
# by four different artists, into the queue. §13.10.3's measured ambiguous case
# was two pressings by ONE artist, which is why title-first and artist-first
# gave the same answer there and the difference never showed.
is( rowFor( $K{h_ambig} )->{review_reason}, 'ambiguous',
	'two entries agreeing on title AND artist is still ambiguous (§13.10.3)' );

is( rowFor( $K{one_agrees} )->{ownership}, 'version',
	'two entries share a title, one is by this artist -> it badges' );
is( rowFor( $K{one_agrees} )->{review_reason}, undef,
	'  ...and it is not a queue item' );

ok( !rowFor( $K{generic} ),
	'three entries share a title, none by this artist -> not owned, no row' );

is( rowFor( $K{no_artist} )->{review_reason}, 'artist-absent',
	'  ...but with no LMS artist to narrow by, it still reaches the queue' );

is( rowFor( $K{h_disagree} )->{review_reason}, 'artist-disagree',
	'a SINGLE entry whose artist disagrees is unchanged - the spelling case' );

# --- what the pass must never write ----------------------------------------
my $untouched = rowFor( $K{d_strict} );
is( $untouched->{source_timestamp}, undef, 'the pass never writes source_timestamp' );
is( $untouched->{snapshot_track_count}, 1,  'the pass never writes a snapshot column' );
is( $untouched->{discogs_master_id}, 9001,  'the pass never writes discogs_master_id' );
is( $untouched->{match_tier}, 'strict',     'the pass never writes match_tier' );

# --- determinism (§13.2): a second pass over the same inputs writes nothing -
my $after = matchCount();
my $snapshot = $dbh->selectall_arrayref(
	'SELECT * FROM squeezewax.discogs_match ORDER BY album_key', { Slice => {} } );

is( $O->apply( \@collection ), 'ok', 'a second pass over the same inputs runs' );
is( matchCount(), $after, '  ...and changes no row count' );
is_deeply(
	$dbh->selectall_arrayref(
		'SELECT * FROM squeezewax.discogs_match ORDER BY album_key', { Slice => {} } ),
	$snapshot,
	'  ...and changes nothing at all - the same inputs give the same answer'
);

# --- a refused write changes nothing ---------------------------------------
{
	no warnings 'redefine', 'once';
	local *Plugins::SqueezeWax::Match::_writeOk = sub { 0 };

	is( $O->apply( \@collection ), 'refused', 'a refused write reports refused' );
	is_deeply(
		$dbh->selectall_arrayref(
			'SELECT * FROM squeezewax.discogs_match ORDER BY album_key', { Slice => {} } ),
		$snapshot,
		'  ...and nothing changed'
	);
}

# --- a record leaving the collection demotes rather than deletes -----------
{
	my @shrunk = grep { $_->{id} != 111 } @collection;

	is( $O->apply( \@shrunk ), 'ok', 'a pass over a shrunk collection runs' );

	my $row = rowFor( $K{d_strict} );
	ok( $row, 'a tagged row whose record left the collection survives' );
	is( $row->{ownership}, 'absent', '  ...with ownership back to absent' );
	is( $row->{state},     'candidate', '  ...and state back to candidate' );
	is( $row->{discogs_release_id}, 111, '  ...and its identification intact' );
}

# --- an empty collection is a valid answer, not a failure ------------------
{
	is( $O->apply( [] ), 'ok', 'a pass over an empty collection runs' );

	my ($ownershipOnly) = $dbh->selectrow_array(
		'SELECT COUNT(*) FROM squeezewax.discogs_match WHERE match_tier IS NULL' );
	is( $ownershipOnly, 0, '  ...and every ownership-only row is gone' );

	my ($identified) = $dbh->selectrow_array(
		'SELECT COUNT(*) FROM squeezewax.discogs_match WHERE match_tier IS NOT NULL' );
	is( $identified, 12, '  ...while every identification survives' );
}

done_testing();
