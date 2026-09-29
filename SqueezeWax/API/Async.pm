package Plugins::SqueezeWax::API::Async;

# Server-side Discogs client: the collection sync (build-order step 5). One of
# two since step 8b - API/Sync.pm is the other, the fetch the scanner makes
# inside our own scan step. The split is not a preference: there is no event
# loop in the scanner (scanner.pl:498, `sub idleStreams {}`), so a timer never
# fires there and SimpleAsyncHTTP cannot complete (decisions §15.18, "Verified
# in this session"). Since §15.18 part 5 this path is the FALLBACK after
# ['rescan','done'] for scans our importer did not run, plus the manual button.
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
# after all - by the pass, never by this module. The scan-time path hands the
# pass its list the same way (§15.18 part 1); Ownership::apply is one matching
# path called from two fetches.

use strict;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::SqueezeWax::API;
use Plugins::SqueezeWax::Schema;

my $log   = logger('plugin.squeezewax');
my $prefs = preferences('plugin.squeezewax');

# The rate-limit state used to live here, as `my $rateState` and `my $rateWait`.
# It moved to API.pm at build-order step 8c (decisions §15.22), unchanged in
# behaviour: step 8c adds Derive.pm as a second server-side consumer of the same
# Discogs budget, and two independent throttles against one budget is how a 429
# arrives that nobody can explain. This file now reads API->rateWait before a
# request and calls API->noteResponse after one; the decision about what a
# response means for the budget was always API.pm's, and now the memory of it is
# too.

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
# refs/lms-plugin-tidal/Plugin.pm:60-66). One of the two triggers this guard
# exists to serialise, ['rescan','done'], is server-wide and must work on a
# headless server, which never loads Settings.pm at all - decisions §15.12 part
# 3, the same trap Plugin.pm's own $prefs->migrate comment records. The guard
# belongs with the thing it guards. (There were three triggers until §15.15
# part 1 removed the interval timer.)
#
# It does NOT serialise the scan-time sync (decisions §15.18). That one runs in
# the scanner, a separate process this flag cannot see; the two cannot overlap
# on the database anyway, because the server path's pass is refused while a
# scan holds the write lock (Match::_writeOk).
#
# `id` is what makes a superseded run harmless: a stale run's in-flight HTTP
# request cannot be cancelled and will still call back, so _finish compares the
# id it was started with against the current one and declines to touch shared
# state if they differ.
my %sync;
my $syncId = 0;

# Set when Discogs rejects the token, cleared when the token changes or a manual
# sync succeeds (§15.15 part 2). While it is set, scan-triggered syncs are
# skipped: retrying a token Discogs has rejected cannot succeed, and the only
# thing a retry produces is another error line in the log.
#
# It governs the SERVER FALLBACK ONLY (decisions §15.18 part 4). The scan-time
# sync runs in a fresh scanner process each scan and has nowhere to keep a
# pause, so a 401 there is logged and retried at the next scan, as a timeout
# is - it answers instantly and costs the scan nothing. §15.17 part 4's notice
# on the queue page describes this flag, so it describes the fallback, which is
# exactly what it says.
#
# In memory, not a pref. It describes this server's last conversation with
# Discogs, not the user's configuration, and a restart is a perfectly good
# reason to try once more. `logged` keeps the skip quiet after the first one -
# §14.2 wants the failure visible, not repeated.
#
# This is a STATED EXCEPTION to §15.2 obligation 1: a sync skipped here is
# dropped, not kept pending. A pass whose WRITE was refused - a scan running
# under it - still stays pending for the next notification, which is a different
# case and unchanged.
my %rejected = ( token => 0, logged => 0 );

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
#
# "Last synced" is the marker in discogs_sync_state, which both paths write
# (decisions §15.18 part 7), not a pref: the scanner cannot persist a pref
# (Slim/Utils/Prefs/Namespace.pm:303), so a pref would go stale on a server
# whose scan-time sync works perfectly. The key names are the ones the page
# already reads. An absent row - never synced, or a database that is not ready -
# is lastSynced 0, which is the value the template tests.
#
# lastError stays a pref. It is the server's alone: a scan-time failure is
# logged only (§15.18 part 3) and never reaches the page.
#
# lastSource is returned and not displayed; a display of it is v2.
sub status {
	my ($class) = @_;

	my $marker = Plugins::SqueezeWax::Schema->syncState;

	return {
		running    => $class->isRunning ? 1 : 0,
		lastSynced => $marker ? $marker->{last_synced} : 0,
		lastItems  => $marker ? $marker->{items}       : undef,
		lastSource => $marker ? $marker->{source}      : undef,
		lastError  => $prefs->get('discogsLastSyncError'),
	};
}

