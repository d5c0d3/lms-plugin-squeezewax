package Plugins::SqueezeWax::API::Async;

# Server-side Discogs client: the collection sync (build-order step 5).
#
# API.pm owns every decision this file makes - what a request looks like
# (buildRequest), what a response means (classifyResponse), how much of the
# rate-limit budget is left (accountRequest), and when to stop retrying a 429
# (backoffFor). This file owns only the wiring: Slim::Networking::
# SimpleAsyncHTTP for the transport and Slim::Utils::Timers for the waiting,
# because LMS is single-threaded and the server process must not block
# (CLAUDE.md: "Server-side HTTP -> SimpleAsyncHTTP (async)"). Where API.pm's
# deleted synchronous path called sleep(), this one returns to the event loop
# and resumes from a timer.
#
# What a sync does NOT do, by decision (step 5 plan §0, decisions §13.2/§15.9):
# it writes nothing to discogs_collection (not a v1 table, dropped by
# migration 3) and it caches no page contents for a later pass. §13.6 still
# holds - "every completed sync re-derives every conclusion from scratch" -
# and the collection is still discarded when the sync returns.
#
# CORRECTED at build-order step 7 (decisions §15.13 part 1): this said
# ownership is computed by a pass "which re-fetches". It does not. A re-fetch
# would double §14.7's per-sync cost for a second copy of what this run already
# has, so the completed sync HANDS the pass its entry list in memory, the pass
# runs inside _finish, and the list is dropped when _finish returns. Nothing
# about a release persists. discogs_match is therefore written during a sync
# after all - by the pass, never by this module.

use strict;

use POSIX qw(ceil);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::SqueezeWax::API;

my $log   = logger('plugin.squeezewax');
my $prefs = preferences('plugin.squeezewax');

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

# This process's rate-limit state. Module-level for the same reason API.pm's
# deleted $rateState was: one Discogs token has one real budget no matter who
# is asking, and the server is a single long-lived process (CLAUDE.md: LMS is
# single-threaded), so there is exactly one of these to track. It deliberately
# outlives an individual sync run - a sync that ends mid-window must not let
# the next one start as though the budget were fresh.
my $rateState;
my $rateWait = 0;

# A run that has not finished in this long is treated as dead, so a wedged sync
# cannot block every future trigger for the life of the server. Deliberately
# generous next to %detection's DETECTION_TIMEOUT of 600: a sync can legitimately
# spend MAX_RETRIES * WINDOW_SECONDS stalled on a single 429, and a large
# collection is many requests each of which may wait out a window.
use constant SYNC_TIMEOUT => 3600;

# Whether a sync is in flight, and which one. Module-level, server-process only,
# and deliberately not a pref: it is transient, and a "running" flag that
# survived a restart would be a lie that blocks the feature.
#
# This lives here rather than in Settings.pm - which is where %detection's
# equivalent lives, and where step 5's plan put it - because Settings.pm is
# loaded only under main::WEBUI (Plugin.pm's initPlugin, following
# refs/lms-plugin-tidal/Plugin.pm:60-66). Two of the three triggers this guard
# exists to serialise, the interval timer and ['rescan','done'], are server-wide
# and must work on a headless server, which never loads Settings.pm at all -
# decisions §15.12 part 3, the same trap Plugin.pm's own $prefs->migrate comment
# records. The guard belongs with the thing it guards.
#
# `id` is what makes a superseded run harmless: a stale run's in-flight HTTP
# request cannot be cancelled and will still call back, so _finish compares the
# id it was started with against the current one and declines to touch shared
# state if they differ.
my %sync;
my $syncId = 0;

# ---------------------------------------------------------------------------
# Pure functions. Covered by scripts/sync-check.pl without a transport.
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# The sync itself.
# ---------------------------------------------------------------------------

