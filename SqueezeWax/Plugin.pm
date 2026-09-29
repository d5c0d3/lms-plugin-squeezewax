package Plugins::SqueezeWax::Plugin;

use strict;

use base qw(Slim::Plugin::Base);

use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::SqueezeWax::Schema;

# WARN, matching Importer.pm's registration of the same category and both
# reference plugins (refs/lms-plugin-tidal/Plugin.pm:18-22).
#
# Step 2 used INFO because our own handful of lines were the only evidence of a
# healthy run. That stopped being true once the importer had a row in the scan
# progress UI and LMS's own "Starting/Completed ... Scan" pair in scanner.log
# (Slim/Music/Import.pm:578, :710-712) - neither of which needs the category
# turned up. The one thing those cannot report, "examined 4,800, identified 0",
# is escalated to warn by the importer itself.
my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.squeezewax',
	description  => 'PLUGIN_SQUEEZEWAX_NAME',
	defaultLevel => 'WARN',
});

my $prefs = preferences('plugin.squeezewax');

# discogsMaxTier is gone (decisions §15.8); drop it from existing prefs files.
# File scope, not initPlugin and not under main::WEBUI: the WEBUI block below is
# the only place Settings.pm is loaded, so a migration there would never run on
# a headless server (decisions §15.12 part 3). The scanner never loads this file
# (Slim/Utils/PluginManager.pm:204), so one process writes the prefs file. Same
# pattern as Slim/Plugin/Podcast/Plugin.pm:34-40. `remove` also drops the
# _ts_discogsMaxTier twin and saves (Slim/Utils/Prefs/Base.pm:242-258).
$prefs->migrate(1, sub { $_[0]->remove('discogsMaxTier'); 1 });

# discogsSyncInterval is gone with the scheduled sync (decisions §15.15 part 1);
# drop it from existing prefs files. Same pattern, same place and same reasoning
# as migrate(1) above.
$prefs->migrate(2, sub { $_[0]->remove('discogsSyncInterval'); 1 });

# discogsLastSynced and discogsLastSyncItems are gone: "last synced" is the
# marker row in discogs_sync_state, which both sync paths write (decisions
# §15.18 part 7). A pref could not be it - the scanner cannot persist one
# (Slim/Utils/Prefs/Namespace.pm:303). discogsLastSyncError stays a pref: it is
# the server's alone. Same pattern, place and reasoning as migrate(1).
$prefs->migrate(3, sub {
	$_[0]->remove('discogsLastSynced');
	$_[0]->remove('discogsLastSyncItems');
	1;
});

# A new token is a new chance (§15.15 parts 2 and 3). The last error and the
# rejection pause both describe the OLD token's last conversation with Discogs,
# and leaving either in place after the user has fixed the thing they describe
# is how a fixed server goes on looking broken - which is exactly how a stale
# `no_response` misled a reader of this project's own logs on 2026-09-22.
#
# File scope, like the migrations: the scanner never loads Settings.pm, and a
# headless server must clear these too. The callback signature is
# ( $prefname, $newvalue, ... ) - refs/slimserver/Slim/Utils/Prefs/Base.pm:91
# dispatches the onchange list registered by
# Slim/Utils/Prefs/Namespace.pm:148-164.
$prefs->setChange( sub {
	$prefs->set( 'discogsLastSyncError', '' );

	require Plugins::SqueezeWax::API::Async;
	Plugins::SqueezeWax::API::Async->clearTokenRejected;
}, 'discogsToken' );

# Collection-sync defaults (build-order step 5). File scope and not under
# main::WEBUI for the same reason as the migrations above: the sync runs on a
# headless server, which never loads Settings.pm, so its defaults cannot be
# established there.
#
# There is no interval pref. §15.15 part 1 removed the scheduled sync outright
# rather than giving it an off switch: a server plugin should not call a third
# party on its own schedule. The accepted cost is recorded there - a record
# added to the collection does not badge until the next scan or a press of the
# button, and staleness is silent.
#
# There is no last-synced pref either (§15.18 part 7). "Never synced" is an
# absent marker row, which API::Async->status turns into lastSynced 0 - still a
# value the template can test rather than a missing key.
$prefs->init({
	discogsLastSyncError => '',

	# A development aid, not a feature: a comma-separated list of Discogs
	# release ids that API.pm's _testFilter hides from the ownership
	# pass, so "a record left the collection" can be exercised without
	# altering anyone's collection. Empty on every normal install, no field on
	# the settings page, and every sync warns while it is set. Documented in
	# docs/dev-repo-workflow.md.
	discogsTestExcludeReleases => '',
});