=head2 tokenRejected( )

True while Discogs has rejected the token and no manual sync has succeeded
since. Scan-triggered syncs consult this; the manual button does not.

=cut

sub tokenRejected {
	my ($class) = @_;

	return $rejected{token} ? 1 : 0;
}

=head2 noteSkipped( )

Record that a scan-triggered sync was skipped, and report whether this is the
first one, so the caller logs once rather than once per scan.

=cut

sub noteSkipped {
	my ($class) = @_;

	return 0 if $rejected{logged};

	$rejected{logged} = 1;

	return 1;
}

=head2 clearTokenRejected( )

Forget a rejection. Called when the token pref changes (§15.15 part 3) and on
any sync that completes.

=cut

sub clearTokenRejected {
	my ($class) = @_;

	%rejected = ( token => 0, logged => 0 );

	return;
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

	# The shared budget (§15.22), so a derive run that spent the window defers
	# this page exactly as one of our own pages would have.
	my $rateWait = Plugins::SqueezeWax::API->rateWait;

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

	# One callback for both outcomes, as Settings.pm's _testToken does - but the
	# error path carries the response SEPARATELY, and the second argument here
	# is what this file got wrong until 2026-09-22.
	#
	# The old comment claimed an unset code "already means no_response". It does
	# not. refs/slimserver/Slim/Networking/Async/HTTP.pm:434-436 routes EVERY
	# status that is not 2xx or 3xx to _http_error, which reaches the error
	# callback; SimpleAsyncHTTP's onError sets neither code nor headers
	# (:76-101), while onBody sets both (:112-114) and then calls the SUCCESS
	# callback. So a 401, a 429, a 404 and a 500 all arrived here with no code
	# and were classified as a dropped connection - every branch of
	# classifyResponse below its !$code test was unreachable. §14.2 wanted a
	# rejected token to read differently from a dropped connection; instead
	# nothing could. The rate-limit back-off was dead the same way: the one
	# response it exists for, a 429, was the one it never saw (§15.15 part 2).
	#
	# onError passes the HTTP::Response as its third argument
	# (SimpleAsyncHTTP.pm:96), so the real status and the real headers are
	# there. A genuine connection failure has no response at all, which is how
	# no_response stays reachable and keeps meaning what it says.
	my $done = sub {
		my ( $http, undef, $response ) = @_;

		_handle( $http, $run, $path, $params, $next, $response );
	};

	Slim::Networking::SimpleAsyncHTTP->new( $done, $done, { timeout => 15 } )
		->get( $url, @headers );

	return;
}