# Fetch the collection. $cb is called exactly once, with a result hashref:
#
#   { ok => 1, items => N, counted => N, pages => N, requests => N }
#   { ok => 0, error => '...', code => N }
#
# The error strings are API.pm's classifyResponse vocabulary, plus 'no_token'
# and 'no_username' raised here. Callers distinguish them per §13.7/§14.2:
# 'unauthorized' is a rejected token and deserves an error-level log, anything
# else is transient and deserves a warning; neither may advance a timestamp.
#
# `items` is the server's own pagination.items; `counted` is how many DISTINCT
# instance_ids were seen. They must agree, and a disagreement now FAILS the
# sync with 'count_mismatch' rather than warning and carrying on - corrected at
# step 7 (§15.13 part 1). The ownership pass derives every badge from this list,
# so a row dropped by pagination would silently remove a badge, which is §13.7's
# named failure. An `items` the server never reported fails the same way, as
# 'count_unknown': completeness that cannot be shown is treated as not shown.
#
# The username is fetched fresh on every run rather than cached in a pref.
# Caching it would save one request per sync and buy a silent-staleness
# failure mode: swap Discogs accounts, forget to re-test the token, and the
# sync goes on quietly reporting the old account's collection. Plan §2
# commit 3, following §13.6/§13.7/§14.2 in preferring a visible cost to an
# invisible wrong answer.
sub sync {
	my ( $class, $token, $cb ) = @_;

	$cb ||= sub { };

	if ( !defined $token || $token eq '' ) {
		$cb->( { ok => 0, error => 'no_token' } );
		return;
	}

	if ( $class->isRunning ) {
		# Not an error the user needs to see as a failure - it means the
		# trigger did its job and something else got there first. §13.7 wants
		# three triggers and one sync, not three syncs.
		$cb->( { ok => 0, error => 'already_running' } );
		return;
	}

	if ( $sync{running} ) {
		# isRunning said no while the flag says yes: the staleness backstop
		# fired. Mirrors _startDetection's handling of the same situation in
		# Settings.pm - warn, tear down what can be torn down, start fresh.
		$log->warn('previous collection sync appears to have died; starting a new one');
		$class->abort;
	}

	my $run = {
		id       => ++$syncId,
		token    => $token,
		cb       => $cb,
		requests => 0,
		counted  => 0,
		entries  => {},
		page     => 1,
		pages    => undef,
		items    => undef,
		attempt  => 0,
	};

	%sync = (
		running => 1,
		started => time(),
		id      => $run->{id},
	);

	_get( $run, '/oauth/identity', {}, \&_gotIdentity );

	return;
}

# Is a sync in flight? Carries the staleness backstop, so a run that died
# without clearing the flag cannot block every future trigger forever - the
# same belt-and-braces shape, and the same reasoning, as Settings.pm's
# %detection guard.
sub isRunning {
	my ($class) = @_;

	return 0 unless $sync{running};

	return 0 if ( time() - ( $sync{started} || 0 ) ) >= SYNC_TIMEOUT;

	return 1;
}

# What the settings page displays: the last outcome, not the live progress.
# There is nothing meaningful to show mid-run - a sync is a handful of requests,
# not a per-album walk like detection - so this is deliberately coarser than
# %detection's report.
sub status {
	my ($class) = @_;

	return {
		running    => $class->isRunning ? 1 : 0,
		lastSynced => $prefs->get('discogsLastSynced') || 0,
		lastItems  => $prefs->get('discogsLastSyncItems'),
		lastError  => $prefs->get('discogsLastSyncError'),
	};
}

# Cancel a pending scheduled request. Only the waiting is cancellable: a request
# already handed to SimpleAsyncHTTP will still complete and still call back.
# That is what $run->{id} is for - see %sync above; _finish declines to act on a
# callback from a superseded run.
sub abort {
	my ($class) = @_;

	Slim::Utils::Timers::killTimers( undef, \&_fire );

	return;
}

# Issue a request, waiting out the local throttle first if the last response
# said the budget was spent. The wait is a timer, not a sleep - returning to
# the event loop is the whole reason this file exists.
#
# Slim::Utils::Timers::setTimer( $obj, $when, $coderef, @args ) calls
# $coderef->( $obj, @args ) (refs/slimserver/Slim/Utils/Timers.pm:66-90, where
# setTimer is an alias for _makeTimer; EV-driven, not a thread). $obj is undef
# here because there is no client involved - the same convention
# Slim/Plugin/OnlineLibrary/Plugin.pm:122-138 uses for a server-wide timer,
# and what makes killTimers(undef, \&_fire) able to cancel it.
sub _get {
	my ( $run, $path, $params, $next ) = @_;

	if ($rateWait) {
		main::INFOLOG && $log->is_info
			&& $log->info("rate budget spent, deferring $path by ${rateWait}s");

		Slim::Utils::Timers::setTimer( undef, time() + $rateWait,
			\&_fire, $run, $path, $params, $next );

		return;
	}

	_fire( undef, $run, $path, $params, $next );

	return;
}