# Long enough to absorb a duplicate ['rescan','done'] and let LMS settle after a
# scan, short enough that a user who rescans to pick up a new record does not
# wait noticeably for the badge. Not a measured figure.
use constant DEBOUNCE_AFTER_RESCAN => 60;

# The skip rule's window (decisions §15.18 part 8): when the last scan finished,
# and when the one before it did. _syncTick skips the fallback only for a 'scan'
# marker written between the two - "a sync happened during the scan that just
# finished". Server process only, and in memory: the scanner is another process
# and learns nothing from these, which is why the marker is a table row.
#
# $windowOpen is what makes "the previous rescan-done" mean the previous SCAN
# rather than the previous notification. A scan can notify two or three times
# (see _rescanDone), and a duplicate arriving 2 s after the first would
# otherwise shrink the window to those 2 s and miss a marker written during the
# scan - so a notification that arrives while a tick is still armed moves only
# the upper bound, exactly as it restarts the debounce rather than stacking a
# second sync. The tick closes the window when it runs.
my $lastRescanDone;
my $prevRescanDone;
my $windowOpen = 0;

sub initPlugin {
	my $class = shift;

	# Same rationale as Importer::initPlugin: proof this entry point ran.
	main::INFOLOG && $log->is_info
		&& $log->info( 'Plugin loaded (' . ( main::SCANNER ? 'scanner' : 'server' ) . ' process)' );

	Plugins::SqueezeWax::Schema->init();

	# After Schema->init and nowhere else: registering the handler forces the
	# reconnect that runs our migrations (Slim/Utils/SQLiteHelper.pm:396-400), so
	# discogs_meta exists by the time this reads it, and not before.
	_checkLogicVersion();

	_initSync();

	# Only the server has a web UI; the scanner never loads this file anyway
	# (Slim/Utils/PluginManager.pm:204). Guarded and required lazily as
	# refs/lms-plugin-tidal/Plugin.pm:60-66 does.
	if (main::WEBUI) {
		require Plugins::SqueezeWax::Settings;
		Plugins::SqueezeWax::Settings->new();
	}

	$class->SUPER::initPlugin(@_);
}

# The key discogs_meta holds the logic version under (decisions §15.24). One
# string, named once.
use constant LOGIC_VERSION_KEY => 'logic_version';

