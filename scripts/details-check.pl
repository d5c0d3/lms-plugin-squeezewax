#!/usr/bin/env perl
#
# Offline exercise of Plugins::SqueezeWax::Details - the release details and
# master details submenus of build-order step 10 (plan
# plans/build-order-step-10-details.md §6, parts 2-7, 9 and 10; decisions
# §15.31).
#
# Real here: Details.pm, API.pm's request building, classification and shared
# rate state, the migrations over a scratch database, the English text of every
# string from strings.txt, and the owner's real replies of 2026-10-12, trimmed
# (scripts/fixtures/release-593568-details.json, master-63790-details.json,
# error-invalid-token.json).
#
# Stubbed at LMS's boundary, as derive-check.pl does:
#   Slim::Networking::SimpleAsyncHTTP  the corrected routing (sync-check.pl's
#                                      stub audit): every status that is not 2xx
#                                      or 3xx reaches the ERROR callback with the
#                                      response as its third argument
#   Slim::Utils::Prefs / Log / PluginManager / Strings
#
# What it cannot prove: that a real app waits up to 15 s for the callback, that
# a skin renders the notice's weblink, or that a player shows the plain address
# (plan §7). Which app counts as a player is decided in Menu.pm and asserted in
# menu-check.pl part 1, which checks the flag this suite is handed.
#
# Usage: scripts/details-check.pl

use strict;
use warnings;

use constant PERFMON  => 0;
use constant DEBUGLOG => 1;
use constant INFOLOG  => 1;

use Config;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

# Host Test::More, before refs goes on @INC - see library-check.pl.
use Test::More;

our @REQUESTS;   # every stubbed request, oldest first, as { url, headers }
our @RESPONSES;  # canned responses, consumed in order
our @LOG;
our @WARNINGS;
our %PREFS;
our %STRINGS;
our @MISSING_STRINGS;

# The clock, pinnable. API.pm's rateWait counts down from the last counted reply
# (decisions §15.32), so a suite that notes a reply at time() and then reads the
# wait would see 60 or 59 depending on where a second boundary fell. Installed
# before any module is compiled, so every time() in API.pm and Details.pm reads
# it; undef means the real clock.
our $NOW;

BEGIN {
	*CORE::GLOBAL::time = sub () { defined $main::NOW ? $main::NOW : CORE::time() };
}

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

	# The English text of every token, so an assertion reads the line the user
	# would see. Read as UTF-8, as LMS reads it (Slim/Utils/Strings.pm:324).
	my $path = "$Bin/../SqueezeWax/strings.txt";

	open my $fh, '<:utf8', $path or die "could not read $path: $!\n";

	my $token;
	while ( my $line = <$fh> ) {
		chomp $line;

		if ( $line =~ /^(PLUGIN_\S+)\s*$/ ) {
			$token = $1;
		}
		elsif ( $token && $line =~ /^\tEN\t(.*)$/ ) {
			$STRINGS{$token} = $1;
		}
	}

	close $fh;

	die "no strings loaded from $path\n" unless keys %STRINGS;

	$INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = 1;
	$INC{'Slim/Utils/Log.pm'}                  = 1;
	$INC{'Slim/Utils/Prefs.pm'}                = 1;
	$INC{'Slim/Utils/PluginManager.pm'}        = 1;
	$INC{'Slim/Utils/Strings.pm'}              = 1;
	$INC{'Slim/Utils/OSDetect.pm'}             = 1;

	no strict 'refs';
	no warnings 'redefine';

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

	*{'Slim::Utils::PluginManager::dataForPlugin'} = sub { { version => '0.0.0.0' } };

	# The token's English text, and a record of any token nobody defined.
	*{'Slim::Utils::Strings::string'} = sub {
		my ($token) = @_;

		return $main::STRINGS{$token} if exists $main::STRINGS{$token};

		push @main::MISSING_STRINGS, $token;

		return $token;
	};
	*{'Slim::Utils::Strings::import'} = sub {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::string"} = \&Slim::Utils::Strings::string;
	};

	*{'main::SCANNER'}   = sub () { 0 };
	*{'main::INFOLOG'}   = sub () { 1 };
	*{'main::DEBUGLOG'}  = sub () { 0 };
	*{'main::ISWINDOWS'} = sub () { 0 };
}