sub _fire {
	my ( undef, $run, $path, $params, $next ) = @_;

	$run->{requests}++;

	my ( $url, @headers ) =
		Plugins::SqueezeWax::API->buildRequest( $path, $params, $run->{token} );

	# One callback for both outcomes, as Settings.pm's _testToken does: on the
	# error path SimpleAsyncHTTP leaves code unset (it only sets it from a real
	# response, refs/slimserver/Slim/Networking/SimpleAsyncHTTP.pm:115), and
	# classifyResponse's !$code branch already means exactly that - no_response.
	my $done = sub {
		_handle( shift, $run, $path, $params, $next );
	};

	Slim::Networking::SimpleAsyncHTTP->new( $done, $done, { timeout => 15 } )
		->get( $url, @headers );

	return;
}

sub _handle {
	my ( $http, $run, $path, $params, $next ) = @_;

	my $result = Plugins::SqueezeWax::API->classifyResponse(
		$http->code, $http->content );

	# Account for the request whatever it returned - a 429 costs budget too,
	# and an error response that carries no rate headers is precisely the case
	# accountRequest's degradation ladder exists for (API.pm §3.4).
	( $rateState, $rateWait ) = Plugins::SqueezeWax::API->accountRequest(
		Plugins::SqueezeWax::API::_parseRateHeaders( $http->headers ),
		time(), $rateState );

	if ( ( $result->{error} || '' ) eq 'rate_limited' ) {
		my $retryWait = Plugins::SqueezeWax::API->backoffFor( $run->{attempt} );

		if ( defined $retryWait ) {
			main::INFOLOG && $log->is_info
				&& $log->info( "rate limited on $path, retrying in ${retryWait}s "
					. "(attempt $run->{attempt})" );

			$run->{attempt}++;

			Slim::Utils::Timers::setTimer( undef, time() + $retryWait,
				\&_fire, $run, $path, $params, $next );

			return;
		}

		# Out of retries. API.pm's MAX_RETRIES comment has the reasoning: this
		# is no longer ordinary pacing, and the right response is to fail the
		# sync for this interval rather than retry forever.
	}

	return _fail( $run, $result ) unless $result->{ok};

	# A clean response resets the retry budget for the next one. The bound is
	# per request, not per sync - a 429 on page 2 says nothing about page 7.
	$run->{attempt} = 0;

	$next->( $run, $result->{data} );

	return;
}

sub _gotIdentity {
	my ( $run, $data ) = @_;

	my $username = $data && ref $data ? $data->{username} : undef;

	if ( !defined $username || $username eq '' ) {
		return _fail( $run, { ok => 0, error => 'no_username' } );
	}

	$run->{username} = $username;
	$run->{path}     = _collectionPath($username);

	main::INFOLOG && $log->is_info
		&& $log->info("collection sync starting for Discogs user $username");

	_get( $run, $run->{path}, _collectionParams(1), \&_gotPage );

	return;
}

sub _gotPage {
	my ( $run, $data ) = @_;

	my $pagination = ( $data && ref $data ) ? $data->{pagination} : undef;

	if ( !defined $run->{pages} ) {
		$run->{items} = $pagination ? $pagination->{items} : undef;
		$run->{pages} =
			( $pagination && $pagination->{pages} && $pagination->{pages} > 0 )
			? $pagination->{pages}
			: _pageCount( $run->{items} );

		if ( $run->{pages} > MAX_PAGES ) {
			# Checked here, on the first page, rather than after the loop: the
			# point of the bound is to not issue the requests, and a
			# self-contradictory pagination block should cost one request, not
			# MAX_PAGES of them against a rate-limited API.
			$log->warn( "collection reported $run->{pages} pages, more than the "
				. MAX_PAGES . " this will fetch - treating this sync as failed" );

			return _fail( $run, { ok => 0, error => 'too_many_pages' } );
		}
	}

	# Collected, and dropped on the floor when _finish returns. Nothing about a
	# release reaches the database - §13.2: ownership is a column on
	# discogs_match, not a mirrored collection, and discogs_collection is not a
	# v1 table. What the ownership pass needs is the five fields below and
	# nothing else (§15.13 part 1).
	#
	# Keyed by instance_id, which is the collection ENTRY's identity: the same
	# release owned twice is two instances, and de-duplicating here would make
	# `counted` disagree with pagination.items and fail the sync. Whether two
	# instances of one release count as one candidate is the ownership pass's
	# question, not this one's.
	for my $release ( @{ ( $data && $data->{releases} ) || [] } ) {
		my $instance = $release->{instance_id};

		next unless defined $instance;

		my $basic = $release->{basic_information} || {};

		$run->{entries}{$instance} = {
			instance_id => $instance,
			id          => $release->{id},
			master_id   => $basic->{master_id},
			title       => $basic->{title},
			artists     => [ map { $_->{name} } @{ $basic->{artists} || [] } ],
		};
	}

	$run->{counted} = scalar keys %{ $run->{entries} };

	if ( $run->{page} < $run->{pages} ) {
		$run->{page}++;

		_get( $run, $run->{path}, _collectionParams( $run->{page} ), \&_gotPage );

		return;
	}

	# The completeness gate. Until step 7 this warned and carried on, because
	# the only durable output was the count itself. Now the ownership pass
	# derives every badge from this list, so an incomplete list silently removes
	# badges - §13.7's named failure - and both ways of being unable to show
	# completeness fail the sync instead (§15.13 part 1).
	#
	# This also makes §9.4's residual tie risk from pinning sort=added fail
	# safe: a reshuffle between pages aborts the pass rather than dropping a
	# record.
	if ( !defined $run->{items} ) {
		$log->warn('collection sync got no pagination.items; cannot show the list is complete');

		return _fail( $run, { ok => 0, error => 'count_unknown' } );
	}

	if ( $run->{counted} != $run->{items} ) {
		$log->warn( "collection sync saw $run->{counted} distinct collection entries but "
			. "the server reported $run->{items} items; not deriving ownership from it" );

		return _fail( $run, { ok => 0, error => 'count_mismatch' } );
	}

	main::INFOLOG && $log->is_info
		&& $log->info( "collection sync complete: $run->{items} items over "
			. "$run->{requests} requests" );

	return _finish( $run, {
		ok       => 1,
		items    => $run->{items},
		counted  => $run->{counted},
		pages    => $run->{pages},
		requests => $run->{requests},
	} );
}

