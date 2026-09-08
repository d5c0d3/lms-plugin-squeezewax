#!/usr/bin/env perl
#
# Captures the seven Discogs fixtures named in
# plans/build-order-step-4-structural-matching.md §4, as raw JSON, into
# scripts/fixtures/. Captured now (build-order step 4 item 3's session)
# even though items 4-5 (candidate enumeration, comparison) are what
# consumes them: Discogs' database is mutable - master 3855547 may gain
# durations, a release's tracklist can be edited - and these fixtures exist
# to pin the exact objects decisions §8's analysis was derived from, not to
# be "current" Discogs data. Re-running this script later would defeat that
# purpose; it is a one-time capture, not a refresh tool.
#
# This is a standalone developer tool, run by hand outside LMS entirely - it
# is not loaded by the plugin and does not ship with it. It reuses
# Plugins::SqueezeWax::API's pure buildRequest/classifyResponse (real code,
# so a bug there would surface here too) but performs the actual HTTP GET
# with a bare LWP::UserAgent rather than Slim::Networking::SimpleSyncHTTP:
# SimpleSyncHTTP refuses to run outside the scanner process
# (logBacktrace unless main::SCANNER - see API.pm's header note), and this
# script is neither the scanner nor the server. _pluginVersion's
# Slim::Utils::PluginManager dependency is stubbed to read install.xml's
# real <version> by regex instead, since there is no running LMS here to
# ask.
#
# Token: read from $DISCOGS_TOKEN, or pass one as the first argument.
# Unauthenticated works for six of the seven fixtures (decisions §9.2:
# search and the catalogue endpoints do not require it) at the lower,
# 25/min rate tier. The seventh - a page of a real collection - needs a
# token for a specific account and is skipped with a clear message if none
# is given; there is no publicly-viewable substitute that stays honest
# about what decisions §8/§9's collection-page finding was measured against.
#
# Usage: scripts/fetch-fixtures.pl [token]

use strict;
use warnings;

use Config;
use FindBin qw($Bin);
use Time::HiRes qw(sleep);

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

BEGIN {
	# API.pm (and JSON::XS/Data::URIEncode, which it uses) resolve the same
	# way the offline suites' refs/slimserver-bundled CPAN copies do - see
	# scripts/match-check.pl's identical block. Nothing here talks to a real
	# LMS process.
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

	# API.pm `use`s Slim::Utils::Log and Slim::Networking::SimpleSyncHTTP,
	# neither of which is called from here: this script uses only
	# buildRequest/classifyResponse (pure) and does its own HTTP with a bare
	# LWP::UserAgent, never _request()/get() - see the file header. Stubbing
	# both avoids needing a running LMS process just to load the module.
	$INC{'Slim/Utils/Log.pm'}                 = 1;
	$INC{'Slim/Networking/SimpleSyncHTTP.pm'} = 1;

	*Slim::Utils::Log::logger   = sub { Test::StubLogger->new };
	*Slim::Utils::Log::logError = sub { };
	*Slim::Utils::Log::import   = sub {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::logger"}   = \&Slim::Utils::Log::logger;
		*{"${caller}::logError"} = \&Slim::Utils::Log::logError;
	};

	# _pluginVersion asks Slim::Utils::PluginManager, which does not exist
	# here either. Give it the real version instead of a placeholder - read
	# straight from install.xml, the same file dataForPlugin would parse on
	# a running server.
	my $installVersion = do {
		local $/;
		open my $fh, '<', "$Bin/../SqueezeWax/install.xml" or die $!;
		my $xml = <$fh>;
		$xml =~ /<version>([^<]+)<\/version>/ ? $1 : undef;
	};

	die "could not read <version> from install.xml\n" unless $installVersion;

	$INC{'Slim/Utils/PluginManager.pm'} = 1;
	*Slim::Utils::PluginManager::dataForPlugin = sub { { version => $installVersion } };

	*main::SCANNER  = sub () { 0 };
	*main::INFOLOG  = sub () { 0 };
	*main::DEBUGLOG = sub () { 0 };
}

use HTTP::Request;
use JSON::XS ();
use LWP::UserAgent;

