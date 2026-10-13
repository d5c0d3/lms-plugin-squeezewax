package Plugins::SqueezeWax::Derive;

# The master arm's backfill: build-order step 8c group A, decisions §15.22.
#
# WHY THIS EXISTS. Design §3 node F badges an album whose release the user does
# not own but whose MASTER they do - own one pressing, rip another. It compares
# discogs_match.discogs_master_id, which is written in exactly two places
# (Match.pm's _recordMatch and recordManual) and in both from a
# DISCOGS_MASTER_ID-family TAG (Tags.pm's _masterId). Nothing resolved a release
# id to its master. So on the reference library that column was NULL on all but 2
# of 506 rows, node F had never once fired, and every one of the 50 `version`
# badges came from the title route - §15.19. Albums the owner demonstrably owns
# were reported `absent` and sent to the review queue to adjudicate a question
# their own collection already answered.
#
# This job asks Discogs for the master of each identified release, once, and
# writes it to derived_master_id (migration 6). Node F reads it.
#
# WHAT IT STORES, AND WHY THAT IS THE WHOLE OF §9.5. One integer per release.
# §9.5 puts a bare identifier in the same class as the release id already in
# discogs_match - "not Content in any meaningful sense. Unconstrained; kept
# indefinitely" - and forbids everything else a /releases/{id} response carries.
# So the response is read in memory, master_id is taken out of it, and the
# response is dropped. No title, no artist, no tracklist, no payload, and
# discogs_release_cache stays unwritten (§9.5's stated consequence, restated in
# the errata to §15.20). scripts/derive-check.pl asserts that rather than
# trusting it: three columns written, nothing else, no string anywhere near the
# database.
#
# WHY IT IS NOT WHAT §13.8 REFUSED. §13.8 replaced per-album Discogs searches
# with collection-first ownership - 4 requests for 203 items against 764. This is
# a per-release lookup, which is that shape, so the difference is argued rather
# than assumed (plan §5): once per release EVER rather than once per sync;
# bounded by identified albums rather than by the library; what is kept is a bare
# identifier, so it is never re-fetched to stay fresh; and it buys what
# collection-first cannot - the collection names the masters the user owns, and
# nothing in it gives the master of a release they do NOT own, which is exactly
# node F's question. Measured: 475 requests, 11.0 minutes, on a cold library of
# this size; zero on a settled one.
#
# WHY IT IS A MODULE OF ITS OWN. Not API/Async.pm, which is the collection client
# and long enough already. Not the ownership pass, which must stay request-free
# (§15.4). Not the scanner, which has no event loop (scanner.pl:498,
# `sub idleStreams {}`) and whose sync is bounded at 120 s by §15.18 part 10,
# against a job that is 11 minutes cold.
#
# WHAT IT NEVER DOES. It does not identify, does not snapshot, does not touch
# ownership, state, match_tier or review_reason, and does not write
# discogs_master_id - that column stays tag-only, because a tag is the user's
# assertion and ours never silently overwrites it (§15.22).

use strict;

use Slim::Music::Import;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::SqueezeWax::API;
use Plugins::SqueezeWax::Match;
use Plugins::SqueezeWax::Schema;

my $log   = logger('plugin.squeezewax');
my $prefs = preferences('plugin.squeezewax');

# Half Discogs' documented 60 a minute (§9.2), which leaves the other half for a
# manual sync pressed while this is running. One request a second, thirty of
# them, then the run ends and a fresh one is armed a minute later if work remains
# (§15.22). 475 releases is about sixteen runs.
#
# The per-run cap is not a rate limit - SPACING is. It exists so that a run has a
# bounded end: every stop condition below is checked once per request, and a run
# that could last for hours would be a run that checked them stale.
use constant PER_RUN => 30;
use constant SPACING => 1;
use constant REARM   => 60;

# A run that has not finished in this long is treated as dead, so a wedged run
# cannot block every future trigger for the life of the server. The same
# belt-and-braces shape, and the same reasoning, as API::Async's SYNC_TIMEOUT and
# Settings.pm's %detection guard. Generous: PER_RUN requests can each wait out a
# full rate window.
use constant RUN_TIMEOUT => 3600;

# The run in flight, or an empty hash. Module-level, server-process only, and
# deliberately not a pref: it is transient, and a "running" flag that survived a
# restart would be a lie that blocks the feature.
#
# `id` is what makes a superseded run harmless - an in-flight HTTP request cannot
# be cancelled and will still call back, so _handle compares the id it was
# started with against the current one, exactly as API::Async::_finish does.
my %run;
my $runId = 0;