{
	package Test::StubPrefs;
	sub new { bless {}, shift }
	sub get { return $main::PREFS{ $_[1] } }
	sub set { $main::PREFS{ $_[1] } = $_[2]; return 1 }
	sub init { 1 }
	sub migrate { 1 }
}

{
	package Test::StubLogger;
	sub new      { bless {}, shift }
	sub error    { shift; push @main::WARNINGS, "@_"; return }
	sub warn     { shift; push @main::WARNINGS, "@_"; return }
	sub info     { shift; push @main::LOG, "@_"; return }
	sub debug    { }
	sub is_info  { 1 }
	sub is_debug { 0 }
}

{
	package Test::StubHeaders;
	sub new { my $class = shift; bless { map { lc $_ } @_ }, $class }
	sub header { return $_[0]->{ lc $_[1] } }
}

{
	package Slim::Networking::SimpleAsyncHTTP;

	sub new {
		my ( $class, $cb, $ecb, $args ) = @_;
		return bless { cb => $cb, ecb => $ecb, args => $args }, $class;
	}

	sub get {
		my ( $self, $url, @headers ) = @_;

		push @REQUESTS, { url => $url, headers => \@headers, args => $self->{args} };

		my $canned = shift @RESPONSES
			or die "stub transport: no canned response left for $url\n";

		if ( !defined $canned->{code} ) {
			$self->{ecb}->( $self, 'connection failed', undef );

			return;
		}

		my $response = Test::StubResponse->new($canned);

		if ( $canned->{code} !~ /^[23]\d\d$/ ) {
			$self->{ecb}->( $self, "HTTP $canned->{code}", $response );

			return;
		}

		$self->{code}    = $canned->{code};
		$self->{content} = $canned->{content};
		$self->{headers} = $response->headers;

		$self->{cb}->($self);

		return;
	}

	sub code    { $_[0]->{code} }
	sub content { $_[0]->{content} }
	sub headers { $_[0]->{headers} }
}

{
	package Test::StubResponse;

	sub new {
		my ( $class, $canned ) = @_;

		return bless {
			code    => $canned->{code},
			content => $canned->{content},
			headers => Test::StubHeaders->new( %{ $canned->{headers} || {} } ),
		}, $class;
	}

	sub code    { $_[0]->{code} }
	sub content { $_[0]->{content} }
	sub headers { $_[0]->{headers} }
}

use DBI;
use JSON::XS qw(encode_json);

# The lines carry an en dash, a middle dot and an A-umlaut.
binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

my $incdir;

BEGIN {
	$incdir = tempdir( CLEANUP => 1 );
	mkdir "$incdir/Plugins";
	symlink "$Bin/../SqueezeWax", "$incdir/Plugins/SqueezeWax"
		or die "could not link the plugin into $incdir: $!\n";
	unshift @INC, $incdir;
}

require Plugins::SqueezeWax::Schema;
require Plugins::SqueezeWax::API;
require Plugins::SqueezeWax::Details;

my $API = 'Plugins::SqueezeWax::API';

# ---------------------------------------------------------------------------
# A real database with the real migrations, and something in every table, so
# "nothing stored" is a comparison against rows rather than against nothing.
# ---------------------------------------------------------------------------

my $dir = tempdir( CLEANUP => 1 );

my $dbh = DBI->connect( "dbi:SQLite:dbname=$dir/library.db", '', '', {
	RaiseError => 1, PrintError => 0, AutoCommit => 1,
} );

