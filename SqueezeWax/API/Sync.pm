package Plugins::SqueezeWax::API::Sync;

# The scanner's Discogs client: the collection fetch the scan-time sync makes
# inside our own scan step (build-order step 8b, decisions §15.18).
#
# One of two. API/Async.pm is the server's, and the split is not a preference:
# there is no event loop in the scanner (scanner.pl:498, `sub idleStreams {}`),
# so Slim::Utils::Timers never fires there and SimpleAsyncHTTP cannot complete.
# This file walks the same endpoints in the same order with a blocking
# transport, Slim::Networking::SimpleSyncHTTP, which is that class's sanctioned
# home - it warns when constructed anywhere but the scanner
# (Slim/Networking/SimpleSyncHTTP.pm:11, :58). The reference plugin does the
# same from its own importer (refs/lms-plugin-tidal/Importer.pm:21, :67;
# API/Sync.pm:104-105).
#
# API.pm owns every decision this file makes, exactly as it does for Async.pm:
# the request (buildRequest), the response (classifyResponse), the budget
# (accountRequest), the pages (_pageCount, _collectionPath, _collectionParams),
# the entries (entryFromRelease) and the test filter (_testFilter). This file
# owns only the wiring and the two rules that exist because a scan is waiting:
#
#   - no retries. backoffFor is never called; a 429 fails the fetch once, and
#     a computed rate wait abandons it rather than blocking the scan for a
#     minute (§15.18 part 11);
#   - a whole-fetch budget of our own, because LWP's timeout measures
#     inactivity, not total time (CPAN/LWP/UserAgent.pm:1565-1568; §15.18
#     part 10).
#
# It writes nothing, touches no pref, and knows nothing about ownership or
# progress. The caller - ScanSync - owns all three.

use strict;

use Slim::Utils::Log;

use Plugins::SqueezeWax::API;

my $log = logger('plugin.squeezewax');

# Per request. What API/Async.pm passes, and what the reference plugin uses
# (refs/lms-plugin-tidal/API/Sync.pm:104-105), so a slow response behaves alike
# on both paths (§15.18 part 10).
#
# Always passed, and never falsy: Base.pm:99-102 falls back to the server's
# remotestreamtimeout only when this is unset, and a falsy timeout makes
# SimpleSyncHTTP.pm:87 return before anything is sent.
use constant REQUEST_TIMEOUT => 15;

# For the whole fetch: our own clock, checked BETWEEN requests. Nothing can
# interrupt a request already in flight, so one slow-but-alive response can
# still run past it - which no code of ours can prevent, and which is on the
# hardware list (plan §7 check 7). A 203-item collection is four requests and
# ~2.7 s, so this is a bound on the pathological case, not a pace.
use constant FETCH_BUDGET => 120;

=head2 fetch( $token [, $onResponse ] )

Fetch the whole collection, synchronously. Returns

  { ok => 1, entries => [...], items => N, counted => N, pages => N, requests => N }
  { ok => 0, error => '...', code => N, requests => N }

C<entries> is the filtered list the ownership pass takes (C<_testFilter> applied,
after the completeness gate). The error names are the async path's -
C<classifyResponse>'s vocabulary plus C<no_token>, C<no_username>,
C<too_many_pages>, C<count_unknown>, C<count_mismatch> - and this path's own two,
C<rate_wait> and C<timeout_budget>.

C<$onResponse>, if given, is called once after every successful response with
C<( $requests, $pages )>; C<$pages> is undef until the first collection page has
answered. It is how the caller ticks a progress row without this file knowing
there is one.

Never dies: every failure is a returned result.

=cut

sub fetch {
	my ( $class, $token, $onResponse ) = @_;

	my $run = {
		token      => $token,
		started    => time(),
		requests   => 0,
		state      => undef,
		wait       => 0,
		onResponse => $onResponse,
		pages      => undef,
	};

	my $result = eval { _fetch($run) };

	if ( !$result ) {
		my $err = $@ || 'unknown error';
		chomp $err;

		$log->error("scan-time collection fetch died: $err");

		$result = { ok => 0, error => 'failed' };
	}

	$result->{requests} = $run->{requests};

	return $result;
}