# ---------------------------------------------------------------------------
# The one public entry point.
# ---------------------------------------------------------------------------

=head2 arm( )

Start deriving masters for identified releases that have none yet, if there is
anything to derive and this is a good moment to do it. Returns 1 if a run
started, 0 otherwise.

Called from C<Plugins::SqueezeWax::Plugin> when a collection sync has completed -
see that file for the two places, and why there are two. Never from a timer of
its own making except to continue or resume a run this one started.

=cut

sub arm {
	my ($class) = @_;

	# Whatever the caller thought, only one run at a time. A second trigger while
	# a run is in flight is not an error - it means the trigger did its job and
	# something else got there first.
	if ( $class->isRunning ) {
		main::INFOLOG && $log->is_info
			&& $log->info('a master derive run is already in flight; not starting a second');

		return 0;
	}

	if ( $run{running} ) {
		# isRunning said no while the flag says yes: the staleness backstop
		# fired. Same handling as API::Async::sync's equivalent - warn, and start
		# fresh rather than staying blocked forever.
		$log->warn('a previous master derive run appears to have died; starting a new one');
	}

	my $token = $prefs->get('discogsToken');

	if ( !defined $token || $token eq '' ) {
		# Not logged. A server with no token has no collection, so it has no
		# badges to fix, and the sync that would have triggered this has already
		# said everything there is to say about the token.
		return 0;
	}

	# Nothing to do. THE NORMAL CASE on a settled library, and the reason this
	# job makes no request at all most of the time: one query, no network, done.
	# §15.15 part 1's rule that this plugin makes no unattended call to Discogs on
	# a schedule survives because the work is bounded by a library that only a
	# scan changes.
	my $pending = _pending();

	if ( !defined $pending ) {
		main::INFOLOG && $log->is_info
			&& $log->info('nothing to derive: every identified release already has an answer');

		return 0;
	}

	%run = (
		running  => 1,
		started  => time(),
		id       => ++$runId,
		token    => $token,
		requests => 0,
		derived  => 0,
		none     => 0,
	);

	main::INFOLOG && $log->is_info
		&& $log->info( "deriving masters: up to " . PER_RUN . " releases this run, "
			. "starting at release $pending" );

	_fetch( $run{id}, $pending );

	return 1;
}

=head2 isRunning( )

Is a derive run in flight? Carries the staleness backstop, so a run that died
without clearing the flag cannot block every future trigger forever.

=cut

sub isRunning {
	my ($class) = @_;

	return 0 unless $run{running};

	return 0 if ( time() - ( $run{started} || 0 ) ) >= RUN_TIMEOUT;

	return 1;
}

=head2 abort( )

Cancel a pending scheduled request and forget the run. Only the waiting is
cancellable: a request already handed to SimpleAsyncHTTP will still complete and
still call back, which is what the run id is for.

=cut

sub abort {
	my ($class) = @_;

	Slim::Utils::Timers::killTimers( undef, \&_fire );
	Slim::Utils::Timers::killTimers( undef, \&_rearm );

	%run = ( running => 0, finished => time(), id => $run{id} );

	return;
}

# ---------------------------------------------------------------------------
# Selection.
# ---------------------------------------------------------------------------

# The next release to ask about, or undef when there is nothing left.
#
# Not a list fetched once. Re-queried per request, for two reasons: a row whose
# tags changed while this run was in flight becomes selectable and should be
# picked up rather than waiting for the next run, and a release this run has
# already settled is excluded by the same predicate that excludes one settled a
# month ago - so there is no in-memory bookkeeping to get wrong. The cost is one
# indexed-free scan of ~500 rows per request, against a request that takes a
# second by design.
#
# The predicate is §15.22's four states read as two questions: has anything been
# recorded for this row at all, and does what was recorded still describe the
# release the tags now name. A row that was looked at and had NO master has
# derived_from_release_id set and derived_master_id NULL, and is therefore NOT
# selected - which is the whole reason that state is storable, and without it the
# 29 masterless releases on the reference library and the 3 whose releases Discogs
# has deleted would be re-fetched on every run forever.
#
# DISTINCT and ordered. Distinct because several albums can name one release -
# one 2-LP set filed as two LMS albums is the measured case - and one fetch
# settles all of them. Ordered so a run is reproducible and a resumed run picks up
# where the last left off rather than wherever the query planner felt like.
#
# Rows carrying a tag-derived master are NOT excluded. Node F prefers the tag
# (§15.22), so the answer is unused where one exists - but there were 2 such rows
# in 506 on the reference library, so the saving is nothing and the query is
# simpler for it. A row whose tags name a master AND whose release id changes
# would otherwise also have to be reasoned about twice.
# The predicate above, named once. _pending selects with it and the settings
# page counts with it (build-order step 9 §4.2); a second copy of it on the page
# would be a status line that could disagree with the job it describes - saying
# nothing is left while the job goes on fetching, or the reverse.
my $IDENTIFIED = q{discogs_release_id IS NOT NULL};