# Has the identification rule changed since these rows were written? Decisions
# §15.23 and §15.24.
#
# WHY IT EXISTS. Importer::_canSkip skips any album whose file mtimes have not
# changed, so an ordinary rescan re-examines nothing and a NEW RULE reaches only
# new and changed albums. Step 8c shipped its cross-track rule to a library where
# every existing identification was exempt from it, and album 3421 was badged as
# owned on tags the same build recorded as contested. The only lever that forced
# re-examination was Match->invalidateStrict, reachable solely as a side effect
# of editing the tag-name set on the settings page.
#
# So: a version for the rule (Tags.pm's LOGIC_VERSION), a copy stored beside the
# rows it describes, and this comparison at every server start.
#
# IT DOES NOT START A SCAN, deliberately. invalidateStrict NULLs source_timestamp
# and drops the strict no-match rows; the re-examination happens at the user's
# next scan, exactly as a tag-name change behaves today. A plugin that started a
# scan on the user's behalf would be a new behaviour of its own, and this is not
# the place to introduce one.
#
# Server only: this file is never loaded by the scanner
# (Slim/Utils/PluginManager.pm:204), and DDL and repair are the server's job
# there too (Schema::postDBConnect).
#
# Required lazily. Match.pm pulls in Library.pm and Slim::Music::Import; nothing
# else in this file needs either.
sub _checkLogicVersion {
	# Not "no version stored": unknowable. The plugin is inactive anyway
	# (Schema::postDBConnect has already logged why), and writing the marker now
	# would claim a re-examination that never happened. The next start retries.
	return unless Plugins::SqueezeWax::Schema->isReady;

	require Plugins::SqueezeWax::Match;
	require Plugins::SqueezeWax::Tags;

	my $current = Plugins::SqueezeWax::Tags::LOGIC_VERSION();
	my $stored  = Plugins::SqueezeWax::Schema->meta(LOGIC_VERSION_KEY);

	# A database written by a NEWER SqueezeWax. Say so once and change nothing:
	# its rows were decided by a rule this code does not have, and neither
	# invalidating them nor overwriting the marker with a lower number could
	# improve on that. Warn, not error - the plugin works, it is the downgrade
	# that is odd.
	if ( defined $stored && $stored > $current ) {
		$log->warn( "squeezewax.db was written by a newer SqueezeWax (identification "
			. "rule $stored, this one has $current); leaving its identifications alone" );

		return;
	}

	# A fresh install: no marker, and nothing has ever been concluded here. Record
	# the current version and say nothing. There is no re-decision to make, and an
	# invalidation line at a first start would describe work that did not happen.
	if ( !defined $stored && !Plugins::SqueezeWax::Match->hasAnyRow ) {
		Plugins::SqueezeWax::Schema->setMeta( LOGIC_VERSION_KEY, $current );

		return;
	}

	# An absent marker over existing rows means version 1 - everything written
	# before the marker itself existed, which on this project is everything up to
	# 0.0.0.12.
	my $from = defined $stored ? $stored : 1;

	return if $from == $current;

	my $rows = Plugins::SqueezeWax::Match->invalidateStrict;

	# REFUSED, not "nothing to do". invalidateStrict returns undef when _writeOk
	# says no - a scan is running, or the schema is not usable (Match.pm:105) -
	# and recording the version anyway would skip the invalidation FOREVER, which
	# is the bug this sub exists to fix with an extra step. Leave the marker
	# alone; the next start tries again.
	if ( !defined $rows ) {
		main::INFOLOG && $log->is_info
			&& $log->info( "the identification rule changed ($from -> $current) but the "
				. 'strict cache could not be invalidated now; will retry at the next start' );

		return;
	}

	main::INFOLOG && $log->is_info
		&& $log->info( "the identification rule changed ($from -> $current): "
			. "$rows rows invalidated; the next scan will re-examine the library" );

	Plugins::SqueezeWax::Schema->setMeta( LOGIC_VERSION_KEY, $current );

	return;
}

# One of §13.7's two triggers, as §15.15 part 1 leaves them. The other is the
# settings-page button, which lives in Settings.pm because that is the only one
# with a user attached; this one is here because it has to run on a headless
# server, which never loads Settings.pm (decisions §15.12 part 3).
#
# Since step 8b this trigger is the FALLBACK (decisions §15.18 part 5). The
# sync and the pass normally run inside the scan, from ScanSync; this path
# covers the scans our importer did not run - an in-process rescan, a
# `rescan album`, the auto-rescan - and a scan-time sync that failed.
#
# Nothing here decides whether to sync. _syncTick's checks do - the scan having
# already synced among them (§15.18 part 8) - and API/Async.pm's guard makes a
# rescan finishing while a manual sync is already running cost one sync, not
# two.
#
# NO TIMER IS ARMED HERE. There is no startup sync and no interval (§15.15 part
# 1): a fresh install syncs for the first time at the first finished scan, or
# when the user presses the button. That is a recorded consequence, not an
# oversight - see TODO.md, 2026-09-22.
sub _initSync {
	# Before the first rescan-done of this server's life the window's lower
	# bound is now, which refuses to skip on a marker left by a previous run
	# (§15.18 part 8): that scan's rescan-done was never seen here.
	$lastRescanDone = time();
	$prevRescanDone = $lastRescanDone;
	$windowOpen     = 0;

	# Keyed by the stringified coderef (refs/slimserver/Slim/Control/Request.pm:
	# 788-809, %listeners), so subscribing the same named sub twice replaces its
	# own entry rather than adding a second. A re-initPlugin cannot double this
	# up - unlike the timer below, which needs a kill first.
	#
	# [['rescan'], ['done']] is the in-tree arg shape, used by seven core
	# subscribers including Slim/Music/Import.pm:789 and
	# Slim/Utils/AutoRescan.pm:112. Completion, not start: decisions §15.2
	# corrects §13.7 on this - there is nothing to compare a collection against
	# until the library scan has finished writing it.
	Slim::Control::Request::subscribe( \&_rescanDone, [ ['rescan'], ['done'] ] );

	return;
}