sub _fetch {
	my ($run) = @_;

	if ( !defined $run->{token} || $run->{token} eq '' ) {
		return { ok => 0, error => 'no_token' };
	}

	my $identity = _request( $run, '/oauth/identity', {} );

	return $identity unless $identity->{ok};

	_notify($run);

	my $username = ref $identity->{data} ? $identity->{data}{username} : undef;

	if ( !defined $username || $username eq '' ) {
		return { ok => 0, error => 'no_username' };
	}

	my $path = Plugins::SqueezeWax::API::_collectionPath($username);

	main::INFOLOG && $log->is_info
		&& $log->info("scan-time collection fetch starting for Discogs user $username");

	# Keyed by instance_id, as the async path keys them: the collection ENTRY's
	# identity (see API.pm's entryFromRelease).
	my %entries;
	my $items;

	for ( my $page = 1 ; ; $page++ ) {
		my $result = _request( $run, $path, Plugins::SqueezeWax::API::_collectionParams($page) );

		return $result unless $result->{ok};

		my $data       = $result->{data};
		my $pagination = ref $data eq 'HASH' ? $data->{pagination} : undef;

		if ( $page == 1 ) {
			$items = $pagination ? $pagination->{items} : undef;

			$run->{pages} =
				( $pagination && $pagination->{pages} && $pagination->{pages} > 0 )
				? $pagination->{pages}
				: Plugins::SqueezeWax::API::_pageCount($items);

			# On the first page, as the async path checks it: the point of the
			# bound is not to issue the requests.
			if ( $run->{pages} > Plugins::SqueezeWax::API::MAX_PAGES ) {
				$log->warn( "collection reported $run->{pages} pages, more than the "
					. Plugins::SqueezeWax::API::MAX_PAGES
					. " this will fetch - treating this sync as failed" );

				return { ok => 0, error => 'too_many_pages' };
			}

		}

		# From page 1 on, the page count is known, so the caller can set its
		# progress total (Slim/Utils/Progress.pm:154-170).
		_notify($run);

		for my $release ( @{ ( ref $data eq 'HASH' && $data->{releases} ) || [] } ) {
			my $entry = Plugins::SqueezeWax::API->entryFromRelease($release) or next;

			$entries{ $entry->{instance_id} } = $entry;
		}

		last if $page >= $run->{pages};
	}

	my $counted = scalar keys %entries;

	# The completeness gate, the async path's, for the async path's reason: the
	# pass derives every badge from this list, so a list that cannot be shown
	# complete removes badges silently - §13.7's named failure (§15.13 part 1).
	if ( !defined $items ) {
		$log->warn('scan-time collection fetch got no pagination.items; cannot show the list is complete');

		return { ok => 0, error => 'count_unknown' };
	}

	if ( $counted != $items ) {
		$log->warn( "scan-time collection fetch saw $counted distinct collection entries but "
			. "the server reported $items items; not deriving ownership from it" );

		return { ok => 0, error => 'count_mismatch' };
	}

	# After the gate, which counted the unfiltered list - the placement that is
	# the whole of _testFilter's safety (API.pm), on this path as on the other.
	my $entries = Plugins::SqueezeWax::API::_testFilter( [ values %entries ] );

	return {
		ok       => 1,
		entries  => $entries,
		items    => $items,
		counted  => $counted,
		pages    => $run->{pages},
	};
}

# One request. Both abandon rules are checked HERE, before the request is
# issued, and never after a response: a wait computed after the last page, or
# a budget crossed by the last response, costs nothing, because there is no
# next request to refuse (§15.18 parts 10 and 11).
sub _request {
	my ( $run, $path, $params ) = @_;

	# The rate wait. accountRequest (API.pm:146) returns one as well as a state,
	# and the server honours it with a timer (API/Async.pm's _get). There is no
	# timer in the scanner, so honouring it would mean blocking the scan for a
	# whole window. The state starts cold every scan - the scanner is a fresh
	# process - which is why a response with no rate headers, first thing,
	# abandons: accountRequest assumes the budget exactly spent when nothing is
	# known (its own comment has why).
	if ( $run->{wait} ) {
		$log->error( "Discogs rate budget spent (wait $run->{wait}s); "
			. 'abandoning the scan-time fetch rather than block the scan' );

		return { ok => 0, error => 'rate_wait' };
	}

	my $elapsed = time() - $run->{started};

	if ( $elapsed >= FETCH_BUDGET ) {
		$log->error( "scan-time collection fetch has taken ${elapsed}s, past its "
			. FETCH_BUDGET . 's budget; abandoning it' );

		return { ok => 0, error => 'timeout_budget' };
	}

	$run->{requests}++;

	my ( $url, @headers ) =
		Plugins::SqueezeWax::API->buildRequest( $path, $params, $run->{token} );

	# Required here rather than used at the top, as Slim/Music/Artwork.pm:771
	# does: only the scanner ever reaches this, and loading the class in the
	# server would be loading the one networking class that warns about being
	# there.
	#
	# Never `cache`. SimpleSyncHTTP caches only when asked
	# (Slim/Networking/SimpleHTTP/Base.pm:81-95), and TIDAL asks; for a
	# collection a cached page would defeat the completeness gate silently.
	require Slim::Networking::SimpleSyncHTTP;

	my $http = Slim::Networking::SimpleSyncHTTP->new( { timeout => REQUEST_TIMEOUT } )
		->get( $url, @headers );

	# code, mess and headers are set for every response, success or not
	# (SimpleSyncHTTP.pm:97-99), so none of the async path's third-argument
	# workaround is needed. content is empty on a non-2xx (:101-108, :137),
	# which classifyResponse does not need.
	my $code    = $http->code;
	my $headers = $http->headers;

	my $result = _isInternalResponse( $code, $headers )
		? { ok => 0, error => 'no_response', code => $code }
		: Plugins::SqueezeWax::API->classifyResponse( $code, $http->content );

	# Every response costs budget, a 429 included, exactly as Async::_handle
	# accounts it.
	( $run->{state}, $run->{wait} ) = Plugins::SqueezeWax::API->accountRequest(
		Plugins::SqueezeWax::API::_parseRateHeaders($headers), time(), $run->{state} );

	return $result;
}

# Once per answered request, from _fetch rather than _request, so that page 1
# is reported once and with its page count.
sub _notify {
	my ($run) = @_;

	$run->{onResponse}->( $run->{requests}, $run->{pages} ) if $run->{onResponse};

	return;
}

# LWP's own 500 (decisions §15.18, "Two rulings taken without a question"). On a
# timeout, a DNS failure or a refused connection LWP::UserAgent builds a
# response itself, carrying `Client-Warning: Internal response`
# (CPAN/LWP/UserAgent.pm:205-219, :1131-1139; documented at :1569-1572). It is
# not Discogs saying anything, and classifying it as server_error would make
# every timeout read "Discogs returned a server error" - so it is no_response,
# which is what the async path reports for the same event. Read, not observed:
# on the hardware list.
sub _isInternalResponse {
	my ( $code, $headers ) = @_;

	return 0 unless defined $code && $code =~ /^5\d\d$/;
	return 0 unless $headers && ref $headers && $headers->can('header');

	my $warning = $headers->header('Client-Warning');

	return ( defined $warning && $warning =~ /internal response/i ) ? 1 : 0;
}

1;
