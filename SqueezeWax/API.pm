package Plugins::SqueezeWax::API;

# Discogs API request construction, response classification and rate-limit
# accounting, plus the collection walk's shared pieces. This module performs no
# network I/O and owns no transport. Built out over build-order step 4 items
# 1-3 (token auth, request construction, rate limiting); the synchronous
# transport it originally carried (sub get, sub _request, wrapping
# Slim::Networking::SimpleSyncHTTP, shape mirrored from
# refs/lms-plugin-tidal/API/Sync.pm commit 8df3d452) was deleted at build-order
# step 5, having never acquired a v1 caller: decisions §13.8 removed the
# per-album scanner search it was written for.
#
# Two transports since step 8b, one per process, each supplying its own:
#
#   - API/Async.pm (step 5) wires these functions, plus accountRequest,
#     backoffFor and _parseRateHeaders, to Slim::Networking::SimpleAsyncHTTP
#     and Slim::Utils::Timers - CLAUDE.md: "Server-side HTTP -> SimpleAsyncHTTP
#     (async)". It is the server's fallback sync and the manual button.
#   - API/Sync.pm (step 8b) wires the same functions, minus backoffFor, to
#     Slim::Networking::SimpleSyncHTTP. The scanner calls buildRequest through
#     it, from our own scan step (decisions §15.18). A second transport is
#     mandatory there, not chosen: the scanner has no event loop.
#
# Settings.pm's token test predates both and wires its own.
#
# Until step 8b this header also claimed that "the scanner's Strict
# identification calls buildRequest and classifyResponse directly". That was
# false from §13.8 on - identification never talked to Discogs - and is true
# again now only in the sense above.
#
# Keeping the decisions out of the shims is what makes them testable:
# scripts/api-check.pl covers every function here without constructing a
# transport object, the same division Match.pm's _writeRefusal uses.

use strict;

use Data::URIEncode qw(complex_to_query);
use JSON::XS qw(decode_json);
use POSIX qw(ceil);

use Slim::Utils::Log;
use Slim::Utils::PluginManager;
use Slim::Utils::Prefs;

my $log   = logger('plugin.squeezewax');
my $prefs = preferences('plugin.squeezewax');

use constant BASE_URL => 'https://api.discogs.com';
use constant REPO_URL => 'https://github.com/d5c0d3/lms-plugin-squeezewax';

# decisions §9.2, verified 2026-09-07: a personal access token yields
# `x-discogs-ratelimit: 60`, documented as a moving average over a 60-second
# window that resets after 60 idle seconds.
use constant DEFAULT_LIMIT  => 60;
use constant WINDOW_SECONDS => 60;

# 429 retry bound (§3.2), shared by the pure backoffFor here and the async
# collection sync's retry loop (API/Async.pm). Three retries (four attempts
# total) at WINDOW_SECONDS each is up to 4 minutes stalled on one request -
# a 429 that survives the local throttle three times in a row means
# something is wrong beyond ordinary pacing (concurrent use of the same
# token from elsewhere, or a genuinely stuck window), and the right response
# is to give up and let this sync fail, not retry forever.
#
# Shared by nothing on the scan path. API/Sync.pm never calls backoffFor: four
# minutes stalled on one request would be four minutes of a scan, and the
# scanner has no timer to wait on anyway, so a 429 there fails the fetch once
# and the server's fallback retries a minute after the scan (decisions §15.18
# parts 2 and 11).
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
# shift rows between pages. The collection listing is paginated and has been
# called since step 5; its explicit sort is pinned by _collectionParams below,
# which both transports use. Any further paginated endpoint must do the same:
# pass an explicit sort/sort_order (or equivalent) in $params rather than
# relying on the endpoint's default.
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

# ---------------------------------------------------------------------------
# The collection walk's shared pieces. Moved from API/Async.pm at step 8b so
# that both transports - Async.pm in the server, Sync.pm in the scanner - build
# the same request and the same entry list: two copies of the entry builder is
# the drift decisions §15.2 reason 1 warned about, and a seam test could only
# ever cover one of them (§15.18 part 15). Pure, except _testFilter, which reads
# a pref and logs.
# ---------------------------------------------------------------------------

# decisions §9.4, quoting the API docs: "By default, 50 items per page ... To
# browse different pages, or change the number of items per page (up to 100),
# use the page and per_page query string parameters." 100 is the documented
# maximum, and the whole cost model (ceil(items/100) requests; measured 3 for
# 203 items) rests on asking for it.
use constant PER_PAGE => 100;