my $UNSETTLED = q{( derived_from_release_id IS NULL
		      OR derived_from_release_id <> discogs_release_id )};

sub _pending {
	my ($release) = Slim::Schema->dbh->selectrow_array(qq{
		SELECT DISTINCT discogs_release_id
		  FROM squeezewax.discogs_match
		 WHERE $IDENTIFIED
		   AND $UNSETTLED
		 ORDER BY discogs_release_id
		 LIMIT 1
	});

	return $release;
}

=head2 progress( )

What the settings page says about this job: C<< { done, total, pending } >> in
releases, or nothing when there is nothing to do.

Distinct releases, not rows, because that is the unit the job works in - several
albums can name one release, and one fetch settles all of them.

One query, and no state of its own: the numbers are read from the same rows
C<_pending> selects from, so a run that died still counts as unfinished work
rather than as progress that stopped being reported. Nothing here issues a
request.

Without this, ownership changes for up to 25 minutes after a scan with nothing
on screen to say why (decisions §15.23, §15.25 ruling 7).

=cut

sub progress {
	my ($class) = @_;

	my ( $total, $pending ) = Slim::Schema->dbh->selectrow_array(qq{
		SELECT COUNT(DISTINCT discogs_release_id),
		       COUNT(DISTINCT CASE WHEN $UNSETTLED THEN discogs_release_id END)
		  FROM squeezewax.discogs_match
		 WHERE $IDENTIFIED
	});

	$total   ||= 0;
	$pending ||= 0;

	return undef unless $pending;

	return {
		total   => $total,
		pending => $pending,
		done    => $total - $pending,
	};
}

# ---------------------------------------------------------------------------
# Pacing, and the three ways a run yields.
# ---------------------------------------------------------------------------

# Why this run may not issue its next request, or undef when it may.
#
# A pure function of the three conditions, for the reason Match::_writeRefusal is
# one: the conditions themselves are process state that a suite would have to
# fake, while the POLICY over them is what actually has to be right, and it can
# then be asserted directly (CLAUDE.md: branch on data, not on process).
#
# 'scan' first. A scan holds the write lock, so the write at the end of a
# request would be refused anyway (Match::_writeOk) - and paying a Discogs
# request to then throw the answer away is the one outcome worth ordering the
# checks to avoid.
sub _yieldReason {
	my ( $scanning, $syncing, $rateWait, $requests ) = @_;

	return 'a scan is running'          if $scanning;
	return 'a collection sync is running' if $syncing;
	return 'the rate budget is spent'   if $rateWait;
	return 'this run has had its share' if $requests >= PER_RUN;

	return undef;
}

# The live conditions behind _yieldReason. Separate so the policy above stays
# testable without stubbing three modules.
sub _yieldNow {
	require Plugins::SqueezeWax::API::Async;

	return _yieldReason(
		Plugins::SqueezeWax::Match->_writeOk ? 0 : 1,
		Plugins::SqueezeWax::API::Async->isRunning ? 1 : 0,
		Plugins::SqueezeWax::API->rateWait ? 1 : 0,
		$run{requests} || 0,
	);
}

# Should this run be continued a minute from now?
#
# Only for a PACING stop - the per-run cap, a sync in flight, a spent budget.
# Those are stops where work provably remains and the cause is a minute old at
# most, so re-arming is how the run resumes.
#
# NOT for a scan, and NOT for an error. A scan ends in ['rescan','done'], which
# brings a sync, which triggers this job again; re-arming through a two-hour scan
# would be a timer loop that achieves nothing. An error - a 401, a 500, a
# connection that dropped - waits for the next completed sync too, because a
# minute is not long enough for anything to have changed and this plugin does not
# poll a third party on a schedule of its own (§15.15 part 1).
my %REARM_ON = map { $_ => 1 } (
	'a collection sync is running',
	'the rate budget is spent',
	'this run has had its share',
);

# ---------------------------------------------------------------------------
# One release.
# ---------------------------------------------------------------------------