$dbh->do("ATTACH '$dir/squeezewax.db' AS squeezewax");

Plugins::SqueezeWax::Schema->_migrate($dbh);

$dbh->do( q{
	INSERT INTO squeezewax.discogs_match
		(album_key, match_tier, ownership, discogs_release_id, discogs_master_id)
	VALUES (?, 'strict', 'exact', 593568, 63790)
}, undef, 'k' x 32 );

my @TABLES = @{ $dbh->selectcol_arrayref(q{
	SELECT name FROM squeezewax.sqlite_master WHERE type = 'table' ORDER BY name
}) };

ok( ( grep { $_ eq 'discogs_match' } @TABLES ), 'the scratch database carries our tables' );

# Every row of every table of ours, as one string.
sub dbSnapshot {
	return join "\n", map {
		my $t = $_;
		"$t: " . encode_json( $dbh->selectall_arrayref("SELECT * FROM squeezewax.$t ORDER BY 1") );
	} @TABLES;
}

# Canonical, or two encodings of one hash can differ by key order alone.
sub prefsSnapshot {
	return JSON::XS->new->canonical->encode( {%PREFS} );
}

# ---------------------------------------------------------------------------
# Fixtures and helpers.
# ---------------------------------------------------------------------------

sub fixture {
	my ($name) = @_;

	my $path = "$Bin/fixtures/$name";

	open my $fh, '<:raw', $path or die "could not read $path: $!\n";
	local $/;

	return scalar <$fh>;
}

my $RELEASE = fixture('release-593568-details.json');
my $MASTER  = fixture('master-63790-details.json');
my $INVALID = fixture('error-invalid-token.json');

sub healthy_headers {
	return {
		'X-Discogs-Ratelimit'           => 60,
		'X-Discogs-Ratelimit-Used'      => 1,
		'X-Discogs-Ratelimit-Remaining' => 59,
	};
}

sub ok_response {
	my ($content) = @_;

	return { code => 200, headers => healthy_headers(), content => $content };
}

# noteResponse, counted. Wrapped rather than replaced, so the shared state still
# moves exactly as it does in production.
my $NOTED = 0;

{
	no warnings 'redefine';

	my $real = \&Plugins::SqueezeWax::API::noteResponse;

	*Plugins::SqueezeWax::API::noteResponse = sub { $NOTED++; goto &$real };
}

# Every open in this suite goes through here, and every one of them is checked
# for part 9: no row of ours and no pref changes, whatever the outcome.
my $STORED = 0;

sub open_details {
	my ( $kind, $id, %opt ) = @_;

	@REQUESTS  = ();
	@RESPONSES = @{ $opt{responses} || [] };
	@LOG       = ();
	$NOTED     = 0;

	# Every open is a fresh one unless the block is about the hold (§15.33).
	Plugins::SqueezeWax::Details->clearHold unless $opt{keepHold};

	my $db    = dbSnapshot();
	my $prefs = prefsSnapshot();

	my $items;
	my $calls = 0;
	my $cb    = sub { $calls++; $items = shift };

	my $linkCapable = exists $opt{linkCapable} ? $opt{linkCapable} : 1;

	if ( $kind eq 'release' ) {
		Plugins::SqueezeWax::Details::_releaseDetails( undef, $cb, {}, $id, $linkCapable );
	}
	else {
		Plugins::SqueezeWax::Details::_masterDetails( undef, $cb, {}, $id, $linkCapable );
	}

	$STORED++ if dbSnapshot() ne $db || prefsSnapshot() ne $prefs;

	is( $calls, 1, "$kind $id: the callback is called exactly once" );
	is( scalar @RESPONSES, 0, '  ...and every canned reply was asked for' );

	return $items;
}

sub names     { return [ map { $_->{name} } @{ $_[0] } ] }
sub weblinked { return [ grep { exists $_->{weblink} } @{ $_[0] } ] }