# Folder 0 is the whole collection - the docs' own "If folder_id is not 0..."
# carve-out for authentication treats 0 as the everything case.
use constant COLLECTION_FOLDER => 0;

# A bound on the page loop, not a product limit. The loop trusts the server's
# own pagination.pages to decide when to stop; this is the backstop if that
# figure is ever absurd or self-contradictory, so a malformed response cannot
# turn into an unbounded request stream against a rate-limited API. 1000 pages
# is 100,000 items - far past any real collection, and still finite.
use constant MAX_PAGES => 1000;

# How many requests a collection of $items costs. The figure build-order item
# 5's hardware check measures (plan §3 check 1), so it lives here as one
# expression rather than being open-coded into the loop.
#
# An empty collection still costs the one request that discovered it was
# empty; the loop always fetches page 1 before it knows anything at all.
sub _pageCount {
	my ( $items, $perPage ) = @_;

	$perPage = PER_PAGE unless defined $perPage && $perPage > 0;

	return 1 unless defined $items && $items =~ /^\d+$/ && $items > 0;

	return ceil( $items / $perPage );
}

# The collection-listing path for a user. Username is interpolated, not
# passed as a query parameter, so it is URI-escaped here - Discogs usernames
# permit characters that are not path-safe.
sub _collectionPath {
	my ($username) = @_;

	my $escaped = $username;
	$escaped =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord($1))/ge;

	return sprintf( '/users/%s/collection/folders/%d/releases',
		$escaped, COLLECTION_FOLDER );
}

# Query parameters for one page.
#
# decisions §9.4 records the pagination hazard - paging over a mutable,
# non-unique sort can shift rows between pages, dropping or duplicating them -
# and instructs: "Pin an explicit stable sort on every paged endpoint, or
# document the accepted risk." Both halves apply here, because the docs offer
# no sort key that is actually stable.
#
# Read from the archived API documentation (web.archive.org snapshot
# 20251226151912 of discogs.com/developers; the live page is behind a
# Cloudflare interstitial), section "Collection Items By Folder". The complete
# set of valid sort keys is: label, artist, title, catno, format, rating,
# added, year. There is no id-based key - neither id nor instance_id is
# offered - so nothing on that list is guaranteed unique.
#
# `added` is nonetheless the best of them, and strictly better than the
# default: every other key except `rating` is release metadata that any
# Discogs contributor can edit mid-sync, and `rating` is user-mutable. The
# time an instance entered the collection is not editable at all. The residual
# risk, documented rather than pretended away: a bulk add gives many instances
# the same timestamp, and ties within one batch may order arbitrarily between
# requests.
#
# For this step that risk is close to theoretical - the sync discards page
# contents and reports only a count, and both the count and the request total
# survive rows being reshuffled. It becomes load-bearing at step 7, which
# consumes the rows; pinning it now means step 7 inherits the better default
# rather than rediscovering this.
#
# Note also that the "default is sort=label&sort_order=asc" figure in
# decisions §9.4 is not in the documentation, which states no default for this
# endpoint at all. It is an observation from this repo's own fixture
# (scripts/fixtures/collection-page1.json, whose pagination.urls.next carries
# those parameters). See TODO.md.
sub _collectionParams {
	my ($page) = @_;

	return {
		page       => ( $page && $page > 0 ) ? $page : 1,
		per_page   => PER_PAGE,
		sort       => 'added',
		sort_order => 'asc',
	};
}

# One format as a line the user can match against the object in their hand:
# "Vinyl, LP, Album, Limited Edition" - the medium, then its descriptions.
#
# `text` is deliberately dropped. On the fixture's first entry it reads
# "Signed, Gatefold, Butterfly Effect Splatter", which is free-form seller prose
# rather than a property of the pressing, and it is long enough to push the
# release id off a narrow row.
#
# `qty` is dropped too: a 2xLP already says "2" in its descriptions where it
# matters, and a bare "1" on every single-disc record is noise.
sub _formatLabel {
	my ($format) = @_;

	return '' unless ref $format eq 'HASH';

	return join ', ',
		grep { defined && /\S/ }
		$format->{name}, @{ $format->{descriptions} || [] };
}

# One label as "Island Records (524 089-2)". The catalogue number is the thing
# that actually separates two pressings on the same label, so it is never
# dropped - but a release with no catno gets the bare name rather than an empty
# bracket.
sub _labelLabel {
	my ($label) = @_;

	return '' unless ref $label eq 'HASH';

	my $name  = $label->{name};
	my $catno = $label->{catno};

	return '' unless defined $name && $name =~ /\S/;

	return ( defined $catno && $catno =~ /\S/ ) ? "$name ($catno)" : $name;
}