use lib "$Bin/..";
require SqueezeWax::API;

my $A = 'Plugins::SqueezeWax::API';

my $token = shift @ARGV || $ENV{DISCOGS_TOKEN};

my $fixtureDir = "$Bin/fixtures";
mkdir $fixtureDir unless -d $fixtureDir;

my $ua = LWP::UserAgent->new( timeout => 15 );

# decisions §9.2: 60/min authenticated, 25/min unauthenticated, both a
# moving average. Six or seven requests total, well inside either budget,
# but a fixed small gap costs nothing and keeps this a well-behaved caller
# per decisions §9.2's own "throttle locally" instruction even for a run
# this short.
use constant PACE_SECONDS => 1.5;

sub fetch {
	my ( $label, $path, $params ) = @_;

	my ( $url, @headers ) = $A->buildRequest( $path, $params, $token );

	print "Fetching $label ($url)...\n";

	my $req = HTTP::Request->new( GET => $url );
	$req->header(@headers);

	my $res = $ua->request($req);

	my $result = $A->classifyResponse( $res->code, $res->content );

	if ( !$result->{ok} ) {
		print "  FAILED: HTTP @{[ $res->code ]}, classified as $result->{error}\n";
		return 0;
	}

	return $result->{data};
}

sub save {
	my ( $filename, $data ) = @_;

	my $path = "$fixtureDir/$filename";

	# Re-serialise rather than writing $res->content verbatim: canonical key
	# order makes the captured fixture diffable if it's ever re-captured
	# deliberately, and pretty-printing makes it readable in review.
	my $json = JSON::XS->new->canonical->pretty->encode($data);

	open my $fh, '>:encoding(UTF-8)', $path or die "could not write $path: $!\n";
	print {$fh} $json;
	close $fh;

	print "  saved $filename (@{[ length $json ]} bytes)\n";
}

my @fixtures = (
	[ 'Master 18080 (Violator) - durations present, community.have/want',
		'master-18080-violator.json', '/masters/18080', {} ],

	[ 'Master 3855547 (Escape The Chaos) - durations absent',
		'master-3855547-escape-the-chaos.json', '/masters/3855547', {} ],

	[ 'Release 14772 - heading entries, multi-disc D-T positions',
		'release-14772.json', '/releases/14772', {} ],

	[ 'Release 2516 - index only, zero countable tracks',
		'release-2516.json', '/releases/2516', {} ],

	[ 'Release 9701013 - master_id: null',
		'release-9701013.json', '/releases/9701013', {} ],

	[ 'type=master search, Violator - 7 masters, 1 correct',
		'search-type-master-violator.json', '/database/search',
		{ type => 'master', artist => 'Depeche Mode', release_title => 'Violator' } ],
);

for my $fixture (@fixtures) {
	my ( $label, $filename, $path, $params ) = @$fixture;

	if ( -e "$fixtureDir/$filename" ) {
		print "Skipping $label - $filename already exists.\n";
		next;
	}

	my $data = fetch( $label, $path, $params );
	save( $filename, $data ) if $data;

	sleep(PACE_SECONDS);
}

# Collection page: needs a token for a specific account, and there's no
# username to page /users/{username}/collection/... without one.
if ( !$token ) {
	print "\nSkipping the collection-page fixture: no token given "
		. "(\$DISCOGS_TOKEN or first argument).\n"
		. "decisions §8/§9's collection-page finding (master_id: 0 sentinel, "
		. "five of 100 sampled) was measured against a real account's own "
		. "collection - there is no honest substitute without one.\n";
}
else {
	my $identity = fetch( 'token identity (for the collection username)', '/oauth/identity', {} );

	if ( !$identity || !$identity->{username} ) {
		print "\nCould not resolve a username from /oauth/identity; "
			. "skipping the collection-page fixture.\n";
	}
	else {
		sleep(PACE_SECONDS);

		my $data = fetch(
			'Collection page 1 - master_id: 0 sentinel',
			"/users/$identity->{username}/collection/folders/0/releases",
			{ page => 1, per_page => 100 },
		);

		save( 'collection-page1.json', $data ) if $data;
	}
}

print "\nDone.\n";