my $NOTICE = $STRINGS{PLUGIN_SQUEEZEWAX_DETAILS_NOTICE};

# The uri as JSON::XS decodes it: characters, so the Ä is one character here.
my $RELEASE_URI = "https://www.discogs.com/release/593568-Die-\x{c4}rzte-Unplugged-RocknRoll-Realschule";
my $MASTER_URI  = "https://www.discogs.com/master/63790-Die-\x{c4}rzte-Unplugged-Rock-n-Roll-Realschule";

%PREFS = ( discogsToken => 'tok', discogsCurrency => 'EUR' );
$API->_resetRate;

# Frozen for the whole suite; a block that needs time to pass moves it.
$NOW = CORE::time();

# ===========================================================================
# 2. Release details opened
# ===========================================================================

{
	my $items = open_details( release => 593568, responses => [ ok_response($RELEASE) ] );

	is( scalar @REQUESTS, 1, 'release details: exactly one request' );
	is( $REQUESTS[0]{url}, 'https://api.discogs.com/releases/593568',
		'  ...to /releases/{id}, with no query string - so no curr_abbr' );

	my %h = @{ $REQUESTS[0]{headers} };

	is( $h{Authorization}, 'Discogs token=tok', '  ...carrying the token' );
	like( $h{'User-Agent'}, qr{^SqueezeWax/\S+ \+https://}, '  ...and our User-Agent' );
	is( $REQUESTS[0]{args}{timeout}, 15, '  ...with a 15 s timeout' );

	is_deeply( names($items), [
		"Hot Action Records \x{2013} 108 934 - 2",
		"CD, Album \x{b7} Europe \x{b7} 04 Nov 2002",
		"Rock \x{b7} Acoustic, Pop Rock, Punk",
		"Have 1622 \x{b7} Want 35",
		'Rating 4.1 / 5 (109 ratings)',
		'For sale: 54, from 1.33 EUR',
		$NOTICE,
	], '  ...and the lines of plan §2, in order, from the real reply' );

	ok( !( grep { ( $_->{type} || '' ) ne 'text' } @$items ), '  ...every one of them a text line' );

	is( scalar @LOG, 1, '  ...logged once at INFO' );
	like( $LOG[0], qr{GET /releases/593568 -> ok}, '  ...naming the path and the outcome' );
}

# With no currency known, the count only: an unlabelled price is never shown.
for my $currency ( '', undef ) {
	local $PREFS{discogsCurrency} = $currency;

	my $items = open_details( release => 593568, responses => [ ok_response($RELEASE) ] );

	is( names($items)->[5], 'For sale: 54',
		'with discogsCurrency ' . ( defined $currency ? 'empty' : 'unset' ) . ', the count only' );
	ok( !( grep { /1\.33/ } @{ names($items) } ), '  ...and the price appears nowhere' );
}

# The label is the stored one, whatever it is: Discogs sends no label of its own.
{
	local $PREFS{discogsCurrency} = 'JPY';

	my $items = open_details( release => 593568, responses => [ ok_response($RELEASE) ] );

	is( names($items)->[5], 'For sale: 54, from 1.33 JPY', 'the price carries the stored currency code' );
}

# ===========================================================================
# 3. Master details opened
# ===========================================================================

{
	my $items = open_details( master => 63790, responses => [ ok_response($MASTER) ] );

	is( scalar @REQUESTS, 1, 'master details: exactly one request' );
	is( $REQUESTS[0]{url}, 'https://api.discogs.com/masters/63790',
		'  ...to /masters/{id}, with no curr_abbr' );

	is_deeply( names($items), [
		'Year 2002',
		"Rock \x{b7} Punk",
		'For sale: 93, from 1.33 EUR',
		$NOTICE,
	], '  ...and the lines of plan §2, in order, from the real reply' );

	like( $LOG[0], qr{GET /masters/63790 -> ok}, '  ...logged with its path' );
}

{
	local $PREFS{discogsCurrency} = '';

	my $items = open_details( master => 63790, responses => [ ok_response($MASTER) ] );

	is( names($items)->[2], 'For sale: 93', 'master details: no currency, the count only' );
}

# --- the "leave the line out" rule, and "None for sale" ----------------------

{
	my $items = open_details( release => 1, responses => [ ok_response( encode_json( {
		uri          => 'https://www.discogs.com/release/1',
		labels       => [ { name => 'A Label', catno => '' } ],
		formats      => [],
		genres       => [],
		styles       => [],
		community    => { have => 0, want => 3, rating => { average => 0, count => 0 } },
		num_for_sale => 0,
		lowest_price => undef,
	} ) ) ] );

	is_deeply( names($items), [
		'A Label',
		"Have 0 \x{b7} Want 3",
		'None for sale',
		$NOTICE,
	], 'missing fields leave their line out, a half-empty line keeps what it has, '
		. 'an unrated release shows no rating, and 0 for sale reads "None for sale"' );

	ok( !( grep { !defined $_ || $_ !~ /\S/ } @{ names($items) } ), '  ...and no line is blank' );
}

{
	my $items = open_details( release => 2, responses => [ ok_response( encode_json( {
		uri => 'https://www.discogs.com/release/2', num_for_sale => 4, lowest_price => undef,
	} ) ) ] );

	is_deeply( names($items), [ 'None for sale', $NOTICE ],
		'copies for sale with no price is "None for sale" too' );
}

{
	my $items = open_details( master => 3, responses => [ ok_response( encode_json( {
		uri => 'https://www.discogs.com/master/3', year => 0, genres => ['Jazz'],
	} ) ) ] );

	is_deeply( names($items), [ 'Jazz', $NOTICE ],
		'a master with year 0 shows no year, and no for-sale field means no for-sale line' );
}

# ===========================================================================
# 4. Busy: the budget is spent at open
# ===========================================================================

{
	local $NOW = $NOW;

	# Spent 15 seconds ago, by someone else.
	$API->_resetRate;
	$API->noteResponse( { limit => 60, used => 60, remaining => 0 }, $NOW - 15 );

	ok( $API->rateWait, 'the shared budget is spent' );

	my $items = open_details( release => 593568, responses => [] );

	is( scalar @REQUESTS, 0, 'busy: no request is made' );
	is_deeply( names($items), [ 'Discogs is busy, try again in 45 s' ],
		'  ...only the busy line, with the seconds actually left in the window' );
	is( $NOTED, 0, '  ...and no reply, so nothing noted' );

	$items = open_details( master => 63790, responses => [] );

	is( scalar @REQUESTS, 0, 'busy master details: no request either' );
	is_deeply( names($items), [ 'Discogs is busy, try again in 45 s' ], '  ...the same line' );

	# The wait counts down with no reply in between (decisions §15.32).
	$NOW += 40;

	$items = open_details( release => 593568, responses => [] );

	is_deeply( names($items), [ 'Discogs is busy, try again in 5 s' ],
		'forty seconds on, the line says five' );

	# And once the window has passed, the SAME open asks Discogs.
	$NOW += 5;

	$items = open_details( release => 593568, responses => [ ok_response($RELEASE) ] );

	is( scalar @REQUESTS, 1, 'once the window has passed, the same open makes its request' );
	is( names($items)->[-1], $NOTICE, '  ...and shows the details' );

	$API->_resetRate;
}

# ===========================================================================
# 5. Every error class gives its line, and no notice
# ===========================================================================

my $NO_ANSWER = "Discogs did not answer \x{2013} try again";

my @ERRORS = (
	[ '401 (the real "Invalid consumer token" body)', { code => 401, content => $INVALID },
	  "Discogs rejected the token \x{2013} check Settings" ],
	[ '404', { code => 404, content => '{"message":"Release not found."}' }, 'Not found on Discogs' ],
	[ '429', { code => 429, content => '' }, 'Discogs is busy, try again in 60 s' ],
	[ '500', { code => 500, content => '' }, $NO_ANSWER ],
	[ 'a dropped connection', { code => undef }, $NO_ANSWER ],
	[ 'a 200 with no body', { code => 200, content => '' }, $NO_ANSWER ],
	[ 'a 200 that will not parse', { code => 200, content => 'not json' }, $NO_ANSWER ],
	[ 'an unmapped status', { code => 418, content => '' }, $NO_ANSWER ],
);

for my $e (@ERRORS) {
	my ( $what, $canned, $line ) = @$e;

	$API->_resetRate;

	for my $kind (qw(release master)) {
		# Per open: an error reply with no rate headers, on a fresh state, leaves
		# the budget spent (API::accountRequest's last rung). The block after
		# this loop asserts that on its own.
		$API->_resetRate;

		my $items = open_details( $kind => 593568, responses => [ {%$canned} ] );

		is_deeply( names($items), [$line], "$kind, $what: its own line, alone" );
		ok( !( grep { ( $_->{name} || '' ) eq $NOTICE } @$items ),
			'  ...with no notice, because no Discogs data is shown' );
		is( scalar @{ weblinked($items) }, 0, '  ...and no link' );
		is( $NOTED, 1, '  ...and the reply noted once' );
		is( scalar @REQUESTS, 1, '  ...after exactly one request - no retry' );
	}
}

$API->_resetRate;

# A reply with no rate headers and nothing known before it - a dropped
# connection as the first request of the process - is accounted as the budget
# spent, per accountRequest's last rung. Until decisions §15.32 that made every
# later open busy until a sync or derive reply arrived, because a busy submenu
# makes no request to clear it. Now the wait counts down and clears by itself.
{
	local $NOW = $NOW;

	$API->_resetRate;

	open_details( release => 593568, responses => [ { code => undef } ] );

	is( $API->rateWait, 60, 'a dropped first connection marks the shared budget spent' );

	$NOW += 20;

	my $items = open_details( release => 593568, responses => [] );

	is_deeply( names($items), [ 'Discogs is busy, try again in 40 s' ],
		'  ...the next open is busy, counting down' );

	$NOW += 40;

	$items = open_details( release => 593568, responses => [ ok_response($RELEASE) ] );

	is( scalar @REQUESTS, 1, '  ...and once the window has passed, it asks again with no other reply between' );
	is( $API->rateWait, 0, '  ...whose healthy reply leaves no wait' );

	$API->_resetRate;
}

# ===========================================================================
# 6. The notice
# ===========================================================================

{
	my $items = open_details( release => 593568, responses => [ ok_response($RELEASE) ] );

	my $links = weblinked($items);

	is( scalar @$links, 1, 'link-capable: one item carries a link' );
	is( $links->[0]{name}, $NOTICE, '  ...and it is the notice' );
	is( $links->[0]{weblink}, $RELEASE_URI, '  ...pointing at the reply\'s own uri' );
	is( $items->[-1], $links->[0], '  ...placed last, after the data' );
	ok( !( grep { exists $_->{rel} } @$items ), '  ...with no rel anywhere' );
}

{
	my $items = open_details( master => 63790, responses => [ ok_response($MASTER) ] );

	is( weblinked($items)->[0]{weblink}, $MASTER_URI, 'master details link the master\'s own uri' );
}

{
	my $items = open_details( release => 593568, linkCapable => 0,
		responses => [ ok_response($RELEASE) ] );

	is( scalar @{ weblinked($items) }, 0, 'player: no weblink at all' );
	is_deeply( [ @{ names($items) }[ -2, -1 ] ], [ $NOTICE, 'discogs.com/release/593568' ],
		'  ...the notice, then the short address built from the id, not the reply\'s uri (§15.32)' );
	is( scalar @$items, 8, '  ...after the same six data lines' );
}

{
	my $items = open_details( master => 63790, linkCapable => 0,
		responses => [ ok_response($MASTER) ] );

	is( names($items)->[-1], 'discogs.com/master/63790',
		'player, master details: the master\'s short address' );
	is( scalar @{ weblinked($items) }, 0, '  ...and no weblink' );
}

# A reply with no uri still links the page the data came from.
{
	my $items = open_details( master => 42, responses => [ ok_response( encode_json( { year => 1990 } ) ) ] );

	is( weblinked($items)->[0]{weblink}, 'https://www.discogs.com/master/42',
		'a reply with no uri links the public page by id' );
}

# ===========================================================================
# 7. No token
# ===========================================================================

for my $token ( '', undef ) {
	local $PREFS{discogsToken} = $token;

	my $items = open_details( release => 593568, responses => [] );

	is( scalar @REQUESTS, 0, 'no token (' . ( defined $token ? 'empty' : 'unset' ) . '): no request' );
	is_deeply( names($items), ['Add your Discogs token in Settings'], '  ...only the token line' );
	is( $NOTED, 0, '  ...and nothing noted' );
}

# A bad id from a bad row never reaches a path.
{
	my $items = open_details( release => '1/../users', responses => [] );

	is( scalar @REQUESTS, 0, 'an id that is not a number makes no request' );
	is_deeply( names($items), ['Not found on Discogs'], '  ...and says not found' );
}

# ===========================================================================
# 8. The 2-minute in-memory hold (decisions §15.33)
# ===========================================================================

{
	local $NOW = $NOW;

	Plugins::SqueezeWax::Details->clearHold;
	$API->_resetRate;

	my $first = open_details( release => 593568, keepHold => 1, responses => [ ok_response($RELEASE) ] );

	is( scalar @REQUESTS, 1, 'hold: the first open fetches' );

	$NOW += 119;

	my $again = open_details( release => 593568, keepHold => 1, responses => [] );

	is( scalar @REQUESTS, 0, '  ...a second open at +119 s makes no request' );
	is_deeply( $again, $first, '  ...and builds the same lines' );

	$NOW += 2;

	open_details( release => 593568, keepHold => 1, responses => [ ok_response($RELEASE) ] );

	is( scalar @REQUESTS, 1, '  ...at +121 s it fetches again and replaces the held reply' );

	# Release and master with one id are held apart.
	Plugins::SqueezeWax::Details->clearHold;

	open_details( release => 7, keepHold => 1, responses => [ ok_response( encode_json( { country => 'UK' } ) ) ] );
	open_details( master  => 7, keepHold => 1, responses => [ ok_response( encode_json( { year => 1999 } ) ) ] );

	is( scalar @REQUESTS, 1, '  ...a master with the same id as a held release is its own fetch' );

	my $r = open_details( release => 7, keepHold => 1, responses => [] );
	my $m = open_details( master  => 7, keepHold => 1, responses => [] );

	is( names($r)->[0], 'UK', '  ...and each is then served from its own held reply' );
	is( names($m)->[0], 'Year 1999', '  ...without a request' );

	# An error is not held.
	Plugins::SqueezeWax::Details->clearHold;

	open_details( release => 9, keepHold => 1, responses => [ { code => 500, headers => healthy_headers(), content => '' } ] );
	open_details( release => 9, keepHold => 1, responses => [ ok_response($RELEASE) ] );

	is( scalar @REQUESTS, 1, '  ...an error reply is not held, so the next open requests' );

	# Served while the budget is spent.
	Plugins::SqueezeWax::Details->clearHold;
	$API->_resetRate;

	my $held = open_details( release => 593568, keepHold => 1, responses => [ ok_response($RELEASE) ] );

	open_details( release => 11, keepHold => 1, responses => [ { code => 429, content => '' } ] );

	ok( $API->rateWait > 0, '  ...the budget is now spent' );

	my $busy = open_details( release => 593568, keepHold => 1, responses => [] );

	is( scalar @REQUESTS, 0, '  ...a held reply is served with no request' );
	is_deeply( $busy, $held, '  ...and with its data, not the busy line' );

	$API->_resetRate;

	# Token change empties it.
	Plugins::SqueezeWax::Details->clearHold;

	open_details( release => 593568, keepHold => 1, responses => [ ok_response($RELEASE) ] );
	Plugins::SqueezeWax::Details->clearHold;
	open_details( release => 593568, keepHold => 1, responses => [ ok_response($RELEASE) ] );

	is( scalar @REQUESTS, 1, '  ...clearHold empties it, so the next open fetches' );

	# Bounded: entry 51 drops the oldest.
	Plugins::SqueezeWax::Details->clearHold;

	open_details( master => $_, keepHold => 1, responses => [ ok_response( encode_json( { year => 2000 } ) ) ] )
		for 1 .. 50;
	open_details( master => 51, keepHold => 1, responses => [ ok_response( encode_json( { year => 2000 } ) ) ] );

	open_details( master => 2, keepHold => 1, responses => [] );
	is( scalar @REQUESTS, 0, '  ...entry 51 keeps the second oldest held' );

	open_details( master => 1, keepHold => 1, responses => [ ok_response( encode_json( { year => 2000 } ) ) ] );
	is( scalar @REQUESTS, 1, '  ...and has dropped the oldest' );

	# Currency and variant come from the current open.
	Plugins::SqueezeWax::Details->clearHold;

	open_details( release => 593568, keepHold => 1, responses => [ ok_response($RELEASE) ] );

	my $jpy = do {
		local $PREFS{discogsCurrency} = 'JPY';
		open_details( release => 593568, keepHold => 1, responses => [] );
	};

	is( scalar @REQUESTS, 0, '  ...currency: still held' );
	is( names($jpy)->[5], 'For sale: 54, from 1.33 JPY', '  ...but labelled with the current currency' );

	my $player = open_details( release => 593568, keepHold => 1, linkCapable => 0, responses => [] );

	is( scalar @REQUESTS, 0, '  ...variant: still held' );
	is( scalar @{ weblinked($player) }, 0, '  ...but built for a player, with no weblink' );
	is( names($player)->[-1], 'discogs.com/release/593568', '  ...and the short address' );

	Plugins::SqueezeWax::Details->clearHold;
}

# ===========================================================================
# 9 and 10. Nothing stored, and every reply noted once
# ===========================================================================

is( $STORED, 0, 'no open, whatever its outcome, changed a row of ours or a pref' );

{
	open_details( release => 593568, responses => [ ok_response($RELEASE) ] );
	is( $NOTED, 1, 'a successful release reply is noted exactly once' );

	open_details( master => 63790, responses => [ ok_response($MASTER) ] );
	is( $NOTED, 1, '  ...and a master reply' );
}

# The shared state really moves: a reply saying the budget is spent makes the
# NEXT open busy, which is how the sync and Derive would see it too.
{
	$API->_resetRate;

	open_details( release => 593568, responses => [ {
		code    => 200,
		content => $RELEASE,
		headers => { 'X-Discogs-Ratelimit' => 60, 'X-Discogs-Ratelimit-Used' => 60,
		             'X-Discogs-Ratelimit-Remaining' => 0 },
	} ] );

	is( $API->rateWait, 60, 'a reply that spends the budget is folded into the shared state' );

	my $items = open_details( release => 593568, responses => [] );

	is( scalar @REQUESTS, 0, '  ...so the next open makes no request' );

	$API->_resetRate;
}

is( $STORED, 0, 'still nothing stored after every open in this suite' );

is_deeply( \@MISSING_STRINGS, [], 'every string Details.pm asks for is defined in strings.txt' );

is_deeply( \@WARNINGS, [], 'nothing was logged at warn or error' );

done_testing();
