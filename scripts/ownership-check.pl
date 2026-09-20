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

use FindBin qw($Bin);
use Test::More;

# Same stubbing as the other suites: logger() is called at file scope.
BEGIN {
	$INC{'Slim/Utils/Log.pm'} = 1;
	$INC{'Slim/Schema.pm'}    = 1;

	no strict 'refs';
	*{'Slim::Utils::Log::logger'}   = sub { Test::StubLogger->new };
	*{'Slim::Utils::Log::logError'} = sub { };
	*{'Slim::Utils::Log::import'}   = sub {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::logger"}   = \&Slim::Utils::Log::logger;
		*{"${caller}::logError"} = \&Slim::Utils::Log::logError;
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

use lib "$Bin/..";
require SqueezeWax::Ownership;

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

# --- §15.7: Various and the LMS various-artists label ----------------------
is( artistsAgree( $VA, ['Various'], $VA ), 'various',
	"the configured label against Discogs' 'Various' is an equivalence, not an agreement" );
# NOT 'various'. With the LMS label at its English default, a Discogs credit of
# 'Various Artists' is reached by PLAIN EQUALITY, before the equivalence is ever
# consulted - so it is not a match "reached only through the Various
# equivalence" in §15.13 part 8's sense, and it is not gated. A credit of
# 'Various' on the same record IS gated. Asserted because it is a real seam in
# the gate rather than an accident, and recorded against Q9 in TODO.md.
is( artistsAgree( $VA, ['Various Artists'], $VA ), 'agree',
	"the default label against 'Various Artists' is plain equality, so it is not gated" );
is( artistsAgree( $VA, ['Various'], $VA ), 'various',
	"  ...while 'Various' on the same record reaches only the equivalence, and is" );

# It is 'various', NOT 'agree'. That distinction is the whole of the Q9 gate
# (§15.13 part 8): step 7 ships without badging these.
isnt( artistsAgree( $VA, ['Various'], $VA ), 'agree',
	'the equivalence never reports agree, so the gate has something to gate on' );

# Consulted only after plain equality fails, so it can widen and never narrow.
is( artistsAgree( $VA, [ 'Various Artists', 'Various' ], $VA ), 'agree',
	'plain equality wins when it is available' );

# The configured label is honoured, and the literal is NOT a second label.
my $custom = 'Diverse Interpreten';
is( artistsAgree( $custom, ['Various'], $custom ), 'various',
	'a customised variousArtistsString is what the LMS side is tested against' );
is( artistsAgree( 'Various Artists', ['Various'], $custom ), 'disagree',
	"a literal 'Various Artists' on the LMS side does NOT match when the label differs" );

# The Discogs side is the literal, because that is Discogs' own vocabulary.
is( artistsAgree( $custom, [$custom], $custom ), 'agree',
	'the label on both sides is a plain agreement, not the equivalence' );
is( artistsAgree( $custom, ['Sundry'], $custom ), 'disagree',
	'the LMS label against some other Discogs artist still disagrees' );

# A missing or blank label must not turn every artist into a Various match.
is( artistsAgree( 'Erasure', ['Various'], undef ), 'disagree',
	'an undef variousArtistsString disables the equivalence rather than widening it' );
is( artistsAgree( '', ['Various'], '' ), 'lms-absent',
	'a blank label cannot make a blank LMS artist match' );

done_testing();