=head2 entryFromRelease( \%release )

One collection entry from one row of a collection page's C<releases>, or undef
when the row has no C<instance_id>. Both transports build their entry list
with this, so the two lists cannot drift (decisions §15.18 part 15).

=cut

# Nothing about a release reaches the database - §13.2: ownership is a column
# on discogs_match, not a mirrored collection, and discogs_collection is not a
# v1 table. The ownership pass needs the first five fields below and nothing
# else (§15.13 part 1); the last three exist only for the queue page's re-match
# list, which is handed this same list and has no other source for them
# (§15.16 part 6). The lifetime is the caller's: one sync, then gone.
#
# The caller keys the list by instance_id, which is the collection ENTRY's
# identity: the same release owned twice is two instances, and de-duplicating
# would make the count disagree with pagination.items and fail the sync.
# Whether two instances of one release count as one candidate is the ownership
# pass's question, not this one's.
sub entryFromRelease {
	my ( $class, $release ) = @_;

	return undef unless ref $release eq 'HASH';

	my $instance = $release->{instance_id};

	return undef unless defined $instance;

	my $basic = $release->{basic_information} || {};

	return {
		instance_id => $instance,
		id          => $release->{id},
		master_id   => $basic->{master_id},
		title       => $basic->{title},
		artists     => [ map { $_->{name} } @{ $basic->{artists} || [] } ],

		# The three the RE-MATCH LIST needs and the pass ignores (§15.16 part
		# 6). They are here because the page is handed this same list and there
		# is no second fetch to get them from - the collection is discarded when
		# the sync ends (§13.2), so a field not kept here is a field the page
		# cannot show.
		#
		# Fixed set, not everything basic_information carries. A user choosing
		# between two pressings of one record needs the year, the medium and
		# the catalogue number, and each of those is on the sleeve in front of
		# them. Nothing else earns its place, and a field picker is recorded as
		# a future feature rather than built.
		#
		# Flattened to plain strings here rather than stored raw, so the
		# template has no structure to walk and _testFilter's list stays
		# something a suite can compare with is_deeply.
		#
		# thumb and cover_image are deliberately NOT kept: whether Discogs'
		# terms permit showing them is unverified (§9.9 already records that
		# image URLs are withheld without authentication).
		year    => $basic->{year},
		formats => [ map { _formatLabel($_) } @{ $basic->{formats} || [] } ],
		labels  => [ map { _labelLabel($_) }  @{ $basic->{labels}  || [] } ],
	};
}

=head2 _testFilter( \@entries )

The entry list with any release id named by C<discogsTestExcludeReleases>
removed. A development aid, not a feature.

=cut

# Build-order steps 6-7's hardware check (6) is "remove a record from the
# Discogs collection and watch the pass react". Doing that for real mutates
# data this project does not own and cannot restore if a step fails. This
# makes a release invisible TO THE PASS instead, which is the only place the
# pass ever sees one.
#
# Where it sits is the whole of its safety. Both transports call it AFTER their
# completeness gate, which compares the distinct entries counted against
# pagination.items - both computed from the unfiltered list, before this is
# reached - so hiding a release can never make a sync look incomplete, and can
# never mask a real short page. It lives here, beside the entry builder, so
# that the scan-time sync and the server's sync hide the same releases: its
# safety argument is that a release hidden from the pass is hidden everywhere
# the pass's conclusions show (decisions §15.18 part 15).
# Nothing is sent to Discogs and the fetch is untouched: the collection on
# discogs.com is not altered, read-only or otherwise.
#
# There is no settings-page field for the pref on purpose. It is set by hand
# for a test and cleared afterwards, and a control on the page would invite it
# being left on.
#
# It cannot sit on silently. While the pref is non-empty EVERY sync logs at
# warn, not info, so a forgotten filter shows up in the log of a server whose
# owner is wondering why a record stopped badging.
sub _testFilter {
	my ($entries) = @_;

	my $raw = $prefs->get('discogsTestExcludeReleases');

	return $entries unless defined $raw && $raw =~ /\S/;

	my %drop = map { $_ => 1 } grep { /^\d+$/ } split /\s*,\s*/, $raw;

	my @kept = grep { !defined $_->{id} || !$drop{ $_->{id} } } @$entries;

	# Logged even when nothing matched: a filter naming ids this collection
	# does not contain is still a filter that is on, and the count is how its
	# owner notices it was the wrong id rather than the wrong conclusion.
	$log->warn( 'test filter active: hiding '
		. ( scalar(@$entries) - scalar(@kept) )
		. ' releases from the ownership pass' );

	return \@kept;
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

1;