sub _handle {
	my ( $http, $run, $path, $params, $next, $response ) = @_;

	# The success path sets both on $http; the error path sets neither and hands
	# the response over separately. Prefer whichever is actually populated, so
	# one classification serves both and no caller has to know which path it is
	# on. undef from both is a real no-response, and classifyResponse's !$code
	# branch still means exactly that.
	my $code    = $http->code;
	my $content = $http->content;
	my $headers = $http->headers;

	if ( !defined $code && $response ) {
		$code    = $response->code;
		$content = $response->content;
		$headers = $response->headers;
	}

	my $result = Plugins::SqueezeWax::API->classifyResponse( $code, $content );

	# Account for the request whatever it returned - a 429 costs budget too,
	# and an error response that carries no rate headers is precisely the case
	# accountRequest's degradation ladder exists for (API.pm §3.4).
	Plugins::SqueezeWax::API->noteResponse(
		Plugins::SqueezeWax::API::_parseRateHeaders($headers), time() );

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
		# is no longer ordinary pacing, and the right response is to fail this
		# sync rather than retry forever.
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
	$run->{path}     = Plugins::SqueezeWax::API::_collectionPath($username);

	main::INFOLOG && $log->is_info
		&& $log->info("collection sync starting for Discogs user $username");

	_get( $run, $run->{path}, Plugins::SqueezeWax::API::_collectionParams(1), \&_gotPage );

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
			: Plugins::SqueezeWax::API::_pageCount( $run->{items} );

		if ( $run->{pages} > Plugins::SqueezeWax::API::MAX_PAGES ) {
			# Checked here, on the first page, rather than after the loop: the
			# point of the bound is to not issue the requests, and a
			# self-contradictory pagination block should cost one request, not
			# MAX_PAGES of them against a rate-limited API.
			$log->warn( "collection reported $run->{pages} pages, more than the "
				. Plugins::SqueezeWax::API::MAX_PAGES
				. " this will fetch - treating this sync as failed" );

			return _fail( $run, { ok => 0, error => 'too_many_pages' } );
		}
	}

	# Collected, and dropped on the floor when _finish returns. Nothing about a
	# release reaches the database (§13.2). Built by API.pm's entryFromRelease,
	# which the scan-time fetch shares (§15.18 part 15); keyed by instance_id,
	# the collection ENTRY's identity - see entryFromRelease for why that must
	# not de-duplicate.
	for my $release ( @{ ( $data && $data->{releases} ) || [] } ) {
		my $entry = Plugins::SqueezeWax::API->entryFromRelease($release) or next;

		$run->{entries}{ $entry->{instance_id} } = $entry;
	}

	$run->{counted} = scalar keys %{ $run->{entries} };

	if ( $run->{page} < $run->{pages} ) {
		$run->{page}++;

		_get( $run, $run->{path},
			Plugins::SqueezeWax::API::_collectionParams( $run->{page} ), \&_gotPage );

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

# The single exit. Every path out of a sync comes through here, which is what
# makes "never partially advance the timestamp for a sync that didn't complete"
# (§13.7/§14.2) one rule in one place rather than a convention each caller has
# to keep.
#
# The marker (discogs_sync_state, §15.18 part 7) advances on success and only on
# success, and only after the pass has written - here that means after apply
# has committed, since the server's handle is AutoCommit. A failure records its
# error - the settings page needs something to show, and §14.2 wants a rejected
# token to be distinguishable from a dropped connection - but leaves the marker
# from the last good sync exactly as it was. A transient failure must not make a
# working collection look like it vanished.
#
# Which log level is the caller's decision, not this one's: only the caller
# knows whether a failure followed a button press the user is watching or the
# unattended fallback after a scan.
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
	# marker advancing, not a second way out: the marker means "ownership last
	# derived", so it may not move for a sync whose conclusions were never
	# written.
	# Hoisted out of the ->apply call it used to be built inside, because the
	# page gets this same list and it must be the SAME one: _testFilter's whole
	# safety argument is that a release hidden from the pass is hidden
	# everywhere the pass's conclusions are visible, and a re-match list that
	# offered a release the pass could not see would let the user link an album
	# to a record that then refuses to badge, with nothing to say why.
	my $entries;

	if ( $result->{ok} ) {
		require Plugins::SqueezeWax::Ownership;

		$entries = Plugins::SqueezeWax::API::_testFilter( [ values %{ $run->{entries} || {} } ] );

		my $applied = Plugins::SqueezeWax::Ownership->apply($entries);

		if ( $applied ne 'ok' ) {
			$result = { ok => 0, error => $applied };
		}
	}

	# The rejection flag is set and cleared here, at the single exit, for the
	# same reason the timestamp is: one rule in one place rather than a
	# convention each caller has to keep. A sync that got far enough to write
	# ownership proves the token works, whatever triggered it.
	if ( ( $result->{error} || '' ) eq 'unauthorized' ) {
		$rejected{token} = 1;
	}
	elsif ( $result->{ok} ) {
		%rejected = ( token => 0, logged => 0 );
	}

	if ( $result->{ok} ) {
		# source 'server': the fallback's skip rule reads it, and a server sync
		# must never suppress a fallback (§15.18 part 8).
		#
		# A lost marker is logged and does not fail the sync. The pass has
		# already committed, so the badges are right; what is lost is the page's
		# timestamp, and the skip rule only ever skips on a 'scan' marker, so it
		# errs toward syncing whatever happens here.
		eval { Plugins::SqueezeWax::Schema->recordSync( $result->{items}, 'server' ); 1 }
			or $log->error( 'ownership was derived but the sync marker was not written: '
				. ( $@ || 'unknown error' ) );

		$prefs->set( 'discogsLastSyncError', '' );
	}
	else {
		$prefs->set( 'discogsLastSyncError', $result->{error} );
	}

	# The second argument, and only here. The other three callback sites -
	# no_token (:225), already_running (:233) and superseded (:680) - pass one
	# argument, because none of them has a list and two of them never issued a
	# request.
	#
	# Only when the FINAL result is ok, which means after the pass has also
	# succeeded: a pass that declined rewrote $result above, and a page that
	# rendered a re-match list from a sync whose conclusions were never written
	# would be offering choices against a badge state that does not exist yet.
	# A pass refusal reaches the page as its existing 'refused' error, which the
	# settings page already has a string for.
	#
	# Nothing is stored and nothing is logged from it. It is dropped when the
	# callback returns - the same lifetime §15.13 part 1 gives the pass, now
	# shared with one render (§15.16 part 6).
	$run->{cb}->( $result, $result->{ok} ? $entries : () );

	return;
}

1;