# The debounce. A scan can emit ['rescan','done'] more than once - Import.pm
# notifies from two places (:238 and :741), and the external-scanner cleanup
# path can fire one of its own - and each arrival restarts the wait rather than
# stacking a second sync behind the first.
#
# The wait also exists for its own sake: a sync immediately after a scan would
# contend with LMS still settling, and nothing about the answer is urgent.
#
# It also records the skip rule's window - see $windowOpen above for why a
# duplicate notification moves only the upper bound.
sub _rescanDone {
	$prevRescanDone = $lastRescanDone unless $windowOpen;
	$lastRescanDone = time();
	$windowOpen     = 1;

	main::INFOLOG && $log->is_info
		&& $log->info('library scan finished; scheduling a fallback collection sync');

	_scheduleSync(DEBOUNCE_AFTER_RESCAN);

	return;
}

# Arm the next sync, replacing any already armed.
#
# killTimers first, every time: Slim::Utils::Timers keys pending timers by
# ($coderef, $obj) and setTimer appends rather than replaces
# (refs/slimserver/Slim/Utils/Timers.pm:66-120), so arming without killing is
# how a self-rescheduling timer silently doubles its own frequency. This is the
# idiom Slim/Plugin/OnlineLibrary/Plugin.pm:122-138 uses for the same job - an
# interval poll in a plugin - where _pollOnlineLibraries' first statement is a
# killTimers of itself. $obj is undef because no client is involved, which is
# also what makes the kill able to find it.
sub _scheduleSync {
	my ($delay) = @_;

	Slim::Utils::Timers::killTimers( undef, \&_syncTick );
	Slim::Utils::Timers::setTimer( undef, time() + $delay, \&_syncTick );

	return;
}

# The debounced tick - the fallback's (§15.18 part 5). Reached only from
# _rescanDone (§15.15 part 1 removed the interval re-arm that used to stand at
# the top of this sub), so every path out of here simply returns: there is
# nothing to re-arm, and the retry for anything that fails is the next finished
# scan or the button (§14.2 as §15.15 sharpens it).
sub _syncTick {
	# The window closes whatever this tick decides. The next rescan-done opens a
	# new one starting where this one ended.
	$windowOpen = 0;

	my $token = $prefs->get('discogsToken');

	if ( !defined $token || $token eq '' ) {
		main::INFOLOG && $log->is_info
			&& $log->info('no Discogs token configured; skipping collection sync');

		return;
	}

	# The scan already synced (decisions §15.18 part 8). Exact, not a time
	# window after the fact: the scan-time sync runs at importer weight 130 and
	# is followed by the artwork importers, the precache and optimizeDB
	# (Slim/Music/Import.pm:462-484), an unbounded tail, so "the marker is less
	# than N seconds old" would be a guess that fails on exactly the large
	# libraries that need it. Instead: a marker written BETWEEN the previous
	# scan's end and this one's is one written during this scan.
	#
	# `source` is load-bearing. A manual sync pressed during the scan, or between
	# scans, also lands inside that window - and it derived ownership for the
	# library as it was BEFORE this scan wrote its albums, so it must not
	# suppress the fallback. Only a 'scan' marker does.
	#
	# Failure bias, chosen deliberately: a needless sync costs four requests and
	# ~2.7 s; a wrong skip costs stale badges until the next scan. Every
	# uncertain case - no marker, a server marker, a marker outside the window,
	# a database that is not ready - falls through and syncs.
	#
	# After the token check, because with no token there is nothing to decide;
	# before the rejection pause, because a healthy scan-time sync should not
	# consult a pause that governs only this path (§15.18 part 4).
	my $marker = Plugins::SqueezeWax::Schema->syncState;

	if (   $marker
		&& ( $marker->{source} || '' ) eq 'scan'
		&& $marker->{last_synced} > $prevRescanDone
		&& $marker->{last_synced} <= $lastRescanDone )
	{
		main::INFOLOG && $log->is_info
			&& $log->info( 'the scan already synced the collection (marker at '
				. $marker->{last_synced} . '); skipping the fallback sync' );

		# The derive job still runs (build-order step 8c). A DEVIATION from the
		# step 8c plan, which says the job is triggered "from Plugin::_syncDone on
		# success, and from nothing else" - taken because on this project's own
		# reference server that trigger would never fire. The scan-time sync
		# (§15.18) writes a 'scan' marker, the skip above therefore returns, and
		# _syncDone is never reached. Group A would have shipped as dead as the
		# master arm it exists to wake up, which is the same defect §15.19
		# describes and the same shape of mistake.
		#
		# The plan's INTENT is honoured exactly: a sync has just completed, the
		# collection is what makes ownership interesting, and there is no interval
		# and no startup run (§15.15 part 1). What is triggered is the completion
		# of a sync; that this one completed in the scanner rather than here is not
		# a difference the job can see, and the collection it needs is not the
		# collection - it is the library's own release ids.
		_deriveMasters();

		return;
	}

	# Paused, not deferred and not retried: Discogs has rejected this token, and
	# nothing a scan does changes that (§15.15 part 2). Logged once, at info -
	# the error that caused the pause was already logged at error, and repeating
	# it at every scan would bury it. The button is the remedy and always runs.
	# The pause is this fallback's alone; the scan-time sync has nowhere to keep
	# one and retries at every scan (§15.18 part 4).
	require Plugins::SqueezeWax::API::Async;

	if ( Plugins::SqueezeWax::API::Async->tokenRejected ) {
		# Marked unconditionally, logged conditionally: whether this skip is the
		# first one is a fact about the pause, not about the log level.
		my $first = Plugins::SqueezeWax::API::Async->noteSkipped;

		main::INFOLOG && $first && $log->is_info
			&& $log->info('Discogs rejected the token; skipping the scan-triggered '
				. 'sync until the token changes or a manual sync succeeds');

		return;
	}

	# Deferred, not refused: the button refuses during a scan because a user is
	# waiting for an answer, and this one has nobody waiting.
	#
	# Its safety net used to be the interval. It is now the scan itself: this
	# tick fires DEBOUNCE_AFTER_RESCAN after a ['rescan','done'], so reaching it
	# while a scan is running means a NEW scan started inside that window - and
	# that scan ends in its own ['rescan','done'], which arms a fresh tick.
	# Dropping this one loses nothing.
	if ( Slim::Music::Import->stillScanning ) {
		main::INFOLOG && $log->is_info
			&& $log->info('library scan in progress; deferring collection sync');

		return;
	}

	Plugins::SqueezeWax::API::Async->sync( $token, \&_syncDone );

	return;
}