sub _fail {
	my ( $run, $result ) = @_;

	return _finish( $run, {
		ok    => 0,
		error => $result->{error} || 'unknown',
		code  => $result->{code},
	} );
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
# Where it sits is the whole of its safety. It runs AFTER the completeness
# gate, which compares $run->{counted} against $run->{items} - both computed
# from the unfiltered list, before this is reached - so hiding a release can
# never make a sync look incomplete, and can never mask a real short page.
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

# The single exit. Every path out of a sync comes through here, which is what
# makes "never partially advance the timestamp for a sync that didn't complete"
# (§13.7/§14.2) one rule in one place rather than a convention each caller has
# to keep.
#
# discogsLastSynced advances on success and only on success. A failure records
# its error - the settings page needs something to show, and §14.2 wants a
# rejected token to be distinguishable from a dropped connection - but leaves
# every figure from the last good sync exactly as it was. A transient failure
# must not make a working collection look like it vanished.
#
# Which log level is the caller's decision, not this one's: only the caller
# knows whether a failure followed a button press the user is watching or a
# background interval tick.
sub _finish {
	my ( $run, $result ) = @_;

	if ( ( $sync{id} || 0 ) != $run->{id} ) {
		# A superseded run's in-flight request came back. It may not touch the
		# prefs or the guard - a newer sync owns both - and its own caller is
		# still owed exactly one callback.
		main::INFOLOG && $log->is_info
			&& $log->info("ignoring result from superseded sync $run->{id}");

		$run->{cb}->( { ok => 0, error => 'superseded' } );

		return;
	}

	%sync = (
		running  => 0,
		finished => time(),
		id       => $run->{id},
	);

	# The ownership pass, after the superseded check and before any pref is set
	# (§15.13 part 1). A superseded run must never reach it: a newer sync owns
	# the prefs and the guard, and it would own the badges too.
	#
	# This stays the single exit. The pass is one more condition on the
	# timestamp advancing, not a second way out: discogsLastSynced means
	# "ownership last derived", so it may not move for a sync whose conclusions
	# were never written.
	if ( $result->{ok} ) {
		require Plugins::SqueezeWax::Ownership;

		my $applied = Plugins::SqueezeWax::Ownership->apply(
			_testFilter( [ values %{ $run->{entries} || {} } ] ) );

		if ( $applied ne 'ok' ) {
			$result = { ok => 0, error => $applied };
		}
	}

	if ( $result->{ok} ) {
		$prefs->set( 'discogsLastSynced',    time() );
		$prefs->set( 'discogsLastSyncItems', $result->{items} );
		$prefs->set( 'discogsLastSyncError', '' );
	}
	else {
		$prefs->set( 'discogsLastSyncError', $result->{error} );
	}

	$run->{cb}->($result);

	return;
}

1;
