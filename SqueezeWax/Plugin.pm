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
# discogsLastSynced is 0, not undef, so "never synced" is a value the template
# can test rather than a missing key.
$prefs->init({
	discogsLastSynced    => 0,
	discogsLastSyncItems => undef,
	discogsLastSyncError => '',

	# A development aid, not a feature: a comma-separated list of Discogs
	# release ids that API/Async.pm's _testFilter hides from the ownership
	# pass, so "a record left the collection" can be exercised without
	# altering anyone's collection. Empty on every normal install, no field on
	# the settings page, and every sync warns while it is set. Documented in
	# docs/dev-repo-workflow.md.
	discogsTestExcludeReleases => '',
});

# The interval field is user-editable, so it needs a floor: a typo of 60 would
# poll hourly, and 0 or a non-integer would make the timer arithmetic nonsense.
# 3600 is the low bound rather than something smaller because nothing about a
# record collection changes faster than that, and the Discogs budget is shared
# with every other thing the plugin will eventually do. intlimit is core's own
# validator (Slim/Utils/Prefs/Namespace.pm:114-135, the same call shape
# Slim/Utils/Prefs.pm:317-322 uses for httpport and bufferSecs); an out-of-range
# value is refused and the previous one kept.
# Long enough to absorb a duplicate ['rescan','done'] and let LMS settle after a
# scan, short enough that a user who rescans to pick up a new record does not
# wait noticeably for the badge. Not a measured figure.
use constant DEBOUNCE_AFTER_RESCAN => 60;

sub initPlugin {
	my $class = shift;

	# Same rationale as Importer::initPlugin: proof this entry point ran.
	main::INFOLOG && $log->is_info
		&& $log->info( 'Plugin loaded (' . ( main::SCANNER ? 'scanner' : 'server' ) . ' process)' );

	Plugins::SqueezeWax::Schema->init();

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

# One of §13.7's two triggers, as §15.15 part 1 leaves them. The other is the
# settings-page button, which lives in Settings.pm because that is the only one
# with a user attached; this one is here because it has to run on a headless
# server, which never loads Settings.pm (decisions §15.12 part 3).
#
# Nothing here decides whether to sync. API/Async.pm's guard does, so a rescan
# finishing while a manual sync is already running costs one sync, not two.
#
# NO TIMER IS ARMED HERE. There is no startup sync and no interval (§15.15 part
# 1): a fresh install syncs for the first time at the first finished scan, or
# when the user presses the button. That is a recorded consequence, not an
# oversight - see TODO.md, 2026-09-22.
sub _initSync {
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
sub _rescanDone {
	main::INFOLOG && $log->is_info
		&& $log->info('library scan finished; scheduling a collection sync');

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

# The debounced tick. Reached only from _rescanDone (§15.15 part 1 removed the
# interval re-arm that used to stand at the top of this sub), so every path out
# of here simply returns: there is nothing to re-arm, and the retry for anything
# that fails is the next finished scan or the button (§14.2 as §15.15 sharpens
# it).
sub _syncTick {
	my $token = $prefs->get('discogsToken');

	if ( !defined $token || $token eq '' ) {
		main::INFOLOG && $log->is_info
			&& $log->info('no Discogs token configured; skipping collection sync');

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

	require Plugins::SqueezeWax::API::Async;

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

1;