sub _fetch {
	my ( $id, $release ) = @_;

	return unless ( $run{id} || 0 ) == $id;

	if ( my $why = _yieldNow() ) {
		return _stop( $id, $why );
	}

	_fire( undef, $id, $release );

	return;
}

# Slim::Utils::Timers::setTimer( $obj, $when, $coderef, @args ) calls
# $coderef->( $obj, @args ) (refs/slimserver/Slim/Utils/Timers.pm:66-90). $obj is
# undef because no client is involved - the convention
# Slim/Plugin/OnlineLibrary/Plugin.pm:122-138 uses for a server-wide timer, and
# what makes killTimers(undef, \&_fire) able to cancel it.
sub _fire {
	my ( undef, $id, $release ) = @_;

	return unless ( $run{id} || 0 ) == $id;

	$run{requests}++;

	my ( $url, @headers ) = Plugins::SqueezeWax::API->buildRequest(
		"/releases/$release", {}, $run{token} );

	# One callback for both outcomes, and the response carried separately on the
	# error path - API/Async.pm's _fire has the whole argument, which is
	# load-bearing here too: a 404 is an ORDINARY outcome for this job (§15.21),
	# and onError sets neither code nor headers on the SimpleAsyncHTTP object
	# (SimpleAsyncHTTP.pm:76-101) while passing the HTTP::Response as its third
	# argument (:96). Reading only $http->code would classify every 404 as a
	# dropped connection and the three deleted releases would be retried forever.
	my $done = sub {
		my ( $http, undef, $response ) = @_;

		_handle( $http, $id, $release, $response );
	};

	Slim::Networking::SimpleAsyncHTTP->new( $done, $done, { timeout => 15 } )
		->get( $url, @headers );

	return;
}

sub _handle {
	my ( $http, $id, $release, $response ) = @_;

	if ( ( $run{id} || 0 ) != $id ) {
		# A superseded run's in-flight request came back. It may not write and it
		# may not schedule: a newer run owns both.
		main::INFOLOG && $log->is_info
			&& $log->info("ignoring the result of a superseded derive run $id");

		return;
	}

	my $code    = $http->code;
	my $content = $http->content;
	my $headers = $http->headers;

	if ( !defined $code && $response ) {
		$code    = $response->code;
		$content = $response->content;
		$headers = $response->headers;
	}

	my $result = Plugins::SqueezeWax::API->classifyResponse( $code, $content );

	# The shared budget (§15.22), for every response whatever it returned.
	Plugins::SqueezeWax::API->noteResponse(
		Plugins::SqueezeWax::API::_parseRateHeaders($headers), time() );

	my $error = $result->{ok} ? '' : ( $result->{error} || 'unknown' );

	# 404: THE RELEASE IS GONE, and that is an ordinary answer (§15.21, measured
	# on 3 of 479 identified albums). Info, not error, and recorded as "looked,
	# and there is no master" so it is never asked again until the tags change.
	# Anything else and this row would be re-fetched on every run for the life of
	# the library.
	if ( $error eq 'not_found' ) {
		main::INFOLOG && $log->is_info
			&& $log->info("release $release is no longer on Discogs; recording that it has no master");

		return _wrote( $id, $release, undef, 'none' );
	}

	# A rejected token stops the run and says nothing. It is the sync's to
	# report, at error level, and it will (§15.15 part 2, §15.18 part 4); a second
	# error line from a background job the user did not ask for would bury it.
	# Not re-armed: nothing a minute from now changes a rejected token.
	if ( $error eq 'unauthorized' ) {
		return _stop( $id, 'Discogs rejected the token' );
	}

	# Anything else - a 429 that outlived the throttle, a 500, a dropped
	# connection, a body that will not parse. The row is left UNTOUCHED, so the
	# next run selects it again and retries; nothing is recorded, because "we
	# looked and there is no master" is a conclusion and this is not one.
	if ($error) {
		$log->warn("could not derive the master of release $release: $error");

		return _stop( $id, "the last request failed ($error)" );
	}

	# The ONLY field taken from the response. Everything else it carries - the
	# title, the credited artists, the tracklist - is Content and is dropped with
	# the response when this sub returns (§9.5).
	my $master = ( ref $result->{data} eq 'HASH' ) ? $result->{data}->{master_id} : undef;

	# 0 and absent collapse to "no master", matching Match::recordManual's guard
	# and Ownership::_indexCollection's: Discogs reports a release with no master
	# as master_id 0, and a response that omits the field leaves it undef. Either
	# taken at face value would make every masterless release collide on one key
	# at node F.
	$master = undef if defined $master && $master == 0;

	return _wrote( $id, $release, $master, defined $master ? 'derived' : 'none' );
}