# §14.2's three levels, decided here because this is the caller that knows the
# sync was unattended: a rejected token is an error that will not fix itself and
# that every future tick will hit; anything else is transient and gets a warning;
# "already running" is not a failure at all, just a trigger that lost the race.
sub _syncDone {
	my ($result) = @_;

	if ( $result->{ok} ) {
		main::INFOLOG && $log->is_info
			&& $log->info( "collection sync complete: $result->{items} items in "
				. "$result->{requests} requests" );

		_deriveMasters();

		return;
	}

	my $error = $result->{error} || 'unknown';

	return if $error eq 'already_running';

	if ( $error eq 'unauthorized' ) {
		$log->error('collection sync failed: Discogs rejected the token');

		return;
	}

	# Not a failure either: the sync itself worked, and the ownership pass
	# declined because a scan started under it (decisions §15.13 part 1). The
	# collection was discarded, so there is nothing to retry FROM - but the
	# scan that caused this ends in a ['rescan','done'], which re-arms a fresh
	# sync through _scheduleSync. That is §15.2 obligation 1's retry, and it
	# needs no mechanism of its own.
	if ( $error eq 'refused' ) {
		main::INFOLOG && $log->is_info
			&& $log->info('ownership pass declined - a scan is running; '
				. 'the next rescan-done will bring another sync');

		return;
	}

	$log->warn("collection sync failed: $error");

	return;
}

# Start the master derive job (build-order step 8c, decisions §15.22), from the
# two places a collection sync has just finished successfully as far as this
# process is concerned: _syncDone above, and _syncTick's "the scan already
# synced" skip.
#
# ON SUCCESS AND NOTHING ELSE, which is what keeps §15.15 part 1 intact: no
# startup run, no interval, and a settled library makes the job issue one query
# and return. The manual button is deliberately NOT a trigger - it has a user
# waiting on a page, and its callback lives in Settings.pm - so pressing it while
# a derive run is in flight is the case the job's yielding exists for rather than
# a second trigger.
#
# Required lazily, as the sync is: Derive.pm pulls in SimpleAsyncHTTP and Timers,
# and a server with no token never reaches here at all.
#
# It decides for itself whether there is anything to do. Nothing here tests that,
# deliberately: a caller that guessed would be a second copy of the selection rule
# (§15.22's four states), and the one that mattered would go stale.
sub _deriveMasters {
	require Plugins::SqueezeWax::Derive;

	Plugins::SqueezeWax::Derive->arm;

	return;
}

1;
