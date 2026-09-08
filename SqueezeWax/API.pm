package Plugins::SqueezeWax::API;

# Discogs API client, synchronous path (build-order step 4 §1 scope:
# "Structural runs in the scanner... API/Async.pm is server-side and belongs
# to steps 5/6"). Shape mirrored from refs/lms-plugin-tidal/API/Sync.pm
# (commit 8df3d452, 2026-07-26): a thin _get wrapping
# Slim::Networking::SimpleSyncHTTP, JSON decode, error handling by response
# code. Built out incrementally over build-order step 4 items 1-3; rate
# limiting (item 3) follows in a later commit.
#
# Request construction and response classification are pure class methods of
# their inputs. SimpleSyncHTTP::new logs a backtrace if !main::SCANNER
# (refs/slimserver/Slim/Networking/SimpleSyncHTTP.pm:58), and main::SCANNER
# is a `use constant`, so the transport itself cannot be exercised in the
# test process. Match.pm's _writeRefusal solved the same shape of problem the
# same way: pull the decision out of the shim so it is testable without the
# shim. _request() below is that shim - no logic beyond wiring the pure
# functions to SimpleSyncHTTP.
#
# Server-side callers (Settings.pm's token test) need the request/response
# pure functions but must use Slim::Networking::SimpleAsyncHTTP instead of
# _request() - CLAUDE.md: "Server-side HTTP -> SimpleAsyncHTTP (async)".
# Settings.pm therefore calls buildRequest/classifyResponse directly and
# wires its own async transport. A full async client (API/Async.pm) is out
# of scope for this step (plan §1).

use strict;

use Data::URIEncode qw(complex_to_query);
use JSON::XS qw(decode_json);

use Slim::Networking::SimpleSyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::PluginManager;

my $log = logger('plugin.squeezewax');

use constant BASE_URL => 'https://api.discogs.com';
use constant REPO_URL => 'https://github.com/d5c0d3/lms-plugin-squeezewax';

# ---------------------------------------------------------------------------
# Pure functions. No I/O, no globals read or written. Covered directly by
# scripts/api-check.pl without ever constructing a transport object.
# ---------------------------------------------------------------------------

# Given an endpoint path, a params hashref and a token, return the URL and
# the header list ready for ->get($url, @headers) (Slim::Networking::
# SimpleHTTP::Base's calling convention, shared by both SimpleSyncHTTP and
# SimpleAsyncHTTP since both inherit from it).
#
# decisions §9.4 pagination hazard: the collection listing and
# /masters/{id}/versions default to a mutable, non-unique sort, which can
# shift rows between pages. No paginated endpoint is called by this step
# (search and collection listing are build-order items 4 and out-of-v1-scope
# respectively) - recorded here so the first caller that adds one is not the
# first place this gets decided: pass an explicit sort/sort_order (or
# equivalent) in $params rather than relying on the endpoint's default.
sub buildRequest {
	my ( $class, $path, $params, $token ) = @_;

	$params ||= {};

	my $query = %$params ? '?' . complex_to_query($params) : '';
	my $url   = BASE_URL . $path . $query;

	# decisions §9.3: unique, RFC 1945 form, contact URL, plugin version -
	# the penalty for getting this wrong is silent blocking, not an error.
	my @headers = (
		'User-Agent' => sprintf( 'SqueezeWax/%s +%s', _pluginVersion(), REPO_URL ),
	);

	# decisions §9.1/9.2: omitted when no token is configured - search works
	# unauthenticated (falsified claim, §9.2), just at the lower rate tier.
	push @headers, 'Authorization' => "Discogs token=$token"
		if defined $token && length $token;

	return ( $url, @headers );
}

# Given a status code and a body, return a decoded structure or a typed
# error. Never dies - eval guards decode_json.
sub classifyResponse {
	my ( $class, $code, $content ) = @_;

	if ( !$code ) {
		# decisions §9.3's FAQ: "Why am I getting an empty response from the
		# server? This generally happens when you forget to add a
		# User-Agent header." A dropped connection surfaces here as no
		# status at all, not as a body - SimpleSyncHTTP/SimpleAsyncHTTP both
		# leave code unset when the request never got a response.
		return { ok => 0, error => 'no_response', code => $code };
	}

	if ( $code == 200 ) {
		if ( !defined $content || $content eq '' ) {
			return { ok => 0, error => 'empty_body', code => $code };
		}

		my $data = eval { decode_json($content) };

		return { ok => 0, error => 'malformed_json', code => $code }
			if $@ || !defined $data;

		return { ok => 1, data => $data, code => $code };
	}

	return { ok => 0, error => 'unauthorized', code => $code } if $code == 401;
	return { ok => 0, error => 'not_found',    code => $code } if $code == 404;
	return { ok => 0, error => 'rate_limited', code => $code } if $code == 429;
	return { ok => 0, error => 'server_error', code => $code } if $code >= 500 && $code < 600;

	return { ok => 0, error => 'unknown', code => $code };
}

# Not pure - reads LMS's own plugin registry - but deterministic given the
# process it runs in and trivially stubbable (Slim::Utils::PluginManager is
# already a singleton every offline suite stubs freely). Kept separate from
# buildRequest so buildRequest's own logic stays a plain data transform.
#
# The scanner never loads Plugin.pm (Slim/Utils/PluginManager.pm:204,
# CLAUDE.md), so $loaded is keyed by whichever of <module>/<importmodule>
# actually ran in this process (refs/slimserver/Slim/Utils/PluginManager.pm:
# 331,373 populate $loaded by $moduleType, dataForPlugin reads it back at
# :478-487). Pattern verified at refs/Spotty-Plugin/Plugin.pm:299-300,120 -
# dataForPlugin($class)->{version}, the same in-tree convention used to read
# a plugin's own install.xml version at runtime rather than hardcoding it
# (decisions §3 item 2: "a hardcoded version drifts").
sub _pluginVersion {
	my $module = main::SCANNER
		? 'Plugins::SqueezeWax::Importer'
		: 'Plugins::SqueezeWax::Plugin';

	my $data = Slim::Utils::PluginManager->dataForPlugin($module);

	return ( $data && ref $data && $data->{version} ) || 'unknown';
}

# ---------------------------------------------------------------------------
# The transport shim. Scanner-only (see the header note and CLAUDE.md). Not
# exercised by scripts/api-check.pl for the reason stated there and in the
# header above - SimpleSyncHTTP itself refuses to run outside the scanner.
# No rate limiting yet (build-order step 4 item 3); a later commit wraps this
# with the accounting function and a 429 retry loop.
# ---------------------------------------------------------------------------

sub _request {
	my ( $path, $params, $token ) = @_;

	my ( $url, @headers ) = Plugins::SqueezeWax::API->buildRequest( $path, $params, $token );

	my $response = Slim::Networking::SimpleSyncHTTP->new( { timeout => 15 } )
		->get( $url, @headers );

	return Plugins::SqueezeWax::API->classifyResponse( $response->code, $response->content );
}

1;