# Write the answer and move on - or, if the write was refused, end the run rather
# than asking Discogs the same question again.
#
# _yieldNow tested for a scan before the request, so a refusal here means one
# started in the second since. Without this the selection query would hand back
# the same release on the next turn (nothing was recorded) and the run would
# spend all PER_RUN requests re-asking one question whose answer it cannot keep.
# No re-arm: the scan ends in ['rescan','done'], which brings a sync, which
# triggers this job.
sub _wrote {
	my ( $id, $release, $master, $outcome ) = @_;

	return _stop( $id, 'a scan is running' ) unless defined _record( $release, $master );

	return _next( $id, $outcome );
}

# ---------------------------------------------------------------------------
# The write. Three columns, nothing else, ever.
# ---------------------------------------------------------------------------

# Every row naming this release, because one fetch settles all of them: a 2-LP
# set filed as two LMS albums is the measured case, and asking twice for one
# answer is the cost this avoids.
#
# derived_from_release_id is written from the SAME value the WHERE clause matched
# on, which is what makes the staleness test at node F meaningful: the pair says
# "this master is the master of THAT release", and if the row's release id later
# changes the pair stops matching and node F ignores it (§15.22).
#
# THREE COLUMNS, and this is the only statement in the plugin that names them.
# Nothing Content-shaped can reach the database from here because nothing
# Content-shaped is in the statement: two integers and a timestamp, and
# derive-check.pl asserts that the row is otherwise byte-identical afterwards.
# discogs_release_cache is not written, here or anywhere (§9.5).
sub _record {
	my ( $release, $master ) = @_;

	# The write is refused during a scan (Match::_writeOk). _yieldNow checked
	# that before the request, so reaching here with a scan running means one
	# started in the second since - the answer is dropped and the next run asks
	# again, which costs one request and cannot corrupt anything.
	return undef unless Plugins::SqueezeWax::Match->_writeOk;

	my $rows = Slim::Schema->dbh->do(
		q{UPDATE squeezewax.discogs_match
		     SET derived_master_id = ?, derived_from_release_id = ?, derived_at = ?
		   WHERE discogs_release_id = ?},
		undef, $master, $release, time(), $release
	);

	# undef is REFUSED and 0 is "no row names this release any more" - a row
	# rewritten by a scan between the selection and now. They are different
	# answers: the first ends the run, the second is a release that has simply
	# stopped mattering and the run carries on to the next one.
	return ( $rows && $rows > 0 ) ? $rows : 0;
}

# ---------------------------------------------------------------------------
# Run control.
# ---------------------------------------------------------------------------

# One release settled. Pace the next one a second out, or end the run.
sub _next {
	my ( $id, $outcome ) = @_;

	return unless ( $run{id} || 0 ) == $id;

	$run{$outcome}++;

	if ( my $why = _yieldNow() ) {
		return _stop( $id, $why );
	}

	my $release = _pending();

	return _stop( $id, 'every identified release now has an answer' )
		unless defined $release;

	# SPACING between requests, as a timer and never a sleep: LMS is
	# single-threaded and the server process must not block (CLAUDE.md).
	Slim::Utils::Timers::setTimer( undef, time() + SPACING, \&_fire, $id, $release );

	return;
}

# The single exit, for the reason API::Async::_finish is one: whether a run is
# re-armed is one rule in one place rather than a convention every branch has to
# keep.
sub _stop {
	my ( $id, $why ) = @_;

	return unless ( $run{id} || 0 ) == $id;

	my $rearm = $REARM_ON{$why} ? 1 : 0;

	main::INFOLOG && $log->is_info
		&& $log->info( "master derive run $id ended: $why"
			. " (derived $run{derived}, no master $run{none}, $run{requests} requests)"
			. ( $rearm ? ', resuming in ' . REARM . 's' : '' ) );

	%run = ( running => 0, finished => time(), id => $id );

	if ($rearm) {
		# killTimers first, every time: Slim::Utils::Timers keys pending timers by
		# ($coderef, $obj) and setTimer appends rather than replaces
		# (Slim/Utils/Timers.pm:66-120), so arming without killing is how a
		# self-rescheduling timer silently doubles its own frequency. The idiom is
		# Plugin::_scheduleSync's, for the same reason.
		Slim::Utils::Timers::killTimers( undef, \&_rearm );
		Slim::Utils::Timers::setTimer( undef, time() + REARM, \&_rearm );
	}

	return;
}

sub _rearm {
	__PACKAGE__->arm;

	return;
}

1;
