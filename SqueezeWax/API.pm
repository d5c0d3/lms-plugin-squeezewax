package Plugins::SqueezeWax::API;

# Discogs API client, synchronous path (build-order step 4 §1 scope:
# "Structural runs in the scanner... API/Async.pm is server-side and belongs
# to steps 5/6"). Shape mirrored from refs/lms-plugin-tidal/API/Sync.pm
# (commit 8df3d452, 2026-07-26): a thin _get wrapping
# Slim::Networking::SimpleSyncHTTP, JSON decode, error handling by response
# code. Built out incrementally over build-order step 4 items 1-3 (token
# auth, request construction, rate limiting).
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

# decisions §9.2, verified 2026-09-07: a personal access token yields
# `x-discogs-ratelimit: 60`, documented as a moving average over a 60-second
# window that resets after 60 idle seconds.
use constant DEFAULT_LIMIT  => 60;
use constant WINDOW_SECONDS => 60;

# 429 retry bound (§3.2). Three retries (four attempts total) at
# WINDOW_SECONDS each is up to 4 minutes stalled on one request. Structural
# runs unattended over hundreds of albums (plan §13's "~9 minutes at 60/min
# for 500 albums" is the scale this competes with), so a single wedged
# request must not be allowed to stall the scan indefinitely - a 429 that
# survives the local throttle three times in a row means something is wrong
# beyond ordinary pacing (concurrent use of the same token from elsewhere, or
# a genuinely stuck window), and the right response is to give up on this one
# request and let the album fall to the review queue, not to retry forever.
use constant MAX_RETRIES => 3;

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

# Given the three response headers (already extracted into a hashref -
# _parseRateHeaders below does that from a real response), the current time
# and the prior state (or undef on the first call), return the new state and
# how many seconds to wait before the next request.
#
# §3.4: headers may be absent (an error response, or a proxy that strips
# them) or malformed (never observed, but not to be trusted with a bare
# numeric comparison). Degrades in two steps rather than one flat default: if
# this response's headers are unusable but a prior state exists, assume this
# request consumed one more unit of the budget last known (conservative
# without being maximally pessimistic on every single bad header); if
# nothing is known at all, assume the documented limit is exactly spent -
# the safest possible starting assumption, per decisions §9.2's own
# instruction to "throttle locally" rather than trust the server not to have
# throttled already.
sub accountRequest {
	my ( $class, $headers, $now, $priorState ) = @_;

	$headers = {} unless $headers;
	$now = time() unless defined $now;

	my ( $limit, $used, $remaining ) = @{$headers}{qw(limit used remaining)};

	my $state;

	if ( _looksNumeric($limit) && _looksNumeric($used) && _looksNumeric($remaining) ) {
		$state = {
			limit     => $limit + 0,
			used      => $used + 0,
			remaining => $remaining + 0,
		};
	}
	elsif ( $priorState && _looksNumeric( $priorState->{remaining} ) ) {
		my $priorRemaining = $priorState->{remaining};
		my $priorLimit     = _looksNumeric( $priorState->{limit} ) ? $priorState->{limit} : DEFAULT_LIMIT;
		my $newRemaining   = $priorRemaining > 0 ? $priorRemaining - 1 : 0;

		$state = {
			limit     => $priorLimit,
			remaining => $newRemaining,
			used      => $priorLimit - $newRemaining,
		};
	}
	else {
		$state = {
			limit     => DEFAULT_LIMIT,
			used      => DEFAULT_LIMIT,
			remaining => 0,
		};
	}

	$state->{checked_at} = $now;

	my $wait = $state->{remaining} > 0 ? 0 : WINDOW_SECONDS;

	return ( $state, $wait );
}

# §3.2: how long to wait before retrying a 429, given how many retries have
# already happened for this request (0 on the first retry decision). undef
# means give up. See MAX_RETRIES above for the bound and its reasoning.
sub backoffFor {
	my ( $class, $attempt ) = @_;

	return undef if !defined $attempt || $attempt >= MAX_RETRIES;

	return WINDOW_SECONDS;
}

sub _looksNumeric {
	my ($v) = @_;

	return defined $v && $v =~ /^\d+$/;
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

# Extract the three Discogs rate-limit headers from a real response's
# headers object into the hashref shape accountRequest expects. The only
# place an HTTP::Headers object (or anything answering ->header) is touched.
sub _parseRateHeaders {
	my ($headers) = @_;

	return {} unless $headers;

	return {
		limit     => scalar $headers->header('X-Discogs-Ratelimit'),
		used      => scalar $headers->header('X-Discogs-Ratelimit-Used'),
		remaining => scalar $headers->header('X-Discogs-Ratelimit-Remaining'),
	};
}

# ---------------------------------------------------------------------------
# The transport shims. Scanner-only (see the header note and CLAUDE.md). Not
# exercised by scripts/api-check.pl for the reason stated there and in the
# header above - SimpleSyncHTTP itself refuses to run outside the scanner.
# ---------------------------------------------------------------------------

sub _request {
	my ( $path, $params, $token ) = @_;

	my ( $url, @headers ) = Plugins::SqueezeWax::API->buildRequest( $path, $params, $token );

	my $response = Slim::Networking::SimpleSyncHTTP->new( { timeout => 15 } )
		->get( $url, @headers );

	my $result = Plugins::SqueezeWax::API->classifyResponse( $response->code, $response->content );

	return ( $result, _parseRateHeaders( $response->headers ) );
}

# This process's rate-limit state. Deliberately module-level rather than
# threaded through every caller: one Discogs token has one real budget
# regardless of which album Structural is currently on, and the scanner is a
# single long-lived process for the duration of one scan (CLAUDE.md: LMS is
# single-threaded), so there is exactly one of these to track.
my $rateState;
my $rateWait = 0;

# Public entry point for a rate-limited, retried request. No logic beyond
# sleeping and calling accountRequest/backoffFor (§3.1/§3.2) around
# _request - the retry loop's shape is wiring, not a decision; every decision
# it makes (how long to wait, whether to give up) comes from a pure function
# above.
sub get {
	my ( $class, $path, $params, $token ) = @_;

	my $attempt = 0;

	while (1) {
		sleep($rateWait) if $rateWait;

		my ( $result, $rateHeaders ) = _request( $path, $params, $token );

		my ( $newState, $wait ) = $class->accountRequest( $rateHeaders, time(), $rateState );
		$rateState = $newState;
		$rateWait  = $wait;

		return $result unless $result->{error} && $result->{error} eq 'rate_limited';

		my $retryWait = $class->backoffFor($attempt);

		return $result unless defined $retryWait;

		main::INFOLOG && $log->is_info
			&& $log->info("rate limited on $path, retrying in ${retryWait}s (attempt $attempt)");

		sleep($retryWait);

		$attempt++;
	}
}

1;
